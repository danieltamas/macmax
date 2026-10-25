import Foundation

extension Database {
    /// One transaction: the system row, the app rows, the process rows and the app registry. A tick with an
    /// invalid row stores nothing.
    public func write(_ tick: TickRows) throws {
        try requireWritable()
        try Task.checkCancellation()
        for app in tick.apps where app.appKey.isEmpty || app.procs < 0 {
            throw StoreError.invalid("an app row needs an app key and a process count of zero or more")
        }
        for process in tick.processes where process.appKey.isEmpty {
            throw StoreError.invalid("a process row needs an app key")
        }
        for info in tick.appInfo where info.appKey.isEmpty { throw StoreError.invalid("an app needs a key") }
        try transaction {
            let system = tick.system
            try execute("""
                INSERT OR REPLACE INTO samples(ts, cpu_user, cpu_system, mem_used, mem_compressed, swap_used, swapins_ps,
                pressure_level, disk_free, disk_read_bps, disk_write_bps, net_in_bps, net_out_bps, thermal)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.int(system.ts), SQLiteValue(system.cpuUser), SQLiteValue(system.cpuSystem), SQLiteValue(system.memUsed),
                      SQLiteValue(system.memCompressed), SQLiteValue(system.swapUsed), SQLiteValue(system.swapinsPerSecond),
                      SQLiteValue(system.pressureLevel), SQLiteValue(system.diskFree), SQLiteValue(system.diskReadBps),
                      SQLiteValue(system.diskWriteBps), SQLiteValue(system.netInBps), SQLiteValue(system.netOutBps),
                      SQLiteValue(system.thermal)])
            let app = try query("""
                INSERT OR REPLACE INTO app_samples(ts, app_key, cpu, footprint, disk_read_bps, disk_write_bps,
                net_in_bytes, net_out_bytes, procs) VALUES(?,?,?,?,?,?,?,?,?)
                """)
            for row in tick.apps {
                try app.reset()
                try app.bind([.int(row.ts), .text(row.appKey), SQLiteValue(row.cpu), SQLiteValue(row.footprint),
                              SQLiteValue(row.diskReadBps), SQLiteValue(row.diskWriteBps), SQLiteValue(row.netInBytes),
                              SQLiteValue(row.netOutBytes), .int(Int64(row.procs))])
                try app.run()
            }
            let process = try query("""
                INSERT OR REPLACE INTO proc_samples(ts, pid, start_us, app_key, name, cpu, footprint) VALUES(?,?,?,?,?,?,?)
                """)
            for row in tick.processes {
                try process.reset()
                try process.bind([.int(row.ts), .int(Int64(row.pid)), .int(row.startUs), .text(row.appKey), .text(row.name),
                                  SQLiteValue(row.cpu), SQLiteValue(row.footprint)])
                try process.run()
            }
            for info in tick.appInfo {
                try execute("""
                    INSERT INTO apps(app_key, name, bundle_id, path, first_seen) VALUES(?,?,?,?,?)
                    ON CONFLICT(app_key) DO UPDATE SET name = excluded.name, bundle_id = COALESCE(excluded.bundle_id, bundle_id), path = COALESCE(excluded.path, path)
                    """, [.text(info.appKey), .text(info.name), SQLiteValue(info.bundleID), SQLiteValue(info.path),
                          .int(info.firstSeen)])
            }
        }
    }

    /// Writes a row only when it differs from the newest stored one (everything but `ts`).
    public func writeIdentityIfChanged(_ row: IdentityRow) throws -> Bool {
        try requireWritable()
        return try transaction {
            let newest = try query("""
                SELECT public_ip, public_cc, isp_ip, isp_cc, vpn_service, vpn_state, route_tunnel, verdict
                FROM identity ORDER BY ts DESC LIMIT 1
                """).textRows().first
            let current: [String?] = [row.publicIP, row.publicCC, row.ispIP, row.ispCC, row.vpnService, row.vpnState,
                                      row.routeTunnel.map { $0 ? "1" : "0" }, row.verdict]
            if newest == current { return false }
            try execute("""
                INSERT OR REPLACE INTO identity(ts, public_ip, public_cc, isp_ip, isp_cc, vpn_service, vpn_state, route_tunnel, verdict)
                VALUES(?,?,?,?,?,?,?,?,?)
                """, [.int(row.ts), SQLiteValue(row.publicIP), SQLiteValue(row.publicCC), SQLiteValue(row.ispIP),
                      SQLiteValue(row.ispCC), SQLiteValue(row.vpnService), SQLiteValue(row.vpnState),
                      SQLiteValue(row.routeTunnel), .text(row.verdict)])
            return true
        }
    }
}
