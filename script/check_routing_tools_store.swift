import Foundation
import LumaRouteCore

@main struct RoutingToolsStoreCheck {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1])
        let app = AppStore(); app.store = try LocalStore(root:root)
        app.runner = CoreRunner(binary:URL(fileURLWithPath:CommandLine.arguments[2]),home:root.appendingPathComponent("runtime"),secret:"fixture-only")
        let active = Profile(name:"single",isRemote:false),remote = Profile(name:"remote",isRemote:true)
        let old = "proxies: [{name: shared-node, type: http, server: 127.0.0.1, port: 18773}, {name: removed, type: direct}]\nproxy-groups: [{name: shared-group, type: select, proxies: [shared-node]}]\nrules: ['MATCH,shared-group']"
        app.database.profiles = [active,remote]; app.database.activeProfileID = active.id
        app.database.customRules = [CustomRule(type:"PROCESS-NAME",payload:"curl",target:"DIRECT")]
        try app.store.commit(app.database,profiles:[active.id:old,remote.id:old])
        try app.store.secrets.write("http://127.0.0.1:18770/composition-b",key:"subscription-"+remote.id.uuidString)
        try await app.update(remote)
        let report = app.database.profiles.first(where:{$0.id == remote.id})!.lastChange!
        precondition(report.removedNodes == ["removed"] && report.addedNodes.isEmpty && report.selectedNodesRemoved.isEmpty)
        let reopened = try LocalStore(root:root).load()
        precondition(reopened.profiles.first(where:{$0.id == remote.id})?.lastChange == report)
        precondition(reopened.customRules.first?.type == "PROCESS-NAME")
        print("PASS successful real subscription update persists its delta and application rules in SQLite")
        let unchanged = app.database.profiles.first(where:{$0.id == remote.id})!
        try await app.update(unchanged)
        precondition(app.database.profiles.first(where:{$0.id == remote.id})?.lastChange == report)
        print("PASS identical update preserves the last actual content change")
        let invalidURL = URL(string:"http://127.0.0.1:18770/state")!
        func fixture(_ invalid: Bool) async throws {
            var request = URLRequest(url:invalidURL); request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject:["composition_invalid":invalid])
            _ = try await URLSession.shared.data(for:request)
        }
        try await fixture(true)
        do { try await app.update(app.database.profiles.first(where:{$0.id == remote.id})!); fatalError("invalid update accepted") } catch {}
        try await fixture(false)
        precondition(app.database.profiles.first(where:{$0.id == remote.id})?.lastChange == report)
        print("PASS failed download validation preserves the prior successful change report")
        do { try await app.saveRoutingRule(CustomRule(type:"PROCESS-NAME",payload:"curl"),profileID:UUID()); fatalError("stale profile accepted") } catch {}
        do { try await app.saveRoutingRule(CustomRule(type:"PROCESS-NAME",payload:"curl",target:"removed-group"),profileID:active.id); fatalError("missing target accepted") } catch {}
        precondition(app.database.customRules == reopened.customRules)
        print("PASS stale editor and missing routing target are rejected without modifying rules")
        app.store = try LocalStore(root:root,readOnly:true)
        do { try await app.update(app.database.profiles.first(where:{$0.id == remote.id})!); fatalError("read-only update accepted") } catch {}
        precondition(app.database.profiles.first(where:{$0.id == remote.id})?.lastChange == report)
        print("PASS SQLite write failure keeps the previous change report")
    }
}
