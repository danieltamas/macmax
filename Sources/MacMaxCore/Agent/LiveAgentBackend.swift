import Foundation

/// The ten tools over `AgentSources`. Read-only by construction: it holds no handle that can act.
public struct LiveAgentBackend: AgentBackend {
    private let sources: AgentSources

    public init(_ sources: AgentSources) { self.sources = sources }

    public func call(_ tool: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        switch tool {
        case "snapshot": return await snapshot()
        case "top_apps": return await topApps(arguments)
        case "process": return try await process(arguments)
        case "network_usage": return await networkUsage(arguments)
        case "network_identity": return await networkIdentity()
        case "run_audit": return await runAudit()
        case "findings": return try await findings(arguments)
        case "history": return try await history(arguments)
        case "who_held": return try await whoHeld(arguments)
        case "cleanup_preview": return await cleanupPreview()
        default: throw AgentError(message: "unknown tool")
        }
    }

    // MARK: Helpers

    private func int(_ arguments: [String: JSONValue], _ name: String, default fallback: Int) -> Int {
        if case let .int(value)? = arguments[name] { return value }
        return fallback
    }

    private func string(_ arguments: [String: JSONValue], _ name: String) -> String? {
        if case let .string(value)? = arguments[name] { return value }
        return nil
    }

    private func date(_ arguments: [String: JSONValue], _ name: String) throws -> Date? {
        guard let text = string(arguments, name) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let parsed = formatter.date(from: text) ?? fractional.date(from: text) else { throw AgentError(message: "\(name) is not an ISO 8601 time like 2026-10-25T09:00:00Z") }
        return parsed
    }

    private func collected() async -> (processes: Reading<[ProcessSample]>, network: NetworkSnapshot) {
        let processes = await sources.processes()
        return (processes, await sources.network(processes.value ?? []))
    }

    private static func rank(_ apps: [AgentApp], by metric: String) -> [AgentApp] {
        func score(_ app: AgentApp) -> Double {
            switch metric {
            case "memory": app.footprint ?? -1
            case "disk": app.diskRead.map { $0 + (app.diskWrite ?? 0) } ?? -1
            case "network": app.netIn.map { Double($0) + Double(app.netOut ?? 0) } ?? -1
            default: app.cpu ?? -1
            }
        }
        return apps.sorted { (score($1), $0.name, $0.key) < (score($0), $1.name, $1.key) }
    }

    /// A stored-history read: bad arguments stay errors, a database that cannot be read is a failed status, never an empty answer.
    private func stored(_ body: () async throws -> JSONValue) async throws -> JSONValue {
        do { return try await body() } catch let error as AgentError { throw error } catch {
            return .object(["available": .bool(false), "status": .string("failed"), "reason": .string("the history database could not be read")])
        }
    }

    // MARK: Tools

    private func snapshot() async -> JSONValue {
        let system = await sources.system()
        let (processes, network) = await collected()
        let apps = AgentApp.group(processes.value ?? [], network: network)
        let identity = await sources.identity(false)
        let audit = await latestVerdict()
        // A failed process read is the failure, not "no apps".
        func top(_ metric: String) -> JSONValue {
            processes.json { _ in .array(Self.rank(apps, by: metric).prefix(5).map { $0.json(includeProcesses: false) }) }
        }
        let netIn = network.interfaces.value.map { $0.reduce(0) { $0 + $1.bytesInPerSecond } }
        let netOut = network.interfaces.value.map { $0.reduce(0) { $0 + $1.bytesOutPerSecond } }
        let vitals: [String: JSONValue] = [
            "cpu": system.cpu.json { .object(["cpu_pct": AgentJSON.number($0.userPercent + $0.systemPercent)]) },
            "memory": system.memory.json { .object(["used_bytes": .int(Int($0.usedBytes)), "physical_bytes": .int(Int($0.physicalBytes)),
                                                    "compressed_bytes": .int(Int($0.compressedBytes))]) },
            "swap": system.swap.json { .object(["used_bytes": .int(Int($0.usedBytes)), "total_bytes": .int(Int($0.totalBytes))]) },
            "pressure": system.pressure.json { .object(["level": .string("\($0.level)"), "available_pct": .int($0.availablePercent)]) },
            "disk": system.diskSpace.json { .object(["free_bytes": .int(Int($0.freeBytes)), "total_bytes": .int(Int($0.totalBytes))]) },
            "disk_io": system.diskIO.json { .object(["read_bps": AgentJSON.number($0.readBytesPerSecond),
                                                     "write_bps": AgentJSON.number($0.writeBytesPerSecond)]) },
            "network": network.interfaces.json { _ in .object(["in_bps": AgentJSON.number(netIn ?? 0), "out_bps": AgentJSON.number(netOut ?? 0)]) },
            "thermal": system.thermal.json { .object(["state": .string("\($0.state)")]) },
            "uptime": system.uptimeSeconds.json { .object(["seconds": .int(Int($0))]) },
        ]
        return .object(["verdict": audit, "vitals": .object(vitals), "processes": processes.json { .int($0.count) },
                        "top_cpu": top("cpu"), "top_memory": top("memory"), "top_network": top("network"),
                        "identity": Self.identitySummary(identity)])
    }

    /// The newest stored verdict when MacMax keeps history here, else a fresh audit.
    private func latestVerdict() async -> JSONValue {
        if sources.appRunning, let database = sources.database {
            do {
                if let stored = try await database.latestAudit() { return .string(stored.verdict.rawValue) }
            } catch { return AgentJSON.failed("the stored audits could not be read") }
        }
        return .string(await sources.audit().report.verdict.rawValue)
    }

    private static func identitySummary(_ identity: NetworkIdentity) -> JSONValue {
        .object(["verdict": .string(identity.verdict.rawValue),
                 "public_country": identity.publicIP.json { $0.country.map(JSONValue.string) ?? .null },
                 "vpn": identity.vpnServices.json { .array($0.filter { $0.state == .connected }.map { .string($0.label) }) }])
    }

    private func topApps(_ arguments: [String: JSONValue]) async -> JSONValue {
        let metric = string(arguments, "by") ?? "cpu"
        let limit = int(arguments, "limit", default: 10)
        let include = arguments["include_processes"] == .bool(true)
        let (processes, network) = await collected()
        guard let list = processes.value else { return processes.json { _ in .null } }
        let apps = Self.rank(AgentApp.group(list, network: network), by: metric).prefix(limit)
        return .object(["by": .string(metric), "apps": .array(apps.map { $0.json(includeProcesses: include) })])
    }

    private func process(_ arguments: [String: JSONValue]) async throws -> JSONValue {
        guard let pid = Int32(exactly: int(arguments, "pid", default: 0)), pid > 0 else { throw AgentError(message: "pid is not a process id") }
        let (processes, network) = await collected()
        guard let list = processes.value else { return processes.json { _ in .null } }
        guard let sample = list.first(where: { $0.identity.pid == pid }) else {
            return .object(["pid": .int(Int(pid)), "found": .bool(false), "reason": .string("no running process has that pid")])
        }
        let byPid = Dictionary(list.map { ($0.identity.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var chain: [JSONValue] = []
        var parent = byPid[sample.parentPid]
        var seen: Set<Int32> = [pid]
        while let current = parent, chain.count < 8, seen.insert(current.identity.pid).inserted {
            chain.append(.object(["pid": .int(Int(current.identity.pid)), "name": .string(current.name)]))
            parent = byPid[current.parentPid]
        }
        let app = AgentApp.group(list, network: network).first { $0.processes.contains { $0.identity == sample.identity } }
        guard case var .object(fields) = AgentApp.processJSON(sample, detailed: true) else { return .null }
        fields["found"] = .bool(true)
        fields["app_key"] = app.map { .string($0.key) } ?? .null
        fields["app"] = app.map { .string($0.name) } ?? .null
        fields["parent_chain"] = .array(chain)
        fields["open_connections"] = AgentJSON.notRead("connections are not read per process")
        return .object(fields)
    }

    private func networkUsage(_ arguments: [String: JSONValue]) async -> JSONValue {
        let window = string(arguments, "window") ?? "now"
        let limit = int(arguments, "limit", default: 10)
        let (processes, network) = await collected()
        let interfaces = network.interfaces.json { rates in
            .array(rates.map { .object(["name": .string($0.name), "in_bps": AgentJSON.number($0.bytesInPerSecond),
                                        "out_bps": AgentJSON.number($0.bytesOutPerSecond)]) }) }
        var apps: JSONValue
        if window == "now", !network.processes.isOK {
            apps = network.processes.json { _ in .null }
        } else if window == "now" {
            let grouped = AgentApp.group(processes.value ?? [], network: network).filter { $0.netIn != nil }
            let top = grouped.sorted { (($1.netIn ?? 0) &+ ($1.netOut ?? 0), $0.name) < (($0.netIn ?? 0) &+ ($0.netOut ?? 0), $1.name) }.prefix(limit)
            apps = processes.json { _ in .array(top.map { .object(["app_key": .string($0.key), "name": .string($0.name),
                                                                    "bytes_in": .int(Int($0.netIn ?? 0)), "bytes_out": .int(Int($0.netOut ?? 0))]) }) }
        } else if sources.appRunning, let database = sources.database {
            let since = Int64(sources.now().timeIntervalSince1970) - (window == "1h" ? 3_600 : 86_400)
            do {
                apps = .array(try await database.appTraffic(since: since, limit: limit).map {
                    .object(["app_key": .string($0.appKey), "name": .string($0.name), "bytes_in": .int(Int($0.bytesIn)), "bytes_out": .int(Int($0.bytesOut))]) })
            } catch { apps = .object(["status": .string("failed"), "reason": .string("the history could not be read")]) }
        } else {
            apps = AgentJSON.notRunning()
        }
        return .object(["window": .string(window), "apps": apps, "interfaces": interfaces])
    }

    private func networkIdentity() async -> JSONValue {
        let identity = await sources.identity(true)
        var lastChange: JSONValue = .null
        if let database = sources.database {
            do {
                if let row = try await database.identityChanges(limit: 1).first { lastChange = AgentJSON.time(seconds: row.ts) }
            } catch { lastChange = AgentJSON.failed("the identity history could not be read") }
        }
        return .object([
            "verdict": .string(identity.verdict.rawValue),
            "public_ip": identity.publicIP.json { .string($0.address) },
            "public_country": identity.publicIP.json { $0.country.map(JSONValue.string) ?? .null },
            "isp_ip": identity.ispIP.json { .string($0.address) },
            "isp_country": identity.ispIP.json { $0.country.map(JSONValue.string) ?? .null },
            "vpn_services": identity.vpnServices.json { services in
                .array(services.map { .object(["name": .string($0.label), "state": .string($0.state.rawValue),
                                               "tunnel": $0.tunnel.map(JSONValue.string) ?? .null]) }) },
            "route_via_tunnel": identity.defaultRoute.json { .bool($0.isTunnel) },
            "route_interface": identity.defaultRoute.json { .string($0.interface) },
            "last_change": lastChange,
        ])
    }

    private static func findingJSON(_ finding: Finding, at: Int64? = nil) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(finding.ruleID), "severity": .string(finding.severity.rawValue), "title": .string(finding.title),
            "evidence": .array(finding.evidence.map { .object(["key": .string($0.key), "value": .string($0.value)]) }),
            "why": .string(finding.why), "suggested_next_step": finding.action.map(JSONValue.string) ?? .null]
        if let at { fields["at"] = AgentJSON.time(seconds: at) }
        return .object(fields)
    }

    private func runAudit() async -> JSONValue {
        let result = await sources.audit()
        return .object(["verdict": .string(result.report.verdict.rawValue), "timestamp": AgentJSON.time(seconds: result.report.timestamp),
                        "findings": .array(result.report.findings.map { Self.findingJSON($0) }),
                        "unknowns": .array(result.report.unknowns.map {
                            .object(["id": .string($0.ruleID), "title": .string($0.title), "reason": .string($0.reason)]) })])
    }

    private func findings(_ arguments: [String: JSONValue]) async throws -> JSONValue {
        let since = try date(arguments, "since")
        guard let database = sources.database else { return AgentJSON.notRunning(["findings": .array([])]) }
        return try await stored {
            let from: Int64
            if let since { from = Int64(since.timeIntervalSince1970) } else { from = try await database.latestAudit()?.timestamp ?? 0 }
            return .object(["available": .bool(true),
                            "findings": .array(try await database.findings(since: from).map { Self.findingJSON($0.finding, at: $0.timestamp) })])
        }
    }

    private static let metrics: [String: HistoryMetric] = ["cpu": .cpu, "memory": .memory, "swap": .swap, "pressure": .pressure,
                                                           "disk_io": .diskIO, "net_in": .netIn, "net_out": .netOut]
    private static let ranges: [String: HistoryRange] = ["1h": .hour, "24h": .day, "7d": .week, "90d": .quarter]

    private func history(_ arguments: [String: JSONValue]) async throws -> JSONValue {
        guard let metricName = string(arguments, "metric"), let metric = Self.metrics[metricName] else { throw AgentError(message: "unknown metric") }
        let rangeName = string(arguments, "range") ?? "24h"
        guard let range = Self.ranges[rangeName] else { throw AgentError(message: "unknown range") }
        guard sources.appRunning, let database = sources.database else { return AgentJSON.notRunning() }
        let now = Int64(sources.now().timeIntervalSince1970)
        let appKey = string(arguments, "app")
        // The stored per-app lines hold footprint, not swap or pressure, so those would be mislabelled.
        if appKey != nil, metricName == "swap" || metricName == "pressure" { throw AgentError(message: "\(metricName) has no per-app history") }
        return try await stored {
            var points = try await database.history(metric, range: range, now: now)
            if let appKey {
                guard let series = try await database.appHistory(metric, range: range, now: now, limit: 50).first(where: { $0.appKey == appKey })
                else { return .object(["available": .bool(true), "metric": .string(metricName), "range": .string(rangeName),
                                       "app": .string(appKey), "points": .array([]), "reason": .string("that app is not among the 50 heaviest for this metric in this range, or has no samples")]) }
                points = series.points
            }
            return .object(["available": .bool(true), "metric": .string(metricName), "range": .string(rangeName),
                            "step_seconds": .int(Int(range.stepSeconds)),
                            "points": .array(points.map { .object(["at": AgentJSON.time(seconds: $0.ts), "value": $0.value.map(AgentJSON.number) ?? .null]) })])
        }
    }

    private func whoHeld(_ arguments: [String: JSONValue]) async throws -> JSONValue {
        guard let metricName = string(arguments, "metric"), let metric = Self.metrics[metricName] else { throw AgentError(message: "unknown metric") }
        guard metricName != "swap", metricName != "pressure" else { throw AgentError(message: "\(metricName) has no per-app history") }
        let at = try date(arguments, "at"), from = try date(arguments, "from"), to = try date(arguments, "to")
        if at != nil { guard from == nil, to == nil else { throw AgentError(message: "give at, or from and to, not both") } }
        else {
            guard let from, let to else { throw AgentError(message: "give at, or from and to") }
            guard to > from else { throw AgentError(message: "to must be after from") }
            guard to <= sources.now() else { throw AgentError(message: "the window reaches into the future") }
        }
        guard sources.appRunning, let database = sources.database else { return AgentJSON.notRunning(["apps": .array([])]) }
        let requested = Int64((at ?? from)!.timeIntervalSince1970)
        // Raw samples live 48 hours; older moments are only in the rollups, so the age picks the table, the window the step.
        let age = Int64(sources.now().timeIntervalSince1970) - requested
        guard age >= 0 else { throw AgentError(message: "the moment is in the future") }
        let span = to.map { Int64($0.timeIntervalSince1970) - requested } ?? 0
        let range: HistoryRange = age > 7 * 86_400 ? .quarter : age > 47 * 3_600 ? .week : span > 3_600 ? .day : .hour
        // Samples are buckets: the moment answers with the bucket that contains it, and the answer says which.
        let start = requested - requested % range.stepSeconds
        return try await stored {
            let holders = try await database.holders(metric, range: range, at: start, limit: 5)
            // The stored samples are buckets: a longer requested window is answered for the bucket it starts in, and says so.
            var answer: [String: JSONValue] = [:]
            if holders.isEmpty { answer["reason"] = .string("no samples are stored for that moment") }
            if let to, to.timeIntervalSince1970 - Double(requested) > Double(range.stepSeconds) {
                answer["note"] = .string("the answer covers the one \(range.stepSeconds)-second bucket that starts at from, not the whole window")
            }
            return .object(answer.merging(["available": .bool(true), "metric": .string(metricName), "from": AgentJSON.time(seconds: start),
                            "to": AgentJSON.time(seconds: start + range.stepSeconds),
                            "apps": .array(holders.map { .object(["app_key": .string($0.appKey), "name": .string($0.name),
                                                                  "value": AgentJSON.number($0.value)]) })]) { first, _ in first })
        }
    }

    private func cleanupPreview() async -> JSONValue {
        let preview = await sources.cleanup()
        return .object(["total_bytes": .int(Int(preview.bytes())),
                        "items": .array(preview.candidates.map { .object(["rule_id": .string($0.ruleID), "path": .string($0.path), "bytes": .int(Int($0.bytes))]) }),
                        "skipped": .array(preview.skipped.map { .object(["path": .string($0.path), "reason": .string($0.reason)]) })])
    }
}
