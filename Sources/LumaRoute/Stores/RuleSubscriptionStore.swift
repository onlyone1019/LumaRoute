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
    func updateRuleSubscription(_ proposed: RuleSubscription,background: Bool = false) async throws {
        let existing = (database.ruleSubscriptions ?? []).first(where:{$0.id == proposed.id})
        var item = existing ?? proposed
        try item.validate()
        guard database.profiles.contains(where:{$0.id == item.profileID}),updatingRuleSubscriptions.insert(item.id).inserted else { return }
        defer { updatingRuleSubscriptions.remove(item.id) }
        var ownsLock = false
        defer { if ownsLock { busy = false } }
        do {
            let entry = try RuleCatalogEntry.entry(item.catalogID)
            let content = try await RuleSubscriptionDownload.fetch(entry)
            if background { try await waitForSubscriptionCommit(); busy = true; ownsLock = true }
            try Task.checkCancellation()
            guard !shuttingDown,database.profiles.contains(where:{$0.id == item.profileID}),
                  (database.ruleSubscriptions ?? []).first(where:{$0.id == item.id}) == existing else { return }
            let oldContent = existing?.revision == nil ? nil:try store.ruleSubscriptionContent(item)
            let changed = oldContent.map { Data($0.utf8) != Data(content.utf8) } ?? true
            if background,changed,item.profileID == database.activeProfileID,item.enabled,!coreReady { return }
            var contents: [UUID:String] = [:]
            if changed {
                // Validate disabled/inactive sets with the actual kernel too.
                try await CoreRunner.validateRuleSubscription(.init(subscription:item,content:content),binary:coreUpdates.currentBinary())
                let revision = UUID(); item.revision = revision; contents[revision] = content
                item.ruleCount = try await Task.detached { try RuleSubscriptionDownload.payload(content).count }.value
            }
            item.lastUpdated = Date(); item.lastAttempt = Date(); item.lastError = nil
            var next = database; var items = next.ruleSubscriptions ?? []
            if let index = items.firstIndex(where:{$0.id == item.id}) { items[index] = item } else { items.append(item) }
            next.ruleSubscriptions = items
            try await commitRuleSubscriptions(next,apply:changed && item.profileID == database.activeProfileID && item.enabled,contents:contents)
            notice = changed ? "\(entry.title)已更新 · \(item.ruleCount) 条规则":"\(entry.title)内容未变化，已刷新更新时间"
            appendLog(source:"规则订阅",message:notice!)
        } catch is CancellationError { throw CancellationError() }
        catch {
            if background && !ownsLock { try await waitForSubscriptionCommit(); busy = true; ownsLock = true }
            if let index = database.ruleSubscriptions?.firstIndex(where:{$0.id == item.id}),database.ruleSubscriptions?[index] == existing {
                var next = database
                next.ruleSubscriptions?[index].lastAttempt = Date()
                next.ruleSubscriptions?[index].lastError = Redactor.clean(error.localizedDescription)
                try? await store.saveAsync(next); database = next
            }
            appendLog(level:"warning",source:"规则订阅",message:"更新失败，已保留上次可用规则："+Redactor.clean(error.localizedDescription))
            throw error
        }
    }
    func updateDueRuleSubscriptions(at date: Date = Date()) async {
        guard !busy else { return }
        let due = (database.ruleSubscriptions ?? []).filter { $0.isDue(at:date) }
        guard !due.isEmpty else { return }
        for item in due {
            if Task.isCancelled || shuttingDown { return }
            guard let current = database.ruleSubscriptions?.first(where:{$0.id == item.id}),current.isDue(at:date) else { continue }
            try? await updateRuleSubscription(current,background:true)
        }
    }
    func updateAllRuleSubscriptions() async throws {
        var failures = 0
        for item in currentRuleSubscriptions { do { try await updateRuleSubscription(item) } catch { failures += 1 } }
        if failures > 0 { throw LumaError.message("\(failures) 个规则订阅更新失败，旧规则已保留") }
    }
    func deleteRuleSubscription(_ item: RuleSubscription) async throws {
        _ = try await store.backupAsync(database,automatic:true)
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
    private func commitRuleSubscriptions(_ next: AppDatabase, apply: Bool = true,contents: [UUID:String] = [:]) async throws {
        try Task.checkCancellation()
        guard !shuttingDown else { throw CancellationError() }
        let previous = database
        do {
            if apply {
                let snapshots = try store.ruleSubscriptionSnapshots(next,profileID:next.activeProfileID,pendingContents:contents)
                try await applyConfiguration(ruleSubscriptions:snapshots)
            }
            try await store.commitAsync(next,profiles:[:],ruleContents:contents); database = next
            await store.cleanRuleSubscriptionCacheAsync(next)
        } catch {
            database = previous
            if apply { try? await applyConfiguration() }
            await store.cleanRuleSubscriptionCacheAsync(previous)
            throw error
        }
    }
}
