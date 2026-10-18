import AppKit
import SwiftUI
import LumaRouteCore

@MainActor final class LiveRulesCheck:NSObject,NSApplicationDelegate {
    var store=AppStore()
    var window:NSWindow!
    var host:NSHostingView<AnyView>!
    var folder:URL!
    var checks:[String]=[]
    var failures:[String]=[]
    var samples:[[String:Any]]=[]
    var initialMemory=0.0
    var maximumMemory=0.0
    var ruleCount=2000
    func check(_ value:Bool,_ message:String) { if value { checks.append(message) } else { failures.append(message) } }
    func find<T:NSView>(_ type:T.Type,in view:NSView)->T? {
        if let value=view as? T { return value }
        return view.subviews.lazy.compactMap { self.find(type,in:$0) }.first
    }
    func footprint()->Double {
        var info=task_vm_info_data_t()
        var count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
        let status=withUnsafeMutablePointer(to:&info) {
            $0.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count) }
        }
        check(status == KERN_SUCCESS,"physical footprint query succeeded")
        return Double(info.phys_footprint)/1048576
    }
    func milliseconds(_ start:ContinuousClock.Instant)->Double {
        let t=start.duration(to:.now).components
        return Double(t.seconds)*1000+Double(t.attoseconds)/1e15
    }
    func sample(_ stage:String,_ start:ContinuousClock.Instant) {
        let mb=footprint();maximumMemory=max(maximumMemory,mb)
        samples.append(["stage":stage,"footprint_mb":mb,"milliseconds":milliseconds(start)])
    }
    func settle(_ ms:Int=20) async {
        try? await Task.sleep(for:.milliseconds(ms))
        host.layoutSubtreeIfNeeded();host.displayIfNeeded()
    }
    func snapshot(_ name:String) async throws {
        await settle(120)
        guard let rep=host.bitmapImageRepForCachingDisplay(in:host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in:host.bounds,to:rep)
        try rep.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(name+".png"))
    }
    func rules(_ count:Int,generation:Int=0) throws -> [LiveRule] {
        let rows=(0..<count).map { i -> [String:Any] in
            ["type":i%3 == 0 ? "IPCIDR":"DomainSuffix","payload":"domain-\(i).example.test",
             "proxy":i%2 == 0 ? "DIRECT":"测试策略-\(generation)","index":i]
        }
        return try JSONDecoder().decode(RulesResponse.self,from:JSONSerialization.data(withJSONObject:["rules":rows])).rules
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        folder=URL(fileURLWithPath:CommandLine.arguments[1])
        ruleCount=Int(CommandLine.arguments[2]) ?? 2000
        try? JSONSerialization.data(withJSONObject:["pid":ProcessInfo.processInfo.processIdentifier]).write(to:folder.appendingPathComponent("progress.json"))
        Task { do { try await run() } catch { failures.append(String(describing:error));finish() } }
    }
    func run() async throws {
        store.shuttingDown=true
        store.liveRules=try rules(ruleCount)
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:850),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="LumaRoute 生效规则 · 隔离回归"
        host=NSHostingView(rootView:AnyView(RootView().environmentObject(store)));window.contentView=host;window.orderFront(nil)
        await settle(120)
        initialMemory=footprint();sample("before",.now)
        if CommandLine.arguments.last == "interactive" {
            store.page = .rules
            NSApp.setActivationPolicy(.regular);window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            return
        }
        for round in 0..<3 {
            store.page = .rules;await settle()
            guard let table=find(NSTableView.self,in:host) else { throw CocoaError(.coderInvalidValue) }
            check(table.numberOfRows==ruleCount,"all rules are available, round \(round)")
            check(table.tableColumns.map(\.title)==["类型","匹配内容","目标策略"],"three original column titles retained")
            check(!table.usesAutomaticRowHeights,"automatic row measurement disabled before scrolling")
            if round == 0 { try await snapshot("rules-top") }
            let start=ContinuousClock.now
            for row in stride(from:0,to:table.numberOfRows,by:20) {
                table.scrollRowToVisible(row);await settle(4)
            }
            table.scrollRowToVisible(table.numberOfRows-1);await settle()
            sample("scrolled-bottom-\(round)",start)
            check(!table.usesAutomaticRowHeights,"automatic row measurement stays disabled after full traversal")
            check(table.rows(in:table.visibleRect).contains(table.numberOfRows-1),"last rule reached")
            let materialized=(0..<table.numberOfRows).filter { table.rowView(atRow:$0,makeIfNecessary:false) != nil }.count
            check(materialized<100,"only a bounded viewport of rows is materialized")
            if round == 0 { try await snapshot("rules-bottom") }
            for page in [AppPage.overview,.settings,.proxies] {
                let start=ContinuousClock.now
                store.page=page;await settle()
                let elapsed=milliseconds(start)
                sample("navigate-\(page.rawValue)-\(round)",start)
                check(elapsed<500,"navigation remains below 500ms after scrolling: \(page.rawValue)")
            }
            for i in 0..<10 { store.coreVersion="unrelated-\(i)";await settle() }
            sample("hidden-page-updates-\(round)",.now)
            store.page = .rules;await settle()
            check(find(NSTableView.self,in:host) === table,"cached rules page and drafts retained on return")
            window.setContentSize(NSSize(width:round%2 == 0 ? 1020:1280,height:850));await settle()
            check(!table.usesAutomaticRowHeights,"window resize keeps fixed row heights")
            store.database.settings.appearance=round%2 == 0 ? "dark":"light";await settle()
        }
        store.liveRules=try rules(3,generation:1);await settle()
        guard let table=find(NSTableView.self,in:host) else { throw CocoaError(.coderInvalidValue) }
        check(table.numberOfRows==3,"changed rule snapshot replaces all old rows")
        check((table.view(atColumn:2,row:1,makeIfNecessary:true) as? NSTableCellView)?.textField?.stringValue=="测试策略-1","changed cell content is rendered")
        store.liveRules=[];await settle()
        check(table.numberOfRows==0,"empty snapshot clears the table")
        store.liveRules=try rules(ruleCount,generation:2);await settle()
        check(table.numberOfRows==ruleCount,"rules can repopulate after clearing")
        check(!table.usesAutomaticRowHeights,"data replacement keeps fixed row heights")
        sample("finished",.now)
        check(maximumMemory-initialMemory<160,"scroll and navigation footprint growth remains below 160 MiB")
        finish()
    }
    func finish() {
        let report:[String:Any]=["checks":checks,"failures":failures,"measurements":samples,"growth_mb":maximumMemory-initialMemory]
        try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("result.json"))
        NSApp.terminate(nil)
    }
}
@main struct LiveRulesCheckMain {
    @MainActor static func main() {
        let app=NSApplication.shared;let delegate=LiveRulesCheck();app.delegate=delegate
        app.setActivationPolicy(.accessory);app.run();withExtendedLifetime(delegate) {}
    }
}
