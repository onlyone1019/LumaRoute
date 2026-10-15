import AppKit
import SwiftUI
import Combine
import LumaRouteCore

@MainActor final class UIResponseDelegate: NSObject,NSApplicationDelegate {
    var window: NSWindow?
    var store: AppStore!
    var folder: URL!
    var label = ""
    var samples: [[String:Any]] = []
    var failures: [String] = []
    var passed: [String] = []
    var fixturePort = 0
    var pageObservation: AnyCancellable?
    var qaMenu: StatusMenuController?
    func check(_ condition:Bool,_ name:String) { if condition { passed.append(name) } else { failures.append(name) } }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args=CommandLine.arguments
        folder=URL(fileURLWithPath:args[1]);label=args[2];fixturePort=Int(args[3])!
        Task { do { try await run(interactive:args[4] == "interactive") } catch { failures.append(String(describing:error));finish() } }
    }
    func run(interactive:Bool) async throws {
        let store=AppStore();self.store=store;store.shuttingDown=true
        let data=folder.appendingPathComponent(label+"-ui-data")
        try FileManager.default.createDirectory(at:data,withIntermediateDirectories:true)
        let db=data.appendingPathComponent("lumaroute.sqlite")
        if FileManager.default.fileExists(atPath:db.path) { try FileManager.default.removeItem(at:db) }
        try FileManager.default.copyItem(at:folder.appendingPathComponent("before.sqlite"),to:db)
        store.store=try LocalStore(root:data,secrets:MemorySecrets(),readOnly:true);store.database=try store.store.load()
        let decoded=try JSONDecoder().decode(ProxiesResponse.self,from:Data(contentsOf:folder.appendingPathComponent("proxies.json")))
        store.proxies=decoded.proxies;store.groupOrder=store.groups.map(\.name)
        #if UI_OPTIMIZED
        let container=PageContainerView(frame:NSRect(x:0,y:0,width:1000,height:700))
        container.show(.subscriptions,store:store)
        let firstPage=container.subviews.first
        container.show(.settings,store:store)
        check(container.subviews.count==1 && container.subviews.first !== firstPage,"only active page is attached")
        container.show(.subscriptions,store:store)
        check(container.subviews.first === firstPage,"visited hosting view is retained")
        container.frame.size=NSSize(width:1100,height:760);container.layoutSubtreeIfNeeded()
        check(container.subviews.first?.frame==container.bounds,"cached page follows window resizing")
        #endif
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:850),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="LumaRoute 界面隔离测试 · "+label
        let host=NSHostingView(rootView:RootView().environmentObject(store));window.contentView=host;self.window=window
        if interactive {
            let button=NSButton(title:"状态菜单 · 隔离测试",target:self,action:#selector(openMenu))
            button.frame=NSRect(x:900,y:window.contentLayoutRect.height-38,width:200,height:28)
            button.autoresizingMask=[.minXMargin,.minYMargin]
            host.addSubview(button)
            qaMenu=StatusMenuController(store:store,openMainWindow:{})
            pageObservation=store.$page.dropFirst().removeDuplicates().sink { [weak self,weak host] page in
                let start=ContinuousClock.now
                DispatchQueue.main.async {
                    guard let self,let host,self.store.page==page else { return }
                    host.layoutSubtreeIfNeeded();host.displayIfNeeded()
                    self.record(["event":"navigation","page":page.rawValue,"milliseconds":self.milliseconds(start)])
                }
            }
            window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);return
        }
        for round in 0..<8 { for page in [AppPage.overview,.subscriptions,.proxies,.rules,.logs,.settings] {
            let start=ContinuousClock.now;store.page=page;host.layoutSubtreeIfNeeded();host.displayIfNeeded()
            samples.append(["round":round,"page":page.rawValue,"milliseconds":milliseconds(start)])
        }}
        let menu=StatusMenuController(store:store,openMainWindow:{})
        var menuTimes:[Double]=[];var firstIDs:[ObjectIdentifier]=[]
        for index in 0..<15 {
            let start=ContinuousClock.now;let root=menu.checkMenu();menuTimes.append(milliseconds(start))
            let ids=root.items.map(ObjectIdentifier.init)
            if index==0 {firstIDs=ids}
            #if UI_OPTIMIZED
            if index != 0 {check(ids==firstIDs,"menu objects retained on open \(index)")}
            #endif
        }
        #if UI_OPTIMIZED
        let original=menu.checkMenu()
        store.coreReady=true
        check(menu.checkMenu().items.first(where:{$0.title=="设置为系统代理"})?.isEnabled==true,"reused menu enables actions when core becomes ready")
        store.busy=true
        let busyMenu=menu.checkMenu()
        check(busyMenu.items.first(where:{$0.title=="设置为系统代理"})?.isEnabled==false,"reused menu disables actions while busy")
        store.busy=false
        var settings=store.database.settings;settings.systemProxy=true;store.database.settings=settings
        check(menu.checkMenu().items.first(where:{$0.title=="设置为系统代理"})?.state == .on,"reused menu updates checked network state")
        settings.systemProxy=false;store.database.settings=settings
        if let name=store.groups.first?.name,var group=store.proxies[name],let alternate=group.all?.last {
            group.now=alternate;store.proxies[name]=group
            let child=menu.checkMenu().items.first(where:{$0.submenu?.title==name})?.submenu
            check(child?.items.contains(where:{$0.toolTip?.hasPrefix(alternate)==true && $0.state == .on})==true,"reused menu follows live group selection")
            menu.checkTracking(true)
            group.all?.append("fixture-added-node");store.proxies[name]=group
            check(menu.checkMenu().items.map(ObjectIdentifier.init)==firstIDs,"structure change deferred while tracking")
            menu.checkTracking(false)
            check(menu.checkMenu().items.map(ObjectIdentifier.init) != firstIDs,"structure change rebuilds after tracking")
        }
        withExtendedLifetime(original) {}
        #endif
        var notifications=0
        let token=store.objectWillChange.sink { _ in notifications += 1 }
        let running=store.serviceRunning,rollback=store.canRollbackGeo
        for _ in 0..<10 {
            #if UI_OPTIMIZED
            store.updateServiceSnapshot(running:running,canRollbackGeo:rollback)
            #else
            store.serviceRunning=running;store.canRollbackGeo=rollback
            #endif
        }
        let unchangedNotifications=notifications
        #if UI_OPTIMIZED
        check(unchangedNotifications==0,"unchanged service snapshots publish nothing")
        store.updateServiceSnapshot(running:!running,canRollbackGeo:!rollback)
        check(notifications==2,"changed service snapshot remains observable")
        #endif
        withExtendedLifetime(token) {}
        var policyTimes:[Double]=[]
        var mainTicks=0
        let ticker=Task { while !Task.isCancelled { mainTicks += 1;try? await Task.sleep(nanoseconds:1_000_000) } }
        if let composition=store.activeProfile?.composition {
            for _ in 0..<8 {
                let start=ContinuousClock.now
                #if UI_OPTIMIZED
                let targets=try await store.compositionPolicyTargets(composition)
                #else
                let targets=try store.compositionPolicyTargets(composition)
                #endif
                check(!targets.isEmpty,"actual composition candidates available")
                policyTimes.append(milliseconds(start))
            }
        }
        ticker.cancel()
        #if UI_OPTIMIZED
        check(store.activeProfile?.composition == nil || mainTicks>0,"UI executor keeps running during candidate generation")
        #endif
        try await refreshChecks(store)
        #if UI_OPTIMIZED
        try await policyChecks()
        #endif
        finish(extra:["menu_ms":menuTimes,"policy_ms":policyTimes,"policy_main_ticks":mainTicks,"unchanged_notifications":unchangedNotifications])
    }
    func refreshChecks(_ store:AppStore) async throws {
        store.database.settings.controllerPort=fixturePort
        store.shuttingDown=false;store.coreReady=true
        store.page = .settings;store.setMainWindowVisible(true)
        await store.refresh()
        try await Task.sleep(nanoseconds:150_000_000)
        _ = try await store.api.data(["reset"])
        for page in [AppPage.subscriptions,.settings,.logs,.settings,.subscriptions] {
            store.page=page;try await Task.sleep(nanoseconds:40_000_000)
        }
        let counts=try JSONSerialization.jsonObject(with:await store.api.data(["counts"])) as! [String:Int]
        #if UI_OPTIMIZED
        check((counts["/proxies"] ?? 0)==0 && (counts["/providers/proxies"] ?? 0)==0,"settings/subscriptions navigation does not force node/provider requests")
        #endif
        samples.append(["navigation_request_counts":counts])
        await store.refresh()
        let forced=try JSONSerialization.jsonObject(with:await store.api.data(["counts"])) as! [String:Int]
        check((forced["/proxies"] ?? 0)>0 && (forced["/providers/proxies"] ?? 0)>0,"explicit refresh still refreshes nodes and providers")
        store.shuttingDown=true
    }
    #if UI_OPTIMIZED
    func policyChecks() async throws {
        let root=folder.appendingPathComponent("policy-fixture-"+UUID().uuidString)
        let local=try LocalStore(root:root,secrets:MemorySecrets())
        let a=Profile(name:"A",isRemote:false),b=Profile(name:"B",isRemote:false)
        let yaml="proxies:\n  - {name: n, type: http, server: 127.0.0.1, port: 9999}\nproxy-groups:\n  - {name: choice, type: select, proxies: [n]}\nrules: ['MATCH,choice']\n"
        try local.saveProfile(yaml,id:a.id);try local.saveProfile(yaml,id:b.id)
        var plan=SubscriptionComposition();plan.profileIDs=[a.id,b.id];plan.baseProfileID=a.id
        let cache=CompositionPolicyCache()
        let initial=try await cache.targets(plan,profiles:[a,b],settings:NetworkSettings(),store:local)
        check(initial.contains("[B] choice"),"cache returns member policy names")
        try local.saveProfile(yaml.replacingOccurrences(of:"choice",with:"changed"),id:b.id)
        let changed=try await cache.targets(plan,profiles:[a,b],settings:NetworkSettings(),store:local)
        check(changed.contains("[B] changed") && !changed.contains("[B] choice"),"content change invalidates cache even with identical metadata")
        var renamed=b;renamed.name="Renamed"
        let names=try await cache.targets(plan,profiles:[a,renamed],settings:NetworkSettings(),store:local)
        check(names.contains("[Renamed] changed"),"rename invalidates candidate aliases")
        let canceled=Task { try await cache.targets(plan,profiles:[a,b],settings:NetworkSettings(),store:local) };canceled.cancel()
        do {_ = try await canceled.value;check(false,"canceled candidate read rejected")}catch is CancellationError {check(true,"canceled candidate read rejected")}
        let readonly=try LocalStore(root:folder.appendingPathComponent("after-ui-data"),secrets:MemorySecrets(),readOnly:true)
        do {_ = try await cache.targets(plan,profiles:[a,b],settings:NetworkSettings(),store:readonly);check(false,"missing member never returns old cache")}catch {check(true,"missing member never returns old cache")}
    }
    #endif
    func milliseconds(_ start:ContinuousClock.Instant)->Double {let t=start.duration(to:.now).components;return Double(t.seconds)*1000+Double(t.attoseconds)/1e15}
    @objc func openMenu() {
        guard let view=window?.contentView,let qaMenu else { return }
        let start=ContinuousClock.now
        _ = qaMenu.checkMenu()
        record(["event":"menu-update","milliseconds":milliseconds(start)])
        qaMenu.showForQA(view)
    }
    func record(_ event:[String:Any]) {
        let path=folder.appendingPathComponent(label+"-interactive.jsonl")
        guard var data=try? JSONSerialization.data(withJSONObject:event) else { return };data.append(10)
        if !FileManager.default.fileExists(atPath:path.path) {FileManager.default.createFile(atPath:path.path,contents:nil)}
        if let handle=try? FileHandle(forWritingTo:path) {defer{try? handle.close()};try? handle.seekToEnd();try? handle.write(contentsOf:data)}
    }
    func finish(extra:[String:Any]=[:]) {
        var result=extra;result["samples"]=samples;result["passed"]=passed;result["failures"]=failures
        try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent(label+"-response.json"))
        NSApp.terminate(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {true}
}
@main struct UIResponseCheck {
    @MainActor static func main() {let app=NSApplication.shared;let delegate=UIResponseDelegate();app.delegate=delegate;app.setActivationPolicy(CommandLine.arguments.last=="interactive" ? .regular:.accessory);app.run();withExtendedLifetime(delegate){}}
}
