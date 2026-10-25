import Foundation
import SQLite3
import Testing
@testable import MacMaxCore

private struct ReaderObservation: Sendable {
    let samples: Int
    let appSamples: Int
    let procSamples: Int
}

private func concurrencyTick(_ index: Int) -> TickRows {
    let ts = Int64(1_000_000 + index)
    var apps: [AppSampleRow] = []
    for app in 0..<40 {
        apps.append(AppSampleRow(ts: ts, appKey: "com.example.App\(app)", cpu: Double(app),
                                 footprint: Int64(10_000 + app), diskReadBps: Double(app),
                                 diskWriteBps: Double(app), netInBytes: Int64(app),
                                 netOutBytes: Int64(app), procs: 1))
    }
    var processes: [ProcSampleRow] = []
    for process in 0..<30 {
        processes.append(ProcSampleRow(ts: ts, pid: Int32(1_000 + process), startUs: Int64(process),
                                       appKey: "com.example.App\(process)", name: "Example Helper \(process)",
                                       cpu: Double(process), footprint: Int64(20_000 + process)))
    }
    let info = (0..<40).map { app in
        AppInfo(appKey: "com.example.App\(app)", name: "Example App \(app)", firstSeen: ts)
    }
    return TickRows(system: SystemSampleRow(ts: ts, cpuUser: 1, cpuSystem: 2,
                                            memUsed: 3, diskFree: 4),
                    apps: apps, processes: processes, appInfo: info)
}

private func rawCounts(_ url: URL) throws -> ReaderObservation {
    let handle = try StoreSQLite.open(url)
    defer { sqlite3_close(handle) }
    sqlite3_busy_timeout(handle, 2_000)
    func count(_ table: String) throws -> Int {
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(handle, "SELECT count(*) FROM \(table)", -1, &statement, nil)
        guard prepare == SQLITE_OK, let statement else {
            throw StoreError.sqlite(code: prepare, message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            throw StoreError.sqlite(code: step, message: String(cString: sqlite3_errmsg(handle)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
    return try ReaderObservation(samples: count("samples"), appSamples: count("app_samples"),
                                 procSamples: count("proc_samples"))
}

private func assertNeverDecreases(_ values: [ReaderObservation]) {
    for pair in zip(values, values.dropFirst()) {
        #expect(pair.1.samples >= pair.0.samples)
        #expect(pair.1.appSamples >= pair.0.appSamples)
        #expect(pair.1.procSamples >= pair.0.procSamples)
    }
}

@Suite("StoreConcurrencyAcceptance")
struct StoreConcurrencyAcceptanceTests {
    @Test("Database and raw SQLite readers run alongside the writer without busy errors",
          .timeLimit(.minutes(1)))
    func readersAndWriter() async throws {
        let startedAt = ContinuousClock.now
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let writer = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        let reader = try Database.open(at: temporary.databaseURL, mode: .readOnly)

        async let writes: Void = {
            for index in 0..<300 { try await writer.write(concurrencyTick(index)) }
        }()
        async let actorReads: [ReaderObservation] = {
            var observations: [ReaderObservation] = []
            for _ in 0..<200 {
                observations.append(try await ReaderObservation(
                    samples: reader.count(.samples),
                    appSamples: reader.count(.appSamples),
                    procSamples: reader.count(.procSamples)
                ))
                await Task.yield()
            }
            return observations
        }()
        async let sqliteReads: [ReaderObservation] = {
            var observations: [ReaderObservation] = []
            for _ in 0..<200 {
                observations.append(try rawCounts(temporary.databaseURL))
                await Task.yield()
            }
            return observations
        }()

        let (_, actorValues, sqliteValues) = try await (writes, actorReads, sqliteReads)
        assertNeverDecreases(actorValues)
        assertNeverDecreases(sqliteValues)
        #expect(try await writer.count(.samples) == 300)
        #expect(try await writer.count(.appSamples) == 12_000)
        #expect(try await writer.count(.procSamples) == 9_000)
        #expect(try await writer.count(.apps) == 40)
        #expect(startedAt.duration(to: .now) < .seconds(20))
    }

    @Test("Rollup and retention do not block concurrent readers", .timeLimit(.minutes(1)))
    func maintenanceAndReaders() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let writer = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        for index in 0..<120 { try await writer.write(concurrencyTick(index)) }
        let reader = try Database.open(at: temporary.databaseURL, mode: .readOnly)

        async let maintenance: Void = {
            for _ in 0..<10 {
                _ = try await writer.rollup(now: 2_000_000, maxBuckets: 2)
                _ = try await writer.retain(now: 2_000_000, maxRowsPerTable: 5)
            }
        }()
        async let reads: Void = {
            for _ in 0..<200 {
                _ = try await reader.count(.samples)
                _ = try rawCounts(temporary.databaseURL)
                await Task.yield()
            }
        }()
        _ = try await (maintenance, reads)
    }
}
