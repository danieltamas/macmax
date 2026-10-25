import Foundation
import SQLite3
import Testing
@testable import MacMaxCore

private func allStoredText(_ url: URL) throws -> [String] {
    let handle = try StoreSQLite.open(url)
    defer { sqlite3_close(handle) }
    var tableStatement: OpaquePointer?
    guard sqlite3_prepare_v2(handle,
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
        -1, &tableStatement, nil) == SQLITE_OK, let tableStatement else {
        throw StoreError.invalid("cannot enumerate tables")
    }
    defer { sqlite3_finalize(tableStatement) }
    var tables: [String] = []
    while sqlite3_step(tableStatement) == SQLITE_ROW {
        if let value = sqlite3_column_text(tableStatement, 0) { tables.append(String(cString: value)) }
    }
    var values: [String] = []
    for table in tables {
        var info: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA table_info(\(table))", -1, &info, nil) == SQLITE_OK,
              let info else { throw StoreError.invalid("cannot inspect \(table)") }
        var textColumns: [String] = []
        while sqlite3_step(info) == SQLITE_ROW {
            let type = sqlite3_column_text(info, 2).map { String(cString: $0).uppercased() } ?? ""
            if type.contains("TEXT"), let name = sqlite3_column_text(info, 1) {
                textColumns.append(String(cString: name))
            }
        }
        sqlite3_finalize(info)
        for column in textColumns {
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT \(column) FROM \(table) WHERE \(column) IS NOT NULL",
                                     -1, &query, nil) == SQLITE_OK, let query else {
                throw StoreError.invalid("cannot read \(table).\(column)")
            }
            while sqlite3_step(query) == SQLITE_ROW {
                if let value = sqlite3_column_text(query, 0) { values.append(String(cString: value)) }
            }
            sqlite3_finalize(query)
        }
    }
    return values
}

@Suite("SamplerAcceptance", .serialized)
struct SamplerAcceptanceTests {
    @Test("A real tick writes one bounded, timestamped snapshot", .timeLimit(.minutes(1)))
    func oneTick() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        let sampler = Sampler(database: database)
        let now = Date(timeIntervalSince1970: 10_000.75)
        let tick = try await sampler.tick(now: now)

        #expect(tick.system.ts == 10_000)
        #expect(try await database.count(.samples) == 1)
        #expect(tick.apps.count >= 1 && tick.apps.count <= 40)
        #expect(tick.processes.count >= 1 && tick.processes.count <= 30)
        #expect(tick.apps.allSatisfy { !$0.appKey.isEmpty })
        #expect(tick.processes.allSatisfy { !$0.appKey.isEmpty })
        #expect(tick.apps.allSatisfy { $0.cpu == nil && $0.diskReadBps == nil && $0.diskWriteBps == nil })
        #expect(tick.apps.allSatisfy { $0.netInBytes == nil && $0.netOutBytes == nil })
        #expect(tick.processes.allSatisfy { $0.cpu == nil })
        #expect(tick.system.thermal != nil)
        #expect(tick.system.memUsed != nil)
        #expect(tick.system.diskFree != nil)
    }

    @Test("A second real tick produces at least one CPU measurement", .timeLimit(.minutes(1)))
    func secondTickCPU() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        let sampler = Sampler(database: database)
        _ = try await sampler.tick(now: .now)
        try await Task.sleep(for: .milliseconds(2_500))
        let second = try await sampler.tick(now: .now)
        #expect(second.apps.contains { $0.cpu != nil })
    }

    @Test("Command-line secrets never reach SQLite text or database bytes", .timeLimit(.minutes(1)))
    func commandLinesAreAbsent() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let secret = "--api-key=examplesecretvalue"
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30", secret]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        let sampler = Sampler(database: database)
        _ = try await sampler.tick(now: .now)

        #expect(try allStoredText(temporary.databaseURL).allSatisfy { !$0.contains("--api-key") })
        let needle = Data(secret.utf8)
        for suffix in ["", "-wal"] {
            let file = URL(fileURLWithPath: temporary.databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) {
                #expect(try Data(contentsOf: file).range(of: needle) == nil)
            }
        }
    }

    @Test("The run loop ticks at five seconds and promptly honors cancellation", .timeLimit(.minutes(1)))
    func runAndCancel() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        let sampler = Sampler(database: database)
        let task = Task { await sampler.run(every: .five) }
        try await Task.sleep(for: .seconds(6))
        let cancelledAt = ContinuousClock.now
        task.cancel()
        await task.value
        let cancellationDelay = cancelledAt.duration(to: .now)
        #expect(cancellationDelay < .seconds(2))
        let samples = try await database.count(.samples)
        #expect(samples >= 1 && samples <= 3)
    }
}
