import AppKit
import Foundation
import LumaRouteCore

@main struct RuleStoreCheck {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1])
        let binary = URL(fileURLWithPath:CommandLine.arguments[2])
        let store = AppStore()
        store.store = try LocalStore(root:root,secrets:MemorySecrets())
        store.coreUpdates = try CoreUpdates(root:root.appendingPathComponent("cores"),bundled:binary)
        let profile = Profile(name:"调度隔离验收",isRemote:false)
        store.database.profiles = [profile]
        var item = RuleSubscription(profileID:profile.id,catalogID:"icloud",target:"DIRECT")
        item.lastUpdated = .distantPast
        store.database.ruleSubscriptions = [item]
        try store.store.save(store.database)
        await store.updateDueRuleSubscriptions()
        guard let updated=store.database.ruleSubscriptions?.first,updated.revision != nil,
              updated.ruleCount > 0,updated.lastError == nil,updated.lastAttempt != nil,
              !store.busy, !store.helperActive else { throw LumaError.message("实际 AppStore 到期调度未完成") }
        print("PASS actual AppStore scheduler downloads and commits due rule subscription")
        let revision = updated.revision
        await store.updateDueRuleSubscriptions()
        guard store.database.ruleSubscriptions?.first?.revision == revision else { throw LumaError.message("未到期的规则被重复更新") }
        print("PASS actual scheduler does not redownload before next interval")
        store.database.ruleSubscriptions?[0].autoUpdate = false
        await store.updateDueRuleSubscriptions(at:Date().addingTimeInterval(1_000_000))
        guard store.database.ruleSubscriptions?.first?.revision == revision else { throw LumaError.message("关闭自动更新未生效") }
        print("PASS disabled auto update skips future due cycle")
        let persisted = try store.store.load()
        guard persisted.ruleSubscriptions?.first?.revision == revision,
              try !store.store.ruleSubscriptionContent(updated).isEmpty else { throw LumaError.message("缓存和元数据未完整持久化") }
        print("PASS automatic update persists usable cache and metadata")
    }
}
