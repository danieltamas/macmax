import Foundation

/// The processes of one app (or Claude Code session) with what the agent tools report about it.
struct AgentApp {
    let key: String
    let name: String
    let processes: [ProcessSample]
    let netIn: UInt64?
    let netOut: UInt64?
    /// Why traffic is missing when the network collector itself failed or was unavailable; nil when it simply saw none for this app.
    var netProblem: JSONValue? = nil

    var cpu: Double? { Self.sum(processes.map { $0.cpuPercent.value }) }
    var footprint: Double? { Self.sum(processes.map { $0.footprintBytes.value.map { Double($0) } }) }
    var diskRead: Double? { Self.sum(processes.map { $0.diskReadBytes.value.map { Double($0) } }) }
    var diskWrite: Double? { Self.sum(processes.map { $0.diskWriteBytes.value.map { Double($0) } }) }

    /// Processes of this app whose CPU or memory could not be read (another user's, or gone mid-read): the totals leave them out.
    var unreadProcesses: Int {
        processes.filter { $0.cpuPercent.value == nil || $0.footprintBytes.value == nil || $0.diskReadBytes.value == nil || $0.diskWriteBytes.value == nil }.count
    }

    /// The sum of the readings that exist; nil when none did, so an app nobody could read is not "0".
    private static func sum(_ values: [Double?]) -> Double? {
        let known = values.compactMap { $0 }
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    static func group(_ processes: [ProcessSample], network: NetworkSnapshot) -> [AgentApp] {
        let rows = processes.map { ProcessRow(pid: $0.identity.pid, parentPid: $0.parentPid, path: $0.path.value, name: $0.name) }
        let folders = Dictionary(processes.compactMap { sample in sample.cwd.value.map { (sample.identity.pid, $0) } },
                                 uniquingKeysWith: { first, _ in first })
        let keys = AppGrouping.nameSessions(AppGrouping.group(rows), folders: folders)
        let counters = network.processes.value ?? [:]
        let problem: JSONValue? = network.processes.isOK ? nil : network.processes.json { _ in .null }
        let grouped = Dictionary(grouping: processes) { keys[$0.identity.pid]?.id ?? "\($0.identity.pid)" }
        return grouped.map { key, members in
            let name = keys[members[0].identity.pid]?.name ?? members[0].name
            let known = members.compactMap { counters[$0.identity]?.value }
            return AgentApp(key: key, name: name, processes: members,
                            netIn: known.isEmpty ? nil : known.reduce(0) { $0 + $1.bytesIn },
                            netOut: known.isEmpty ? nil : known.reduce(0) { $0 + $1.bytesOut }, netProblem: problem)
        }
    }

    private static func count(_ value: Double?, _ reason: String, _ problem: JSONValue? = nil) -> JSONValue {
        guard let value else { return problem ?? AgentJSON.notRead(reason) }
        return .int(Int(value))
    }

    func json(includeProcesses: Bool) -> JSONValue {
        var fields: [String: JSONValue] = ["app_key": .string(key), "name": .string(name), "processes": .int(processes.count)]
        fields["cpu_pct"] = cpu.map(AgentJSON.number) ?? AgentJSON.notRead("no process CPU reading")
        fields["footprint_bytes"] = Self.count(footprint, "no process memory reading")
        fields["disk_read_bytes"] = Self.count(diskRead, "no process disk reading")
        fields["disk_write_bytes"] = Self.count(diskWrite, "no process disk reading")
        fields["net_in_bytes"] = Self.count(netIn.map { Double($0) }, "no process network reading", netProblem)
        fields["net_out_bytes"] = Self.count(netOut.map { Double($0) }, "no process network reading", netProblem)
        if unreadProcesses > 0 { fields["unread_processes"] = .int(unreadProcesses) }
        if includeProcesses {
            let ordered = processes.sorted { ($0.cpuPercent.value ?? -1, $1.identity.pid) > ($1.cpuPercent.value ?? -1, $0.identity.pid) }
            fields["process_list"] = .array(ordered.prefix(50).map { Self.processJSON($0, detailed: false) })
        }
        return .object(fields)
    }

    /// One process. The command line is redacted here, at the only two places a command line is returned.
    static func processJSON(_ sample: ProcessSample, detailed: Bool) -> JSONValue {
        var fields: [String: JSONValue] = ["pid": .int(Int(sample.identity.pid)), "name": .string(sample.name),
                                           "cpu_pct": sample.cpuPercent.json { AgentJSON.number($0) },
                                           "footprint_bytes": sample.footprintBytes.json { .int(Int($0)) },
                                           "rosetta": sample.isTranslated.json { .bool($0) },
                                           "command_line": sample.argv.json { .string(Redaction.redact($0).joined(separator: " ")) }]
        if detailed {
            fields["start_time"] = AgentJSON.time(Date(timeIntervalSince1970: TimeInterval(sample.identity.startTimeMicroseconds) / 1_000_000))
            fields["path"] = sample.path.json { .string($0) }
            fields["disk_read_bytes"] = sample.diskReadBytes.json { .int(Int($0)) }
            fields["disk_write_bytes"] = sample.diskWriteBytes.json { .int(Int($0)) }
            fields["user"] = .string(getpwuid(uid_t(sample.uid)).map { String(cString: $0.pointee.pw_name) } ?? "uid \(sample.uid)")
        }
        return .object(fields)
    }
}
