import Foundation
import SwiftToolchainCSQLite

/// A failure that SQLite reported, with its extended result code and its own message.
public struct SQLiteError: Error, Equatable, CustomStringConvertible {
    public let code: Int32
    public let message: String
    /// The database file, so that a failure names where Muxify keeps its state.
    public let path: String

    /// SQLite gave up waiting for another connection's lock: the busy timeout ran out.
    public var isBusy: Bool { code & 0xFF == SQLITE_BUSY }

    public var description: String {
        isBusy ? "Another Muxify process holds \((path as NSString).lastPathComponent) for too long."
               : "Muxify could not read or write its state in \(path). SQLite: \(message)."
    }
}

/// A value SQLite can store in a column: `nil` binds NULL.
public protocol SQLiteBindable {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32
}

extension Int: SQLiteBindable {
    public func bind(to statement: OpaquePointer, at index: Int32) -> Int32 { sqlite3_bind_int64(statement, index, Int64(self)) }
}

extension Int64: SQLiteBindable {
    public func bind(to statement: OpaquePointer, at index: Int32) -> Int32 { sqlite3_bind_int64(statement, index, self) }
}

extension Bool: SQLiteBindable {
    public func bind(to statement: OpaquePointer, at index: Int32) -> Int32 { sqlite3_bind_int64(statement, index, self ? 1 : 0) }
}

extension Double: SQLiteBindable {
    public func bind(to statement: OpaquePointer, at index: Int32) -> Int32 { sqlite3_bind_double(statement, index, self) }
}

extension String: SQLiteBindable {
    public func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        sqlite3_bind_text(statement, index, self, -1, SQLiteStatement.transient)
    }
}

extension Data: SQLiteBindable {
    public func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), SQLiteStatement.transient) }
    }
}

/// One connection to a SQLite database file. Use it from one thread at a time: a transaction belongs to the
/// connection, not to the thread that began it.
public final class SQLiteConnection {
    public let path: String
    private let handle: OpaquePointer

    /// Opens the file for reading and writing, and creates it when it is missing. The folder must exist.
    public init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard let handle else { throw SQLiteError(code: result, message: String(cString: sqlite3_errstr(result)), path: path) }
        guard result == SQLITE_OK else {
            let error = SQLiteError(code: sqlite3_extended_errcode(handle), message: String(cString: sqlite3_errmsg(handle)), path: path)
            sqlite3_close_v2(handle)
            throw error
        }
        sqlite3_extended_result_codes(handle, 1)
        self.handle = handle
    }

    deinit { sqlite3_close_v2(handle) }

    /// How long a statement waits for another connection's lock before it fails with a busy error.
    public func setBusyTimeout(_ seconds: TimeInterval) throws {
        try check(sqlite3_busy_timeout(handle, Int32(seconds * 1000)))
    }

    /// Compiles one statement. Bind its `?` parameters, then step it.
    public func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
        guard let statement else { throw SQLiteError(code: SQLITE_MISUSE, message: "no statement in \(sql)", path: path) }
        return SQLiteStatement(statement, connection: self)
    }

    /// Runs one statement with these arguments to its end, and drops any rows it gives.
    public func execute(_ sql: String, _ arguments: (any SQLiteBindable)?...) throws {
        let statement = try prepare(sql)
        try statement.bind(arguments)
        while try statement.step() {}
    }

    /// Runs one statement with these arguments and gives each row it returns through `row`.
    public func query<T>(_ sql: String, _ arguments: (any SQLiteBindable)?..., row: (SQLiteStatement) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        try statement.bind(arguments)
        var rows: [T] = []
        while try statement.step() { rows.append(try row(statement)) }
        return rows
    }

    /// Runs `body` in a transaction: it commits when `body` returns and rolls back when it throws. The outer
    /// transaction takes the write lock at once (`BEGIN IMMEDIATE`), so it waits out the busy timeout there and never
    /// fails later on a lock it could not upgrade. A transaction inside another is a savepoint of the outer one.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        let outer = sqlite3_get_autocommit(handle) != 0
        let savepoint = "muxify_\(depth)"
        try execute(outer ? "BEGIN IMMEDIATE" : "SAVEPOINT \(savepoint)")
        depth += 1
        defer { depth -= 1 }
        let value: T
        do {
            value = try body()
        } catch {
            if outer {
                try? execute("ROLLBACK")
            } else {
                try? execute("ROLLBACK TO \(savepoint)")
                try? execute("RELEASE \(savepoint)")
            }
            throw error
        }
        do {
            try execute(outer ? "COMMIT" : "RELEASE \(savepoint)")
        } catch {
            try? execute(outer ? "ROLLBACK" : "ROLLBACK TO \(savepoint)")
            throw error
        }
        return value
    }

    private var depth = 0

    func check(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw lastError() }
    }

    /// The failure of the last call on this connection that failed.
    func lastError() -> SQLiteError {
        SQLiteError(code: sqlite3_extended_errcode(handle), message: String(cString: sqlite3_errmsg(handle)), path: path)
    }
}

/// A compiled statement. Its columns are read by index, from 0, after a `step` that gave a row.
public final class SQLiteStatement {
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let handle: OpaquePointer
    private let connection: SQLiteConnection

    init(_ handle: OpaquePointer, connection: SQLiteConnection) {
        self.handle = handle
        self.connection = connection
    }

    deinit { sqlite3_finalize(handle) }

    /// Binds the `?` parameters in order, after a reset, so one statement runs again with new values.
    public func bind(_ arguments: [(any SQLiteBindable)?]) throws {
        try connection.check(sqlite3_reset(handle))
        try connection.check(sqlite3_clear_bindings(handle))
        for (offset, argument) in arguments.enumerated() {
            let index = Int32(offset + 1)
            try connection.check(argument.map { $0.bind(to: handle, at: index) } ?? sqlite3_bind_null(handle, index))
        }
    }

    /// Runs the statement to its next row: true when there is a row to read, false when it is done.
    public func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            let error = connection.lastError()
            sqlite3_reset(handle)
            throw error
        }
    }

    public func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }
    public func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(handle, column)) }
    public func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    public func bool(_ column: Int32) -> Bool { sqlite3_column_int64(handle, column) != 0 }

    /// The column as text, or `nil` when it is NULL.
    public func text(_ column: Int32) -> String? {
        guard let text = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: text)
    }

    /// The column as bytes, or `nil` when it is NULL.
    public func data(_ column: Int32) -> Data? {
        guard !isNull(column) else { return nil }
        let count = Int(sqlite3_column_bytes(handle, column))
        guard count > 0, let bytes = sqlite3_column_blob(handle, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}
