import Foundation
import SQLite3
import Testing
@testable import MacMaxCore

private func budgetTick(ts: Int64) -> TickRows {
    var apps: [AppSampleRow] = []
    for index in 0..<40 {
        apps.append(AppSampleRow(ts: ts, appKey: "com.example.App\(index)", cpu: Double(index) + 0.25,
                                 footprint: Int64(80_000_000 + index * 1_000_000),
                                 diskReadBps: Double(10_000 + index), diskWriteBps: Double(5_000 + index),
                                 netInBytes: Int64(20_000 + index), netOutBytes: Int64(10_000 + index), procs: 2))
    }
    var processes: [ProcSampleRow] = []
    for index in 0..<30 {
        processes.append(ProcSampleRow(ts: ts, pid: Int32(2_000 + index), startUs: Int64(10_000 + index),
                                       appKey: "com.example.App\(index)", name: "Example Helper Process \(index)",
                                       cpu: Double(index) + 0.125,
                                       footprint: Int64(40_000_000 + index * 500_000)))
    }
    let appInfo = (0..<40).map { index in
        AppInfo(appKey: "com.example.App\(index)", name: "Example Application \(index)",
                bundleID: "com.example.App\(index)", path: "/Applications/ExampleApp\(index).app",
                firstSeen: ts)
    }
    return TickRows(
        system: SystemSampleRow(ts: ts, cpuUser: 21.5, cpuSystem: 8.25, memUsed: 12_000_000_000,
                                memCompressed: 1_000_000_000, swapUsed: 200_000_000,
                                swapinsPerSecond: 0.25, pressureLevel: 1, diskFree: 400_000_000_000,
                                diskReadBps: 1_250_000, diskWriteBps: 750_000,
                                netInBps: 500_000, netOutBps: 250_000, thermal: 0),
        apps: apps, processes: processes, appInfo: appInfo
    )
}

private func bindText(_ statement: OpaquePointer, index: Int32, value: String) {
    _ = value.withCString { pointer in
        sqlite3_bind_text(statement, index, pointer, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}

private func executePrepared(_ statement: OpaquePointer, handle: OpaquePointer) throws {
    let result = sqlite3_step(statement)
    guard result == SQLITE_DONE else {
        throw StoreError.sqlite(code: result, message: String(cString: sqlite3_errmsg(handle)))
    }
    sqlite3_reset(statement)
    sqlite3_clear_bindings(statement)
}

private func insertBudgetRollups(_ url: URL, now: Int64) throws {
    let handle = try StoreSQLite.open(url, flags: SQLITE_OPEN_READWRITE)
    defer { sqlite3_close(handle) }
    sqlite3_busy_timeout(handle, 2_000)
    var system: OpaquePointer?
    var app: OpaquePointer?
    let systemSQL = """
        INSERT INTO PLACEHOLDER(ts,n,cpu_user,cpu_system,mem_used,mem_compressed,swap_used,swapins_ps,
        pressure_level,disk_free,disk_read_bps,disk_write_bps,net_in_bps,net_out_bps,thermal,
        cpu_max,mem_used_max,net_in_bps_max,net_out_bps_max) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
    let appSQL = """
        INSERT INTO PLACEHOLDER(ts,app_key,n,cpu,footprint,disk_read_bps,disk_write_bps,net_in_bytes,
        net_out_bytes,procs,cpu_max,footprint_max) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
        """

    func insertLevel(tableSuffix: String, rows: Int, step: Int64, start: Int64) throws {
        let systemStatement = systemSQL.replacingOccurrences(of: "PLACEHOLDER", with: "samples_\(tableSuffix)")
        let appStatement = appSQL.replacingOccurrences(of: "PLACEHOLDER", with: "app_samples_\(tableSuffix)")
        guard sqlite3_prepare_v2(handle, systemStatement, -1, &system, nil) == SQLITE_OK,
              sqlite3_prepare_v2(handle, appStatement, -1, &app, nil) == SQLITE_OK,
              let system, let app else {
            throw StoreError.sqlite(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(system); sqlite3_finalize(app) }
        try StoreSQLite.exec(handle, "BEGIN IMMEDIATE")
        do {
            for row in 0..<rows {
                let ts = start + Int64(row) * step
                sqlite3_bind_int64(system, 1, ts)
                sqlite3_bind_int64(system, 2, tableSuffix == "1m" ? 6 : 360)
                for index: Int32 in [3, 4, 8, 11, 12, 13, 14, 16, 18, 19] {
                    sqlite3_bind_double(system, index, Double(index) * 1_000.25)
                }
                for index: Int32 in [5, 6, 7, 9, 10, 15, 17] {
                    sqlite3_bind_int64(system, index, Int64(index) * 1_000_000)
                }
                try executePrepared(system, handle: handle)
                for index in 0..<40 {
                    sqlite3_bind_int64(app, 1, ts)
                    bindText(app, index: 2, value: "com.example.App\(index)")
                    sqlite3_bind_int64(app, 3, tableSuffix == "1m" ? 6 : 360)
                    sqlite3_bind_double(app, 4, Double(index) + 0.25)
                    sqlite3_bind_int64(app, 5, Int64(80_000_000 + index * 1_000_000))
                    sqlite3_bind_double(app, 6, Double(10_000 + index))
                    sqlite3_bind_double(app, 7, Double(5_000 + index))
                    sqlite3_bind_int64(app, 8, Int64(20_000 + index))
                    sqlite3_bind_int64(app, 9, Int64(10_000 + index))
                    sqlite3_bind_int64(app, 10, 2)
                    sqlite3_bind_double(app, 11, Double(index) + 0.5)
                    sqlite3_bind_int64(app, 12, Int64(90_000_000 + index * 1_000_000))
                    try executePrepared(app, handle: handle)
                }
            }
            try StoreSQLite.exec(handle, "COMMIT")
        } catch {
            try? StoreSQLite.exec(handle, "ROLLBACK")
            throw error
        }
    }

    try insertLevel(tableSuffix: "1m", rows: 20_160, step: 60, start: now - 14 * 86_400)
    try insertLevel(tableSuffix: "1h", rows: 2_160, step: 3_600, start: now - 90 * 86_400)
}

@Suite("StoreBudget", .serialized)
struct StoreBudgetAcceptanceTests {
    @Test("Ninety-day steady state remains below 250 decimal MB", .timeLimit(.minutes(2)))
    func steadyStateSize() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        let now: Int64 = 40_000_000
        let rawStart = now - 172_800
        for tick in 0..<17_280 {
            try await database.write(budgetTick(ts: rawStart + Int64(tick * 10)))
        }
        try insertBudgetRollups(temporary.databaseURL, now: now)
        _ = try await database.retain(now: now, maxRowsPerTable: Int.max)
        let bytes = await database.fileSizeBytes()
        print(String(format: "StoreBudget size: %.2f MB (%lld bytes)", Double(bytes) / 1_000_000, bytes))
        #expect(bytes < 250_000_000)
    }
}
