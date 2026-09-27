import Foundation
import SQLite3

/// `SQLITE_TRANSIENT` tells SQLite to copy the bound buffer immediately, so
/// Swift `Data` lifetimes never outlive the call.
let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin, checked wrapper around one `sqlite3` connection.
///
/// The connection is not thread-safe; it must stay inside the owning actor.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    let path: String

    static func openReadWrite(path: String) throws -> SQLiteDatabase {
        try SQLiteDatabase(path: path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
    }

    static func openReadOnly(path: String) throws -> SQLiteDatabase {
        try SQLiteDatabase(path: path, flags: SQLITE_OPEN_READONLY)
    }

    init(path: String, flags: Int32) throws {
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open"
            if let handle {
                sqlite3_close_v2(handle)
            }
            throw SnapshotStoreError.sqlite(code: code, message: message)
        }
        self.handle = opened
        self.path = path
        sqlite3_extended_result_codes(opened, 1)
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    func close() {
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    var errorMessage: String {
        guard let handle else { return "database is closed" }
        return String(cString: sqlite3_errmsg(handle))
    }

    var lastErrorCode: Int32 {
        guard let handle else { return SQLITE_MISUSE }
        return sqlite3_errcode(handle)
    }

    func execute(_ sql: String) throws {
        guard let handle else {
            throw SnapshotStoreError.sqlite(code: SQLITE_MISUSE, message: "database is closed")
        }
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &error)
        guard code == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw SnapshotStoreError.sqlite(code: code, message: message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let handle else {
            throw SnapshotStoreError.sqlite(code: SQLITE_MISUSE, message: "database is closed")
        }
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw SnapshotStoreError.sqlite(code: code, message: errorMessage)
        }
        return SQLiteStatement(statement, database: self)
    }

    func lastInsertRowID() -> Int64 {
        guard let handle else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    func changes() -> Int {
        guard let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    /// Runs `body` inside `BEGIN IMMEDIATE ... COMMIT`. Any thrown error — from
    /// `body` or from `COMMIT` itself — attempts a rollback and rethrows the
    /// original failure, leaving the connection able to start a new
    /// transaction.
    func withTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Runs `body` inside a deferred read transaction. Used by the read-only
    /// connection so revision, aggregate, count and page are observed from one
    /// consistent snapshot. A `BEGIN DEFERRED` never takes a write lock, so it
    /// is valid on a `SQLITE_OPEN_READONLY` handle.
    func withReadTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN DEFERRED")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

/// Checked prepared statement. `finalize` is idempotent and also runs from
/// `deinit`, so a thrown error can never leak the statement.
final class SQLiteStatement {
    private var raw: OpaquePointer?
    private unowned let database: SQLiteDatabase
    private var finalized = false

    init(_ raw: OpaquePointer, database: SQLiteDatabase) {
        self.raw = raw
        self.database = database
    }

    deinit {
        if let raw {
            sqlite3_finalize(raw)
        }
    }

    func finalize() {
        guard let raw, !finalized else { return }
        sqlite3_finalize(raw)
        self.raw = nil
        finalized = true
    }

    private var handle: OpaquePointer {
        get throws {
            guard let raw else {
                throw SnapshotStoreError.sqlite(code: SQLITE_MISUSE, message: "statement is finalized")
            }
            return raw
        }
    }

    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK else {
            throw SnapshotStoreError.sqlite(code: code, message: database.errorMessage)
        }
    }

    func reset() throws {
        let code = sqlite3_reset(try handle)
        try check(code)
        let clearCode = sqlite3_clear_bindings(try handle)
        try check(clearCode)
    }

    func bindBlob(_ index: Int32, _ data: Data) throws {
        let raw = try handle
        let code = data.withUnsafeBytes { buffer -> Int32 in
            sqlite3_bind_blob(raw, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
        }
        try check(code)
    }

    func bindNull(_ index: Int32) throws {
        try check(sqlite3_bind_null(try handle, index))
    }

    func bindInt64(_ index: Int32, _ value: Int64) throws {
        try check(sqlite3_bind_int64(try handle, index, value))
    }

    func bindDouble(_ index: Int32, _ value: Double) throws {
        try check(sqlite3_bind_double(try handle, index, value))
    }

    func bindText(_ index: Int32, _ value: String) throws {
        let raw = try handle
        let code = value.withCString { pointer in
            sqlite3_bind_text(raw, index, pointer, -1, sqliteTransient)
        }
        try check(code)
    }

    /// Steps the statement. Returns `true` when a row is available and `false`
    /// when execution finished.
    func step() throws -> Bool {
        let code = sqlite3_step(try handle)
        switch code {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw SnapshotStoreError.sqlite(code: code, message: database.errorMessage)
        }
    }

    func columnCount() -> Int {
        guard let raw else { return 0 }
        return Int(sqlite3_column_count(raw))
    }

    func columnIsNull(_ index: Int32) -> Bool {
        guard let raw else { return true }
        return sqlite3_column_type(raw, index) == SQLITE_NULL
    }

    func columnBlob(_ index: Int32) -> Data? {
        guard let raw, !columnIsNull(index) else { return nil }
        let count = Int(sqlite3_column_bytes(raw, index))
        guard count > 0 else { return Data() }
        guard let pointer = sqlite3_column_blob(raw, index) else { return Data() }
        return Data(bytes: pointer, count: count)
    }

    func columnInt64(_ index: Int32) -> Int64 {
        guard let raw else { return 0 }
        return sqlite3_column_int64(raw, index)
    }

    func columnDouble(_ index: Int32) -> Double {
        guard let raw else { return 0 }
        return sqlite3_column_double(raw, index)
    }

    func columnText(_ index: Int32) -> String? {
        guard let raw, !columnIsNull(index), let pointer = sqlite3_column_text(raw, index) else {
            return nil
        }
        return String(cString: pointer)
    }
}
