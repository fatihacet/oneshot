import Foundation
import SQLite3

public enum SQLiteError: LocalizedError {
    case open(String)
    case prepare(String, sql: String)
    case step(String)

    public var errorDescription: String? {
        switch self {
        case .open(let message): return "Could not open the database: \(message)"
        case .prepare(let message, let sql): return "SQL error: \(message) in \(sql)"
        case .step(let message): return "SQL error: \(message)"
        }
    }
}

enum SQLValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    init(_ string: String?) {
        self = string.map(SQLValue.text) ?? .null
    }
}

/// A minimal wrapper around the system SQLite library. Not thread-safe; use from one actor.
final class SQLiteConnection {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw SQLiteError.open(message)
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit {
        sqlite3_close(handle)
    }

    var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(error)
            throw SQLiteError.prepare(message, sql: sql)
        }
    }

    func prepare(_ sql: String, _ values: [SQLValue] = []) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError.prepare(lastErrorMessage, sql: sql)
        }
        let prepared = SQLiteStatement(statement: statement, connection: self)
        prepared.bind(values)
        return prepared
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try prepare(sql, values)
        _ = try statement.step()
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

final class SQLiteStatement {
    private let statement: OpaquePointer
    private let connection: SQLiteConnection
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(statement: OpaquePointer, connection: SQLiteConnection) {
        self.statement = statement
        self.connection = connection
    }

    deinit {
        sqlite3_finalize(statement)
    }

    func bind(_ values: [SQLValue]) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null:
                sqlite3_bind_null(statement, index)
            case .integer(let integer):
                sqlite3_bind_int64(statement, index, integer)
            case .real(let real):
                sqlite3_bind_double(statement, index, real)
            case .text(let text):
                sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .blob(let data):
                data.withUnsafeBytes { raw in
                    _ = sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(data.count), Self.transient)
                }
            }
        }
    }

    /// Advances to the next row. Returns false when done.
    func step() throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError.step(connection.lastErrorMessage)
        }
    }

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }

    func string(_ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }

    func data(_ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}
