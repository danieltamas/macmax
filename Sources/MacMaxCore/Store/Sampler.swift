import Foundation
import os

/// The sampler periods the settings allow.
public enum SamplerInterval: Int, Sendable, CaseIterable {
    case five = 5, ten = 10, thirty = 30, sixty = 60

    public init?(seconds: Int) { self.init(rawValue: seconds) }
}

/// Collects one snapshot per tick and writes its rows: one system row, the top 40 apps, the top 30 processes.
/// Rates need two samples, so the first tick stores NULL for them (never zero).
public actor Sampler {
    private static let log = Logger(subsystem: "ro.danieltamas.macmax", category: "sampler")

    private let database: Database
    private let system = SystemCollector()
    private let processes = ProcessCollector()
    private let network = NetworkCollector()
    private var diskRates = DiskRateTracker()
    private var inFlight: Task<TickRows, Error>?
    private var lastTimestamp: Int64 = 0

    public init(database: Database) { self.database = database }

    /// Runs the collectors once, writes the tick and returns what was written.
    /// Ticks queue behind each other: they share the disk-rate state and the network stream.
    public func tick(now: Date = .now) async throws -> TickRows {
        let earlier = inFlight
        let task = Task { () -> TickRows in
            _ = try? await earlier?.value
            try Task.checkCancellation()
            return try await self.collectAndWrite(now: now)
        }
        inFlight = task
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func collectAndWrite(now: Date) async throws -> TickRows {
        let systemSnapshot = await system.collect()
        let processSamples = await processes.collect()
        let samples = processSamples.value ?? []
        let uptime = DispatchTime.now().uptimeNanoseconds
        let networkSnapshot = await network.collect(processes: samples)

        let rates = diskRates.update(
            Dictionary(samples.compactMap { sample -> (ProcessIdentity, ProcessDiskCounters)? in
                guard let read = sample.diskReadBytes.value, let write = sample.diskWriteBytes.value else { return nil }
                return (sample.identity, ProcessDiskCounters(readBytes: read, writeBytes: write))
            }, uniquingKeysWith: { first, _ in first }), uptimeNanoseconds: uptime)
        let perProcessNetwork = networkSnapshot.processes.value ?? [:]
        let groups = AppGrouping.group(samples.map {
            ProcessRow(pid: $0.identity.pid, parentPid: $0.parentPid, path: $0.path.value, name: $0.name)
        })
        let measurements = samples.compactMap { sample -> ProcessMeasurement? in
            guard let app = groups[sample.identity.pid] else { return nil }
            let rate = rates[sample.identity] ?? nil
            let counters = perProcessNetwork[sample.identity]?.value
            return ProcessMeasurement(identity: sample.identity, app: app, name: sample.name, cpu: sample.cpuPercent.value,
                                      footprintBytes: sample.footprintBytes.value, diskReadBps: rate?.readBps,
                                      diskWriteBps: rate?.writeBps, netInBytes: counters?.bytesIn, netOutBytes: counters?.bytesOut)
        }
        // One tick per second: a second tick in the same second would overwrite matching rows and leave stale ones.
        let ts = max(Int64(now.timeIntervalSince1970), lastTimestamp + 1)
        let apps = TickSelection.topApps(TickSelection.aggregate(measurements))
        let rows = TickRows(
            system: Self.systemRow(ts: ts, systemSnapshot, network: networkSnapshot),
            apps: apps.map { Self.appRow(ts: ts, $0) },
            processes: TickSelection.topProcesses(measurements).map {
                ProcSampleRow(ts: ts, pid: $0.identity.pid, startUs: $0.identity.startTimeMicroseconds, appKey: $0.app.id,
                              name: $0.name, cpu: $0.cpu, footprint: $0.footprintBytes.map(Int64.init(clamping:)))
            },
            appInfo: apps.map { AppInfo(appKey: $0.app.id, name: $0.app.name, firstSeen: ts) },
            interfaces: networkSnapshot.interfaces.value ?? [])
        try Task.checkCancellation()
        try await database.write(rows)
        lastTimestamp = ts
        return rows
    }

    /// Ticks until cancelled, on a monotonic clock; a failed tick is logged and the next one still runs.
    public func run(every interval: SamplerInterval) async {
        let clock = ContinuousClock()
        var next = clock.now
        while !Task.isCancelled {
            do { _ = try await tick() } catch { Self.log.error("tick failed: \(error.localizedDescription, privacy: .public)") }
            // A slow tick skips the slots it overran instead of bunching up.
            repeat { next += .seconds(interval.rawValue) } while next < clock.now
            do { try await clock.sleep(until: next) } catch { break }
        }
        await network.stop()
    }

    private static func systemRow(ts: Int64, _ snapshot: SystemSnapshot, network: NetworkSnapshot) -> SystemSampleRow {
        let interfaces = network.interfaces.value
        return SystemSampleRow(
            ts: ts, cpuUser: snapshot.cpu.value?.userPercent, cpuSystem: snapshot.cpu.value?.systemPercent,
            memUsed: snapshot.memory.value.map { Int64(clamping: $0.usedBytes) },
            memCompressed: snapshot.memory.value.map { Int64(clamping: $0.compressedBytes) },
            swapUsed: snapshot.swap.value.map { Int64(clamping: $0.usedBytes) },
            swapinsPerSecond: snapshot.swapInsPerSecond.value, pressureLevel: snapshot.pressure.value?.level.rawValue,
            diskFree: snapshot.diskSpace.value.map { Int64(clamping: $0.freeBytes) },
            diskReadBps: snapshot.diskIO.value?.readBytesPerSecond, diskWriteBps: snapshot.diskIO.value?.writeBytesPerSecond,
            netInBps: interfaces?.reduce(0) { $0 + $1.bytesInPerSecond },
            netOutBps: interfaces?.reduce(0) { $0 + $1.bytesOutPerSecond }, thermal: snapshot.thermal.value?.state.rawValue)
    }

    private static func appRow(ts: Int64, _ app: AppAggregate) -> AppSampleRow {
        AppSampleRow(ts: ts, appKey: app.app.id, cpu: app.cpu, footprint: app.footprintBytes.map(Int64.init(clamping:)),
                     diskReadBps: app.diskReadBps, diskWriteBps: app.diskWriteBps,
                     netInBytes: app.netInBytes.map(Int64.init(clamping:)), netOutBytes: app.netOutBytes.map(Int64.init(clamping:)),
                     procs: app.processCount)
    }
}
