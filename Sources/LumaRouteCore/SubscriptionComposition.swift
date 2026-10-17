import Foundation

public struct SubscriptionDomainRoute: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var enabled = true
    public var type = "DOMAIN-SUFFIX"
    public var domain = ""
    public var profileID: UUID?
    /// Nil preserves the original subscription binding in older saved profiles.
    public var target: String?
    public init(profileID: UUID? = nil) { self.profileID = profileID }
    public func normalizedDomain() throws -> String {
        if type != "DOMAIN" && type != "DOMAIN-SUFFIX" { return try CompositionRouting.normalized(type:type,payload:domain) }
        var value = domain.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        guard ["DOMAIN","DOMAIN-SUFFIX"].contains(type),!value.isEmpty,value.utf8.count <= 253,
              value.split(separator:".",omittingEmptySubsequences:false).allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                  label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }),value.utf8.contains(where:{(97...122).contains($0)}) else {
            throw LumaError.message("请填写有效域名，例如 example.com；不包含协议、路径或通配符")
        }
        return value
    }
}

/// A composition is a local profile. Its member subscriptions remain ordinary
/// profiles, so existing single-profile selection, scoped overlays and backups work.
public struct SubscriptionComposition: Codable, Equatable, Sendable {
    public var profileIDs: [UUID] = []
    public var baseProfileID: UUID?
    public var fallbackProfileID: UUID?
    public var domainRoutes: [SubscriptionDomainRoute] = []
    public var customRules: [CustomRule] = []
    public static let aggregateGroup = "聚合节点"
    public static let automaticGroup = "聚合自动"
    public init() {}
    public func validate(profiles: [Profile]) throws {
        let available = Set(profiles.filter { $0.composition == nil }.map(\.id))
        let members = Set(profileIDs)
        guard (2...16).contains(profileIDs.count),members.count == profileIDs.count,members.isSubset(of:available),
              let baseProfileID,members.contains(baseProfileID),fallbackProfileID.map({members.contains($0)}) ?? true else {
            throw LumaError.message("请选择 2 至 16 个不同订阅，并从中选择基础配置和默认出口；组合不能引用另一个组合")
        }
        guard domainRoutes.count <= 256 else { throw LumaError.message("每个组合最多添加 256 条分流规则") }
        var seen: Set<String> = []
        for route in domainRoutes where route.enabled {
            let domain = try route.normalizedDomain()
            if let target = route.target {
                try CustomRule(type:route.type,payload:domain,target:target).validate()
            } else {
                guard let id = route.profileID,members.contains(id) else { throw LumaError.message("分流规则的目标订阅已移出组合，请重新选择或停用这条规则") }
            }
            guard seen.insert(CompositionRouting.matchKey(type:route.type,payload:domain)).inserted else { throw LumaError.message("分流存在重复匹配，请合并或停用重复规则") }
        }
    }
    public func aliases(profiles: [Profile]) -> [UUID:String] {
        let originals = profiles.filter { $0.composition == nil && profileIDs.contains($0.id) }
        func clean(_ name: String) -> String {
            let value = String(name.map { ",:#[]\n\r".contains($0) ? Character(" "):$0 }.prefix(32)).trimmingCharacters(in:.whitespacesAndNewlines)
            return value.isEmpty ? "订阅":value
        }
        let counts = Dictionary(grouping:originals,by:{clean($0.name)}).mapValues(\.count)
        return Dictionary(uniqueKeysWithValues:originals.map { profile in
            let name = clean(profile.name)
            return (profile.id,counts[name,default:0] > 1 ? name+" · "+profile.id.uuidString.prefix(8):name)
        })
    }
    public func group(for id: UUID,profiles: [Profile]) -> String { "订阅 · "+(aliases(profiles:profiles)[id] ?? "已移除") }
    public func routingRules(profiles: [Profile]) throws -> [CustomRule] {
        try validate(profiles:profiles)
        return try domainRoutes.filter(\.enabled).map {
            var rule = CustomRule(type:$0.type,payload:try $0.normalizedDomain(),target:$0.target ?? group(for:$0.profileID!,profiles:profiles))
            rule.id = $0.id
            return rule
        }
    }
}
