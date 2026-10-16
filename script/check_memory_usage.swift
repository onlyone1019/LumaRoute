import AppKit
import SwiftUI
import LumaRouteCore

@MainActor final class MemoryCheckDelegate: NSObject,NSApplicationDelegate {
    var window:NSWindow!
    var host:NSHostingView<AnyView>!
    var store:AppStore!
    var folder:URL!
    var label=""
    var measurements:[[String:Any]]=[]
    var navigation:[[String:Any]]=[]
    var failures:[String]=[]
    var checks:[String]=[]
    func check(_ condition:Bool,_ name:String) { if condition { checks.append(name) } else { failures.append(name) } }
    func applicationDidFinishLaunching(_ notification:Notification) {
        folder=URL(fileURLWithPath:CommandLine.arguments[1]);label=CommandLine.arguments[2]
        Task { do { try await run() } catch { failures.append(String(describing:error));finish() } }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
    func settle(_ nanoseconds:UInt64=80_000_000) async { try? await Task.sleep(nanoseconds:nanoseconds);host.layoutSubtreeIfNeeded();host.displayIfNeeded() }
    func memory(_ stage:String) {
        var info=task_vm_info_data_t()
        var count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
        let status=withUnsafeMutablePointer(to:&info) { pointer in
            pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count) }
        }
        check(status==KERN_SUCCESS,"footprint query: "+stage)
        measurements.append(["stage":stage,"footprint_mb":Double(info.phys_footprint)/1048576])
    }
    func snapshot(_ name:String) throws {
        guard let rep=host.bitmapImageRepForCachingDisplay(in:host.bounds) else { throw NSError(domain:"snapshot",code:1) }
        host.cacheDisplay(in:host.bounds,to:rep)
        try rep.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(label+"-"+name+".png"))
    }
    func switchTo(_ page:AppPage,round:Int) async {
        let began=ContinuousClock.now
        store.page=page
        // Include the run-loop turn that applies SwiftUI navigation and layout.
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        host.layoutSubtreeIfNeeded();host.displayIfNeeded()
        let t=began.duration(to:.now).components
        navigation.append(["page":page.rawValue,"round":round,"milliseconds":Double(t.seconds)*1000+Double(t.attoseconds)/1e15])
        await settle()
    }
    func run() async throws {
        let store=AppStore();self.store=store;store.shuttingDown=true
        store.store=try LocalStore(root:folder.appendingPathComponent(label+"-data-"+UUID().uuidString),secrets:MemorySecrets())
        var profile=Profile(name:"内存测试配置",isRemote:false)
        profile.nodeCount=160
        store.database.profiles=[profile];store.database.activeProfileID=profile.id
        let nodes=(0..<160).map { ["name":"测试节点-\($0)","type":"Shadowsocks"] }
        var proxies=Dictionary(uniqueKeysWithValues:nodes.map { ($0["name"]!,$0 as [String:Any]) })
        for index in 0..<8 {
            let names=nodes.map { $0["name"]! }
            proxies["策略组-\(index)"]=["name":"策略组-\(index)","type":"Selector","now":names[0],"all":names]
        }
        store.proxies=try JSONDecoder().decode(ProxiesResponse.self,from:JSONSerialization.data(withJSONObject:["proxies":proxies])).proxies
        let connections=(0..<300).map { i -> [String:Any] in
            ["id":"connection-\(i)","upload":i*100,"download":i*1000,"chains":["策略组-0"],
             "metadata":["host":"service-\(i).example.test","network":"tcp","process":"测试程序","processPath":"/test/application","destinationPort":"443"]]
        }
        store.connections=try JSONDecoder().decode(ConnectionsResponse.self,from:JSONSerialization.data(withJSONObject:["uploadTotal":0,"downloadTotal":0,"connections":connections])).connections!
        store.logs=(0..<2000).map { i in
            var entry=LogEntry(source:"内核",message:"[\(i)] tcp connection service.example.test:443 via 策略组-0 "+String(repeating:"payload ",count:32))
            entry.date=Date(timeIntervalSince1970:1_700_000_000+Double(i));return entry
        }
        store.database.customRules=[CustomRule(payload:"example.test")]
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:850),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="LumaRoute 内存隔离测试 · "+label
        host=NSHostingView(rootView:AnyView(RootView().environmentObject(store)));window.contentView=host
        window.orderFront(nil)
        await settle(300_000_000)
        if CommandLine.arguments.last == "interactive" {
            store.page = .logs
            NSApp.setActivationPolicy(.regular);window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            return
        }
        memory("overview")
        for round in 0..<5 {
            for page in AppPage.allCases { await switchTo(page,round:round) }
        }
        memory("all_pages_warm")
        await switchTo(.logs,round:5)
        weak var logsView=findView(PageContainerView.self,in:host)?.subviews.first
        try snapshot("logs")
        let started=ContinuousClock.now
        for index in 0..<40 {
            store.logs.removeFirst();store.logs.append(LogEntry(source:"内核",message:"live-update-\(index)"))
            await settle(10_000_000)
        }
        let elapsed=started.duration(to:.now).components
        measurements.append(["stage":"40_log_updates","milliseconds":Double(elapsed.seconds)*1000+Double(elapsed.attoseconds)/1e15])
        memory("after_log_updates")
        await switchTo(.connections,round:5);try snapshot("connections")
        weak var connectionsView=findView(PageContainerView.self,in:host)?.subviews.first
        await switchTo(.settings,round:5);try snapshot("settings")
        // Real production timeout: the optimized host releases only inactive
        // read-only pages. Baseline waits for the same interval.
        await settle(61_000_000_000)
        memory("after_61s_idle")
        #if MEMORY_OPTIMIZED
        check(logsView==nil && connectionsView==nil,"real idle timeout releases both inactive hosting views")
        #else
        check(logsView != nil && connectionsView != nil,"baseline retains both inactive hosting views")
        #endif
        for page in [AppPage.logs,.connections,.settings] { await switchTo(page,round:6) }
        memory("after_return")
        #if MEMORY_OPTIMIZED
        try await lifecycleChecks()
        #endif
        finish()
    }
    func findView<T:NSView>(_ type:T.Type,in view:NSView)->T? {
        if let match=view as? T { return match }
        return view.subviews.lazy.compactMap { self.findView(type,in:$0) }.first
    }
    #if MEMORY_OPTIMIZED
    func lifecycleChecks() async throws {
        guard let container=findView(PageContainerView.self,in:host) else { check(false,"page container exists");return }
        let exporting=LogsPageState()
        check(exporting.exportDocument==nil,"no export document is built before request")
        var sensitive=LogEntry(source:"测试",message:"placeholder")
        sensitive.message="https://example.test/subscribe?token=private-token"
        exporting.prepareExport([sensitive])
        check(exporting.exporting && exporting.exportDocument?.text.contains("[测试]")==true,"requested export contains source and formatted log")
        check(exporting.exportDocument?.text.contains("private-token")==false,"requested export redacts credentials")
        let exported=exporting.exportDocument?.text
        sensitive.message="changed after export"
        check(exporting.exportDocument?.text==exported,"export uses a fixed snapshot")
        exporting.finishExport()
        check(!exporting.exporting && exporting.exportDocument==nil,"completion or cancellation releases export text")

        await switchTo(.logs,round:7)
        weak var warmLog=container.subviews.first
        await switchTo(.settings,round:7);await switchTo(.logs,round:7)
        check(container.subviews.first === warmLog,"normal return reuses exact hosting view")
        container.logsState.search="live-update"
        container.logsState.source="内核"
        container.logsState.autoScroll=false
        container.logsState.paused=true
        container.logsState.snapshot=store.logs
        container.logsState.selection=store.logs.last?.id
        await settle()
        if let scroll=findView(NSScrollView.self,in:container) { scroll.contentView.scroll(to:NSPoint(x:0,y:200)) }
        await switchTo(.connections,round:7)
        container.connectionsState.search="service"
        container.connectionsState.network="tcp"
        container.connectionsState.policy="策略组-0"
        container.connectionsState.selection="connection-99"
        container.connectionsState.sortOrder=[KeyPathComparator(\LiveConnection.download,order:.forward)]
        await settle()
        if let scroll=findView(NSScrollView.self,in:container) { scroll.contentView.scroll(to:NSPoint(x:0,y:300)) }
        if let table=findView(NSTableView.self,in:container) { table.tableColumns.first?.width=100 }
        let offset=findView(NSScrollView.self,in:container)?.contentView.bounds.origin
        let columnWidth=findView(NSTableView.self,in:container)?.tableColumns.first?.width
        weak var recycledConnection=container.subviews.first
        await switchTo(.settings,round:7)
        weak var settingsView=container.subviews.first
        container.releaseInactivePages()
        await settle()
        check(warmLog==nil && recycledConnection==nil,"explicit cleanup deallocates inactive rendering trees")
        check(container.subviews.first === settingsView,"cleanup retains current editing page")
        await switchTo(.connections,round:7)
        let c=container.connectionsState
        check(c.search=="service" && c.network=="tcp" && c.policy=="策略组-0" && c.selection=="connection-99","connection filters and selection survive recreation")
        check(c.sortOrder.first?.order == .forward,"connection sorting survives recreation")
        if let offset,let restored=findView(NSScrollView.self,in:container)?.contentView.bounds.origin {
            check(abs(restored.y-offset.y)<1,"connection scroll position survives recreation")
        } else { check(false,"connection scroll view available for restoration check") }
        if let columnWidth,let restored=findView(NSTableView.self,in:container)?.tableColumns.first?.width {
            check(abs(restored-columnWidth)<1,"connection column width survives recreation")
        } else { check(false,"connection table available for restoration check") }
        await switchTo(.logs,round:7)
        let l=container.logsState
        check(l.search=="live-update" && l.source=="内核" && !l.autoScroll && l.paused && l.snapshot.count==2000 && l.selection==store.logs.last?.id,"log filters pause snapshot and selection survive recreation")
        weak var active=container.subviews.first
        container.releaseInactivePages();await settle()
        check(container.subviews.first === active,"cleanup never releases active live page")
        await switchTo(.settings,round:7)
        check(container.subviews.first === settingsView,"editing page view is retained through cleanup and navigation")
        check(l.exportDocument==nil,"live updates and recreation do not prepare an export")
        container.frame.size=NSSize(width:1080,height:760);container.layoutSubtreeIfNeeded()
        check(container.subviews.first?.frame==container.bounds,"page still follows window resize")
    }
    #endif
    func finish() {
        let result:[String:Any]=["measurements":measurements,"navigation":navigation,"checks":checks,"failures":failures]
        try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent(label+".json"))
        NSApp.terminate(nil)
    }
}
@main struct MemoryCheck {
    @MainActor static func main() {
        let app=NSApplication.shared;let delegate=MemoryCheckDelegate();app.delegate=delegate
        app.setActivationPolicy(.accessory);app.run();withExtendedLifetime(delegate) {}
    }
}
