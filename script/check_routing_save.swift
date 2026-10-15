import Foundation
import LumaRouteCore

@main struct RoutingSaveStoreCheck {
    @MainActor static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),binary=URL(fileURLWithPath:CommandLine.arguments[2])
        let app=AppStore();app.store=try LocalStore(root:root)
        app.database.settings.mixedPort=19962;app.database.settings.controllerPort=19963
        let a=Profile(name:"A",isRemote:false),b=Profile(name:"B",isRemote:false)
        let sourceA="proxies: [{name: node, type: http, server: 127.0.0.1, port: 18771}]\nproxy-groups: [{name: group, type: select, proxies: [node]}]\nrules: ['MATCH,group']"
        let sourceB=sourceA.replacingOccurrences(of:"18771",with:"18773")
        var plan=SubscriptionComposition();plan.profileIDs=[a.id,b.id];plan.baseProfileID=a.id;plan.fallbackProfileID=a.id
        var combo=Profile(name:"组合",isRemote:false);combo.composition=plan
        app.database.profiles=[a,b,combo];app.database.activeProfileID=combo.id
        let source=try CompositionComposer.compose(plan,profiles:app.database.profiles,contents:[a.id:sourceA,b.id:sourceB],settings:app.database.settings)
        try app.store.commit(app.database,profiles:[a.id:sourceA,b.id:sourceB,combo.id:source])
        app.runner=CoreRunner(binary:binary,home:root.appendingPathComponent("runtime"),secret:app.secret)
        let (yaml,file)=try await app.runner.prepare(source:source,settings:app.database.settings,rules:[])
        try await app.runner.validate(file:file);try await app.runner.start(yaml:yaml,settings:app.database.settings)
        app.coreReady=true
        app.restartStreams()
        let traffic=app.trafficTask!,logs=app.logTask!
        defer { traffic.cancel();logs.cancel() }
        var updated=combo
        var route=SubscriptionDomainRoute(profileID:b.id);route.domain="other.test";updated.composition?.domainRoutes=[route]
        do {
            let began=Date();try await app.saveComposition(updated,activate:true)
            let ms=Date().timeIntervalSince(began)*1000
            precondition(ms < 800)
            let probe1 = try await CompositionRouteProbe.route(19962)
            precondition(probe1 == "osaka")
            let reopened=try LocalStore(root:root).load()
            precondition(reopened.profiles.first{$0.id==combo.id}?.composition?.domainRoutes == [route])
            precondition(!traffic.isCancelled && !logs.isCancelled)
            print("PASS actual AppStore saves composition rules and SQLite in \(Int(ms)) ms without restarting streams")
            let custom=CustomRule(type:"DOMAIN",payload:"other.test",target:"订阅 · A")
            try await app.applyRules([custom])
            let probe2 = try await CompositionRouteProbe.route(19962)
            precondition(probe2 == "tokyo")
            precondition(!traffic.isCancelled && !logs.isCancelled)
            print("PASS custom rules use the fast path and retain precedence over composition routes")
            var invalid=updated;invalid.composition?.domainRoutes[0].target="missing"
            do { try await app.saveComposition(invalid,activate:true);fatalError("invalid group accepted") } catch {}
            let probe3 = try await CompositionRouteProbe.route(19962)
            precondition(probe3 == "tokyo")
            precondition(app.database.profiles.first{$0.id==combo.id}?.composition?.domainRoutes == [route])
            print("PASS invalid candidate preserves metadata and active routing")
            app.store=try LocalStore(root:root,readOnly:true)
            do { try await app.applyRules([]);fatalError("read-only save accepted") } catch {}
            let probe4 = try await CompositionRouteProbe.route(19962)
            precondition(probe4 == "tokyo")
            precondition(app.currentCustomRules == [custom])
            print("PASS SQLite save failure rolls back kernel rules and metadata through the fast path")
            precondition(!traffic.isCancelled && !logs.isCancelled)
            print("PASS successful and failed rule saves preserve existing stream tasks")
            await app.runner.stop()
        } catch { await app.runner.stop();throw error }
    }
}

enum CompositionRouteProbe {
 static func route(_ port: Int) async throws -> String {
    try await Task.detached {
        let p=Process(),output=Pipe();p.executableURL=URL(fileURLWithPath:"/usr/bin/curl")
        p.arguments=["--disable","--silent","--fail","--noproxy","","--proxy","http://127.0.0.1:\(port)","--max-time","5","http://other.test/route"]
        p.standardOutput=output;p.standardError=FileHandle.nullDevice;try p.run()
        let data=output.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
        guard p.terminationStatus==0,let json=try JSONSerialization.jsonObject(with:data) as? [String:Any],let route=json["route"] as? String else { throw LumaError.message("route failed") }
        return route
    }.value
 }
}
