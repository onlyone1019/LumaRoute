import Foundation

public protocol SecretStore {
    func read(_ key: String) throws -> String?
    func write(_ value: String, key: String) throws
    func delete(_ key: String) throws
}
public final class SQLiteSecrets: SecretStore, @unchecked Sendable {
    private let database: SQLiteDatabase
    init(database: SQLiteDatabase) { self.database = database }
    public func read(_ key: String) throws -> String? {
        try database.rows("SELECT value FROM secrets WHERE name=?",[.text(key)]).first?.first.map { String(decoding:$0,as:UTF8.self) }
    }
    public func write(_ value: String,key: String) throws {
        try database.execute("INSERT INTO secrets(name,value) VALUES(?,?) ON CONFLICT(name) DO UPDATE SET value=excluded.value",[.text(key),.text(value)])
    }
    public func delete(_ key: String) throws { try database.execute("DELETE FROM secrets WHERE name=?",[.text(key)]) }
}
public extension SecretStore {
    func readAsync(_ key: String) async throws -> String? {
        if let sqlite = self as? SQLiteSecrets { return try await Task.detached { try sqlite.read(key) }.value }
        return try read(key)
    }
    func writeAsync(_ value: String,key: String) async throws {
        if let sqlite = self as? SQLiteSecrets { try await Task.detached { try sqlite.write(value,key:key) }.value }
        else { try write(value,key:key) }
    }
    func deleteAsync(_ key: String) async throws {
        if let sqlite = self as? SQLiteSecrets { try await Task.detached { try sqlite.delete(key) }.value }
        else { try delete(key) }
    }
}
public final class MemorySecrets: SecretStore {
    private var values: [String: String] = [:]
    public init() {}
    public func read(_ key: String) throws -> String? { values[key] }
    public func write(_ value: String,key: String) throws { values[key] = value }
    public func delete(_ key: String) throws { values.removeValue(forKey:key) }
}
