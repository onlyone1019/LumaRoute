import Foundation
import Security

public protocol SecretStore {
    func read(_ key: String) throws -> String?
    func write(_ value: String, key: String) throws
    func delete(_ key: String) throws
}
public final class KeychainSecrets: SecretStore, @unchecked Sendable {
    private let service: String
    public init(service: String = "app.lumaroute.desktop") { self.service = service }
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
    public func read(_ key: String) throws -> String? {
        var q = query(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw LumaError.message("无法读取钥匙串：\(status)") }
        return String(data: data, encoding: .utf8)
    }
    public func write(_ value: String, key: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(key); q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw LumaError.message("无法写入钥匙串：\(added)") }
        } else if status != errSecSuccess { throw LumaError.message("无法更新钥匙串：\(status)") }
    }
    public func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LumaError.message("无法删除钥匙串：\(status)") }
    }
}
public extension SecretStore {
    func readAsync(_ key: String) async throws -> String? {
        if let keychain = self as? KeychainSecrets { return try await Task.detached { try keychain.read(key) }.value }
        return try read(key)
    }
    func writeAsync(_ value: String,key: String) async throws {
        if let keychain = self as? KeychainSecrets { try await Task.detached { try keychain.write(value,key:key) }.value }
        else { try write(value,key:key) }
    }
    func deleteAsync(_ key: String) async throws {
        if let keychain = self as? KeychainSecrets { try await Task.detached { try keychain.delete(key) }.value }
        else { try delete(key) }
    }
}
public final class MemorySecrets: SecretStore {
    private var values: [String: String] = [:]
    public init() {}
    public func read(_ key: String) throws -> String? { values[key] }
    public func write(_ value: String, key: String) throws { values[key] = value }
    public func delete(_ key: String) throws { values.removeValue(forKey: key) }
}

