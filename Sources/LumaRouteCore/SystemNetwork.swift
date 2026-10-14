import Foundation
import SystemConfiguration

/// Runs only inside the authorized helper. Restores only values still owned by LumaRoute.
public final class SystemNetwork {
    private let journal: URL
    private var records: [String: [String: Any]] = [:]
    public init(journal: URL) throws {
        self.journal = journal
        if FileManager.default.fileExists(atPath:journal.path),
           let object = try PropertyListSerialization.propertyList(from:Data(contentsOf:journal),format:nil) as? [String: [String:Any]] { records = object }
    }
    public func apply(settings: NetworkSettings) throws {
        guard geteuid() == 0 else { throw LumaError.message("网络设置需要管理员授权的后台服务") }
        guard let prefs = SCPreferencesCreate(nil,"LumaRoute" as CFString,nil), SCPreferencesLock(prefs,false) else { throw LumaError.message("其他程序正在修改系统网络设置，请稍后重试") }
        defer { SCPreferencesUnlock(prefs) }
        guard let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { throw LumaError.message("无法读取网络服务") }
        let previous = records
        var restored: Set<String> = []
        do { for service in services {
            guard let identifier = SCNetworkServiceGetServiceID(service) else { continue }
            let serviceID = identifier as String
            let enabled = SCNetworkServiceGetEnabled(service)
            if try setProtocol(service:service,serviceID:serviceID,type:kSCNetworkProtocolTypeProxies,desired:enabled && settings.systemProxy ? [
                "HTTPEnable":1,"HTTPProxy":"127.0.0.1","HTTPPort":settings.mixedPort,
                "HTTPSEnable":1,"HTTPSProxy":"127.0.0.1","HTTPSPort":settings.mixedPort,
                "SOCKSEnable":1,"SOCKSProxy":"127.0.0.1","SOCKSPort":settings.mixedPort,
                "ProxyAutoConfigEnable":0,"ProxyAutoDiscoveryEnable":0,
                "ExceptionsList":settings.bypass,"ExcludeSimpleHostnames":1
            ] : nil) { restored.insert(serviceID+":"+(kSCNetworkProtocolTypeProxies as String)) }
            if try setProtocol(service:service,serviceID:serviceID,type:kSCNetworkProtocolTypeDNS,desired:enabled && settings.tun && settings.dnsHijack ? ["ServerAddresses":["223.6.6.6"]] : nil) { restored.insert(serviceID+":"+(kSCNetworkProtocolTypeDNS as String)) }
        }
        // Journal both the previous and proposed owned value before committing.
        // A crash on either side of SCPreferencesCommitChanges is recoverable.
        try persist()
        } catch { records = previous; throw error }
        guard SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else { throw LumaError.message("无法应用系统网络设置") }
        for key in restored { records.removeValue(forKey:key) }
        for key in records.keys { records[key]?.removeValue(forKey:"previousApplied") }
        try persist()
    }
    private func setProtocol(service: SCNetworkService,serviceID: String,type: CFString,desired: [String:Any]?) throws -> Bool {
        guard let proto = SCNetworkServiceCopyProtocol(service,type) else { return false }
        let key = serviceID + ":" + (type as String)
        let current = SCNetworkProtocolGetConfiguration(proto) as? [String:Any]
        if let desired {
            if let record = records[key], !Self.owns(current,record:record) {
                throw LumaError.message("其他软件已覆盖网络设置，请先暂停 LumaRoute 接管再重试")
            }
            if records[key] == nil { records[key] = ["original":current ?? [:],"originalMissing":current == nil] }
            var merged = current ?? [:]
            for (k,v) in desired { merged[k] = v }
            if let applied = records[key]?["applied"] { records[key]?["previousApplied"] = applied }
            records[key]?["applied"] = merged
            guard SCNetworkProtocolSetConfiguration(proto,merged as CFDictionary) else { throw LumaError.message("无法修改网络协议设置") }
        } else if let record = records[key] {
            if Self.owns(current,record:record) {
                let original = record["original"] as? [String:Any] ?? [:]
                let missing = record["originalMissing"] as? Bool ?? false
                guard SCNetworkProtocolSetConfiguration(proto,missing ? nil : original as CFDictionary) else { throw LumaError.message("无法恢复原网络设置") }
            }
            return true
        }
        return false
    }
    public static func owns(_ current: [String:Any]?,record: [String:Any]) -> Bool {
        ["applied","previousApplied"].contains { key in
            guard let value = record[key] as? [String:Any] else { return false }
            return NSDictionary(dictionary:current ?? [:]).isEqual(to:value)
        }
    }
    public func verifyOwnership() throws {
        guard !records.isEmpty else { return }
        guard let prefs = SCPreferencesCreate(nil,"LumaRoute-check" as CFString,nil),
              let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { throw LumaError.message("无法检查系统网络接管状态") }
        for service in services {
            guard let id = SCNetworkServiceGetServiceID(service) as String? else { continue }
            for type in [kSCNetworkProtocolTypeProxies,kSCNetworkProtocolTypeDNS] {
                guard let record = records[id+":"+(type as String)],let proto = SCNetworkServiceCopyProtocol(service,type) else { continue }
                guard Self.owns(SCNetworkProtocolGetConfiguration(proto) as? [String:Any],record:record) else {
                    throw LumaError.message("其他软件已覆盖系统网络设置，LumaRoute 将停止接管并保留该修改")
                }
            }
        }
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at:journal.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let data = try PropertyListSerialization.data(fromPropertyList:records,format:.binary,options:0)
        try data.write(to:journal,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:journal.path)
    }
    public func restore() throws {
        var settings = NetworkSettings(); settings.systemProxy = false; settings.tun = false
        try apply(settings:settings)
    }
}

