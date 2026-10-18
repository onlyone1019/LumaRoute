import AppKit
import SwiftUI
import LumaRouteCore

/// Real page rendering with synthetic logs and a private store; no core or helper.
@MainActor final class LogsCheckDelegate:NSObject,NSApplicationDelegate {
    var window:NSWindow!
    var host:NSHostingView<AnyView>!
    var store:AppStore!
    var folder:URL!
    var checks:[String]=[]
    var failures:[String]=[]
    var navigation:[Double]=[]
    var updates:[Double]=[]
    var geometry:[String:Any]=[:]
    func check(_ condition:Bool,_ name:String) { if condition { checks.append(name) } else { failures.append(name) } }
    func applicationDidFinishLaunching(_ notification:Notification) {
        folder=URL(fileURLWithPath:CommandLine.arguments[1])
        try? JSONSerialization.data(withJSONObject:["pid":ProcessInfo.processInfo.processIdentifier,"binary_path":Bundle.main.executableURL!.path]).write(to:folder.appendingPathComponent("progress.json"))
        Task { do { try await run() } catch { failures.append(String(describing:error));finish() } }
    }
    func settle() async { try? await Task.sleep(nanoseconds:100_000_000) }
    func flush() async {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        host.layoutSubtreeIfNeeded();host.displayIfNeeded()
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        host.layoutSubtreeIfNeeded();host.displayIfNeeded()
    }
    func milliseconds(_ start:ContinuousClock.Instant)->Double {
        let t=start.duration(to:.now).components
        return Double(t.seconds)*1000+Double(t.attoseconds)/1e15
    }
    func find<T:NSView>(_ type:T.Type,in view:NSView)->T? {
        if let match=view as? T { return match }
        return view.subviews.lazy.compactMap { self.find(type,in:$0) }.first
    }
    var container:PageContainerView { find(PageContainerView.self,in:host)! }
    var table:NSTableView? { find(NSTableView.self,in:container) }
    var state:LogsPageState { container.logsState }
    func visit(_ page:AppPage,measure:Bool=false) async {
        let began=ContinuousClock.now
        store.page=page;await flush()
        if measure { navigation.append(milliseconds(began)) }
        await settle()
    }
    func snapshot(_ name:String) throws {
        guard let rep=host.bitmapImageRepForCachingDisplay(in:host.bounds) else { throw NSError(domain:"snapshot",code:1) }
        host.cacheDisplay(in:host.bounds,to:rep)
        try rep.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(name+".png"))
        if let table {
            let scroll=table.enclosingScrollView!
            geometry[name]=["width":table.bounds.width,"row_heights":(max(0,table.numberOfRows-12)..<table.numberOfRows).map { table.rect(ofRow:$0).height },"visible_origin":scroll.contentView.bounds.origin.y,"visible_height":scroll.contentView.bounds.height,"table_height":table.bounds.height]
        }
    }
    func entry(_ i:Int)->LogEntry {
        var log=LogEntry(level:["info","warning","error"][i % 3],source:i % 4==0 ? "应用":"内核",message:i % 2==0 ? "[\(i)] 连接已建立" : "[\(i)] tcp connection service.example.test:443 via 策略组-0 "+String(repeating:"payload ",count:32))
        log.date=Date(timeIntervalSince1970:1_700_000_000+Double(i));return log
    }
    func run() async throws {
        let store=AppStore();self.store=store;store.shuttingDown=true
        store.store=try LocalStore(root:folder.appendingPathComponent("private-"+UUID().uuidString),secrets:MemorySecrets())
        store.database.settings.appearance="light"
        store.logs=(0..<2000).map(entry)
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:850),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="LumaRoute 日志性能隔离测试"
        host=NSHostingView(rootView:AnyView(RootView().environmentObject(store)));window.contentView=host
        window.orderFront(nil);await settle()
        for round in 0..<3 {
            await visit(.logs,measure:true)
            check(table?.numberOfRows==2000,"2,000 rows after recreation \(round)")
            if let table { check(table.rows(in:table.visibleRect).contains(1999),"tail visible after recreation \(round)") }
            if round==0 { try snapshot("light") }
            await visit(.settings);container.releaseInactivePages()
        }
        await visit(.logs)
        state.autoScroll=false;await flush();await settle()
        table?.scrollRowToVisible(500);await settle()
        let origin=table?.enclosingScrollView?.contentView.bounds.origin.y
        store.logs.append(entry(2000));await flush();await settle()
        check(table?.numberOfRows==2001,"new entry is displayed")
        if let origin,let current=table?.enclosingScrollView?.contentView.bounds.origin.y { check(abs(origin-current)<1,"auto-scroll off retains position") }
        state.autoScroll=true;await flush();await settle()
        if let table { check(table.rows(in:table.visibleRect).contains(2000),"enabling auto-scroll reveals tail") }
        state.snapshot=store.logs;state.paused=true;await flush();await settle()
        store.logs.append(entry(2001));await flush();await settle()
        check(table?.numberOfRows==2001,"pause keeps a fixed snapshot")
        state.paused=false;state.snapshot=[];await flush();await settle()
        check(table?.numberOfRows==2002,"resume displays new logs")
        if let table { check(table.rows(in:table.visibleRect).contains(2001),"resume follows current tail") }
        state.search="service.example.test";state.level="warning";state.source="内核";await flush();await settle()
        let expected=store.logs.filter { $0.message.contains("service.example.test") && $0.level=="warning" && $0.source=="内核" }
        check(table?.numberOfRows==expected.count,"search, severity and source combine")
        state.autoScroll=false;await flush();await settle()
        table?.scrollRowToVisible(0);await settle()
        table?.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        await flush();await settle()
        check(state.selection==expected.first?.id,"native selection opens matching details")
        try snapshot("selected")
        if let table,let row=table.rowView(atRow:0,makeIfNecessary:false) { row.isEmphasized=true;try snapshot("selection-emphasized");row.isEmphasized=false }
        state.autoScroll=false
        await visit(.settings);container.releaseInactivePages();await visit(.logs)
        check(state.search=="service.example.test" && state.level=="warning" && state.source=="内核" && state.selection==expected.first?.id,"filters and selection survive page eviction")
        state.selection=nil;state.search="";state.level="全部级别";state.source="全部来源";state.autoScroll=true
        await flush();await settle()
        store.database.settings.appearance="dark";window.appearance=NSAppearance(named:.darkAqua);await flush();await settle();try snapshot("dark")
        window.setContentSize(NSSize(width:1000,height:760));await flush();await settle();try snapshot("narrow")
        if let table { check(table.rows(in:table.visibleRect).contains(table.numberOfRows-1),"resize keeps tail visible") }
        store.database.settings.appearance="light";window.appearance=NSAppearance(named:.aqua);window.setContentSize(NSSize(width:1280,height:850));await flush();await settle()
        for i in 0..<40 {
            let began=ContinuousClock.now
            store.logs.removeFirst();store.logs.append(entry(2002+i));await flush()
            updates.append(milliseconds(began));await settle()
            check(table?.numberOfRows==2002,"bounded live update \(i)")
            if let table { check(table.rows(in:table.visibleRect).contains(2001),"live update follows tail \(i)") }
        }
        store.logs=[];state.snapshot=[];await flush();await settle()
        check(table?.numberOfRows==0,"clear removes all rows");try snapshot("empty")
        store.logs=[entry(0),entry(1)];await flush();await settle()
        check(table?.numberOfRows==2,"empty table accepts new logs")
        if let table { check(table.rect(ofRow:0).height < table.rect(ofRow:1).height,"one-line and two-line rows retain different heights") }
        store.logs=["单行日志", "第一行\n第二行\n第三行", "✅已连接 foo.example.test", String(repeating:"中文日志换行测试 ",count:32),String(repeating:"W",count:200),"末尾空格    "].enumerated().map { i,text in
            var log=entry(i);log.message=text;return log
        }
        await flush();await settle();try snapshot("unicode")
        check(table?.numberOfRows==6,"Unicode and explicit newline entries render")
        finish()
    }
    func finish() {
        let result:[String:Any]=["checks":checks,"failures":failures,"open_ms":navigation,"update_ms":updates,"geometry":geometry,"pid":ProcessInfo.processInfo.processIdentifier,"binary_path":Bundle.main.executableURL!.path]
        try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("result.json"))
        NSApp.terminate(nil)
    }
}
@main struct LogsCheck {
    @MainActor static func main() {
        let app=NSApplication.shared;let delegate=LogsCheckDelegate();app.delegate=delegate
        app.setActivationPolicy(.accessory);app.run();withExtendedLifetime(delegate) {}
    }
}
