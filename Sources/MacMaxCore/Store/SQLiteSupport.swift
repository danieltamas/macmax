import Foundation
import SQLite3

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A prepared statement on one connection. Used only inside the `Database` actor.
final class SQLiteStatement {
    private var statement: OpaquePointer?
    private let database: OpaquePointer

    init(_ database: OpaquePointer, _ sql: String) throws {
        self.database = database
        let code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard code == SQLITE_OK else { throw StoreError.sqlite(code: code, message: String(cString: sqlite3_errmsg(database))) }
    }

    deinit { sqlite3_finalize(statement) }

    func reset() throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    func bind(_ values: [SQLiteValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null: code = sqlite3_bind_null(statement, index)
            case let .int(number): code = sqlite3_bind_int64(statement, index, number)
            case let .real(number): code = sqlite3_bind_double(statement, index, number)
            case let .text(text): code = sqlite3_bind_text(statement, index, text, -1, transient)
            }
            guard code == SQLITE_OK else { throw StoreError.sqlite(code: code, message: String(cString: sqlite3_errmsg(database))) }
        }
    }

    /// Runs to completion; returns the rows changed.
    @discardableResult
    func run() throws -> Int {
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else {
            throw StoreError.sqlite(code: code, message: String(cString: sqlite3_errmsg(database)))
        }
        return Int(sqlite3_changes(database))
    }

    /// The first column of the first row as an integer, nil when there is no row or the value is NULL.
    func firstInt() throws -> Int64? {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw StoreError.sqlite(code: code, message: String(cString: sqlite3_errmsg(database))) }
        return sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 0)
    }

    /// Every row's first two columns as integers (bucket and count style queries).
    func column0() throws -> [Int64] {
        var values: [Int64] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return values }
            guard code == SQLITE_ROW else { throw StoreError.sqlite(code: code, message: String(cString: sqlite3_errmsg(database))) }
            values.append(sqlite3_column_int64(statement, 0))
        }
    }

    /// The text of the first column of every row.
    func textRows() throws -> [[String?]] {
        var rows: [[String?]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW else { throw StoreError.sqlite(code: code, message: String(cString: sqlite3_errmsg(database))) }
            rows.append((0 ..< sqlite3_column_count(statement)).map { column in
                sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(statement, column))
            })
        }
    }
}

enum SQLiteValue {
    case null, int(Int64), real(Double), text(String)

    init(_ value: Int64?) { self = value.map(SQLiteValue.int) ?? .null }
    init(_ value: Int?) { self = value.map { .int(Int64($0)) } ?? .null }
    init(_ value: Double?) { self = value.map(SQLiteValue.real) ?? .null }
    init(_ value: String?) { self = value.map(SQLiteValue.text) ?? .null }
    init(_ value: Bool?) { self = value.map { .int($0 ? 1 : 0) } ?? .null }
}
