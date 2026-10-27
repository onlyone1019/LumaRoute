import Foundation
import LumaRouteCore

extension AppStore {
    func saveProxyChains(_ chains: [ProxyChain],profileID: UUID) async throws {
        guard database.activeProfileID == profileID,let index = database.profiles.firstIndex(where:{$0.id == profileID}) else {
            throw LumaError.message("当前配置已改变，请重新打开链路编辑器")
        }
        let previous = database
        let removed = Set((previous.profiles[index].proxyChains ?? []).filter(\.enabled).map(\.groupName)).subtracting(chains.filter(\.enabled).map(\.groupName))
        let references = currentCustomRules.filter(\.enabled).map(\.target)
            + (activeProfile?.composition?.domainRoutes ?? []).filter(\.enabled).compactMap(\.target)
            + (database.ruleSubscriptions ?? []).filter { $0.enabled && $0.profileID == profileID }.map(\.target)
        guard removed.isDisjoint(with:references) else { throw LumaError.message("此链路仍被分流规则使用，请先修改对应规则，再停用、删除或改名") }
        var next = previous
        next.profiles[index].proxyChains = chains.isEmpty ? nil:chains
        // Resolve and validate before touching the running core or persisted state.
        let source = try await activeSource(configuration:next)
        var attemptedApply = false
        do {
            attemptedApply = true
            try await applyConfiguration(source:source,configuration:next)
            next.settings = database.settings
            try await store.saveAsync(next)
            database = next
            await refresh()
            notice = "链式代理已保存，可在分流规则中选择链路策略组"
        } catch {
            database = previous
            if attemptedApply { try? await applyConfiguration(configuration:previous) }
            throw error
        }
    }

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
