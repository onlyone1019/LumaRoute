import AppKit
import SwiftUI
import LumaRouteCore

@MainActor enum Probe {
    static var connectionFilters=0
    static var connectionReloads=0
    static var logFilters=0
    static var menuUpdates=0
    static func reset(){connectionFilters=0;connectionReloads=0;logFilters=0;menuUpdates=0}
}
@MainActor final class PerformanceDelegate:NSObject,NSApplicationDelegate {
    let store=AppStore()
    let connections=ConnectionsPageState()
    let logs=LogsPageState()
    var window:NSWindow!
    var host:NSHostingView<AnyView>!
    var folder:URL!
    var interactiveMenu:StatusMenuController?
    var checks:[String]=[],failures:[String]=[]
    func check(_ value:Bool,_ message:String){if value{checks.append(message)}else{failures.append(message)}}
    func applicationDidFinishLaunching(_ notification:Notification){
        folder=URL(fileURLWithPath:CommandLine.arguments[1])
        try? JSONSerialization.data(withJSONObject:["pid":ProcessInfo.processInfo.processIdentifier]).write(to:folder.appendingPathComponent("progress.json"))
        Task {
            do {
                if CommandLine.arguments.contains("interactive") { try showInteractive();return }
                try await run()
            } catch { failures.append(String(describing:error)) }
            finish()
        }
    }
    func settle()async{try? await Task.sleep(for:.milliseconds(50));host.layoutSubtreeIfNeeded();host.displayIfNeeded();try? await Task.sleep(for:.milliseconds(30))}
    func table(in view:NSView)->NSTableView?{if let t=view as? NSTableView{return t};return view.subviews.lazy.compactMap{self.table(in:$0)}.first}
    func rows()throws->[LiveConnection]{
        let data=(0..<2000).map {i -> [String:Any] in ["id":"id-\(i)","metadata":["host":"service-\(i).example.test","network":i%2==0 ? "tcp":"udp","process":"Test"],"chains":[i%2==0 ? "A":"B"],"download":i,"upload":2000-i]}
        return try JSONDecoder().decode([LiveConnection].self,from:JSONSerialization.data(withJSONObject:data))
    }
    func run()async throws{
        store.shuttingDown=true
        store.store=try LocalStore(root:folder.appendingPathComponent("data"),secrets:MemorySecrets())
        store.database.profiles=[Profile(name:"Synthetic",isRemote:false)];store.database.activeProfileID=store.database.profiles[0].id
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:850),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="LumaRoute 性能回归（隔离数据）"
        host=NSHostingView(rootView:AnyView(ConnectionsPage(state:connections).padding(28).environmentObject(store)))
        window.contentView=host;window.orderFront(nil)
        var data=try rows();store.connections=data;await settle()
        check(table(in:host)?.numberOfRows==2000,"connection page displays all rows")
        Probe.reset();data[0].download=5000;store.connections=data;await settle()
        check(Probe.connectionFilters==1,"one filter/sort per connection snapshot render")
        Probe.reset();store.connections=data;await settle()
        check(Probe.connectionFilters==0 && Probe.connectionReloads==0,"identical connection snapshot performs no render or table reload")
        Probe.reset();connections.selection="id-0";await settle()
        check(Probe.connectionReloads==0,"selection-only changes do not reload connection rows")
        check(table(in:host)?.selectedRow==0,"selection uses current sorted position")
        Probe.reset();data[0].metadata.process="Changed";store.connections=data;await settle()
        check(Probe.connectionReloads>0 && store.connections[0].processName=="Changed","same ID with changed process refreshes rows")
        connections.search="service-1999";await settle();check(table(in:host)?.numberOfRows==1,"connection search retains matching row")
        connections.network="tcp";await settle();check(table(in:host)?.numberOfRows==0,"protocol filter composes with search")
        connections.search="";connections.network="all";connections.policy="A";await settle();check(table(in:host)?.numberOfRows==1000,"policy filter remains effective")
        connections.policy="all";connections.sortOrder=[KeyPathComparator(\LiveConnection.upload,order:.forward)];await settle()
        check(table(in:host)?.selectedRow==1999,"sorting moves the selected row without losing its ID")
        data.removeFirst();store.connections=data;await settle();check(table(in:host)?.selectedRow == -1,"disappearing selection is cleared in the native table")
        store.connections=[];await settle();check(table(in:host)?.numberOfRows==0,"empty connection snapshot clears rows")
        try await checkTableParent()
        try await checkLogs()
        try checkMenu()
    }
    func checkTableParent()async throws{
        var selected:String?="id-0",captured=""
        let data=Array(try rows().prefix(2))
        func parent(_ target:String,_ enabled:Bool)->ConnectionTableView{
            ConnectionTableView(rows:data,selection:Binding(get:{selected},set:{selected=$0}),sortOrder:.constant([KeyPathComparator(\LiveConnection.download)]),targets:[(target,target)],canCreateRule:enabled,createRule:{_,_,value in captured=value})
        }
        let native=NSTableView();let coordinator=parent("old",true).makeCoordinator()
        coordinator.update(parent("old",true),table:native)
        Probe.reset();coordinator.update(parent("new",false),table:native)
        check(Probe.connectionReloads==0,"same rows skip reload when actions change")
        check(coordinator.menu(for:0)?.items.first?.isEnabled==false,"busy state updates despite skipped reload")
        coordinator.update(parent("new",true),table:native)
        let action=coordinator.menu(for:0)?.items.first?.submenu
        check(action?.items.first?.title=="new","routing targets update despite skipped reload")
        action?.performActionForItem(at:0)
        check(captured=="new","routing action uses the new callback and target")
    }
    func checkLogs()async throws{
        let entries=(0..<2000).map {LogEntry(level:$0%2==0 ? "info":"warning",source:$0%2==0 ? "内核":"应用",message:"synthetic message \($0)")}
        host.rootView=AnyView(LogsPage(state:logs).padding(28).environmentObject(store));store.logs=entries;await settle()
        Probe.reset();logs.search="message 1999";await settle()
        check(Probe.logFilters==1,"one log filter per search render")
        check(table(in:host)?.numberOfRows==1,"log search preserves matching entry")
        logs.selection=entries.last?.id;await settle();check(table(in:host)?.selectedRow==0,"filtered log selection remains correct")
        logs.snapshot=entries;logs.paused=true;store.logs=[];await settle();check(table(in:host)?.numberOfRows==1,"paused logs keep their snapshot after live data changes")
        logs.paused=false;logs.snapshot=[];await settle();check(table(in:host)?.numberOfRows==0,"resume uses current live logs")
        store.logs=entries;logs.search="";logs.level="warning";logs.source="应用";await settle();check(table(in:host)?.numberOfRows==1000,"level and source filters compose")
        logs.prepareExport(store.logs);check(logs.exportDocument?.text.contains("synthetic message 0")==true,"export still includes unfiltered live logs")
        logs.finishExport();check(logs.exportDocument==nil,"export snapshot is released")
    }
    func makeMenu(groupCount:Int=20,nodeCount:Int=1000)throws->StatusMenuController{
        var nodes:[String:[String:Any]]=[:]
        for i in 0..<nodeCount {nodes["n\(i)"]=["name":"n\(i)","type":"Shadowsocks"]}
        for i in 0..<groupCount {nodes["g\(i)"]=["name":"g\(i)","type":i==0 ? "URLTest":"Selector","now":"n0","all":(0..<nodeCount).map{"n\($0)"}]}
        store.proxies=try JSONDecoder().decode([String:ProxyNode].self,from:JSONSerialization.data(withJSONObject:nodes))
        store.coreReady=true
        return StatusMenuController(store:store,openMainWindow:{})
    }
    func checkMenu()throws{
        let controller=try makeMenu()
        defer{controller.testDispose()}
        let root=controller.testMenu()
        guard let group=root.items.first(where:{$0.submenu?.title=="g0"})?.submenu,
              let unopened=root.items.first(where:{$0.submenu?.title=="g1"})?.submenu else{check(false,"group menu exists");return}
        check(group.numberOfItems==0 && unopened.numberOfItems==0,"opening root does not build node submenus")
        check(root.items.first(where:{$0.title=="延迟测速"})?.keyEquivalent=="t","global latency shortcut remains eager")
        controller.menuWillOpen(root);check(controller.testTimerRunning,"menu open starts refresh timer")
        controller.menuNeedsUpdate(group);controller.menuWillOpen(group)
        check(group.items.contains(where:{$0.toolTip=="n0" && $0.state == .on}),"lazy submenu reflects selected node")
        check(group.items.contains(where:{$0.title=="自动选择"}),"automatic strategy action remains available")
        let firstItems=group.items.map(ObjectIdentifier.init)
        store.proxies["g0"]?.now="n1";store.testRunning=true;store.testTotal=1000;store.testProgress=7
        store.nodeErrors["n1"]="fixture timeout";controller.testTick()
        check(group.items.map(ObjectIdentifier.init)==firstItems,"live menu refresh preserves item identity and scroll state")
        check(group.items.contains(where:{$0.toolTip=="n1 · 超时" && $0.state == .on}),"open submenu updates selected node and latency error")
        check(group.items.first?.title=="正在测速 (7/1000)" && group.items.first?.isEnabled==false,"submenu benchmark progress remains live")
        controller.menuDidClose(group);store.proxies["g0"]?.now="n2";Probe.menuUpdates=0;controller.testTick()
        check(Probe.menuUpdates<100,"closed node submenus are not traversed by periodic state refresh")
        controller.menuNeedsUpdate(group);check(group.items.contains(where:{$0.toolTip=="n2" && $0.state == .on}),"reopened submenu catches up with current selection")
        store.busy=true;controller.testTick()
        let config=root.items.first(where:{$0.submenu?.title=="配置"})?.submenu
        check(config?.items.first(where:{$0.keyEquivalent=="r"})?.isEnabled==false,"eager configuration shortcut stays disabled while busy")
        let oldRoot=root.items.map(ObjectIdentifier.init)
        store.proxies["g0"]?.all=["n0","n2"];controller.menuNeedsUpdate(root)
        check(root.items.map(ObjectIdentifier.init)==oldRoot,"structure changes are deferred during root tracking")
        controller.menuDidClose(root);check(!controller.testTimerRunning,"last menu close stops refresh timer")
        let updated=controller.testMenu().items.first(where:{$0.submenu?.title=="g0"})!.submenu!
        controller.menuNeedsUpdate(updated)
        check(updated.items.filter{$0.toolTip?.hasPrefix("n")==true}.count==2,"next root session rebuilds changed group membership")
    }
    func showInteractive()throws {
        store.shuttingDown=true;store.database.settings.controllerPort=0
        interactiveMenu=try makeMenu(groupCount:2,nodeCount:5)
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:500,height:180),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title="LumaRoute 隔离菜单验收"
        let button=NSButton(title:"展开隔离菜单",target:self,action:#selector(openMenu))
        button.frame=NSRect(x:140,y:65,width:220,height:40);window.contentView?.addSubview(button)
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    @objc func openMenu(_ sender:NSButton){interactiveMenu?.testShow(at:sender)}
    func finish(){
        let result:[String:Any]=["checks":checks,"failures":failures]
        try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("result.json"))
        window?.orderOut(nil);NSApp.terminate(nil)
    }
}
@main struct PerformanceRegression {
    @MainActor static func main(){let app=NSApplication.shared;let delegate=PerformanceDelegate();app.delegate=delegate;app.setActivationPolicy(.accessory);app.run()}
}
