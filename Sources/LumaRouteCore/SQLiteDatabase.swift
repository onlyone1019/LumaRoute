import Foundation
import SQLite3
import Darwin

/// All statements and whole transactions share one lock, including secret reads
/// from detached tasks. FULLMUTEX alone does not isolate a multi-statement commit.
final class SQLiteDatabase: @unchecked Sendable {
    let file: URL
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to:sqlite3_destructor_type.self)
    enum Value { case text(String), blob(Data), integer(Int) }

    init(file: URL, readOnly: Bool = false) throws {
        self.file = file
        if !readOnly {
            let fd = Darwin.open(file.path,O_CREAT | O_EXCL | O_WRONLY,0o600)
            if fd >= 0 { Darwin.close(fd) }
            else if errno != EEXIST { throw LumaError.message("无法创建本地数据库") }
            let attributes = try FileManager.default.attributesOfItem(atPath:file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw LumaError.message("本地数据库文件或归属无效")
            }
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        }
        let flags = (readOnly ? SQLITE_OPEN_READONLY:SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(file.path,&handle,flags,nil)
        guard result == SQLITE_OK else {
            sqlite3_close(handle); handle = nil
            throw failure(result)
        }
        do {
            sqlite3_busy_timeout(handle,500)
            let version = try rows("PRAGMA user_version").first?.first.flatMap { Int(String(decoding:$0,as:UTF8.self)) } ?? -1
            guard version == 1 || (!readOnly && version == 0) else { throw LumaError.message("本地数据库版本不受支持") }
            if !readOnly {
                _ = try rows("PRAGMA journal_mode=DELETE")
                _ = try rows("PRAGMA secure_delete=ON")
                if version == 0 { try transaction {
                    try execute("CREATE TABLE IF NOT EXISTS app_state (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL)")
                    for table in ["profiles","custom_rules","group_strategies","rule_subscriptions"] {
                        try execute("CREATE TABLE IF NOT EXISTS \(table) (id TEXT PRIMARY KEY, ordinal INTEGER NOT NULL, payload BLOB NOT NULL)")
                    }
                    try execute("CREATE TABLE IF NOT EXISTS choices (name TEXT PRIMARY KEY, node TEXT NOT NULL)")
                    try execute("CREATE TABLE IF NOT EXISTS profile_contents (profile_id TEXT NOT NULL, version TEXT NOT NULL, content TEXT NOT NULL, PRIMARY KEY(profile_id,version))")
                    try execute("CREATE TABLE IF NOT EXISTS rule_contents (revision TEXT PRIMARY KEY, content TEXT NOT NULL)")
                    try execute("CREATE TABLE IF NOT EXISTS secrets (name TEXT PRIMARY KEY, value TEXT NOT NULL)")
                    try execute("PRAGMA user_version=1")
                } }
            }
        } catch {
            sqlite3_close(handle); handle = nil
            throw error
        }
    }
    deinit { sqlite3_close(handle) }
    private func failure(_ code: Int32) -> Error {
        // SQLite's detailed error can contain bound credential values.
        LumaError.message("本地数据库操作失败（SQLite \(code)）")
    }
    private func prepare(_ sql: String,_ values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle,sql,-1,&statement,nil)
        guard result == SQLITE_OK,let statement else { throw failure(result) }
        do {
            for (index,value) in values.enumerated() {
                let binding: Int32
                switch value {
                case .integer(let number): binding = sqlite3_bind_int64(statement,Int32(index+1),Int64(number))
                case .text(let text):
                    let bytes = Array(text.utf8) + [0]
                    binding = bytes.withUnsafeBufferPointer {
                        sqlite3_bind_text(statement,Int32(index+1),UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to:CChar.self),Int32(bytes.count-1),Self.transient)
                    }
                case .blob(let data):
                    if data.isEmpty { binding = sqlite3_bind_zeroblob(statement,Int32(index+1),0) }
                    else { binding = data.withUnsafeBytes { sqlite3_bind_blob(statement,Int32(index+1),$0.baseAddress,Int32(data.count),Self.transient) } }
                }
                guard binding == SQLITE_OK else { throw failure(binding) }
            }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }
    func execute(_ sql: String,_ values: [Value] = []) throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql,values); defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw failure(result) }
    }
    func rows(_ sql: String,_ values: [Value] = []) throws -> [[Data]] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql,values); defer { sqlite3_finalize(statement) }
        var output: [[Data]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return output }
            guard result == SQLITE_ROW else { throw failure(result) }
            var row: [Data] = []
            for column in 0..<sqlite3_column_count(statement) {
                let count = Int(sqlite3_column_bytes(statement,column))
                if let bytes = sqlite3_column_blob(statement,column),count > 0 { row.append(Data(bytes:bytes,count:count)) }
                else { row.append(Data()) }
            }
            output.append(row)
        }
    }
    func transaction<T>(write: Bool = true,_ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute(write ? "BEGIN IMMEDIATE":"BEGIN")
        do { let result = try operation(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
}
