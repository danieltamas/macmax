import Foundation

/// An app's traffic over a window, summed from the raw rows (kept for 48 hours, so 1 and 24 hour windows are exact).
public struct AppTraffic: Sendable, Equatable {
    public let appKey: String
    public let name: String
    public let bytesIn: Int64
    public let bytesOut: Int64

    public init(appKey: String, name: String, bytesIn: Int64, bytesOut: Int64) {
        self.appKey = appKey
        self.name = name
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

extension Database {
    /// Traffic per app since `since`, heaviest first (in + out, then name, then key). An app with no readable
    /// traffic byte in the window is left out: unknown is not zero.
    public func appTraffic(since: Int64, limit: Int = 100) throws -> [AppTraffic] {
        try query("""
            SELECT s.app_key, COALESCE(a.name, s.app_key), SUM(s.net_in_bytes), SUM(s.net_out_bytes)
            FROM app_samples s LEFT JOIN apps a ON a.app_key = s.app_key
            WHERE s.ts >= ? AND (s.net_in_bytes IS NOT NULL OR s.net_out_bytes IS NOT NULL)
            GROUP BY s.app_key
            ORDER BY COALESCE(SUM(s.net_in_bytes), 0) + COALESCE(SUM(s.net_out_bytes), 0) DESC, 2, 1
            LIMIT ?
            """, [.int(since), .int(Int64(max(limit, 0)))]).textRows().map { columns in
            guard let key = columns[0], let name = columns[1] else { throw StoreError.invalid("a stored app is incomplete") }
            return AppTraffic(appKey: key, name: name, bytesIn: columns[2].flatMap { Int64($0) } ?? 0,
                              bytesOut: columns[3].flatMap { Int64($0) } ?? 0)
        }
    }

    /// The newest `limit` system rows since `since`, oldest first, for sparklines.
    public func systemSeries(since: Int64, limit: Int) throws -> [SystemSampleRow] {
        let rows = try query("""
            SELECT ts, cpu_user, cpu_system, mem_used, mem_compressed, swap_used, swapins_ps, pressure_level, disk_free,
                   disk_read_bps, disk_write_bps, net_in_bps, net_out_bps, thermal
            FROM samples WHERE ts >= ? ORDER BY ts DESC LIMIT ?
            """, [.int(since), .int(Int64(max(limit, 0)))]).textRows()
        return try rows.reversed().map { c in
            guard let ts = c[0].flatMap({ Int64($0) }) else { throw StoreError.invalid("a stored sample has no time") }
            return SystemSampleRow(
                ts: ts, cpuUser: c[1].flatMap { Double($0) }, cpuSystem: c[2].flatMap { Double($0) },
                memUsed: c[3].flatMap { Int64($0) }, memCompressed: c[4].flatMap { Int64($0) },
                swapUsed: c[5].flatMap { Int64($0) }, swapinsPerSecond: c[6].flatMap { Double($0) },
                pressureLevel: c[7].flatMap { Int($0) }, diskFree: c[8].flatMap { Int64($0) },
                diskReadBps: c[9].flatMap { Double($0) }, diskWriteBps: c[10].flatMap { Double($0) },
                netInBps: c[11].flatMap { Double($0) }, netOutBps: c[12].flatMap { Double($0) }, thermal: c[13].flatMap { Int($0) })
        }
    }

    /// The newest `limit` identity rows (rows are written only when something changed), newest first.
    public func identityChanges(limit: Int) throws -> [IdentityRow] {
        try query("""
            SELECT ts, public_ip, public_cc, isp_ip, isp_cc, vpn_service, vpn_state, route_tunnel, verdict
            FROM identity ORDER BY ts DESC LIMIT ?
            """, [.int(Int64(max(limit, 0)))]).textRows().map { c in
            guard let ts = c[0].flatMap({ Int64($0) }), let verdict = c[8] else { throw StoreError.invalid("a stored identity is incomplete") }
            return IdentityRow(ts: ts, publicIP: c[1], publicCC: c[2], ispIP: c[3], ispCC: c[4], vpnService: c[5],
                               vpnState: c[6], routeTunnel: c[7].flatMap { Int($0) }.map { $0 != 0 }, verdict: verdict)
        }
    }
}

extension Database {
    /// Deletes the recorded history (samples, their rollups, identity changes). Audits and the action log stay:
    /// they are records of what was told or done, not measurements.
    public func clearHistory() throws {
        try requireWritable()
        try transaction {
            for table in ["samples", "app_samples", "proc_samples", "samples_1m", "app_samples_1m", "samples_1h", "app_samples_1h",
                          "identity"] {
                _ = try execute("DELETE FROM \(table)")
            }
        }
    }
}
