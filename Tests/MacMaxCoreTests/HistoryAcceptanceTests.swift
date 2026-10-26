import Foundation
import SQLite3
import Testing
@testable import MacMaxCore

func historyDatabase() throws -> (StoreTestDirectory, Database) {
    let temporary = try StoreTestDirectory()
    return (temporary, try Database.open(at: temporary.databaseURL, mode: .readWrite))
}

private func writeHistoryRow(
    _ database: Database,
    ts: Int64,
    cpuUser: Double? = nil,
    cpuSystem: Double? = nil,
    memory: Int64? = nil,
    swap: Int64? = nil,
    pressure: Int? = nil,
    diskRead: Double? = nil,
    diskWrite: Double? = nil,
    netIn: Double? = nil,
    netOut: Double? = nil
) async throws {
    try await database.write(TickRows(system: SystemSampleRow(
        ts: ts, cpuUser: cpuUser, cpuSystem: cpuSystem, memUsed: memory,
        swapUsed: swap, pressureLevel: pressure, diskReadBps: diskRead,
        diskWriteBps: diskWrite, netInBps: netIn, netOutBps: netOut
    )))
}

func executeHistorySQL(_ url: URL, _ statements: [String]) throws {
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

func point(_ points: [HistoryPoint], at ts: Int64) -> HistoryPoint? {
    points.first { $0.ts == ts }
}

@Suite("History queries")
struct HistoryAcceptanceTests {
    @Test("Ranges expose their duration and step")
    func rangeConstants() {
        #expect(HistoryRange.allCases.map(\.seconds) == [3_600, 86_400, 604_800, 7_776_000])
        #expect(HistoryRange.allCases.map(\.stepSeconds) == [60, 300, 900, 3_600])
    }

    @Test("Every range returns inclusive aligned ascending buckets")
    func rangeShape() async throws {
        let (temporary, database) = try historyDatabase()
        defer { temporary.remove() }
        let now: Int64 = 8_000_123
        let cases: [(HistoryRange, Int)] = [(.hour, 61), (.day, 289), (.week, 673), (.quarter, 2_161)]

        for (range, expectedCount) in cases {
            let points = try await database.history(.memory, range: range, now: now)
            let expectedFirst = ((now - range.seconds) / range.stepSeconds) * range.stepSeconds
            let expectedLast = (now / range.stepSeconds) * range.stepSeconds
            #expect(points.count == expectedCount)
            #expect(points.first?.ts == expectedFirst)
            #expect(points.last?.ts == expectedLast)
            #expect(points.allSatisfy { $0.ts % range.stepSeconds == 0 })
            #expect(zip(points, points.dropFirst()).allSatisfy { $0.ts < $1.ts })
            #expect(points.allSatisfy { $0.value == nil })
        }
    }

    @Test("Raw history averages rows and preserves gaps without interpolation")
    func meanAndGaps() async throws {
        let (temporary, database) = try historyDatabase()
        defer { temporary.remove() }
        try await writeHistoryRow(database, ts: 3_601, memory: 100)
        try await writeHistoryRow(database, ts: 3_659, memory: 300)
        try await writeHistoryRow(database, ts: 3_900, memory: 900)

        let points = try await database.history(.memory, range: .hour, now: 7_200)
        #expect(point(points, at: 3_600)?.value == 200)
        #expect(point(points, at: 3_660)?.value == nil)
        #expect(point(points, at: 3_720)?.value == nil)
        #expect(point(points, at: 3_840)?.value == nil)
        #expect(point(points, at: 3_900)?.value == 900)
    }

    @Test("Nil metrics and incomplete CPU sums are gaps")
    func nilMetrics() async throws {
        let (temporary, database) = try historyDatabase()
        defer { temporary.remove() }
        try await writeHistoryRow(database, ts: 3_601, cpuUser: 8, cpuSystem: nil)
        try await writeHistoryRow(database, ts: 3_602, cpuUser: nil, cpuSystem: 4)
        try await writeHistoryRow(database, ts: 3_603)

        let cpu = try await database.history(.cpu, range: .hour, now: 7_200)
        let memory = try await database.history(.memory, range: .hour, now: 7_200)
        #expect(point(cpu, at: 3_600)?.value == nil)
        #expect(point(memory, at: 3_600)?.value == nil)
    }

    @Test("Each history metric reads its specified raw columns")
    func rawMetricColumns() async throws {
        let (temporary, database) = try historyDatabase()
        defer { temporary.remove() }
        try await writeHistoryRow(database, ts: 3_601, cpuUser: 2, cpuSystem: 3,
                                  memory: 11, swap: 13, pressure: 2,
                                  diskRead: 17, diskWrite: 19, netIn: 23, netOut: 29)
        let expected: [(HistoryMetric, Double)] = [
            (.cpu, 5), (.pressure, 2), (.memory, 11), (.swap, 13),
            (.diskIO, 36), (.netIn, 23), (.netOut, 29),
        ]
        for (metric, value) in expected {
            let points = try await database.history(metric, range: .hour, now: 7_200)
            #expect(point(points, at: 3_600)?.value == value)
        }
    }

    @Test("Week reads minute rollups and ignores raw rows")
    func weekSource() async throws {
        let (temporary, database) = try historyDatabase()
        defer { temporary.remove() }
        let bucket: Int64 = 604_800
        try await writeHistoryRow(database, ts: bucket + 1, cpuUser: 500, cpuSystem: 500)
        try executeHistorySQL(temporary.databaseURL, [
            "INSERT INTO samples_1m(ts,n,cpu_user,cpu_system) VALUES(\(bucket),2,4,6),(\(bucket + 60),1,10,20),(\(bucket + 120),9,NULL,100)"
        ])

        let points = try await database.history(.cpu, range: .week, now: 1_209_600)
        #expect(point(points, at: bucket)?.value == 50.0 / 3.0)
    }

    @Test("Day reads raw rows and ignores minute rollups")
    func daySource() async throws {
        let (temporary, database) = try historyDatabase()
        defer { temporary.remove() }
        let bucket: Int64 = 86_400
        try await writeHistoryRow(database, ts: bucket + 1, netOut: 31)
        try executeHistorySQL(temporary.databaseURL, [
            "INSERT INTO samples_1m(ts,n,net_out_bps) VALUES(\(bucket),1,999)"
        ])

        let points = try await database.history(.netOut, range: .day, now: 172_800)
        #expect(point(points, at: bucket)?.value == 31)
    }

    @Test("Quarter reads hour rollups and ignores raw and minute rows")
    func quarterSource() async throws {
        let (temporary, database) = try historyDatabase()
        defer { temporary.remove() }
        let bucket: Int64 = 7_776_000
        try await writeHistoryRow(database, ts: bucket + 1, netIn: 999)
        try executeHistorySQL(temporary.databaseURL, [
            "INSERT INTO samples_1m(ts,n,net_in_bps) VALUES(\(bucket),1,777)",
            "INSERT INTO samples_1h(ts,n,net_in_bps) VALUES(\(bucket),1,41)"
        ])

        let points = try await database.history(.netIn, range: .quarter, now: 15_552_000)
        #expect(point(points, at: bucket)?.value == 41)
    }

    @Test("Hour rollups use n-weighted means and omit nil values from both sums")
    func hourRollupWeighting() async throws {
        let (temporary, database) = try historyDatabase()
        defer { temporary.remove() }
        let bucket: Int64 = 7_776_000
        try executeHistorySQL(temporary.databaseURL, [
            "INSERT INTO samples_1h(ts,n,mem_used) VALUES(\(bucket),2,10),(\(bucket + 1_800),1,30),(\(bucket + 3_000),9,NULL)"
        ])

        let points = try await database.history(.memory, range: .quarter, now: 15_552_000)
        #expect(point(points, at: bucket)?.value == 50.0 / 3.0)
    }

    @Test("Holders return the top five of seven with deterministic tie order")
    func topFiveAndTieOrder() async throws {
        let (temporary, database) = try historyDatabase()
        defer { temporary.remove() }
        let apps: [(String, String, Double)] = [
            ("app.zulu", "Zulu App", 70), ("app.beta", "beta App", 60),
            ("app.alpha.two", "Alpha App", 60), ("app.alpha.one", "Alpha App", 60),
            ("app.delta", "Delta App", 40), ("app.echo", "Echo App", 30),
            ("app.foxtrot", "Foxtrot App", 20),
        ]
        let rows = apps.map { AppSampleRow(ts: 1_000, appKey: $0.0, cpu: $0.2) }
        let info = apps.map { AppInfo(appKey: $0.0, name: $0.1, firstSeen: 1_000) }
        try await database.write(TickRows(system: SystemSampleRow(ts: 1_000), apps: rows, appInfo: info))

        let holders = try await database.holders(.cpu, range: .hour, at: 960)
        #expect(holders.map(\.appKey) == ["app.zulu", "app.alpha.one", "app.alpha.two", "app.beta", "app.delta"])
        #expect(holders.map(\.value) == [70, 60, 60, 60, 40])
    }

    @Test("Holders average their window and omit nil, zero, and outside rows")
    func holderWindowAndFiltering() async throws {
        let (temporary, database) = try historyDatabase()
        defer { temporary.remove() }
        let rows: [(Int64, Double?)] = [(999, 500), (1_000, 10), (1_030, 30), (1_059, 0), (1_060, 700)]
        for (ts, cpu) in rows {
            try await database.write(TickRows(
                system: SystemSampleRow(ts: ts),
                apps: [AppSampleRow(ts: ts, appKey: "app.example", cpu: cpu)]
            ))
        }
        try await database.write(TickRows(
            system: SystemSampleRow(ts: 1_010),
            apps: [AppSampleRow(ts: 1_010, appKey: "app.nil", cpu: nil),
                   AppSampleRow(ts: 1_010, appKey: "app.zero", cpu: 0)]
        ))

        let holders = try await database.holders(.cpu, range: .hour, at: 1_000)
        #expect(holders == [HistoryHolder(appKey: "app.example", name: "app.example", value: 40.0 / 3.0)])
        #expect(try await database.holders(.cpu, range: .hour, at: 2_000) == [])
    }

    @Test("Holder metrics use CPU, footprint, IO, and network columns")
    func holderMetricColumns() async throws {
        let (temporary, database) = try historyDatabase()
        defer { temporary.remove() }
        try await database.write(TickRows(
            system: SystemSampleRow(ts: 1_000),
            apps: [AppSampleRow(ts: 1_000, appKey: "app.example", cpu: 2, footprint: 11,
                                diskReadBps: 3, diskWriteBps: 5, netInBytes: 7, netOutBytes: 13)],
            appInfo: [AppInfo(appKey: "app.example", name: "Example App", firstSeen: 1_000)]
        ))
        let expected: [(HistoryMetric, Double)] = [
            (.cpu, 2), (.memory, 11), (.swap, 11), (.pressure, 11),
            (.diskIO, 8), (.netIn, 7), (.netOut, 13),
        ]
        for (metric, value) in expected {
            let holders = try await database.holders(metric, range: .hour, at: 1_000)
            #expect(holders == [HistoryHolder(appKey: "app.example", name: "Example App", value: value)])
        }
    }

    @Test("Holder limit is respected and rollup tables are selected by range")
    func holderLimitAndSources() async throws {
        let (temporary, database) = try historyDatabase()
        defer { temporary.remove() }
        try executeHistorySQL(temporary.databaseURL, [
            "INSERT INTO apps(app_key,name,first_seen) VALUES('app.one','Example One',1),('app.two','Example Two',1)",
            "INSERT INTO app_samples(ts,app_key,cpu,procs) VALUES(900,'app.one',900,1)",
            "INSERT INTO app_samples_1m(ts,app_key,n,cpu,procs) VALUES(900,'app.one',1,10,1),(960,'app.two',1,30,1)",
            "INSERT INTO app_samples_1h(ts,app_key,n,cpu,procs) VALUES(3600,'app.one',1,40,1),(7200,'app.two',1,50,1)"
        ])

        let week = try await database.holders(.cpu, range: .week, at: 900, limit: 1)
        #expect(week == [HistoryHolder(appKey: "app.two", name: "Example Two", value: 30)])
        let quarter = try await database.holders(.cpu, range: .quarter, at: 3_600)
        #expect(quarter == [HistoryHolder(appKey: "app.one", name: "Example One", value: 40)])
    }

    @Test("Minute app rollups keep network holders as an n-weighted mean")
    func minuteAppRollupWeighting() async throws {
        let (temporary, database) = try historyDatabase()
        defer { temporary.remove() }
        try executeHistorySQL(temporary.databaseURL, [
            "INSERT INTO app_samples_1m(ts,app_key,n,net_in_bytes,procs) VALUES(900,'app.weighted',2,10,1),(960,'app.weighted',1,30,1),(1020,'app.weighted',8,NULL,1)"
        ])

        let holders = try await database.holders(.netIn, range: .week, at: 900)
        #expect(holders == [HistoryHolder(appKey: "app.weighted", name: "app.weighted", value: 50.0 / 3.0)])
    }

    @Test("Hour app rollups use n-weighted means")
    func hourAppRollupWeighting() async throws {
        let (temporary, database) = try historyDatabase()
        defer { temporary.remove() }
        try executeHistorySQL(temporary.databaseURL, [
            "INSERT INTO app_samples_1h(ts,app_key,n,cpu,procs) VALUES(3600,'app.weighted',2,10,1),(5400,'app.weighted',1,30,1)"
        ])

        let holders = try await database.holders(.cpu, range: .quarter, at: 3_600)
        #expect(holders == [HistoryHolder(appKey: "app.weighted", name: "app.weighted", value: 50.0 / 3.0)])
    }
}
