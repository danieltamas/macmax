import Testing
@testable import MacMaxCore

private func panelTick(
    ts: Int64,
    system: SystemSampleRow? = nil,
    apps: [AppSampleRow] = [],
    appInfo: [AppInfo] = []
) -> TickRows {
    TickRows(system: system ?? SystemSampleRow(ts: ts), apps: apps, appInfo: appInfo)
}

@Suite("PanelQueries")
struct PanelQueriesAcceptanceTests {
    @Test("App traffic uses the requested window, known bytes, display names, and stable weight ordering")
    func appTrafficWindowAndOrdering() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)

        try await database.write(panelTick(ts: 99, apps: [
            AppSampleRow(ts: 99, appKey: "com.example.before", netInBytes: 50_000, netOutBytes: 50_000)
        ]))
        try await database.write(panelTick(ts: 100, apps: [
            AppSampleRow(ts: 100, appKey: "com.example.alpha-a", netInBytes: 10, netOutBytes: nil),
            AppSampleRow(ts: 100, appKey: "com.example.alpha-b", netInBytes: 20, netOutBytes: 20),
            AppSampleRow(ts: 100, appKey: "com.example.beta", netInBytes: 40, netOutBytes: 0),
            AppSampleRow(ts: 100, appKey: "com.example.fallback", netInBytes: nil, netOutBytes: 20),
            AppSampleRow(ts: 100, appKey: "com.example.unknown", netInBytes: nil, netOutBytes: nil)
        ], appInfo: [
            AppInfo(appKey: "com.example.alpha-a", name: "Alpha", firstSeen: 100),
            AppInfo(appKey: "com.example.alpha-b", name: "Alpha", firstSeen: 100),
            AppInfo(appKey: "com.example.beta", name: "Beta", firstSeen: 100),
            AppInfo(appKey: "com.example.unknown", name: "Unknown", firstSeen: 100)
        ]))
        try await database.write(panelTick(ts: 110, apps: [
            AppSampleRow(ts: 110, appKey: "com.example.alpha-a", netInBytes: nil, netOutBytes: 30)
        ]))

        #expect(try await database.appTraffic(since: 100) == [
            AppTraffic(appKey: "com.example.alpha-a", name: "Alpha", bytesIn: 10, bytesOut: 30),
            AppTraffic(appKey: "com.example.alpha-b", name: "Alpha", bytesIn: 20, bytesOut: 20),
            AppTraffic(appKey: "com.example.beta", name: "Beta", bytesIn: 40, bytesOut: 0),
            AppTraffic(appKey: "com.example.fallback", name: "com.example.fallback", bytesIn: 0, bytesOut: 20)
        ])
        #expect(try await database.appTraffic(since: 100, limit: 2).map(\.appKey) == [
            "com.example.alpha-a", "com.example.alpha-b"
        ])
        #expect(try await database.appTraffic(since: 100, limit: 0).isEmpty)
        #expect(try await database.appTraffic(since: 100, limit: -1).isEmpty)
    }

    @Test("System series selects the newest rows, displays them oldest first, and preserves unknown values")
    func systemSeriesWindowLimitAndNulls() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        let rows = [
            SystemSampleRow(ts: 99, cpuUser: 99, memUsed: 99),
            SystemSampleRow(ts: 100, cpuUser: 10, memUsed: 1_000),
            SystemSampleRow(ts: 110, cpuUser: 11, memUsed: 1_100),
            SystemSampleRow(ts: 120, cpuUser: nil, memUsed: 1_200, netInBps: nil),
            SystemSampleRow(ts: 130, cpuUser: 13, memUsed: nil, netInBps: 130)
        ]
        for row in rows {
            try await database.write(panelTick(ts: row.ts, system: row))
        }

        let series = try await database.systemSeries(since: 100, limit: 2)
        #expect(series == [rows[3], rows[4]])
        #expect(series[0].cpuUser == nil)
        #expect(series[0].netInBps == nil)
        #expect(series[1].memUsed == nil)
        #expect(try await database.systemSeries(since: 100, limit: 0).isEmpty)
    }

    @Test("Identity history is newest first and round-trips optional fields and tunnel state")
    func identityHistoryOrderingAndOptionalValues() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        let rows = [
            IdentityRow(ts: 100, publicIP: "192.0.2.10", publicCC: "RO", ispIP: "198.51.100.10",
                        ispCC: "RO", vpnService: "Example VPN", vpnState: "Connected",
                        routeTunnel: true, verdict: "tunnel_ok"),
            IdentityRow(ts: 200, publicIP: "203.0.113.20", publicCC: "DE", ispIP: "198.51.100.10",
                        ispCC: "RO", vpnService: "Example VPN", vpnState: "Connected",
                        routeTunnel: false, verdict: "split_tunnel"),
            IdentityRow(ts: 300, routeTunnel: nil, verdict: "unknown")
        ]
        for row in rows {
            #expect(try await database.writeIdentityIfChanged(row))
        }

        let history = try await database.identityChanges(limit: 3)
        #expect(history == [rows[2], rows[1], rows[0]])
        #expect(history[0].publicIP == nil)
        #expect(history[0].publicCC == nil)
        #expect(history[0].ispIP == nil)
        #expect(history[0].ispCC == nil)
        #expect(history[0].vpnService == nil)
        #expect(history[0].vpnState == nil)
        #expect(history.map(\.routeTunnel) == [nil, false, true])
        #expect(try await database.identityChanges(limit: 2) == [rows[2], rows[1]])
    }

    @Test("A read-only database handle runs every panel history query")
    func readOnlyHandleRunsAllQueries() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let writer = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        try await writer.write(panelTick(
            ts: 100,
            system: SystemSampleRow(ts: 100, cpuUser: 12.5),
            apps: [AppSampleRow(ts: 100, appKey: "com.example.Reader", netInBytes: 300, netOutBytes: 200)],
            appInfo: [AppInfo(appKey: "com.example.Reader", name: "Reader", firstSeen: 100)]
        ))
        let identity = IdentityRow(ts: 100, publicIP: "192.0.2.44", routeTunnel: true, verdict: "tunnel_ok")
        #expect(try await writer.writeIdentityIfChanged(identity))

        let reader = try Database.open(at: temporary.databaseURL, mode: .readOnly)
        #expect(try await reader.appTraffic(since: 100, limit: 10) == [
            AppTraffic(appKey: "com.example.Reader", name: "Reader", bytesIn: 300, bytesOut: 200)
        ])
        #expect(try await reader.systemSeries(since: 100, limit: 10) == [
            SystemSampleRow(ts: 100, cpuUser: 12.5)
        ])
        #expect(try await reader.identityChanges(limit: 10) == [identity])
    }
}
