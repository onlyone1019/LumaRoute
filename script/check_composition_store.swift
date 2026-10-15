import Foundation
import LumaRouteCore

@main struct CompositionStoreCheck {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1])
        let binary = URL(fileURLWithPath:CommandLine.arguments[2])
        let app = AppStore(); app.store = try LocalStore(root:root)
        app.runner = CoreRunner(binary:binary,home:root.appendingPathComponent("runtime"),secret:"synthetic-controller-secret")
        let a = Profile(name:"A",isRemote:true), b = Profile(name:"B",isRemote:true)
        let source = "proxies: [{name: shared, type: http, server: 127.0.0.1, port: 18771}]\nproxy-groups: [{name: choice, type: select, proxies: [shared]}]\nrules: ['MATCH,choice']\n"
        app.database.profiles = [a,b]; app.database.activeProfileID = a.id
        app.database.customRules = [CustomRule(payload:"single.test",target:"choice")]
        try app.store.commit(app.database,profiles:[a.id:source,b.id:source])
        var plan = SubscriptionComposition(); plan.profileIDs = [a.id,b.id]; plan.baseProfileID = a.id
        var route = SubscriptionDomainRoute(profileID:b.id); route.domain = "b.test"; plan.domainRoutes = [route]
        var composite = Profile(name:"组合测试",isRemote:false); composite.composition = plan
        try await app.saveComposition(composite,activate:false)
        precondition(app.database.activeProfileID == a.id && app.database.profiles.count == 3 && !app.helperActive)
        print("PASS saving inactive composition validates without disturbing the selected single subscription")
        app.database.activeProfileID = composite.id
        precondition(app.currentCustomRules.isEmpty)
        let old = try app.activeSource()!
        let updated = source.replacingOccurrences(of:"18771",with:"18773")
        let candidate = try app.activeSource(overrides:[b.id:updated])!
        let parsed = try ConfigComposer.parse(candidate)
        let nodes = parsed["proxies"] as! [[String:Any]]
        precondition(nodes.first(where:{$0["name"] as? String == "[B] shared"})?["port"] as? Int == 18773)
        let retained = try app.activeSource()!
        precondition(retained == old)
        print("PASS active composition rebuilds a changed member candidate without overwriting usable content")
        app.database.activeProfileID = a.id
        let single = try app.activeSource()
        precondition(app.currentCustomRules == app.database.customRules && single == source)
        print("PASS single subscription source and custom rules remain independent")
        do { try await app.deleteProfile(b); fatalError("referenced subscription deletion allowed") } catch {}
        precondition(app.database.profiles.contains(where:{$0.id == b.id}))
        print("PASS referenced member cannot be deleted leaving a broken composition")
        let backup = try app.store.backup(app.database)
        let (restored,contents) = try app.store.readBackup(backup)
        let rebuilt = try app.activeSource(composite.id,configuration:restored,overrides:contents)
        precondition(rebuilt == old)
        print("PASS restored composition is regenerated from backup member contents")
        let targets = try await app.compositionPolicyTargets(plan)
        precondition(targets.contains("[B] choice") && targets.contains("聚合节点") && !targets.contains("choice"))
        print("PASS draft composition targets come from member caches rather than the running single profile")
        var unified = composite
        let additions = try CompositionRouting.batch("DOMAIN-KEYWORD,video\nIP-CIDR,192.168.1.1/16\nIP-CIDR6,2001:db8::/32\nPROCESS-NAME,curl\nPROCESS-PATH,/usr/bin/curl",type:"DOMAIN",profileID:nil,target:"DIRECT",existing:plan.domainRoutes)
        unified.composition?.domainRoutes += additions
        try await app.saveComposition(unified,activate:false)
        let persisted = try LocalStore(root:root).load().profiles.first { $0.id == composite.id }!
        precondition(persisted.composition?.domainRoutes == unified.composition?.domainRoutes && app.database.activeProfileID == a.id)
        print("PASS new match types and direct exits persist through actual AppStore save and SQLite reopen")
        var missing = unified; missing.composition?.domainRoutes[1].target = "[missing] group"
        do { try await app.saveComposition(missing,activate:false); fatalError("missing group accepted") } catch {}
        precondition(app.database.profiles.first { $0.id == composite.id }?.composition == unified.composition)
        print("PASS invalid policy group candidate preserves saved composition and active subscription")
        app.store = try LocalStore(root:root,readOnly:true)
        var changed = app.database.profiles.first(where:{$0.id == composite.id})!
        changed.name = "不得保存"
        do { try await app.saveComposition(changed,activate:false); fatalError("expected read-only save failure") } catch {}
        precondition(app.database.profiles.first(where:{$0.id == composite.id})?.name == "组合测试")
        print("PASS failed SQLite save preserves composition metadata and active single subscription")
    }
}
