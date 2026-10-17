import Foundation

public enum GroupStrategyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case subscription, lowestLatency = "url-test", fallback
    public var id: String { rawValue }
    public var label: String {
        switch self { case .subscription: return "保持订阅策略"; case .lowestLatency: return "自动选择最低延迟"; case .fallback: return "故障转移" }
    }
}
public struct GroupStrategy: Codable, Equatable, Sendable {
    public var profileID: UUID
    public var group: String
    public var mode: GroupStrategyMode
    public var candidateFilter: String
    public var interval: Int
    public var tolerance: Int
    public init(profileID: UUID, group: String, mode: GroupStrategyMode = .subscription, candidateFilter: String = "", interval: Int = 60, tolerance: Int = 50) {
        self.profileID = profileID; self.group = group; self.mode = mode; self.candidateFilter = candidateFilter; self.interval = interval; self.tolerance = tolerance
    }
    public static let japanFilter = "(?i)日本|东京|大阪|japan|tokyo|osaka|🇯🇵"
    public func validate() throws {
        guard !group.isEmpty, (10...3600).contains(interval), (0...1000).contains(tolerance), candidateFilter.utf8.count <= 1024 else { throw LumaError.message("自动策略的测试间隔或切换容差无效") }
        if !candidateFilter.isEmpty { _ = try NSRegularExpression(pattern:candidateFilter) }
    }
}

extension ConfigComposer {
    static func applyGroupStrategies(_ strategies: [GroupStrategy], config: inout [String:Any], settings: NetworkSettings) throws {
        guard var groups = config["proxy-groups"] as? [[String:Any]] else { return }
        let groupNames = Set(groups.compactMap { $0["name"] as? String })
        let directNames = Set((config["proxies"] as? [[String:Any]] ?? []).filter { $0["type"] as? String == "direct" }.compactMap { $0["name"] as? String }).union(["DIRECT","REJECT","COMPATIBLE","PASS"])
        for strategy in strategies where strategy.mode != .subscription {
            try strategy.validate()
            guard let index = groups.firstIndex(where:{$0["name"] as? String == strategy.group}) else { continue }
            var group = groups[index]
            let members = (group["proxies"] as? [String] ?? []).filter { name in
                !groupNames.contains(name) && !directNames.contains(name) && (strategy.candidateFilter.isEmpty || name.range(of:strategy.candidateFilter,options:.regularExpression) != nil)
            }
            let providers = group["use"] as? [String] ?? []
            let includeAll = group["include-all"] as? Bool == true || group["include-all-providers"] as? Bool == true || group["include-all-proxies"] as? Bool == true
            guard !members.isEmpty || !providers.isEmpty || includeAll else { throw LumaError.message("\(strategy.group) 没有匹配的代理节点；请调整候选范围，或设置其引用的策略组") }
            group["proxies"] = members
            group["type"] = strategy.mode.rawValue
            group["url"] = settings.testURL
            group["interval"] = strategy.interval
            group["timeout"] = settings.testTimeout
            group["tolerance"] = strategy.tolerance
            group["lazy"] = false
            group["max-failed-times"] = 1
            group["empty-fallback"] = "REJECT"
            let excluded = group["exclude-type"] as? String ?? ""
            group["exclude-type"] = ([excluded,"Direct","Reject","Pass","Selector","URLTest","Fallback","LoadBalance"].filter { !$0.isEmpty }).joined(separator:"|")
            if !strategy.candidateFilter.isEmpty { group["filter"] = strategy.candidateFilter }
            groups[index] = group
        }
        config["proxy-groups"] = groups
    }
}
