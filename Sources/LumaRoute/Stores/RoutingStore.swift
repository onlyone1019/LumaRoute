import Foundation
import LumaRouteCore

extension AppStore {
    func compositionPolicyTargets(_ composition: SubscriptionComposition) async throws -> [String] {
        // Derive from candidate members, never from whichever profile is currently running.
        try await compositionPolicyCache.targets(composition,profiles:database.profiles,settings:database.settings,store:store)
    }
    var routingTargets: [(name:String,label:String)] {
        var result = [(name:"DIRECT",label:"直连"),(name:"REJECT",label:"拒绝连接")]
        if let composition = activeProfile?.composition {
            for id in composition.profileIDs {
                if let profile = database.profiles.first(where:{$0.id == id}) {
                    result.append((composition.group(for:id,profiles:database.profiles),"订阅："+profile.name))
                }
            }
        }
        for group in groups where group.name != "GLOBAL" && !result.contains(where:{$0.name == group.name}) { result.append((group.name,group.name)) }
        return result
    }
    func saveRoutingRule(_ rule: CustomRule,profileID: UUID?) async throws {
        guard database.activeProfileID == profileID,activeProfile != nil else { throw LumaError.message("当前配置已改变，请重新打开分流编辑器") }
        guard routingTargets.contains(where:{$0.name == rule.target}) else { throw LumaError.message("目标策略已不存在，请重新选择") }
        try await applyRules(RoutingTools.saving(rule,in:currentCustomRules))
        notice = "分流规则已应用；新连接生效，已有连接保持原出口"
    }
}
