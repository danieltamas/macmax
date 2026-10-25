import Foundation

extension Database {
    private static let rawSeconds: Int64 = 48 * 3600
    private static let minuteRowsSeconds: Int64 = 14 * 86400
    private static let hourRowsSeconds: Int64 = 365 * 86400
    private static let auditSeconds: Int64 = 90 * 86400

    /// Rolls complete buckets up: raw to 1-minute, 1-minute to 1-hour, at most `maxBuckets` per level per call.
    /// An hour's averages weight each minute by its `n`, so they equal the average over the raw rows.
    /// A tick is stamped when it starts and written seconds later: callers pass `now` a minute behind the clock so a
    /// minute is rolled only once no tick can still land in it. Rows added to an already represented bucket are not folded in.
    public func rollup(now: Int64, maxBuckets: Int) throws -> (minutes: Int, hours: Int) {
        try requireWritable()
        guard maxBuckets > 0 else { return (0, 0) }
        return try transaction {
            // A bucket is open work while any raw row has no rolled counterpart (a late app in a rolled minute counts);
            // INSERT OR IGNORE then adds only what is missing.
            let minutes = try query("""
                SELECT b FROM (
                  SELECT ts / 60 * 60 AS b FROM samples WHERE ts / 60 * 60 NOT IN (SELECT ts FROM samples_1m)
                  UNION SELECT ts / 60 * 60 FROM app_samples a
                    WHERE NOT EXISTS (SELECT 1 FROM app_samples_1m m WHERE m.ts = a.ts / 60 * 60 AND m.app_key = a.app_key))
                WHERE b + 60 <= ? ORDER BY b LIMIT ?
                """, [.int(now), .int(Int64(maxBuckets))]).column0()
            for bucket in minutes { try rollMinute(bucket) }
            // An hour is built only when none of its raw minutes is still waiting, or a partial hour would be final.
            let hours = try query("""
                SELECT b FROM (
                  SELECT ts / 3600 * 3600 AS b FROM samples_1m WHERE ts / 3600 * 3600 NOT IN (SELECT ts FROM samples_1h)
                  UNION SELECT ts / 3600 * 3600 FROM app_samples_1m a
                    WHERE NOT EXISTS (SELECT 1 FROM app_samples_1h h WHERE h.ts = a.ts / 3600 * 3600 AND h.app_key = a.app_key))
                WHERE b + 3600 <= ?
                  AND NOT EXISTS (SELECT 1 FROM samples WHERE ts >= b AND ts < b + 3600 AND ts / 60 * 60 NOT IN (SELECT ts FROM samples_1m))
                  AND NOT EXISTS (SELECT 1 FROM app_samples a WHERE a.ts >= b AND a.ts < b + 3600 AND NOT EXISTS
                                  (SELECT 1 FROM app_samples_1m m WHERE m.ts = a.ts / 60 * 60 AND m.app_key = a.app_key))
                ORDER BY b LIMIT ?
                """, [.int(now), .int(Int64(maxBuckets))]).column0()
            for bucket in hours { try rollHour(bucket) }
            return (minutes.count, hours.count)
        }
    }

    /// Deletes rows older than each cut, at most `maxRowsPerTable` per table per call; returns the rows deleted.
    public func retain(now: Int64, maxRowsPerTable: Int) throws -> [StoreTable: Int] {
        try requireWritable()
        guard maxRowsPerTable > 0 else { return [:] }
        let limit = Int64(maxRowsPerTable)
        var deleted: [StoreTable: Int] = [:]
        try transaction {
            let cuts: [(StoreTable, [String], Int64)] = [
                (.samples, ["ts"], now - Self.rawSeconds), (.appSamples, ["ts", "app_key"], now - Self.rawSeconds),
                (.procSamples, ["ts", "pid", "start_us"], now - Self.rawSeconds),
                (.samples1m, ["ts"], now - Self.minuteRowsSeconds), (.appSamples1m, ["ts", "app_key"], now - Self.minuteRowsSeconds),
                (.samples1h, ["ts"], now - Self.hourRowsSeconds), (.appSamples1h, ["ts", "app_key"], now - Self.hourRowsSeconds),
                (.identity, ["ts"], now - Self.hourRowsSeconds), (.actions, ["rowid"], now - Self.hourRowsSeconds),
            ]
            for (table, key, cut) in cuts {
                let columns = key.joined(separator: ", ")
                deleted[table] = try execute("""
                    DELETE FROM \(table.rawValue) WHERE (\(columns)) IN
                    (SELECT \(columns) FROM \(table.rawValue) WHERE ts < ? ORDER BY ts LIMIT ?)
                    """, [.int(cut), .int(limit)])
            }
            // Findings go with their audits, and both stop at the bound: an audit is deleted once its findings are gone.
            var findingsLeft = maxRowsPerTable
            let audits = try query("SELECT id FROM audits WHERE ts < ? ORDER BY ts LIMIT ?",
                                   [.int(now - Self.auditSeconds), .int(limit)]).column0()
            for id in audits where findingsLeft > 0 {
                let removed = try execute("""
                    DELETE FROM findings WHERE rowid IN (SELECT rowid FROM findings WHERE audit_id = ? LIMIT ?)
                    """, [.int(id), .int(Int64(findingsLeft))])
                findingsLeft -= removed
                deleted[.findings, default: 0] += removed
                guard try query("SELECT 1 FROM findings WHERE audit_id = ? LIMIT 1", [.int(id)]).firstInt() == nil else { break }
                deleted[.audits, default: 0] += try execute("DELETE FROM audits WHERE id = ?", [.int(id)])
            }
        }
        _ = try? query("PRAGMA wal_checkpoint(TRUNCATE)").textRows()
        return deleted
    }

    private func rollMinute(_ bucket: Int64) throws {
        let length: Int64 = 60
        let averages = DatabaseSchema.sampleAverages.map { "AVG(\($0))" }.joined(separator: ", ")
        try execute("""
            INSERT OR IGNORE INTO samples_1m(ts, n, \(DatabaseSchema.sampleAverages.joined(separator: ", ")),
            cpu_max, mem_used_max, net_in_bps_max, net_out_bps_max)
            SELECT ?, COUNT(*), \(averages),
            MAX(CASE WHEN cpu_user IS NOT NULL AND cpu_system IS NOT NULL THEN cpu_user + cpu_system END),
            MAX(mem_used), MAX(net_in_bps), MAX(net_out_bps) FROM samples WHERE ts >= ? AND ts < ? HAVING COUNT(*) > 0
            """, [.int(bucket), .int(bucket), .int(bucket + length)])
        try execute("""
            INSERT OR IGNORE INTO app_samples_1m(ts, app_key, n, cpu, footprint, disk_read_bps, disk_write_bps,
            net_in_bytes, net_out_bytes, procs, cpu_max, footprint_max)
            SELECT ?, app_key, COUNT(*), AVG(cpu), AVG(footprint), AVG(disk_read_bps), AVG(disk_write_bps),
            SUM(net_in_bytes), SUM(net_out_bytes), MAX(procs), MAX(cpu), MAX(footprint)
            FROM app_samples WHERE ts >= ? AND ts < ? GROUP BY app_key
            """, [.int(bucket), .int(bucket), .int(bucket + length)])
    }

    private func rollHour(_ bucket: Int64) throws {
        func weighted(_ column: String) -> String {
            "SUM(CASE WHEN \(column) IS NOT NULL THEN \(column) * n END) * 1.0 / SUM(CASE WHEN \(column) IS NOT NULL THEN n END)"
        }
        let averages = DatabaseSchema.sampleAverages.map(weighted).joined(separator: ", ")
        try execute("""
            INSERT OR IGNORE INTO samples_1h(ts, n, \(DatabaseSchema.sampleAverages.joined(separator: ", ")),
            cpu_max, mem_used_max, net_in_bps_max, net_out_bps_max)
            SELECT ?, SUM(n), \(averages), MAX(cpu_max), MAX(mem_used_max), MAX(net_in_bps_max), MAX(net_out_bps_max)
            FROM samples_1m WHERE ts >= ? AND ts < ? HAVING COUNT(*) > 0
            """, [.int(bucket), .int(bucket), .int(bucket + 3600)])
        try execute("""
            INSERT OR IGNORE INTO app_samples_1h(ts, app_key, n, cpu, footprint, disk_read_bps, disk_write_bps,
            net_in_bytes, net_out_bytes, procs, cpu_max, footprint_max)
            SELECT ?, app_key, SUM(n), \(weighted("cpu")), \(weighted("footprint")), \(weighted("disk_read_bps")),
            \(weighted("disk_write_bps")), SUM(net_in_bytes), SUM(net_out_bytes), MAX(procs), MAX(cpu_max), MAX(footprint_max)
            FROM app_samples_1m WHERE ts >= ? AND ts < ? GROUP BY app_key
            """, [.int(bucket), .int(bucket), .int(bucket + 3600)])
    }
}
