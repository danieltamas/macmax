import Foundation
import SQLite3
import Testing
@testable import MacMaxCore

private func rollupTick(ts: Int64, user: Double?, system: Double?, memory: Int64?, appCPU: Double?,
                        appBytes: Int64?, procs: Int = 1) -> TickRows {
    TickRows(
        system: SystemSampleRow(ts: ts, cpuUser: user, cpuSystem: system, memUsed: memory,
                                netInBps: user.map { $0 * 2 }, netOutBps: nil),
        apps: [AppSampleRow(ts: ts, appKey: "com.example.Alpha", cpu: appCPU,
                            footprint: memory, netInBytes: appBytes, netOutBytes: nil, procs: procs)],
        appInfo: [AppInfo(appKey: "com.example.Alpha", name: "Example Alpha", firstSeen: ts)]
    )
}

private func rawExec(_ url: URL, _ statements: [String]) throws {
    let handle = try StoreSQLite.open(url, flags: SQLITE_OPEN_READWRITE)
    defer { sqlite3_close(handle) }
    sqlite3_busy_timeout(handle, 2_000)
    try StoreSQLite.exec(handle, "BEGIN IMMEDIATE")
    do {
        for statement in statements { try StoreSQLite.exec(handle, statement) }
        try StoreSQLite.exec(handle, "COMMIT")
    } catch {
        try? StoreSQLite.exec(handle, "ROLLBACK")
        throw error
    }
}

@Suite("StoreRollupAcceptance")
struct StoreRollupAcceptanceTests {
    @Test("Minute rollups compute averages, maxima, sums, counts, and NULLs")
    func minuteCorrectness() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        let bucket: Int64 = 120
        for offset in 0..<60 {
            let user: Double? = offset == 0 ? nil : Double((offset + 1) * 10)
            let system: Double? = offset == 0 ? nil : 5
            try await database.write(rollupTick(ts: bucket + Int64(offset), user: user, system: system,
                                                memory: Int64(1_000 + offset), appCPU: user,
                                                appBytes: Int64(offset + 1), procs: offset % 5))
        }
        let result = try await database.rollup(now: 180, maxBuckets: 10)
        #expect(result.minutes == 1)
        #expect(try StoreSQLite.scalarInt(temporary.databaseURL,
            "SELECT n FROM samples_1m WHERE ts=120") == 60)
        #expect(try StoreSQLite.scalarDouble(temporary.databaseURL,
            "SELECT cpu_user FROM samples_1m WHERE ts=120") == 310)
        #expect(try StoreSQLite.scalarDouble(temporary.databaseURL,
            "SELECT cpu_max FROM samples_1m WHERE ts=120") == 605)
        #expect(try StoreSQLite.scalarInt(temporary.databaseURL,
            "SELECT mem_used_max FROM samples_1m WHERE ts=120") == 1_059)
        #expect(try StoreSQLite.scalarDouble(temporary.databaseURL,
            "SELECT net_out_bps FROM samples_1m WHERE ts=120") == nil)
        #expect(try StoreSQLite.scalarInt(temporary.databaseURL,
            "SELECT n FROM app_samples_1m WHERE ts=120 AND app_key='com.example.Alpha'") == 60)
        #expect(try StoreSQLite.scalarDouble(temporary.databaseURL,
            "SELECT cpu FROM app_samples_1m WHERE ts=120 AND app_key='com.example.Alpha'") == 310)
        #expect(try StoreSQLite.scalarInt(temporary.databaseURL,
            "SELECT net_in_bytes FROM app_samples_1m WHERE ts=120 AND app_key='com.example.Alpha'") == 1_830)
        #expect(try StoreSQLite.scalarDouble(temporary.databaseURL,
            "SELECT net_out_bytes FROM app_samples_1m WHERE ts=120 AND app_key='com.example.Alpha'") == nil)
        #expect(try StoreSQLite.scalarInt(temporary.databaseURL,
            "SELECT procs FROM app_samples_1m WHERE ts=120 AND app_key='com.example.Alpha'") == 4)
        #expect(try StoreSQLite.scalarDouble(temporary.databaseURL,
            "SELECT cpu_max FROM app_samples_1m WHERE ts=120 AND app_key='com.example.Alpha'") == 600)
    }

    @Test("Hour averages are weighted by minute sample counts")
    func weightedHour() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        try await database.write(rollupTick(ts: 60, user: 10, system: 1, memory: 100,
                                            appCPU: 10, appBytes: 10, procs: 1))
        for second in 0..<3 {
            try await database.write(rollupTick(ts: 120 + Int64(second), user: 30, system: 3, memory: 300,
                                                appCPU: 30, appBytes: 20, procs: 3))
        }
        _ = try await database.rollup(now: 3_600, maxBuckets: 100)
        #expect(try StoreSQLite.scalarInt(temporary.databaseURL,
            "SELECT n FROM samples_1h WHERE ts=0") == 4)
        #expect(try StoreSQLite.scalarDouble(temporary.databaseURL,
            "SELECT cpu_user FROM samples_1h WHERE ts=0") == 25)
        #expect(try StoreSQLite.scalarDouble(temporary.databaseURL,
            "SELECT cpu_max FROM samples_1h WHERE ts=0") == 33)
        #expect(try StoreSQLite.scalarDouble(temporary.databaseURL,
            "SELECT cpu FROM app_samples_1h WHERE ts=0 AND app_key='com.example.Alpha'") == 25)
        #expect(try StoreSQLite.scalarInt(temporary.databaseURL,
            "SELECT net_in_bytes FROM app_samples_1h WHERE ts=0 AND app_key='com.example.Alpha'") == 70)
        #expect(try StoreSQLite.scalarInt(temporary.databaseURL,
            "SELECT procs FROM app_samples_1h WHERE ts=0 AND app_key='com.example.Alpha'") == 3)
    }

    @Test("App rollups remain separated by app identity")
    func twoAppGroups() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        var tick = rollupTick(ts: 60, user: 1, system: 1, memory: 10, appCPU: 2, appBytes: 3)
        tick.apps.append(AppSampleRow(ts: 60, appKey: "com.example.Beta", cpu: 20,
                                      footprint: 100, netInBytes: 30, procs: 2))
        tick.appInfo.append(AppInfo(appKey: "com.example.Beta", name: "Example Beta", firstSeen: 60))
        try await database.write(tick)
        _ = try await database.rollup(now: 120, maxBuckets: 10)
        #expect(try StoreSQLite.scalarInt(temporary.databaseURL,
            "SELECT count(*) FROM app_samples_1m WHERE ts=60") == 2)
        #expect(try StoreSQLite.scalarDouble(temporary.databaseURL,
            "SELECT cpu FROM app_samples_1m WHERE ts=60 AND app_key='com.example.Beta'") == 20)
    }

    @Test("Incomplete buckets wait and repeated rollup is idempotent")
    func completenessAndIdempotence() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        try await database.write(rollupTick(ts: 120, user: 1, system: 1, memory: 1,
                                            appCPU: 1, appBytes: 1))
        let early = try await database.rollup(now: 179, maxBuckets: 10)
        #expect(early.minutes == 0)
        #expect(try await database.count(.samples1m) == 0)
        let first = try await database.rollup(now: 180, maxBuckets: 10)
        #expect(first.minutes == 1)
        let second = try await database.rollup(now: 180, maxBuckets: 10)
        #expect(second.minutes == 0)
        #expect(second.hours == 0)
        #expect(try await database.count(.samples1m) == 1)
    }

    @Test("maxBuckets processes oldest buckets first and repeated calls finish")
    func boundedRollup() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        for ts: Int64 in [60, 120, 180] {
            try await database.write(rollupTick(ts: ts, user: Double(ts), system: 0, memory: ts,
                                                appCPU: Double(ts), appBytes: ts))
        }
        let first = try await database.rollup(now: 240, maxBuckets: 1)
        #expect(first.minutes == 1)
        #expect(try StoreSQLite.scalarInt(temporary.databaseURL, "SELECT min(ts) FROM samples_1m") == 60)
        let second = try await database.rollup(now: 240, maxBuckets: 1)
        let third = try await database.rollup(now: 240, maxBuckets: 1)
        #expect(second.minutes == 1)
        #expect(third.minutes == 1)
        #expect(try await database.count(.samples1m) == 3)
    }

    @Test("Rollup accepts raw rows older than the retention horizon")
    func oldRawRowsRollUp() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        try await database.write(rollupTick(ts: 60, user: 7, system: 3, memory: 9,
                                            appCPU: 7, appBytes: 5))
        let result = try await database.rollup(now: 172_861, maxBuckets: 10)
        #expect(result.minutes == 1)
        #expect(try StoreSQLite.scalarDouble(temporary.databaseURL,
            "SELECT cpu_user FROM samples_1m WHERE ts=60") == 7)
    }

    @Test("maxBuckets independently bounds hour buckets")
    func boundedHourRollup() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        try rawExec(temporary.databaseURL, [
            "INSERT INTO samples_1m(ts,n,cpu_user,cpu_max) VALUES(60,1,10,10),(3660,1,20,20)",
            "INSERT INTO app_samples_1m(ts,app_key,n,cpu,procs,cpu_max) VALUES(60,'com.example.Alpha',1,10,1,10),(3660,'com.example.Alpha',1,20,1,20)"
        ])
        let first = try await database.rollup(now: 7_200, maxBuckets: 1)
        #expect(first.hours == 1)
        #expect(try await database.count(.samples1h) == 1)
        let second = try await database.rollup(now: 7_200, maxBuckets: 1)
        #expect(second.hours == 1)
        #expect(try await database.count(.samples1h) == 2)
    }

    @Test("Retention applies every cut exactly and never deletes apps")
    func retentionCuts() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        let now: Int64 = 40_000_000
        let rawCut = now - 172_800
        for ts in [rawCut - 1, rawCut, rawCut + 1] {
            try await database.write(sampleTick(ts: ts, appKey: "com.example.\(ts)"))
        }
        let minuteCut = now - 14 * 86_400
        let hourCut = now - 365 * 86_400
        let auditCut = now - 90 * 86_400
        try rawExec(temporary.databaseURL, [
            "INSERT INTO samples_1m(ts,n) VALUES(\(minuteCut - 1),1),(\(minuteCut),1),(\(minuteCut + 1),1)",
            "INSERT INTO app_samples_1m(ts,app_key,n,procs) VALUES(\(minuteCut - 1),'com.example.Alpha',1,1),(\(minuteCut),'com.example.Alpha',1,1),(\(minuteCut + 1),'com.example.Alpha',1,1)",
            "INSERT INTO samples_1h(ts,n) VALUES(\(hourCut - 1),1),(\(hourCut),1),(\(hourCut + 1),1)",
            "INSERT INTO app_samples_1h(ts,app_key,n,procs) VALUES(\(hourCut - 1),'com.example.Alpha',1,1),(\(hourCut),'com.example.Alpha',1,1),(\(hourCut + 1),'com.example.Alpha',1,1)",
            "INSERT INTO audits(id,ts,verdict,duration_ms,snapshot_json) VALUES(1,\(auditCut - 1),'OK',1,'{}'),(2,\(auditCut),'OK',1,'{}'),(3,\(auditCut + 1),'OK',1,'{}')",
            "INSERT INTO findings(audit_id,rule_id,severity,title,evidence_json) VALUES(1,'old','INFO','Old','{}'),(2,'cut','INFO','Cut','{}'),(3,'new','INFO','New','{}')",
            "INSERT INTO actions(ts,kind,target,result,detail) VALUES(\(hourCut - 1),'test','Example','OK','old'),(\(hourCut),'test','Example','OK','cut'),(\(hourCut + 1),'test','Example','OK','new')",
            "INSERT INTO identity(ts,verdict) VALUES(\(hourCut - 1),'OLD'),(\(hourCut),'CUT'),(\(hourCut + 1),'NEW')"
        ])
        _ = try await database.retain(now: now, maxRowsPerTable: 100)
        for table in ["samples", "app_samples", "proc_samples"] {
            #expect(try StoreSQLite.scalarInt(temporary.databaseURL,
                "SELECT count(*) FROM \(table) WHERE ts < \(rawCut)") == 0)
            #expect(try StoreSQLite.scalarInt(temporary.databaseURL,
                "SELECT count(*) FROM \(table) WHERE ts >= \(rawCut)") == 2)
        }
        for table in ["samples_1m", "app_samples_1m"] {
            #expect(try StoreSQLite.scalarInt(temporary.databaseURL, "SELECT count(*) FROM \(table)") == 2)
            #expect(try StoreSQLite.scalarInt(temporary.databaseURL,
                "SELECT count(*) FROM \(table) WHERE ts=\(minuteCut)") == 1)
        }
        for table in ["samples_1h", "app_samples_1h", "actions", "identity"] {
            #expect(try StoreSQLite.scalarInt(temporary.databaseURL, "SELECT count(*) FROM \(table)") == 2)
            #expect(try StoreSQLite.scalarInt(temporary.databaseURL,
                "SELECT count(*) FROM \(table) WHERE ts=\(hourCut)") == 1)
        }
        #expect(try StoreSQLite.scalarInt(temporary.databaseURL, "SELECT count(*) FROM audits") == 2)
        #expect(try StoreSQLite.scalarInt(temporary.databaseURL, "SELECT count(*) FROM findings") == 2)
        #expect(try StoreSQLite.scalarInt(temporary.databaseURL,
            "SELECT count(*) FROM findings WHERE audit_id=1") == 0)
        #expect(try await database.count(.apps) == 3)
    }

    @Test("Retention is bounded per table and repeated calls finish")
    func boundedRetention() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        let now: Int64 = 1_000_000
        for ts: Int64 in [1, 2, 3] { try await database.write(sampleTick(ts: ts)) }
        let first = try await database.retain(now: now, maxRowsPerTable: 1)
        #expect(first[.samples] == 1)
        #expect(first[.appSamples] == 1)
        #expect(first[.procSamples] == 1)
        #expect(try await database.count(.samples) == 2)
        _ = try await database.retain(now: now, maxRowsPerTable: 1)
        _ = try await database.retain(now: now, maxRowsPerTable: 1)
        #expect(try await database.count(.samples) == 0)
        #expect(try await database.count(.apps) == 1)
    }

    @Test("Retention on an empty database is a no-op")
    func emptyRetention() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        let deleted = try await database.retain(now: 1_000_000, maxRowsPerTable: 10)
        #expect(deleted.values.reduce(0, +) == 0)
    }
}
