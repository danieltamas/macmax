import Foundation
import Testing
@testable import MacMaxCore

private func appPoint(_ series: HistoryAppSeries, at ts: Int64) -> HistoryPoint? {
    series.points.first { $0.ts == ts }
}

@Suite("Per-app history queries")
struct HistoryAppsAcceptanceTests {
    @Test("An empty database has no app series")
    func emptyDatabase() async throws {
        let (temporary, database) = try historyDatabase()
        defer { temporary.remove() }

        #expect(try await database.appHistory(.cpu, range: .hour, now: 7_200) == [])
    }

    @Test("Top five use the whole range, deterministic ties, aligned points, and gaps")
    func rankingAlignmentAndGaps() async throws {
        let (temporary, database) = try historyDatabase()
        defer { temporary.remove() }
        try executeHistorySQL(temporary.databaseURL, [
            "INSERT INTO apps(app_key,name,first_seen) VALUES" +
                "('app.zulu','Zulu App',1),('app.beta','beta App',1)," +
                "('app.alpha.two','Alpha App',1),('app.alpha.one','Alpha App',1)," +
                "('app.delta','Delta App',1),('app.echo','Echo App',1),('app.foxtrot','Foxtrot App',1)",
            "INSERT INTO app_samples(ts,app_key,cpu,procs) VALUES" +
                "(3599,'app.foxtrot',999,1),(3601,'app.zulu',70,1),(3601,'app.beta',60,1)," +
                "(3601,'app.alpha.two',60,1),(3601,'app.alpha.one',60,1),(3601,'app.delta',40,1)," +
                "(3601,'app.echo',30,1),(3601,'app.foxtrot',20,1),(3661,'app.zulu',70,1)," +
                "(3661,'app.alpha.one',60,1),(7260,'app.foxtrot',999,1)"
        ])

        let systemPoints = try await database.history(.cpu, range: .hour, now: 7_200)
        let series = try await database.appHistory(.cpu, range: .hour, now: 7_200)
        #expect(series.map(\.appKey) == ["app.zulu", "app.alpha.one", "app.alpha.two", "app.beta", "app.delta"])
        #expect(series.map(\.name) == ["Zulu App", "Alpha App", "Alpha App", "beta App", "Delta App"])
        #expect(series.allSatisfy { $0.points.map(\.ts) == systemPoints.map(\.ts) })
        #expect(appPoint(series[0], at: 3_600)?.value == 70)
        #expect(appPoint(series[0], at: 3_660)?.value == 70)
        #expect(appPoint(series[1], at: 3_660)?.value == 60)
        #expect(appPoint(series[2], at: 3_660)?.value == nil)
    }

    @Test("Limit is respected and zero or nil whole-range means are omitted")
    func limitAndFiltering() async throws {
        let (temporary, database) = try historyDatabase()
        defer { temporary.remove() }
        try executeHistorySQL(temporary.databaseURL, [
            "INSERT INTO app_samples(ts,app_key,cpu,procs) VALUES" +
                "(3601,'app.high',20,1),(3601,'app.low',10,1),(3601,'app.zero',0,1),(3601,'app.nil',NULL,1)"
        ])

        let series = try await database.appHistory(.cpu, range: .hour, now: 7_200, limit: 1)
        #expect(series.map(\.appKey) == ["app.high"])
        #expect(series.first?.name == "app.high")
        #expect(try await database.appHistory(.cpu, range: .hour, now: 7_200, limit: 0) == [])
    }

    @Test("Every range reads only its specified table")
    func rangeSources() async throws {
        let (temporary, database) = try historyDatabase()
        defer { temporary.remove() }
        try executeHistorySQL(temporary.databaseURL, [
            "INSERT INTO app_samples(ts,app_key,cpu,procs) VALUES(7776001,'app.raw',11,1)",
            "INSERT INTO app_samples_1m(ts,app_key,n,cpu,procs) VALUES(7776000,'app.minute',1,22,1)",
            "INSERT INTO app_samples_1h(ts,app_key,n,cpu,procs) VALUES(7776000,'app.hour',1,33,1)"
        ])

        #expect(try await database.appHistory(.cpu, range: .hour, now: 7_779_600).map(\.appKey) == ["app.raw"])
        #expect(try await database.appHistory(.cpu, range: .day, now: 7_862_400).map(\.appKey) == ["app.raw"])
        #expect(try await database.appHistory(.cpu, range: .week, now: 8_380_800).map(\.appKey) == ["app.minute"])
        #expect(try await database.appHistory(.cpu, range: .quarter, now: 15_552_000).map(\.appKey) == ["app.hour"])
    }

    @Test("Rollup ranking and buckets use n-weighted means and ignore nil readings")
    func weightedRollups() async throws {
        let (temporary, database) = try historyDatabase()
        defer { temporary.remove() }
        let bucket: Int64 = 604_800
        try executeHistorySQL(temporary.databaseURL, [
            "INSERT INTO app_samples_1m(ts,app_key,n,cpu,procs) VALUES" +
                "(\(bucket),'app.weighted',2,10,1),(\(bucket + 60),'app.weighted',1,30,1)," +
                "(\(bucket + 120),'app.weighted',9,NULL,1),(\(bucket),'app.other',1,18,1)"
        ])

        let series = try await database.appHistory(.cpu, range: .week, now: 1_209_600)
        #expect(series.map(\.appKey) == ["app.other", "app.weighted"])
        #expect(appPoint(series[1], at: bucket)?.value == 50.0 / 3.0)
    }

    @Test("App metrics use footprint, disk sum, and inbound network columns")
    func metricColumns() async throws {
        let (temporary, database) = try historyDatabase()
        defer { temporary.remove() }
        try executeHistorySQL(temporary.databaseURL, [
            "INSERT INTO app_samples(ts,app_key,footprint,disk_read_bps,disk_write_bps,net_in_bytes,procs) " +
                "VALUES(3601,'app.metrics',11,3,5,7,1)"
        ])

        let expected: [(HistoryMetric, Double)] = [(.memory, 11), (.diskIO, 8), (.netIn, 7)]
        for (metric, value) in expected {
            let series = try await database.appHistory(metric, range: .hour, now: 7_200)
            #expect(series.map(\.appKey) == ["app.metrics"])
            #expect(appPoint(series[0], at: 3_600)?.value == value)
        }
    }
}
