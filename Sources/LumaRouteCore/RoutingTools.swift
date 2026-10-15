import Foundation
import Darwin

public enum RoutingTools {
    public static func domainRule(for connection: LiveConnection) throws -> CustomRule {
        let host = connection.target.trimmingCharacters(in:.whitespacesAndNewlines)
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET,host,&v4) == 1 { return CustomRule(type:"IP-CIDR",payload:host+"/32") }
        if inet_pton(AF_INET6,host,&v6) == 1 { return CustomRule(type:"IP-CIDR6",payload:host+"/128") }
        var route = SubscriptionDomainRoute(); route.type = "DOMAIN"; route.domain = host
        return CustomRule(type:"DOMAIN",payload:try route.normalizedDomain())
    }
    public static func applicationRule(for connection: LiveConnection) throws -> CustomRule {
        let rule: CustomRule
        if let path = connection.metadata.processPath,!path.isEmpty { rule = CustomRule(type:"PROCESS-PATH",payload:path) }
        else if let name = connection.metadata.process,!name.isEmpty { rule = CustomRule(type:"PROCESS-NAME",payload:name) }
        else { throw LumaError.message("尚未识别此连接的应用，请等待进程信息或手动添加应用规则") }
        try rule.validate(); return rule
    }
    public static func subscription(for connection: LiveConnection,profiles: [Profile],activeID: UUID?) -> String {
        guard let active = profiles.first(where:{$0.id == activeID}) else { return "未知订阅" }
        let chain = connection.chains ?? []
        if chain.contains("DIRECT") { return "直连" }
        if chain.contains("REJECT") || chain.contains("REJECT-DROP") { return "已拦截" }
        guard let composition = active.composition else { return active.name }
        let aliases = composition.aliases(profiles:profiles)
        let matches = composition.profileIDs.filter { id in
            guard let alias = aliases[id] else { return false }
            return chain.contains { $0 == composition.group(for:id,profiles:profiles) || $0.hasPrefix("["+alias+"] ") }
        }
        let names = matches.compactMap { id in profiles.first { $0.id == id }?.name }
        return names.isEmpty ? "来源未识别":names.joined(separator:" → ")
    }
    /// Insert at highest custom priority so a broad earlier rule cannot hide this action.
    public static func saving(_ rule: CustomRule,in rules: [CustomRule]) throws -> [CustomRule] {
        try rule.validate()
        return [rule]+rules.filter { $0.id != rule.id && !($0.type == rule.type && $0.payload == rule.payload) }
    }
}
