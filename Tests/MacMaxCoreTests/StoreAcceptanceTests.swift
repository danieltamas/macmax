import Foundation
import SQLite3
import Testing
@testable import MacMaxCore

struct StoreTestDirectory {
    let url: URL
    let databaseURL: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMaxStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        databaseURL = url.appendingPathComponent("macmax.db")
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

enum StoreSQLite {
    static func open(_ url: URL, flags: Int32 = SQLITE_OPEN_READONLY) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let handle { sqlite3_close(handle) }
            throw StoreError.sqlite(code: result, message: message)
        }
        return handle
    }

    static func exec(_ handle: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(error)
            throw StoreError.sqlite(code: result, message: message)
        }
    }

    static func scalarInt(_ url: URL, _ sql: String) throws -> Int64 {
        let handle = try open(url)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.sqlite(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw StoreError.sqlite(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
        }
        return sqlite3_column_int64(statement, 0)
    }

    static func scalarDouble(_ url: URL, _ sql: String) throws -> Double? {
        let handle = try open(url)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.sqlite(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 0)
    }

    static func scalarText(_ url: URL, _ sql: String) throws -> String? {
        let handle = try open(url)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.sqlite(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    static func columns(_ url: URL, table: String) throws -> Set<String> {
        let handle = try open(url)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.invalid("cannot inspect schema") }
        defer { sqlite3_finalize(statement) }
        var result = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { result.insert(String(cString: name)) }
        }
        return result
    }
}

func sampleTick(ts: Int64, appKey: String = "com.example.Alpha", name: String = "Example Helper") -> TickRows {
    TickRows(
        system: SystemSampleRow(ts: ts, cpuUser: 10, cpuSystem: 5, memUsed: 1_000, memCompressed: 200,
                                swapUsed: 30, swapinsPerSecond: 0.5, pressureLevel: 1, diskFree: 9_000,
                                diskReadBps: 40, diskWriteBps: 20, netInBps: 60, netOutBps: 30, thermal: 0),
        apps: [AppSampleRow(ts: ts, appKey: appKey, cpu: 15, footprint: 500, diskReadBps: 40,
                            diskWriteBps: 20, netInBytes: 600, netOutBytes: 300, procs: 1)],
        processes: [ProcSampleRow(ts: ts, pid: 101, startUs: 1_000, appKey: appKey, name: name,
                                  cpu: 15, footprint: 500)],
        appInfo: [AppInfo(appKey: appKey, name: name, bundleID: appKey,
                          path: "/Applications/Example.app", firstSeen: ts)]
    )
}

func expectReadOnly(_ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("expected StoreError.readOnly")
    } catch let error as StoreError {
        #expect(error == .readOnly)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Suite("StoreAcceptance")
struct StoreAcceptanceTests {
    @Test("A new database has the versioned WAL schema and secure file mode")
    func schemaContract() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.url.path)
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)

        #expect(try await database.userVersion() == Database.schemaVersion)
        #expect(try StoreSQLite.scalarText(temporary.databaseURL, "PRAGMA journal_mode")?.lowercased() == "wal")
        for table in StoreTable.allCases {
            #expect(try StoreSQLite.scalarInt(temporary.databaseURL,
                "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='\(table.rawValue)'") == 1)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.databaseURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: temporary.url.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        #expect(try StoreSQLite.columns(temporary.databaseURL, table: "proc_samples").contains("argv") == false)
        #expect(try StoreSQLite.columns(temporary.databaseURL, table: "samples") == [
            "ts", "cpu_user", "cpu_system", "mem_used", "mem_compressed", "swap_used", "swapins_ps",
            "pressure_level", "disk_free", "disk_read_bps", "disk_write_bps", "net_in_bps", "net_out_bps", "thermal"
        ])
        #expect(try StoreSQLite.columns(temporary.databaseURL, table: "app_samples") == [
            "ts", "app_key", "cpu", "footprint", "disk_read_bps", "disk_write_bps", "net_in_bytes", "net_out_bytes", "procs"
        ])
        #expect(try StoreSQLite.columns(temporary.databaseURL, table: "proc_samples") == [
            "ts", "pid", "start_us", "app_key", "name", "cpu", "footprint"
        ])
        #expect(try StoreSQLite.columns(temporary.databaseURL, table: "apps") == [
            "app_key", "name", "bundle_id", "path", "first_seen"
        ])
        #expect(try StoreSQLite.columns(temporary.databaseURL, table: "identity") == [
            "ts", "public_ip", "public_cc", "isp_ip", "isp_cc", "vpn_service", "vpn_state", "route_tunnel", "verdict"
        ])
        let systemRollup = Set(["ts", "n", "cpu_user", "cpu_system", "mem_used", "mem_compressed",
                                "swap_used", "swapins_ps", "pressure_level", "disk_free", "disk_read_bps",
                                "disk_write_bps", "net_in_bps", "net_out_bps", "thermal", "cpu_max",
                                "mem_used_max", "net_in_bps_max", "net_out_bps_max"])
        let appRollup = Set(["ts", "app_key", "n", "cpu", "footprint", "disk_read_bps", "disk_write_bps",
                             "net_in_bytes", "net_out_bytes", "procs", "cpu_max", "footprint_max"])
        #expect(try StoreSQLite.columns(temporary.databaseURL, table: "samples_1m") == systemRollup)
        #expect(try StoreSQLite.columns(temporary.databaseURL, table: "samples_1h") == systemRollup)
        #expect(try StoreSQLite.columns(temporary.databaseURL, table: "app_samples_1m") == appRollup)
        #expect(try StoreSQLite.columns(temporary.databaseURL, table: "app_samples_1h") == appRollup)
        #expect(try StoreSQLite.columns(temporary.databaseURL, table: "audits") == [
            "id", "ts", "verdict", "duration_ms", "snapshot_json"
        ])
        #expect(try StoreSQLite.columns(temporary.databaseURL, table: "findings") == [
            "audit_id", "rule_id", "severity", "title", "evidence_json"
        ])
        #expect(try StoreSQLite.columns(temporary.databaseURL, table: "actions") == [
            "ts", "kind", "target", "result", "detail"
        ])
    }

    @Test("Opening and migration are idempotent and preserve written data")
    func idempotentOpen() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        var first: Database? = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        try await first?.write(sampleTick(ts: 100))
        first = nil
        let second = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        #expect(try await second.userVersion() == 1)
        #expect(try await second.count(.samples) == 1)
        #expect(try await second.count(.appSamples) == 1)
        #expect(try await second.count(.procSamples) == 1)
    }

    @Test("Read-only refuses a missing path")
    func readOnlyMissing() throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        do {
            _ = try Database.open(at: temporary.databaseURL, mode: .readOnly)
            Issue.record("read-only open unexpectedly created a database")
        } catch let error as StoreError {
            guard case .openFailed = error else {
                Issue.record("wrong error: \(error)")
                return
            }
        }
        #expect(FileManager.default.fileExists(atPath: temporary.databaseURL.path) == false)
    }

    @Test("A newer schema is readable but cannot be opened for writing")
    func newerSchemaModes() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let raw = try StoreSQLite.open(temporary.databaseURL,
                                       flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        try StoreSQLite.exec(raw, "PRAGMA user_version=99")
        sqlite3_close(raw)
        let before = try Data(contentsOf: temporary.databaseURL)
        let reader = try Database.open(at: temporary.databaseURL, mode: .readOnly)
        #expect(try await reader.userVersion() == 99)
        do {
            _ = try Database.open(at: temporary.databaseURL, mode: .readWrite)
            Issue.record("newer schema opened for writing")
        } catch let error as StoreError {
            #expect(error == .schemaTooNew(found: 99, supported: 1))
        }
        #expect(try Data(contentsOf: temporary.databaseURL) == before)
    }

    @Test("Every mutating operation refuses a read-only handle")
    func readOnlyMutations() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        _ = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        let reader = try Database.open(at: temporary.databaseURL, mode: .readOnly)
        await expectReadOnly { try await reader.write(sampleTick(ts: 1)) }
        await expectReadOnly {
            _ = try await reader.writeIdentityIfChanged(IdentityRow(ts: 1, verdict: "OK"))
        }
        await expectReadOnly { _ = try await reader.rollup(now: 10_000, maxBuckets: 10) }
        await expectReadOnly { _ = try await reader.retain(now: 10_000, maxRowsPerTable: 10) }
    }

    @Test("Invalid SQLite input fails without being overwritten")
    func invalidFile() throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let bytes = Data([0x13, 0x37, 0x00, 0xff, 0x41])
        try bytes.write(to: temporary.databaseURL)
        do {
            _ = try Database.open(at: temporary.databaseURL, mode: .readWrite)
            Issue.record("random bytes opened as SQLite")
        } catch let error as StoreError {
            switch error {
            case .openFailed, .sqlite: break
            default: Issue.record("wrong error: \(error)")
            }
        }
        #expect(try Data(contentsOf: temporary.databaseURL) == bytes)
    }

    @Test("A tick writes every row, preserves NULLs, and parameterizes strings")
    func writesTick() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        let dangerous = "Example '; DROP TABLE samples; -- 🚀"
        let tick = TickRows(
            system: SystemSampleRow(ts: 200),
            apps: [AppSampleRow(ts: 200, appKey: "com.example.Alpha", procs: 1)],
            processes: [ProcSampleRow(ts: 200, pid: 7, startUs: 8, appKey: "com.example.Alpha", name: dangerous)],
            appInfo: [AppInfo(appKey: "com.example.Alpha", name: dangerous, firstSeen: 200)]
        )
        try await database.write(tick)
        #expect(try await database.count(.samples) == 1)
        #expect(try await database.count(.appSamples) == 1)
        #expect(try await database.count(.procSamples) == 1)
        #expect(try StoreSQLite.scalarInt(temporary.databaseURL,
            "SELECT cpu_user IS NULL AND typeof(cpu_user)='null' FROM samples WHERE ts=200") == 1)
        #expect(try StoreSQLite.scalarText(temporary.databaseURL,
            "SELECT name FROM proc_samples WHERE ts=200 AND pid=7") == dangerous)
        #expect(try StoreSQLite.scalarInt(temporary.databaseURL,
            "SELECT count(*) FROM samples") == 1)
    }

    @Test("App registry keeps first_seen and refreshes descriptive fields")
    func appUpsert() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        try await database.write(sampleTick(ts: 100, name: "Example Helper"))
        try await database.write(sampleTick(ts: 200, name: "Example Helper Updated"))
        #expect(try StoreSQLite.scalarInt(temporary.databaseURL,
            "SELECT first_seen FROM apps WHERE app_key='com.example.Alpha'") == 100)
        #expect(try StoreSQLite.scalarText(temporary.databaseURL,
            "SELECT name FROM apps WHERE app_key='com.example.Alpha'") == "Example Helper Updated")
    }

    @Test(arguments: ["empty", "negative"])
    func invalidTickIsAtomic(kind: String) async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        var tick = sampleTick(ts: 300)
        if kind == "empty" { tick.apps[0].appKey = "" } else { tick.apps[0].procs = -1 }
        do {
            try await database.write(tick)
            Issue.record("invalid tick was accepted")
        } catch let error as StoreError {
            guard case .invalid = error else {
                Issue.record("wrong error: \(error)")
                return
            }
        }
        #expect(try await database.count(.samples) == 0)
        #expect(try await database.count(.appSamples) == 0)
        #expect(try await database.count(.procSamples) == 0)
        #expect(try await database.count(.apps) == 0)
    }

    @Test("Identity writes only when a non-timestamp value changes")
    func identityChanges() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        let first = IdentityRow(ts: 1, publicIP: "192.0.2.1", vpnState: "Disconnected",
                                routeTunnel: nil, verdict: "WARN")
        #expect(try await database.writeIdentityIfChanged(first))
        var same = first
        same.ts = 2
        #expect(try await database.writeIdentityIfChanged(same) == false)
        #expect(try await database.count(.identity) == 1)
        var changed = same
        changed.ts = 3
        changed.verdict = "OK"
        #expect(try await database.writeIdentityIfChanged(changed))
        var routeChanged = changed
        routeChanged.ts = 4
        routeChanged.routeTunnel = true
        #expect(try await database.writeIdentityIfChanged(routeChanged))
        #expect(try await database.count(.identity) == 3)
    }
}
