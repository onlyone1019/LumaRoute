import AppKit
import SwiftUI
import LumaRouteCore

/// Render the production page with synthetic values; never bootstrap AppStore.
@MainActor final class ConnectionTableCheckDelegate:NSObject,NSApplicationDelegate {
    var window:NSWindow!
    var host:NSHostingView<AnyView>!
    var store:AppStore!
    var state=ConnectionsPageState()
    var folder:URL!
    var mode=""
    var checks:[String]=[]
    var failures:[String]=[]
    var updates=0
    var heightSamples=0
    var heightViolations=0
    var soakUpdates=0
    var soakElapsed=0.0
    func sampleHeight(_ table:NSTableView) {
        heightSamples+=1
        if table.usesAutomaticRowHeights { heightViolations+=1 }
    }
    func check(_ condition:Bool,_ message:String) {
        if condition { checks.append(message) } else { failures.append(message) }
    }
    func find<T:NSView>(_ type:T.Type,in view:NSView)->T? {
        if let value=view as? T { return value }
        return view.subviews.lazy.compactMap { self.find(type,in:$0) }.first
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        folder=URL(fileURLWithPath:CommandLine.arguments[1]);mode=CommandLine.arguments[2]
        try? JSONSerialization.data(withJSONObject:["pid":ProcessInfo.processInfo.processIdentifier]).write(to:folder.appendingPathComponent(mode+"-progress.json"),options:.atomic)
        Task { do { try await run() } catch { failures.append(String(describing:error));finish() } }
    }
    func settle() async {
        try? await Task.sleep(for:.milliseconds(20))
        host.layoutSubtreeIfNeeded();host.displayIfNeeded()
    }
    func connections(_ count:Int,generation:Int) throws -> [LiveConnection] {
        let rows=(0..<count).map { index -> [String:Any] in
            ["id":"connection-\(generation/5)-\(index)",
             "metadata":["network":index%3==0 ? "udp":"tcp","process":"测试应用-\(index%10)",
                         "host":String(repeating:"long-hostname.",count:index%7)+"\(index).example.test","destinationPort":"443"],
             "chains":["测试策略组-\(index%4)"],"upload":(index*17+generation*73)%20000,"download":(index*131+generation*977)%400000]
        }
        return try JSONDecoder().decode([LiveConnection].self,from:JSONSerialization.data(withJSONObject:rows))
    }
    func snapshot(_ name:String) async throws {
        // SwiftUI commits its layer contents on a later run-loop turn than
        // NSTableView's row count. Wait for drawing before capturing the page.
        await settle()
        try await Task.sleep(for:.milliseconds(100))
        await settle()
        guard let image=host.bitmapImageRepForCachingDisplay(in:host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in:host.bounds,to:image)
        guard let data=image.representation(using:.png,properties:[:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to:folder.appendingPathComponent(mode+"-"+name+".png"))
    }
    func run() async throws {
        store=AppStore();store.shuttingDown=true
        // Only synthetic state and a private SQLite folder; no real credentials, core or helper.
        store.store=try LocalStore(root:folder.appendingPathComponent(mode+"-data-"+UUID().uuidString),secrets:MemorySecrets())
        store.database.profiles=[Profile(name:"GUI 测试",isRemote:false)]
        store.database.activeProfileID=store.database.profiles[0].id
        store.page = .connections
        store.connections=try connections(80,generation:0)
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:850),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="LumaRoute 连接表格 GUI 回归"
        let content:AnyView=mode=="direct" ? AnyView(ConnectionsPage(state:state).padding(28).environmentObject(store)):AnyView(RootView().environmentObject(store))
        host=NSHostingView(rootView:content);window.contentView=host;window.orderFront(nil)
        await settle()
        if mode=="container" {
            guard let container=find(PageContainerView.self,in:host) else { throw CocoaError(.coderInvalidValue) }
            state=container.connectionsState
        }
        guard var table=find(NSTableView.self,in:host) else { throw CocoaError(.coderInvalidValue) }
        check(table.numberOfRows==80,"initial populated page renders all rows")
        check(table.tableColumns.count==5,"five native columns retained")
        check(table.tableColumns.map { $0.headerCell.stringValue }==["进程","目标","策略","下载","上传"],"column names retained")
        try await snapshot("initial")
        check(table.rowView(atRow:0,makeIfNecessary:false) != nil,"initial visible row materialized")
        check(table.view(atColumn:0,row:0,makeIfNecessary:false) != nil,"initial visible cell materialized")
        let nativeStyle:[String:Any]=["row_height":table.rowHeight,"style":table.style.rawValue,
            "intercell_width":table.intercellSpacing.width,"intercell_height":table.intercellSpacing.height,
            "grid_style":table.gridStyleMask.rawValue,"autoresize_style":table.columnAutoresizingStyle.rawValue,
            "header_height":table.headerView?.frame.height ?? 0,"column_widths":table.tableColumns.map(\.width)]
        try JSONSerialization.data(withJSONObject:nativeStyle,options:.prettyPrinted).write(to:folder.appendingPathComponent(mode+"-style.json"))
        sampleHeight(table)
        for step in 0..<240 {
            let count=[0,1,500,3,1200,5,0,180][step%8]
            store.connections=try connections(count,generation:step)
            if step%7==0 { state.selection=store.connections.first?.id }
            if step%11==0 { state.selection=nil }
            if step%17==0 { state.sortOrder=[KeyPathComparator(\LiveConnection.upload,order:step%2==0 ? .forward:.reverse)] }
            if step%29==0 { state.network=step%2==0 ? "tcp":"all" }
            if step%19==0 { window.setContentSize(NSSize(width:step%2==0 ? 1020:1280,height:850)) }
            await settle()
            sampleHeight(table)
            let expected=state.network=="all" ? count:count-(count+2)/3
            check(table.numberOfRows==expected,"updated rows \(step)")
            if table.numberOfRows>0 && step%4==0 { table.scrollRowToVisible((step*13)%table.numberOfRows) }
            updates+=1
            if step%20==0 {
                try JSONSerialization.data(withJSONObject:["pid":ProcessInfo.processInfo.processIdentifier,"updates":updates]).write(to:folder.appendingPathComponent(mode+"-progress.json"),options:.atomic)
            }
        }
        let soakSeconds=CommandLine.arguments.count>3 ? Int(CommandLine.arguments[3]) ?? 0:0
        if soakSeconds>0 {
            state.search="";state.network="all";state.policy="all";state.selection=nil
            weak var inactiveLogs:NSView?
            if mode=="container",let container=find(PageContainerView.self,in:host) {
                store.page = .logs;await settle();inactiveLogs=container.subviews.first
                store.page = .connections;await settle()
            }
            let activeBeforeIdle=ObjectIdentifier(table)
            let began=ContinuousClock.now
            let deadline=began.advanced(by:.seconds(soakSeconds))
            var values=try connections(180,generation:1000)
            var evictionChecked=false
            while ContinuousClock.now<deadline {
                let step=soakUpdates
                if step%13==0 {
                    values=try connections([0,1,220,850,20][(step/13)%5],generation:1000+step)
                    for index in values.indices { values[index].id="00000000-0000-4000-8000-"+String(100_000_000_000+step*2000+index) }
                } else {
                    for index in values.indices {
                        values[index].download+=Int64(1+(index*131+step*977)%50000)
                        values[index].upload+=Int64(1+(index*17+step*73)%1000)
                    }
                }
                store.connections=values
                if step%17==0 { state.selection=values.first?.id }
                if step%19==0 { state.sortOrder=[KeyPathComparator(\LiveConnection.download,order:step%2==0 ? .forward:.reverse)] }
                if step%23==0 { window.setContentSize(NSSize(width:step%2==0 ? 1020:1280,height:850)) }
                await settle()
                if let current=find(NSTableView.self,in:host) {
                    table=current;sampleHeight(current)
                    check(current.numberOfRows==values.count,"steady visible rows \(step)")
                    if current.numberOfRows>0 && step%3==0 { current.scrollRowToVisible((step*19)%current.numberOfRows) }
                    if step%11==0 { current.tableColumns[1].width=step%2==0 ? 160:240 }
                } else { check(false,"steady native table exists") }
                let elapsed=began.duration(to:.now)
                if mode=="container",elapsed >= .seconds(65),!evictionChecked {
                    check(inactiveLogs==nil,"real 60-second idle timer releases inactive logs while connections refresh")
                    check(find(NSTableView.self,in:host).map { ObjectIdentifier($0) } == activeBeforeIdle,"idle eviction preserves active connections table")
                    evictionChecked=true
                }
                if mode=="container",elapsed >= .seconds(75),step%64==0,let container=find(PageContainerView.self,in:host) {
                    store.page = .settings;await settle();container.releaseInactivePages()
                    store.page = .connections;await settle()
                    if let recreated=find(NSTableView.self,in:host) { table=recreated;sampleHeight(recreated) }
                    else { check(false,"steady recycled table exists") }
                }
                soakUpdates+=1
                try JSONSerialization.data(withJSONObject:["pid":ProcessInfo.processInfo.processIdentifier,"updates":updates,"soak_updates":soakUpdates]).write(to:folder.appendingPathComponent(mode+"-progress.json"),options:.atomic)
                try await Task.sleep(for:.milliseconds(200))
            }
            let elapsed=began.duration(to:.now).components
            soakElapsed=Double(elapsed.seconds)+Double(elapsed.attoseconds)/1e18
        }
        // Exercise actual native selection after sorting, not just the state setters.
        state.search="";state.network="all";state.policy="all"
        var rows=try connections(3,generation:0)
        rows[0].download=100;rows[1].download=300;rows[2].download=200
        rows[0].metadata.host="alpha.example.test";rows[1].metadata.host="beta.example.test";rows[2].metadata.host="gamma.example.test"
        store.connections=rows;state.selection=nil
        state.sortOrder=[KeyPathComparator(\LiveConnection.download,order:.reverse)]
        await settle();table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);await settle()
        check(state.selection==rows[1].id,"native selection follows descending sort")
        check(table.enclosingScrollView?.hasHorizontalScroller == true,"narrow table can scroll to every column")
        table.scrollColumnToVisible(4);await settle()
        check(table.visibleRect.maxX>=table.rect(ofColumn:4).maxX-1,"upload column remains reachable beside details")
        table.scrollColumnToVisible(0);await settle()
        try await snapshot("selected")
        state.sortOrder=[KeyPathComparator(\LiveConnection.download,order:.forward)]
        await settle();table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);await settle()
        check(state.selection==rows[0].id,"native selection follows ascending sort")
        if let prototype=table.tableColumns.last?.sortDescriptorPrototype,
           let reverse=prototype.reversedSortDescriptor as? NSSortDescriptor {
            table.sortDescriptors=[reverse];await settle()
            check(state.sortOrder.first?.keyPath == \LiveConnection.upload && state.sortOrder.first?.order == .reverse,"native header sort updates SwiftUI sort state")
        } else { check(false,"native upload header is sortable") }
        let point=table.convert(NSPoint(x:table.rect(ofColumn:0).midX,y:table.rect(ofRow:0).midY),to:nil)
        if let event=NSEvent.mouseEvent(with:.rightMouseDown,location:point,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1),
           let menu=table.menu(for:event) {
            check(menu.items.map(\.title)==["此域名以后走","此应用以后走"],"right-click routing menus retained")
            if let option=menu.items.first?.submenu?.items.first(where:{$0.title=="拒绝连接"}),let action=option.action {
                NSApp.sendAction(action,to:option.target,from:option)
                check(state.routingRule?.payload=="gamma.example.test" && state.routingRule?.target=="REJECT","native routing action uses the clicked connection and selected target")
                state.routingRule=nil
            } else { check(false,"native routing destination exists") }
        } else { check(false,"native right-click menu exists") }
        state.search="beta.example.test";await settle();check(table.numberOfRows==1,"search filters live snapshot")
        state.search="";state.network="udp";await settle();check(table.numberOfRows==1,"protocol filter retained")
        state.network="all";state.policy="测试策略组-1";await settle();check(table.numberOfRows==1,"policy filter retained")
        state.policy="all";state.selection=nil;await settle()
        table.tableColumns[1].width=160
        if mode=="container",let container=find(PageContainerView.self,in:host) {
            store.page = .rules;await settle()
            if let rules=find(NSTableView.self,in:host) {
                check(rules.usesAutomaticRowHeights,"unrelated rule list keeps its row sizing")
                store.connections=try connections(20,generation:50);await settle()
                check(rules.usesAutomaticRowHeights,"hidden connection updates do not reconfigure rule list")
            } else { check(false,"unrelated rule list exists") }
            store.page = .settings;await settle()
            store.connections=try connections(9,generation:100)
            container.releaseInactivePages()
            store.page = .connections;await settle()
            if let recreated=find(NSTableView.self,in:host) {
                sampleHeight(recreated)
                check(recreated.numberOfRows==9,"recreated page renders latest snapshot")
                check(abs(recreated.tableColumns[1].width-160)<1,"column width survives eviction")
            } else { check(false,"recreated native table exists") }
        }
        store.database.settings.appearance="dark";await settle()
        if let current=find(NSTableView.self,in:host) { check(current.numberOfRows==store.connections.count,"appearance change retains live rows") }
        if let current=find(NSTableView.self,in:host) { sampleHeight(current) }
        store.database.settings.appearance="light";await settle()
        store.connections=[];await settle()
        if let current=find(NSTableView.self,in:host) { check(current.numberOfRows==0,"all connections can close") }
        try await snapshot("empty")
        check(!store.database.settings.systemProxy && !store.database.settings.tun && store.runner==nil,"no network bootstrap or takeover")
        check(heightViolations==0,"connection table never re-enables automatic row-height lookup")
        finish()
    }
    func finish() {
        let report:[String:Any]=["pid":ProcessInfo.processInfo.processIdentifier,"mode":mode,"updates":updates,"soak_updates":soakUpdates,"soak_seconds":soakElapsed,"height_samples":heightSamples,"automatic_height_violations":heightViolations,"checks":checks,"failures":failures]
        try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent(mode+".json"),options:.atomic)
        NSApp.terminate(nil)
    }
}
@main struct ConnectionTableCheck {
    @MainActor static func main() {
        let app=NSApplication.shared;let delegate=ConnectionTableCheckDelegate();app.delegate=delegate
        app.setActivationPolicy(.accessory);app.run();withExtendedLifetime(delegate) {}
    }
}
