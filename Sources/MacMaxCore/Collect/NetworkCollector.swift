import Foundation

/// Per-process and per-interface traffic. Process rows are matched to identities through the process
/// samples of the same tick. Rates need two readings, so the first `collect` reports them as `unavailable`.
/// One long-lived nettop child is supervised: if it dies, that tick is `failed` and the next tick restarts it.
public actor NetworkCollector {
    private static let nettop = "/usr/bin/nettop"
    private static let timeout = Duration.seconds(5)

    private let stream = NettopStream()
    private let sampleSeconds: Int
    private var tracker = NetworkDeltaTracker()
    private var epoch = 0
    private var inFlight: Task<NetworkSnapshot, Never>?
    private var previousInterfaces: (counters: [String: NetworkCounters], uptime: UInt64)?

    /// `sampleSeconds` is clamped to 1...60: nettop needs a whole positive interval.
    public init(sampleSeconds: Int = 2) { self.sampleSeconds = min(max(sampleSeconds, 1), 60) }

    /// Calls queue behind each other: a collection waits on the stream and updates the delta state, and
    /// two interleaved collections would consume the same block and apply their deltas out of order.
    public func collect(processes: [ProcessSample]) async -> NetworkSnapshot {
        let earlier = inFlight
        let queuedAt = epoch
        let task = Task { () -> NetworkSnapshot in
            await earlier?.value
            // A call queued before `stop()` must not start a new child after it.
            guard await self.epoch == queuedAt else { return NetworkSnapshot.stopped }
            return await self.collectOne(processes: processes)
        }
        inFlight = task
        return await task.value
    }

    private func collectOne(processes: [ProcessSample]) async -> NetworkSnapshot {
        let (perProcess, skipped) = await processReadings(processes, at: Date())
        // Read after the wait for nettop, so the counters and the clock describe the same instant.
        return NetworkSnapshot(processes: perProcess, skippedRows: skipped,
                               interfaces: interfaceReadings(uptime: DispatchTime.now().uptimeNanoseconds, at: Date()))
    }

    /// The sockets of one process, read once on demand (never on every tick).
    public func connections(ofPid pid: Int32) async -> Reading<[NetworkConnection]> {
        guard pid > 0 else { return .failed(reason: "not a process id") }
        switch await run(["-m", "tcp", "-L", "1", "-x", "-n", "-p", String(pid)]) {
        case let .success(text): return NettopConnectionsParser.parse(text)
        case let .failure(reason): return .failed(reason: reason)
        }
    }

    private func processReadings(_ processes: [ProcessSample], at: Date)
        async -> (Reading<[ProcessIdentity: Reading<NetworkCounters>]>, Int) {
        let text: String
        switch await freshBlock() {
        case let .success(output): text = output
        case let .failure(reason): return (.failed(reason: reason), 0)
        }
        guard case let .ok(snapshot, _, _) = NettopParser.parse(text, at: at) else {
            return (.failed(reason: NettopParser.parse(text).problem ?? "nettop output not understood"), 0)
        }
        let identities = Dictionary(processes.map { ($0.identity.pid, $0.identity) }, uniquingKeysWith: { first, _ in first })
        var counters: [ProcessIdentity: NetworkCounters] = [:]
        // A process that ended since the process snapshot has no identity: it is left out, not guessed.
        for row in snapshot.rows {
            if let identity = identities[row.pid] { counters[identity] = NetworkCounters(bytesIn: row.bytesIn, bytesOut: row.bytesOut) }
        }
        let readings = tracker.update(counters, tickMicroseconds: Int64(at.timeIntervalSince1970 * 1_000_000))
        return (.ok(readings, source: "nettop", at: at), snapshot.skippedRows)
    }

    private func interfaceReadings(uptime: UInt64, at: Date) -> Reading<[InterfaceRate]> {
        let current: [String: NetworkCounters]
        switch InterfaceCounters.read(at: at) {
        case let .ok(counters, _, _): current = counters
        case let .unavailable(reason): previousInterfaces = nil; return .unavailable(reason: reason)
        case let .failed(reason): previousInterfaces = nil; return .failed(reason: reason)
        }
        defer { previousInterfaces = (current, uptime) }
        guard let previous = previousInterfaces else {
            return .unavailable(reason: "needs a second reading to compute a rate")
        }
        return InterfaceCounters.rates(from: previous.counters, previousUptimeNanoseconds: previous.uptime,
                                       to: current, currentUptimeNanoseconds: uptime, at: at)
    }

    /// The next nettop block that started after this call, so a transfer that just ended is in it.
    private func freshBlock() async -> Run {
        if !stream.isRunning {
            // A new child counts from zero again: old cumulative counters would read as going backwards.
            tracker = NetworkDeltaTracker()
            do { try stream.start(executable: Self.nettop, sampleSeconds: sampleSeconds) } catch {
                return .failure("nettop did not start: \(error.localizedDescription)")
            }
        }
        let mark = stream.currentSequence
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(sampleSeconds + 4) * 1_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let block = stream.completedBlock(after: mark) { return .success(block) }
            guard stream.isRunning else { return .failure("nettop stopped; it restarts on the next tick") }
            try? await Task.sleep(for: .milliseconds(40))
        }
        stream.stop()
        return .failure("nettop produced no sample in time; it restarts on the next tick")
    }

    /// Ends the nettop child; the next `collect` starts a new one.
    public func stop() {
        epoch += 1
        previousInterfaces = nil
        stream.stop()
    }

    private enum Run { case success(String), failure(String) }

    private func run(_ arguments: [String]) async -> Run {
        do {
            let output = try await ProcessRunner().run(Self.nettop, arguments, timeout: Self.timeout)
            guard output.status == 0 else { return .failure("nettop exited with status \(output.status)") }
            return .success(String(decoding: output.stdout, as: UTF8.self))
        } catch {
            return .failure("nettop did not finish: \(error.localizedDescription)")
        }
    }
}
