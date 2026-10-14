import Foundation
import LumaRouteCore

extension AppStore {
    var currentRuleSubscriptions: [RuleSubscription] {
        (database.ruleSubscriptions ?? []).filter { $0.profileID == database.activeProfileID }
    }
    var ruleSubscriptionTargets: [String] { ["DIRECT","REJECT"] + groupOrder.filter { !["DIRECT","REJECT"].contains($0) } }
    func ruleSubscriptionProblem(_ item: RuleSubscription) -> String? {
        if item.enabled && !ruleSubscriptionTargets.contains(item.target) { return "目标策略组已不存在，此规则订阅已暂停；请选择新的策略组。" }
        return item.lastError
    }
    func saveRuleSubscription(_ proposed: RuleSubscription) async throws {
        guard proposed.profileID == database.activeProfileID else { throw LumaError.message("机场配置已切换，请重新打开规则订阅设置") }
        try proposed.validate()
        guard !proposed.enabled || ruleSubscriptionTargets.contains(proposed.target) else { throw LumaError.message("目标策略组已不存在，请重新选择") }
        guard !(database.ruleSubscriptions ?? []).contains(where:{$0.profileID == proposed.profileID && $0.catalogID == proposed.catalogID && $0.id != proposed.id}) else { throw LumaError.message("当前机场配置已经添加了这个规则集") }
        if proposed.revision == nil { try await updateRuleSubscription(proposed); return }
        var next = database
        var items = next.ruleSubscriptions ?? []
        guard let index = items.firstIndex(where:{$0.id == proposed.id}) else { throw LumaError.message("规则订阅已不存在") }
        items[index] = proposed; next.ruleSubscriptions = items
        try await commitRuleSubscriptions(next)
        notice = "规则订阅设置已应用"
    }
    func updateRuleSubscription(_ proposed: RuleSubscription) async throws {
        let existing = (database.ruleSubscriptions ?? []).first(where:{$0.id == proposed.id})
        var item = existing ?? proposed
        try item.validate()
        guard database.profiles.contains(where:{$0.id == item.profileID}) else { throw LumaError.message("绑定的机场配置已不存在") }
        do {
            let entry = try RuleCatalogEntry.entry(item.catalogID)
            let content = try await RuleSubscriptionDownload.fetch(entry)
            // Validate even disabled/inactive sets with the actual kernel before caching.
            try await CoreRunner.validateRuleSubscription(.init(subscription:item,content:content),binary:coreUpdates.currentBinary())
            item.revision = try store.saveRuleSubscriptionContent(content)
            item.ruleCount = try await Task.detached { try RuleSubscriptionDownload.payload(content).count }.value
            item.lastUpdated = Date(); item.lastAttempt = Date(); item.lastError = nil
            var next = database; var items = next.ruleSubscriptions ?? []
            if let index = items.firstIndex(where:{$0.id == item.id}) { items[index] = item } else { items.append(item) }
            next.ruleSubscriptions = items
            try await commitRuleSubscriptions(next,apply:item.profileID == database.activeProfileID && item.enabled)
            notice = "\(entry.title)已更新 · \(item.ruleCount) 条规则"
            appendLog(source:"规则订阅",message:notice!)
        } catch {
            if let index = database.ruleSubscriptions?.firstIndex(where:{$0.id == item.id}) {
                var next = database
                next.ruleSubscriptions?[index].lastAttempt = Date()
                next.ruleSubscriptions?[index].lastError = Redactor.clean(error.localizedDescription)
                try? store.save(next); database = next
            }
            appendLog(level:"warning",source:"规则订阅",message:"更新失败，已保留上次可用规则："+Redactor.clean(error.localizedDescription))
            throw error
        }
    }
    func updateDueRuleSubscriptions(at date: Date = Date()) async {
        guard !busy else { return }
        let due = (database.ruleSubscriptions ?? []).filter { $0.isDue(at:date) }
        guard !due.isEmpty else { return }
        busy = true; defer { busy = false }
        for item in due { try? await updateRuleSubscription(item) }
    }
    func updateAllRuleSubscriptions() async throws {
        var failures = 0
        for item in currentRuleSubscriptions { do { try await updateRuleSubscription(item) } catch { failures += 1 } }
        if failures > 0 { throw LumaError.message("\(failures) 个规则订阅更新失败，旧规则已保留") }
    }
    func deleteRuleSubscription(_ item: RuleSubscription) async throws {
        _ = try store.backup(database)
        var next = database
        next.ruleSubscriptions?.removeAll { $0.id == item.id }
        try await commitRuleSubscriptions(next)
        notice = "规则订阅已移除，机场原规则保留；可从本地备份恢复"
    }
    func moveRuleSubscription(_ item: RuleSubscription, direction: Int) async throws {
        var next = database
        var items = next.ruleSubscriptions ?? []
        let indices = items.indices.filter { items[$0].profileID == item.profileID }
        guard let position = indices.firstIndex(where:{items[$0].id == item.id}),indices.indices.contains(position+direction) else { return }
        items.swapAt(indices[position],indices[position+direction]); next.ruleSubscriptions = items
        try await commitRuleSubscriptions(next)
    }
    private func commitRuleSubscriptions(_ next: AppDatabase, apply: Bool = true) async throws {
        let previous = database
        do {
            if apply {
                let snapshots = try store.ruleSubscriptionSnapshots(next,profileID:next.activeProfileID)
                try await applyConfiguration(ruleSubscriptions:snapshots)
            }
            try store.save(next); database = next
            store.cleanRuleSubscriptionCache(next)
        } catch {
            database = previous
            if apply { try? await applyConfiguration() }
            store.cleanRuleSubscriptionCache(previous)
            throw error
        }
    }
}
