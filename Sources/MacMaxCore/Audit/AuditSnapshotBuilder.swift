import Foundation

public enum AuditSnapshotBuilder {
    private static let gibibyte = Double(1 << 30)
    private static let microsecondsPerDay = 86_400_000_000.0

    /// Reduces collector output to the rounded values the rules compare (docs/RULES.md, "Building the snapshot").
    /// Pure: the same inputs give the same snapshot. A reading that is not ok keeps its kind and reason.
    public static func build(_ inputs: AuditInputs) -> AuditSnapshot {
        var snapshot = AuditSnapshot()
        snapshot.timestamp = Int64(saturatingInt(inputs.now.timeIntervalSince1970.rounded(.down)))
        applySystem(inputs.system, to: &snapshot)
        applyProcesses(inputs, to: &snapshot)
        applyIdentity(inputs, to: &snapshot)
        let probes = inputs.probes
        snapshot.zombies = Measure(probes.zombies)
        snapshot.kernelTaskCPU = Measure(probes.kernelTaskCPU)
        snapshot.daemonResidentMB = Measure(probes.daemonResidentMB.map(sanitized))
        snapshot.dockerVMCompressedGB = Measure(probes.dockerVMCompressedGB)
        snapshot.containerCPU = Measure(probes.containerCPU.map(sanitized))
        snapshot.crashReports7d = Measure(probes.crashReports7d)
        snapshot.jetsam7d = Measure(probes.jetsam7d)
        snapshot.launchItems = Measure(probes.launchItems)
        snapshot.appleSilicon = Measure(probes.appleSilicon)
        snapshot.brewInstalls = Measure(probes.brew)
        snapshot.vpnShouldBeOn = inputs.vpnShouldBeOn
        return snapshot
    }

    // MARK: - System

    private static func applySystem(_ system: SystemSnapshot, to snapshot: inout AuditSnapshot) {
        snapshot.uptimeDays = derive(system.uptimeSeconds) { .success(saturatingInt(($0 / 86_400).rounded(.down))) }
        snapshot.load5 = Measure(system.load.map(\.five))
        snapshot.coreCount = Measure(system.coreCount)
        snapshot.ramBytes = Measure(system.memory.map(\.physicalBytes))
        snapshot.cpuIdlePercent = Measure(system.cpu.map(\.idlePercent))
        snapshot.swapUsedGB = Measure(system.swap.map { rounded(Double($0.usedBytes) / gibibyte, decimals: 1) })
        snapshot.swapInsPerSecond = Measure(system.swapInsPerSecond)
        snapshot.compressorPercent = derive(system.memory) { memory in
            memory.physicalBytes == 0 ? .failure("physical memory is zero")
                : percent(Double(memory.compressedBytes) / Double(memory.physicalBytes) * 100, "compressed memory")
        }
        snapshot.memoryLevel = Measure(system.pressure.map(\.availablePercent))
        snapshot.diskFreePercent = derive(system.diskSpace) { disk in
            disk.totalBytes == 0 ? .failure("disk size is zero")
                : percent(Double(disk.freeBytes) / Double(disk.totalBytes) * 100, "free disk space")
        }
        snapshot.diskIOPS = Measure(system.diskIO.map { $0.readOperationsPerSecond + $0.writeOperationsPerSecond })
        snapshot.cpuSpeedLimit = Measure(system.thermal.map { $0.cpuSpeedLimitPercent ?? 100 })
    }

    // MARK: - Processes

    private struct AppTotals {
        var name: String
        var footprint: UInt64 = 0
        var cpu = 0.0
        var cpuKnown = true
    }

    private static func applyProcesses(_ inputs: AuditInputs, to snapshot: inout AuditSnapshot) {
        guard case let .ok(processes, _, _) = inputs.processes else {
            let reason = inputs.processes.problem ?? "process list not collected"
            snapshot.processCount = .failed(reason)
            snapshot.chromeProcesses = .failed(reason)
            snapshot.claudeSessionAgesDays = .failed(reason)
            snapshot.mcpSidecars = .failed(reason)
            snapshot.apps = .failed(reason)
            snapshot.translatedProcesses = .failed(reason)
            snapshot.appGrowth = Measure(inputs.processes.map { _ in [AppGrowth]() })
            return
        }
        let nowMicroseconds = inputs.now.timeIntervalSince1970 * 1_000_000
        snapshot.processCount = .ok(processes.count)
        // A path that failed to read (as opposed to being withheld) could hide a Chrome process behind its name.
        let pathProblem = processes.compactMap { process -> String? in
            if case let .failed(reason) = process.path { return reason }
            return nil
        }.first
        if let reason = pathProblem {
            snapshot.chromeProcesses = .failed(reason)
        } else {
            snapshot.chromeProcesses = .ok(processes.filter { ($0.path.value ?? $0.name).contains("Google Chrome") }.count)
        }
        // Claude detection falls back to the name when the path is withheld, so a failed path makes it unknown too.
        snapshot.claudeSessionAgesDays = pathProblem.map { .failed($0) } ?? .ok(processes.filter { isClaude($0) }.map {
            max(0, saturatingInt(((nowMicroseconds - Double($0.identity.startTimeMicroseconds)) / microsecondsPerDay).rounded(.down)))
        })
        // The script's own list of MCP sidecar command lines.
        if let reason = processes.compactMap({ process -> String? in
            if case let .failed(reason) = process.argv { return reason }
            return nil
        }).first {
            snapshot.mcpSidecars = .failed(reason)
        } else {
            snapshot.mcpSidecars = .ok(processes.filter { process in
                process.argv.value.map { TidyAnalysis.isMCPSidecar($0.joined(separator: " ")) } ?? false
            }.count)
        }

        // A footprint that should have been readable and was not would understate every app it belongs to; a
        // process the kernel withholds (unavailable) simply adds nothing.
        let unreadableFootprint = processes.compactMap { process -> String? in
            if case let .failed(reason) = process.footprintBytes { return reason }
            // A path that failed to read would split one app's helpers into separate groups.
            if case let .failed(reason) = process.path { return reason }
            return nil
        }.first
        let keys = AppGrouping.group(processes.map {
            ProcessRow(pid: $0.identity.pid, parentPid: $0.parentPid, path: $0.path.value, name: $0.name)
        })
        var totals: [String: AppTotals] = [:]
        for process in processes {
            guard let key = keys[process.identity.pid] else { continue }
            var total = totals[key.id] ?? AppTotals(name: Redaction.sanitizeText(key.name))
            let (sum, overflow) = total.footprint.addingReportingOverflow(process.footprintBytes.value ?? 0)
            total.footprint = overflow ? UInt64.max : sum
            if let cpu = process.cpuPercent.value { total.cpu += cpu } else { total.cpuKnown = false }
            totals[key.id] = total
        }
        let ordered = totals.sorted { ($1.value.footprint, $0.value.name, $0.key) < ($0.value.footprint, $1.value.name, $1.key) }
        if let unreadableFootprint {
            snapshot.apps = .failed(unreadableFootprint)
            snapshot.appGrowth = .failed(unreadableFootprint)
        } else {
            snapshot.apps = .ok(ordered.map { AppFootprint(name: $0.value.name, footprintBytes: $0.value.footprint) })
            snapshot.appGrowth = growth(ordered, old: inputs.footprintOneHourAgo)
        }

        snapshot.translatedProcesses = translated(processes, keys: keys, history: inputs.cpuHistory)
    }

    /// Claude Code replaces its binary when it updates, and a running session of the old one has no readable path
    /// (`proc_pidpath` fails with ENOENT); its kernel command name is "claude" or the version number.
    private static func isClaude(_ process: ProcessSample) -> Bool {
        if let path = process.path.value { return path.contains(/\/claude$|^claude$|\/claude\/versions\/[0-9.]+$/) }
        return process.name.contains(/^claude$|^[0-9]+\.[0-9]+\.[0-9]+$/)
    }

    private static func translated(_ processes: [ProcessSample], keys: [Int32: AppKey],
                                   history: [ProcessIdentity: [Double]]) -> Measure<[TranslatedProcess]> {
        // A translation flag that should have been readable and was not could hide a Rosetta process.
        if let reason = processes.compactMap({ process -> String? in
            if case let .failed(reason) = process.isTranslated { return reason }
            return nil
        }).first { return .failed(reason) }
        let found = processes.filter { $0.isTranslated.value == true }
        if found.isEmpty { return .ok([]) }
        if history.isEmpty { return .failed("CPU history not collected") }
        return .ok(found.map { process in
            TranslatedProcess(name: Redaction.sanitizeText(process.name), app: Redaction.sanitizeText(keys[process.identity.pid]?.name ?? process.name),
                              cpuSamples: Array((history[process.identity] ?? []).suffix(3)))
        })
    }

    /// Apps present now and an hour ago; an app with a process whose CPU is unknown is left out, because a
    /// growth that cannot be called idle must not be reported.
    private static func growth(_ apps: [(key: String, value: AppTotals)],
                               old: Reading<[String: UInt64]>) -> Measure<[AppGrowth]> {
        derive(old) { before in
            .success(apps.compactMap { app in
                guard app.value.cpuKnown, let was = before[app.key] else { return nil }
                return AppGrowth(name: app.value.name, footprintBytes: app.value.footprint,
                                 footprintOneHourAgoBytes: was, cpuPercent: app.value.cpu)
            }.sorted { ($0.name, $0.footprintBytes) < ($1.name, $1.footprintBytes) })
        }
    }

    // MARK: - Identity

    private static func applyIdentity(_ inputs: AuditInputs, to snapshot: inout AuditSnapshot) {
        if let identity = inputs.identity {
            snapshot.identity = derive(identity.vpnServices) { services in
                .success(IdentityFacts(verdict: identity.verdict.rawValue,
                                       vpnConnected: services.contains { $0.state == .connected },
                                       publicIP: identity.publicIP.value?.address,
                                       publicCountry: identity.publicIP.value?.country))
            }
        } else {
            snapshot.identity = .failed("network identity not collected")
        }
        // Collector reasons can name an executable by its absolute path; only its name belongs in the snapshot.
        if case let .failed(reason) = snapshot.identity {
            snapshot.identity = .failed(reason.replacing(/\/[^\s:]*\/([^\s\/:]+)/) { String($0.output.1) })
        }
        guard let previous = inputs.previous else {
            snapshot.previousIdentity = .unavailable("first audit")
            return
        }
        if case let .failed(reason) = previous.identity {
            snapshot.previousIdentity = .failed("the previous audit could not read the identity: \(reason)")
        } else if let facts = previous.identity.value, let address = facts.publicIP {
            snapshot.previousIdentity = .ok(PreviousIdentity(publicIP: address, publicCountry: facts.publicCountry))
        } else {
            snapshot.previousIdentity = .unavailable("the previous audit had no public IP")
        }
    }

    // MARK: - Helpers

    /// Int(_:) traps on NaN and out-of-range values; a malformed reading must not crash an audit.
    private static func saturatingInt(_ value: Double) -> Int {
        guard !value.isNaN else { return 0 }
        return value >= Double(Int.max) ? Int.max : value <= Double(Int.min) ? Int.min : Int(value)
    }

    /// A percentage that a malformed reading could push out of Int's range; it fails instead of trapping.
    private static func percent(_ value: Double, _ what: String) -> Result<Int, DeriveFailure> {
        let result = rounded(value, decimals: 0)
        guard result.isFinite, abs(result) < 1_000_000 else { return .failure("\(what) is out of range") }
        return .success(Int(result))
    }

    private static func sanitized(_ values: [NamedValue]) -> [NamedValue] {
        values.map { NamedValue(name: Redaction.sanitizeText($0.name), value: $0.value) }
    }

    /// A reading's value through `transform`, or the reading's own kind and reason when it has none.
    private static func derive<T: Sendable, U: Sendable & Codable & Equatable>(
        _ reading: Reading<T>, _ transform: (T) -> Result<U, DeriveFailure>) -> Measure<U> {
        switch reading {
        case let .ok(value, _, _):
            switch transform(value) {
            case let .success(result): .ok(result)
            case let .failure(failure): .failed(failure.reason)
            }
        case let .unavailable(reason): .unavailable(reason)
        case let .failed(reason): .failed(reason)
        }
    }

    /// Ties to even, after snapping to six decimals: a value a few bytes short of a tie (byte counts are whole
    /// numbers) still counts as the tie, the way the script's decimal text would.
    private static func rounded(_ value: Double, decimals: Int) -> Double {
        let scale = pow(10, Double(decimals))
        let snapped = (value * 1_000_000).rounded() / 1_000_000
        return (snapped * scale).rounded(.toNearestOrEven) / scale
    }
}

struct DeriveFailure: Error {
    let reason: String
}

extension Result where Failure == DeriveFailure {
    static func failure(_ reason: String) -> Self { .failure(DeriveFailure(reason: reason)) }
}
