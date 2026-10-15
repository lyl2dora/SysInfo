// 系统 libsqlite3 的薄封装（CPU 模块设计 §6，D23：Apple SDK 自带，不算第三方依赖）。
//
// 只提供历史库用到的部分：打开、执行、预编译语句（按名缓存）、绑定、逐行读取、事务。
// 不是线程安全的：由持有它的一方（HistoryStore 所在的 actor，或 CLI 的单线程）串行使用。

import Foundation
import SQLite3

/// SQLite 调用失败。
public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public var code: Int32
    public var message: String
    public var context: String

    public var description: String { "\(context): [\(code)] \(message)" }
}

/// `SQLITE_TRANSIENT`：让 SQLite 立即复制绑定的文本（C 宏，Swift 里不可见）。
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    let path: String

    /// 打开（必要时创建）数据库文件。`path` 为 `:memory:` 时是内存库（测试用）。
    init(path: String) throws(SQLiteError) {
        self.path = path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(db)
            throw SQLiteError(code: rc, message: message, context: "open")
        }
        handle = db
        sqlite3_busy_timeout(db, 2000)
    }

    deinit {
        close()
    }

    func close() {
        for statement in statements.values { sqlite3_finalize(statement) }
        statements = [:]
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    private func error(_ rc: Int32, _ context: String) -> SQLiteError {
        SQLiteError(code: rc, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed", context: context)
    }

    /// 执行一段不返回行的 SQL（可以有多条语句）。
    func execute(_ sql: String) throws(SQLiteError) {
        let rc = sqlite3_exec(handle, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw error(rc, sql.prefix(60).description) }
    }

    /// 在一个事务里执行 `body`；抛错时回滚。
    func transaction<T>(_ body: () throws(SQLiteError) -> T) throws(SQLiteError) -> T {
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

    /// 取（并缓存）预编译语句，复位后返回。
    func statement(_ sql: String) throws(SQLiteError) -> Statement {
        if let cached = statements[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return Statement(raw: cached, database: self, sql: sql)
        }
        var raw: OpaquePointer?
        let rc = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &raw, nil)
        guard rc == SQLITE_OK, let raw else { throw error(rc, "prepare \(sql.prefix(60))") }
        statements[sql] = raw
        return Statement(raw: raw, database: self, sql: sql)
    }

    /// 读一个整数 PRAGMA（例如 `user_version`）。
    func pragmaInt(_ name: String) throws(SQLiteError) -> Int64 {
        // 读完就复位：留着一条没走完的读语句，之后的 wal_checkpoint(TRUNCATE) 会报 SQLITE_LOCKED（2026-10-15 自查发现）。
        try statement("PRAGMA \(name)").query { $0.int(0) }.first ?? 0
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }

    struct Statement {
        let raw: OpaquePointer
        unowned let database: SQLiteDatabase
        let sql: String

        /// 按位置绑定（从 1 开始）。
        func bind(_ values: [SQLiteValue]) throws(SQLiteError) {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let rc: Int32
                switch value {
                case .null: rc = sqlite3_bind_null(raw, index)
                case .int(let v): rc = sqlite3_bind_int64(raw, index, v)
                case .double(let v): rc = sqlite3_bind_double(raw, index, v)
                case .text(let v): rc = sqlite3_bind_text(raw, index, v, -1, sqliteTransient)
                }
                guard rc == SQLITE_OK else { throw database.error(rc, "bind \(index) in \(sql.prefix(60))") }
            }
        }

        /// 执行一步；有行时返回 true。
        @discardableResult
        func step() throws(SQLiteError) -> Bool {
            let rc = sqlite3_step(raw)
            switch rc {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw database.error(rc, "step \(sql.prefix(60))")
            }
        }

        /// 绑定并执行到底（不返回行的语句）。
        func run(_ values: [SQLiteValue] = []) throws(SQLiteError) {
            try bind(values)
            while try step() {}
            sqlite3_reset(raw)
        }

        /// 绑定并逐行读取。
        func query<T>(_ values: [SQLiteValue] = [], _ row: (Statement) -> T) throws(SQLiteError) -> [T] {
            try bind(values)
            var out: [T] = []
            while try step() { out.append(row(self)) }
            sqlite3_reset(raw)
            return out
        }

        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(raw, column) == SQLITE_NULL }
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(raw, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(raw, column) }
        func optionalDouble(_ column: Int32) -> Double? { isNull(column) ? nil : double(column) }
        func optionalInt(_ column: Int32) -> Int64? { isNull(column) ? nil : int(column) }
        func text(_ column: Int32) -> String {
            guard let c = sqlite3_column_text(raw, column) else { return "" }
            return String(cString: c)
        }
    }
}

enum SQLiteValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)

    static func int(_ v: Int) -> SQLiteValue { .int(Int64(v)) }
    static func optional(_ v: Double?) -> SQLiteValue { v.map { .double($0) } ?? .null }
    static func optional(_ v: Int64?) -> SQLiteValue { v.map { .int($0) } ?? .null }
}
