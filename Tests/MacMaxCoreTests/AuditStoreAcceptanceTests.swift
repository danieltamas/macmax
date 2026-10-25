import Foundation
import SQLite3
import Testing
@testable import MacMaxCore

private struct AuditStoreDirectory {
    let root: URL
    let database: URL

    init() throws {
        root = try temporaryAuditDirectory("AuditStore")
        database = root.appendingPathComponent("macmax.db")
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private enum AuditRawSQLite {
    static func open(_ url: URL, flags: Int32 = SQLITE_OPEN_READONLY) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard code == SQLITE_OK, let handle else { throw StoreError.invalid("raw SQLite open failed") }
        return handle
    }

    static func text(_ url: URL, _ sql: String) throws -> String? {
        let db = try open(url)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.invalid("raw SQLite prepare failed")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: bytes)
    }

    static func integer(_ url: URL, _ sql: String) throws -> Int64 {
        let db = try open(url)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.invalid("raw SQLite prepare failed")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreError.invalid("raw SQLite row missing") }
        return sqlite3_column_int64(statement, 0)
    }

    static func execute(_ url: URL, _ sql: String) throws {
        let db = try open(url, flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "raw SQLite execution failed"
            sqlite3_free(error)
            throw StoreError.invalid(message)
        }
    }
}

@Suite("Database audit acceptance")
struct AuditStoreAcceptanceTests {
    @Test("writeAudit atomically stores sorted snapshot JSON and ordered findings with increasing ids")
    func writeAndLatestRoundTrip() async throws {
        let directory = try AuditStoreDirectory()
        defer { directory.remove() }
        let database = try Database.open(at: directory.database, mode: .readWrite)
        var snapshot = healthyAuditSnapshot()
        snapshot.timestamp = 2_000
        snapshot.swapUsedGB = .ok(7)
        snapshot.uptimeDays = .ok(31)
        let report = AuditEngine.evaluate(snapshot)
        let firstID = try await database.writeAudit(report, snapshot: snapshot, durationMilliseconds: 17)
        let secondID = try await database.writeAudit(report, snapshot: snapshot, durationMilliseconds: 18)
        #expect(secondID > firstID)
        #expect(try await database.count(.audits) == 2)
        #expect(try await database.count(.findings) == report.findings.count * 2)

        let storedJSON = try AuditRawSQLite.text(directory.database,
            "SELECT snapshot_json FROM audits WHERE id=\(firstID)")
        let json = try #require(storedJSON)
        #expect(json == String(decoding: try sortedSnapshotJSON(snapshot), as: UTF8.self))
        #expect(try JSONDecoder().decode(AuditSnapshot.self, from: Data(json.utf8)) == snapshot)

        let stored = try #require(try await database.latestAudit())
        #expect(stored.id == secondID)
        #expect(stored.timestamp == snapshot.timestamp)
        #expect(stored.durationMilliseconds == 18)
        #expect(stored.snapshot == snapshot)
        #expect(stored.verdict == report.verdict)
        #expect(stored.findings.map(\.ruleID) == report.findings.map(\.ruleID))
        #expect(stored.findings.map(\.severity) == report.findings.map(\.severity))
        #expect(stored.findings.map(\.title) == report.findings.map(\.title))
        #expect(stored.findings.map(\.evidence) == report.findings.map(\.evidence))
        for finding in stored.findings {
            let rule = try #require(RuleSet.all.first { $0.id == finding.ruleID })
            #expect(finding.why == rule.why)
            #expect(finding.action == rule.action)
            #expect(finding.scriptPattern == rule.scriptPattern)
        }
        #expect(stored.report == AuditReport(timestamp: report.timestamp, verdict: report.verdict,
                                             findings: stored.findings, unknowns: []))
    }

    @Test("writeAudit rolls back its audit row when any finding insert fails")
    func writeIsAtomic() async throws {
        let directory = try AuditStoreDirectory()
        defer { directory.remove() }
        let database = try Database.open(at: directory.database, mode: .readWrite)
        try AuditRawSQLite.execute(directory.database, """
            CREATE TRIGGER reject_synthetic_finding BEFORE INSERT ON findings
            BEGIN SELECT RAISE(ABORT, 'synthetic finding rejection'); END
            """)
        var snapshot = healthyAuditSnapshot()
        snapshot.swapUsedGB = .ok(7)
        do {
            _ = try await database.writeAudit(AuditEngine.evaluate(snapshot), snapshot: snapshot,
                                              durationMilliseconds: 1)
            Issue.record("a rejected finding insert unexpectedly succeeded")
        } catch {
            #expect(try await database.count(.audits) == 0)
            #expect(try await database.count(.findings) == 0)
        }
    }

    @Test("latestAudit is nil when empty, round-trips zero findings, and breaks timestamp ties by id")
    func latestOrderingAndEmptyReport() async throws {
        let directory = try AuditStoreDirectory()
        defer { directory.remove() }
        let database = try Database.open(at: directory.database, mode: .readWrite)
        #expect(try await database.latestAudit() == nil)
        var first = healthyAuditSnapshot()
        first.timestamp = 3_000
        let firstReport = AuditEngine.evaluate(first)
        let firstID = try await database.writeAudit(firstReport, snapshot: first, durationMilliseconds: 1)
        var second = first
        second.vpnShouldBeOn = true
        let secondReport = AuditEngine.evaluate(second)
        let secondID = try await database.writeAudit(secondReport, snapshot: second, durationMilliseconds: 2)
        #expect(firstReport.findings.isEmpty)
        #expect(secondID > firstID)
        let latest = try #require(try await database.latestAudit())
        #expect(latest.id == secondID)
        #expect(latest.snapshot == second)
        #expect(latest.findings == secondReport.findings)
    }

    @Test("Audit reads work read-only and writes throw StoreError.readOnly")
    func readOnlyContract() async throws {
        let directory = try AuditStoreDirectory()
        defer { directory.remove() }
        let writer = try Database.open(at: directory.database, mode: .readWrite)
        let snapshot = healthyAuditSnapshot()
        let report = AuditEngine.evaluate(snapshot)
        _ = try await writer.writeAudit(report, snapshot: snapshot, durationMilliseconds: 4)
        let reader = try Database.open(at: directory.database, mode: .readOnly)
        #expect(try await reader.latestAudit()?.snapshot == snapshot)
        do {
            _ = try await reader.writeAudit(report, snapshot: snapshot, durationMilliseconds: 5)
            Issue.record("read-only audit write unexpectedly succeeded")
        } catch let error as StoreError {
            #expect(error == .readOnly)
        }
    }

    @Test("Retention removes old audits and their findings but keeps recent audits")
    func auditRetention() async throws {
        let directory = try AuditStoreDirectory()
        defer { directory.remove() }
        let database = try Database.open(at: directory.database, mode: .readWrite)
        let now: Int64 = 20_000_000
        var old = healthyAuditSnapshot()
        old.timestamp = now - 91 * 86_400
        old.swapUsedGB = .ok(7)
        var recent = old
        recent.timestamp = now - 86_400
        let oldID = try await database.writeAudit(AuditEngine.evaluate(old), snapshot: old, durationMilliseconds: 1)
        let recentID = try await database.writeAudit(AuditEngine.evaluate(recent), snapshot: recent, durationMilliseconds: 1)
        _ = try await database.retain(now: now, maxRowsPerTable: 100)
        #expect(try AuditRawSQLite.integer(directory.database, "SELECT COUNT(*) FROM audits WHERE id=\(oldID)") == 0)
        #expect(try AuditRawSQLite.integer(directory.database, "SELECT COUNT(*) FROM findings WHERE audit_id=\(oldID)") == 0)
        #expect(try AuditRawSQLite.integer(directory.database, "SELECT COUNT(*) FROM audits WHERE id=\(recentID)") == 1)
        #expect(try AuditRawSQLite.integer(directory.database, "SELECT COUNT(*) FROM findings WHERE audit_id=\(recentID)") > 0)
    }

    @Test("appFootprints selects the newest complete tick at or before the target and omits NULLs")
    func appFootprints() async throws {
        let directory = try AuditStoreDirectory()
        defer { directory.remove() }
        let database = try Database.open(at: directory.database, mode: .readWrite)
        try await database.write(TickRows(system: SystemSampleRow(ts: 1_000), apps: [
            AppSampleRow(ts: 1_000, appKey: "a", footprint: 100),
            AppSampleRow(ts: 1_000, appKey: "b", footprint: 200),
            AppSampleRow(ts: 1_000, appKey: "null", footprint: nil),
        ]))
        try await database.write(TickRows(system: SystemSampleRow(ts: 1_010), apps: [
            AppSampleRow(ts: 1_010, appKey: "a", footprint: 150),
        ]))
        #expect(try await database.appFootprints(near: 1_005, toleranceSeconds: 10) == ["a": 100, "b": 200])
        #expect(try await database.appFootprints(near: 1_010, toleranceSeconds: 10) == ["a": 150])
        #expect(try await database.appFootprints(near: 900, toleranceSeconds: 50) == nil)
        #expect(try await database.appFootprints(near: 1_500, toleranceSeconds: 100) == nil)
    }
}

private func sortedSnapshotJSON(_ snapshot: AuditSnapshot) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return try encoder.encode(snapshot)
}
