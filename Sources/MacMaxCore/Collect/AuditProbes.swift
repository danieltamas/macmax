import Foundation

/// The readings an audit takes that the per-tick collectors do not: zombies, kernel_task and daemon memory from
/// one `top` sample, the Docker VM and containers, report counts, launch items and the Homebrew prefixes. Stock
/// tools only, no sudo, every command under a time limit. A probe that cannot answer is `failed` with the reason;
/// only a thing this Mac lacks is `unavailable`.
public struct AuditProbes: Sendable {
    private static let daemons = ["fseventsd", "WindowServer", "Finder", "mds_stores"]
    private static let probeLimit = Duration.seconds(15)
    private let runner = ProcessRunner()

    public init() {}

    public func run(processes: Reading<[ProcessSample]>, now: Date = Date()) async -> AuditProbeResults {
        // Without the process list there are no daemon or VM pids, and "no daemon found" or "no VM" must not read as
        // healthy: those probes fail with the list's reason, and only pid 0 (always known) is sampled.
        let list = processes.value
        // A path that failed to read could hide the Docker VM, so "no VM" is not a safe answer then.
        let pathProblem = list?.compactMap { process -> String? in
            if case let .failed(reason) = process.path { return reason }
            return nil
        }.first
        let daemonPids = Dictionary(grouping: (list ?? []).filter { Self.daemons.contains($0.name) }, by: \.name)
            .mapValues { $0.map(\.identity.pid) }
        let vmPids = (list ?? []).filter {
            $0.path.value?.contains("com.apple.Virtualization") == true || $0.name.hasPrefix("com.apple.Virtualization")
        }.map(\.identity.pid)
        async let zombies = countZombies(at: now)
        async let top = sampleTop(pids: [0] + daemonPids.values.flatMap { $0 } + vmPids, at: now)
        let containerFailure = list == nil ? (processes.problem ?? "process list not collected") : pathProblem
        let vmRunning = !vmPids.isEmpty
        async let containers = containerReading(failure: containerFailure, vmRunning: vmRunning, at: now)
        let rows = await top
        let listProblem = processes.problem ?? "process list not collected"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let reports = [home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
                       URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true)]
        return AuditProbeResults(
            zombies: await zombies,
            kernelTaskCPU: kernelTaskCPU(rows, at: now),
            daemonResidentMB: list == nil ? .failed(reason: listProblem) : daemonMemory(rows, pids: daemonPids, at: now),
            dockerVMCompressedGB: list == nil ? .failed(reason: listProblem) : pathProblem.map { .failed(reason: $0) } ?? vmCompressed(rows, vmPids: vmPids, at: now),
            containerCPU: await containers,
            crashReports7d: ReportCounter.count(in: reports, matching: { _ in true }, modifiedWithinDays: 7, now: now, at: now),
            jetsam7d: ReportCounter.count(in: [reports[1]], matching: { $0.hasPrefix("JetsamEvent-") },
                                          modifiedWithinDays: 7, now: now, at: now),
            launchItems: launchItems(at: now),
            appleSilicon: appleSilicon(at: now),
            brew: brew(at: now))
    }

    // MARK: - Processes

    private func countZombies(at: Date) async -> Reading<Int> {
        switch await output("/bin/ps", ["-Axo", "stat="], timeout: Self.probeLimit) {
        case let .success(text):
            return .ok(text.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Z") }.count,
                       source: "ps -Axo stat", at: at)
        case let .failure(reason): return .failed(reason: reason)
        }
    }

    /// One `top` run covering kernel_task, the named daemons and the Docker VM; its second sample carries real CPU.
    private func sampleTop(pids: [Int32], at: Date) async -> Reading<[TopProcessRow]> {
        let arguments = ["-l", "2", "-s", "3", "-stats", "pid,command,mem,cmprs,cpu"] + pids.flatMap { ["-pid", String($0)] }
        switch await output("/usr/bin/top", arguments, timeout: .seconds(25)) {
        case let .success(text): return TopParser.parse(text, at: at)
        case let .failure(reason): return .failed(reason: reason)
        }
    }

    private func kernelTaskCPU(_ rows: Reading<[TopProcessRow]>, at: Date) -> Reading<Double> {
        switch rows {
        case let .ok(rows, _, _):
            guard let cpu = rows.first(where: { $0.pid == 0 })?.cpuPercent else { return .failed(reason: "top did not report kernel_task") }
            return .ok(cpu, source: "top", at: at)
        case let .unavailable(reason): return .unavailable(reason: reason)
        case let .failed(reason): return .failed(reason: reason)
        }
    }

    private func daemonMemory(_ rows: Reading<[TopProcessRow]>, pids: [String: [Int32]], at: Date) -> Reading<[NamedValue]> {
        switch rows {
        case let .ok(rows, _, _):
            var values: [NamedValue] = []
            for (name, daemonPids) in pids.sorted(by: { $0.key < $1.key }) {
                let found = rows.filter { daemonPids.contains($0.pid) }
                guard found.count == daemonPids.count, found.allSatisfy({ $0.memoryBytes != nil }) else {
                    return .failed(reason: "top did not report the memory of \(name)")
                }
                values.append(NamedValue(name: name, value: found.reduce(0.0) { $0 + Double($1.memoryBytes ?? 0) / 1_048_576 }.rounded(.down)))
            }
            return .ok(values, source: "top", at: at)
        case let .unavailable(reason): return .unavailable(reason: reason)
        case let .failed(reason): return .failed(reason: reason)
        }
    }

    private func vmCompressed(_ rows: Reading<[TopProcessRow]>, vmPids: [Int32], at: Date) -> Reading<Double> {
        guard !vmPids.isEmpty else { return .unavailable(reason: "the Docker VM is not running") }
        switch rows {
        case let .ok(rows, _, _):
            // Every VM process must report its compressed memory: a partial sum would read below the threshold.
            let vmRows = rows.filter { vmPids.contains($0.pid) }
            guard !vmRows.isEmpty, vmRows.count == vmPids.count, vmRows.allSatisfy({ $0.compressedBytes != nil }) else {
                return .failed(reason: "top did not report the compressed memory of the Docker VM")
            }
            return .ok(vmRows.reduce(0.0) { $0 + Double($1.compressedBytes ?? 0) } / 1_073_741_824, source: "top", at: at)
        case let .unavailable(reason): return .unavailable(reason: reason)
        case let .failed(reason): return .failed(reason: reason)
        }
    }

    // MARK: - Docker

    private func containerReading(failure: String?, vmRunning: Bool, at: Date) async -> Reading<[NamedValue]> {
        if let failure { return .failed(reason: failure) }
        return await dockerContainers(vmRunning: vmRunning, at: at)
    }

    private func dockerContainers(vmRunning: Bool, at: Date) async -> Reading<[NamedValue]> {
        guard let docker = Executables.resolve("docker") else { return .unavailable(reason: "Docker not installed") }
        let result = await output(docker, ["stats", "--no-stream", "--format", "{{.Name}}\t{{.CPUPerc}}"],
                                  timeout: Self.probeLimit, environment: ["PATH": Executables.searchPath(for: docker)])
        switch result {
        case let .success(text):
            var values: [NamedValue] = []
            for line in text.split(separator: "\n") {
                let columns = line.split(separator: "\t")
                guard columns.count == 2, columns[1].hasSuffix("%"), let cpu = Double(columns[1].dropLast()),
                      cpu.isFinite, cpu >= 0 else {
                    return .failed(reason: "docker stats printed a line that is not understood")
                }
                values.append(NamedValue(name: String(columns[0]), value: cpu))
            }
            return .ok(values, source: "docker stats", at: at)
        case let .failure(reason):
            // Docker installed but its engine is not running is the normal state of a Mac with Docker Desktop closed.
            return vmRunning ? .failed(reason: reason) : .unavailable(reason: "Docker is not running")
        }
    }

    // MARK: - Files and platform

    private func launchItems(at: Date) -> Reading<Int> {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directories = ["/Library/LaunchAgents", "/Library/LaunchDaemons", home.appendingPathComponent("Library/LaunchAgents").path]
        var total = 0
        for directory in directories {
            do { guard try ReportCounter.exists(directory) else { continue } } catch {
                return .failed(reason: "cannot look up \(URL(fileURLWithPath: directory).lastPathComponent)")
            }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                return .failed(reason: "cannot read \(URL(fileURLWithPath: directory).lastPathComponent)")
            }
            total += names.filter { $0.hasSuffix(".plist") }.count
        }
        return .ok(total, source: "launch directories", at: at)
    }

    private func appleSilicon(at: Date) -> Reading<Bool> {
        // hw.optional.arm64 exists (as 1) only on Apple Silicon and an Intel kernel has no such key, so a failed read
        // cannot be told from the Intel answer; the worst outcome is that brew_under_rosetta stays quiet.
        .ok(Sysctl.int32("hw.optional.arm64") == 1, source: "sysctl hw.optional.arm64", at: at)
    }

    /// Homebrew under /usr/local on an Apple Silicon Mac can only be the Rosetta (x86_64) install: native Homebrew
    /// lives in /opt/homebrew.
    private func brew(at: Date) -> Reading<BrewInstalls> {
        let files = FileManager.default
        return .ok(BrewInstalls(intelPrefixIsX86: files.isExecutableFile(atPath: "/usr/local/bin/brew"),
                                nativePrefixPresent: files.isExecutableFile(atPath: "/opt/homebrew/bin/brew")),
                   source: "brew prefixes", at: at)
    }

    // MARK: - Running tools

    private enum Output { case success(String), failure(String) }

    private func output(_ executable: String, _ arguments: [String], timeout: Duration,
                        environment: [String: String] = [:]) async -> Output {
        do {
            // C locale: a decimal comma would make every number the parsers read look malformed.
            let result = try await runner.run(executable, arguments, environment: environment.merging(["LC_ALL": "C"]) { $1 },
                                              timeout: timeout)
            guard result.status == 0 else {
                let detail = result.stderr.split(separator: "\n").first.map { Redaction.sanitizeText(String($0.prefix(120))) } ?? "exit \(result.status)"
                return .failure("\(URL(fileURLWithPath: executable).lastPathComponent) failed: \(detail)")
            }
            return .success(String(decoding: result.stdout, as: UTF8.self))
        } catch ProcessRunner.Failure.timedOut {
            return .failure("\(URL(fileURLWithPath: executable).lastPathComponent) did not answer in time")
        } catch {
            return .failure("\(URL(fileURLWithPath: executable).lastPathComponent) could not run")
        }
    }
}
