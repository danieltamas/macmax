import Foundation
import SQLite3

public enum DatabaseMode: Sendable { case readWrite, readOnly }

public enum StoreTable: String, Sendable, CaseIterable {
    case apps, samples
    case appSamples = "app_samples"
    case procSamples = "proc_samples"
    case samples1m = "samples_1m"
    case appSamples1m = "app_samples_1m"
    case samples1h = "samples_1h"
    case appSamples1h = "app_samples_1h"
    case identity, audits, findings, actions
}

public enum StoreError: Error, Equatable {
    /// The database was opened read-only.
    case readOnly
    /// The file was written by a newer MacMax; it can be read, never written.
    case schemaTooNew(found: Int, supported: Int)
    case openFailed(String)
    case sqlite(code: Int32, message: String)
    case invalid(String)
}

/// `~/.macmax/macmax.db`: SQLite through the system library, WAL, one writer. The schema is in
/// docs/ARCHITECTURE.md (Store). A `readOnly` handle never writes: the CLI and the MCP server use it.
public actor Database {
    public static let schemaVersion = 1
    private static let busyTimeoutMilliseconds: Int32 = 2000
    private static let busyRetries = 3

    /// Only the actor's own methods use it, one at a time; `open` uses it before the actor is shared.
    nonisolated(unsafe) let handle: OpaquePointer
    let mode: DatabaseMode
    private let url: URL

    private init(handle: OpaquePointer, mode: DatabaseMode, url: URL) {
        self.handle = handle
        self.mode = mode
        self.url = url
    }

    deinit { sqlite3_close_v2(handle) }

    public static func open(at url: URL, mode: DatabaseMode) throws -> Database {
        let path = url.path
        let exists = FileManager.default.fileExists(atPath: path)
        if mode == .readOnly, !exists { throw StoreError.openFailed("the database does not exist") }
        if mode == .readWrite {
            // Newer than this build: refuse before anything is written to the file.
            if exists, let found = try peekVersion(path), found > schemaVersion {
                throw StoreError.schemaTooNew(found: found, supported: schemaVersion)
            }
            if !exists { FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            try restrictPermissions(path)
        }
        var raw: OpaquePointer?
        let flags = mode == .readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(path, &raw, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let raw else {
            let message = raw.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open"
            sqlite3_close_v2(raw)
            throw StoreError.openFailed(message)
        }
        sqlite3_busy_timeout(raw, busyTimeoutMilliseconds)
        do {
            if mode == .readWrite { try migrate(raw) } else { _ = try readUserVersion(raw) }
        } catch let error as StoreError {
            sqlite3_close_v2(raw)
            if case let .sqlite(code, message) = error, code == SQLITE_NOTADB || code == SQLITE_CORRUPT {
                throw StoreError.openFailed(message)
            }
            throw error
        }
        let database = Database(handle: raw, mode: mode, url: url)
        // SQLite creates the -wal and -shm files at the first WAL write with the process umask.
        if mode == .readWrite { try restrictPermissions(path) }
        return database
    }

    /// The history is personal data: owner-only on the database and its WAL files, also when an older run left them open.
    private static func restrictPermissions(_ path: String) throws {
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
            do { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path + suffix) } catch {
                throw StoreError.openFailed("could not restrict the permissions of the database")
            }
        }
    }

    /// `PRAGMA user_version` of the open file.
    public func userVersion() throws -> Int { try readUserVersion() }

    public func count(_ table: StoreTable) throws -> Int {
        Int(try query("SELECT COUNT(*) FROM \(table.rawValue)").firstInt() ?? 0)
    }

    /// The database file plus its WAL, in bytes.
    public func fileSizeBytes() -> Int64 {
        [url.path, url.path + "-wal"].reduce(0) { total, path in
            total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0)
        }
    }

    // MARK: - Internal helpers shared with the write and maintenance extensions

    func requireWritable() throws {
        guard mode == .readWrite else { throw StoreError.readOnly }
    }

    func query(_ sql: String, _ values: [SQLiteValue] = []) throws -> SQLiteStatement {
        try Self.query(handle, sql, values)
    }

    @discardableResult
    func execute(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int { try Self.execute(handle, sql, values) }

    func transaction<T>(_ body: () throws -> T) throws -> T { try Self.transaction(handle, body) }

    private func readUserVersion() throws -> Int { try Self.readUserVersion(handle) }

    // The primitives take the handle so `open` can migrate before the actor is shared; the isolated wrappers above
    // are the only way for other code to reach the connection, which keeps a transaction from interleaving.

    private static func query(_ handle: OpaquePointer, _ sql: String, _ values: [SQLiteValue] = []) throws -> SQLiteStatement {
        let statement = try SQLiteStatement(handle, sql)
        try statement.bind(values)
        return statement
    }

    /// Runs one statement; a busy or locked database is retried a few times (the busy timeout already waited).
    @discardableResult
    private static func execute(_ handle: OpaquePointer, _ sql: String, _ values: [SQLiteValue] = []) throws -> Int {
        var attempt = 0
        while true {
            do { return try query(handle, sql, values).run() } catch let StoreError.sqlite(code, message) {
                attempt += 1
                guard (code == SQLITE_BUSY || code == SQLITE_LOCKED), attempt < busyRetries else {
                    throw StoreError.sqlite(code: code, message: message)
                }
            }
        }
    }

    /// `BEGIN IMMEDIATE ... COMMIT`; any error rolls everything back.
    private static func transaction<T>(_ handle: OpaquePointer, _ body: () throws -> T) throws -> T {
        try execute(handle, "BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute(handle, "COMMIT")
            return result
        } catch {
            _ = try? execute(handle, "ROLLBACK")
            throw error
        }
    }

    private static func readUserVersion(_ handle: OpaquePointer) throws -> Int {
        Int(try query(handle, "PRAGMA user_version").firstInt() ?? 0)
    }

    private static func migrate(_ handle: OpaquePointer) throws {
        let found = try readUserVersion(handle)
        if found > schemaVersion { throw StoreError.schemaTooNew(found: found, supported: schemaVersion) }
        _ = try query(handle, "PRAGMA journal_mode=WAL").textRows()
        guard found < schemaVersion else { return }
        try transaction(handle) {
            for statement in DatabaseSchema.statements { try execute(handle, statement) }
            try execute(handle, "PRAGMA user_version = \(schemaVersion)")
        }
    }

    /// The version of a file without writing to it; nil for an empty file.
    private static func peekVersion(_ path: String) throws -> Int? {
        var raw: OpaquePointer?
        guard sqlite3_open_v2(path, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let raw else {
            sqlite3_close_v2(raw)
            throw StoreError.openFailed("could not read the database")
        }
        defer { sqlite3_close_v2(raw) }
        let statement: SQLiteStatement
        do { statement = try SQLiteStatement(raw, "PRAGMA user_version") } catch let StoreError.sqlite(code, message) {
            throw StoreError.openFailed(code == SQLITE_NOTADB ? "not a MacMax database" : message)
        }
        do { return try statement.firstInt().map(Int.init) } catch let StoreError.sqlite(code, message) {
            throw code == SQLITE_NOTADB || code == SQLITE_CORRUPT ? StoreError.openFailed("not a MacMax database") : StoreError.sqlite(code: code, message: message)
        }
    }
}
