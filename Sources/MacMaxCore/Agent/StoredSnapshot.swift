import Foundation

/// `snapshot` while MacMax runs: the app's newest stored tick, so the answer needs no second sample. Nil when there is
/// no tick younger than two minutes or the read fails, and the caller then samples live.
extension LiveAgentBackend {
    func storedSnapshot() async -> [String: JSONValue]? {
        guard sources.appRunning, let database = sources.database else { return nil }
        let now = Int64(sources.now().timeIntervalSince1970)
        guard let row = try? await database.systemSeries(since: now - 120, limit: 1).first else { return nil }
        let bucket = row.ts - row.ts % HistoryRange.hour.stepSeconds
        func holders(_ metric: HistoryMetric) async -> JSONValue {
            guard let list = try? await database.holders(metric, range: .hour, at: bucket, limit: 5) else { return AgentJSON.failed("the stored samples could not be read") }
            return .array(list.map { .object(["app_key": .string($0.appKey), "name": .string($0.name), "value": AgentJSON.number($0.value)]) })
        }
        func traffic() async -> JSONValue {
            guard let list = try? await database.appTraffic(since: now - 300, limit: 5) else { return AgentJSON.failed("the stored samples could not be read") }
            return .array(list.map { .object(["app_key": .string($0.appKey), "name": .string($0.name),
                                              "bytes_in": .int(Int($0.bytesIn)), "bytes_out": .int(Int($0.bytesOut))]) })
        }
        func reading(_ value: Double?, _ make: (Double) -> JSONValue) -> JSONValue {
            value.map(make) ?? AgentJSON.notRead("the stored tick has no value for it")
        }
        let cpu: Double? = row.cpuUser.flatMap { user in row.cpuSystem.map { user + $0 } }
        let vitals: [String: JSONValue] = [
            "cpu": reading(cpu) { .object(["cpu_pct": AgentJSON.number($0)]) },
            "memory": reading(row.memUsed.map(Double.init)) { .object(["used_bytes": .int(Int($0)),
                                                                       "compressed_bytes": row.memCompressed.map { .int(Int($0)) } ?? AgentJSON.notRead("not stored")]) },
            "swap": reading(row.swapUsed.map(Double.init)) { .object(["used_bytes": .int(Int($0))]) },
            "pressure": reading(row.pressureLevel.map(Double.init)) { .object(["level": .int(Int($0))]) },
            "disk": reading(row.diskFree.map(Double.init)) { .object(["free_bytes": .int(Int($0)),
                                                                     "purgeable_bytes": AgentJSON.notRead("not stored in the tick")]) },
            "disk_io": reading(row.diskReadBps.flatMap { read in row.diskWriteBps.map { (read, $0) } }.map { $0.0 }) { _ in
                .object(["read_bps": AgentJSON.number(row.diskReadBps ?? 0), "write_bps": AgentJSON.number(row.diskWriteBps ?? 0)]) },
            "network": reading(row.netInBps.flatMap { input in row.netOutBps.map { (input, $0) } }.map { $0.0 }) { _ in
                .object(["in_bps": AgentJSON.number(row.netInBps ?? 0), "out_bps": AgentJSON.number(row.netOutBps ?? 0)]) },
            "thermal": reading(row.thermal.map(Double.init)) { .object(["state": .int(Int($0))]) },
            "uptime": AgentJSON.notRead("not stored in the tick"),
        ]
        let identity = await sources.identity(false)
        let verdict = await latestVerdict()
        let topCPU = await holders(.cpu), topMemory = await holders(.memory), topNetwork = await traffic()
        return ["verdict": verdict, "vitals": .object(vitals), "sampled_at": AgentJSON.time(seconds: row.ts),
                // The top lists are averages over stored buckets, not the newest tick; the answer says which window.
                "top_cpu_window": .string("the \(HistoryRange.hour.stepSeconds)-second bucket containing sampled_at, average"),
                "top_memory_window": .string("the \(HistoryRange.hour.stepSeconds)-second bucket containing sampled_at, average"),
                "top_network_window": .string("the 300 seconds before the request, summed"),
                "top_cpu": topCPU, "top_memory": topMemory, "top_network": topNetwork,
                "identity": Self.identitySummary(identity)]
    }
}
