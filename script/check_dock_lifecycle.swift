import AppKit

// Only external services are stubbed. The runner compiles AppDelegate directly
// from production source so notification ordering and reopen behavior are real.
@MainActor final class AppStore {
    var error:String?
    func setMainWindowVisible(_ visible:Bool) {}
    func shutdown() async {}
    func prepareForSleep() {}
    func resumeAfterNetworkChange() async {}
}
@MainActor final class StatusMenuController {
    init(store:AppStore,openMainWindow:@escaping ()->Void) {}
}

@MainActor final class DockLifecycleCheck:NSObject,NSApplicationDelegate {
    let production = AppDelegate()
    let store = AppStore()
    var windows:[NSWindow] = []
    var passed:[String] = []
    var failures:[String] = []
    var dockSequence = 0
    var folder:URL { Bundle.main.bundleURL.deletingLastPathComponent() }
    var observingDock:Bool { FileManager.default.fileExists(atPath:folder.appendingPathComponent("observe-dock").path) }
    func check(_ condition:Bool,_ name:String) {
        if condition { passed.append(name) } else { failures.append(name) }
    }
    func settle() async {
        // Let AppKit deliver window notifications and the production delegate's
        // coalesced main-queue update before observing policy.
        try? await Task.sleep(nanoseconds:500_000_000)
    }
    func checkDock(_ count:Int,_ name:String) async {
        guard observingDock else { return }
        dockSequence += 1
        let phase:[String:Any] = ["id":dockSequence,"count":count,"name":name]
        try! JSONSerialization.data(withJSONObject:phase).write(to:folder.appendingPathComponent("dock-phase.json"),options:.atomic)
        for _ in 0..<80 {
            if let data = try? Data(contentsOf:folder.appendingPathComponent("dock-ack.json")),
               let ack = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
               ack["id"] as? Int == dockSequence {
                check(ack["passed"] as? Bool == true,"actual Dock: " + name)
                return
            }
            try? await Task.sleep(nanoseconds:50_000_000)
        }
        check(false,"actual Dock observer timed out: " + name)
    }
    func makeWindow() -> NSWindow {
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:480,height:240),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title="Dock lifecycle check"
        window.isReleasedWhenClosed=false
        windows.append(window)
        production.registerMainWindow(window)
        return window
    }
    func applicationWillFinishLaunching(_ notification:Notification) {
        check(Bundle.main.object(forInfoDictionaryKey:"LSUIElement") as? Bool != true,"bundle launches as a regular application")
        production.applicationWillFinishLaunching(notification)
        check(NSApp.activationPolicy() == .regular,"will-finish-launching keeps the Dock eligible")
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        production.applicationDidFinishLaunching(notification)
        production.configure(store:store,openMainWindow:{ [weak self] in
            self?.makeWindow().makeKeyAndOrderFront(nil)
        })
        Task { @MainActor in
            await settle()
            check(NSApp.activationPolicy() == .regular,"delayed first scene does not hide the Dock")
            let first=makeWindow()
            await settle()
            check(NSApp.activationPolicy() == .regular,"registered but not yet ordered scene keeps launch presentation pending")
            first.makeKeyAndOrderFront(nil)
            await settle()
            check(NSApp.activationPolicy() == .regular,"visible main window uses regular policy")
            await checkDock(1,"launch has exactly one tile")
            first.orderOut(nil)
            await settle()
            check(!first.isVisible && NSApp.activationPolicy() == .regular,"temporarily ordering out an open main window retains Dock policy")
            first.makeKeyAndOrderFront(nil)
            await settle()
            NSApp.hide(nil)
            await settle()
            check(NSApp.isHidden && NSApp.activationPolicy() == .regular,"hiding the app does not close its main window or hide its Dock policy")
            await checkDock(1,"hidden app retains its tile")
            NSApp.unhide(nil)
            await settle()
            check(first.isVisible && NSApp.activationPolicy() == .regular,"unhiding restores the main window with regular Dock policy")
            await checkDock(1,"unhidden main window has exactly one tile")
            NSApp.hide(nil)
            await settle()
            _=production.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
            await settle()
            check(!NSApp.isHidden && first.isVisible && windows.count == 1,"menu reopen unhides and reuses the existing main window")
            first.miniaturize(nil)
            await settle()
            check(first.isMiniaturized && NSApp.activationPolicy() == .regular,"minimized window retains Dock policy")
            await checkDock(1,"minimized main window retains its tile")
            _=production.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
            await settle()
            check(!first.isMiniaturized && first.isVisible && windows.count == 1,"Dock reopen restores the existing minimized window")
            first.close()
            try? await Task.sleep(nanoseconds:50_000_000)
            check(NSApp.activationPolicy() == .regular,"close defers the accessory transformation while a reopen can still cancel it")
            _=production.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
            await settle()
            check(NSApp.activationPolicy() == .regular && windows.count == 2,"quick reopen cancels pending Dock hide")
            let reopened=windows.last!
            reopened.close()
            await settle()
            check(NSApp.activationPolicy() == .accessory,"closing last main window hides Dock policy")
            await checkDock(0,"closing the last main window removes its tile")
            _=production.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
            await settle()
            check(windows.count == 3 && windows.last!.isVisible && NSApp.activationPolicy() == .regular,"reopen after close creates a main window and restores Dock policy")
            await checkDock(1,"reopening restores exactly one tile")
            let second=windows.last!
            let third=makeWindow()
            third.makeKeyAndOrderFront(nil)
            await settle()
            second.close()
            await settle()
            check(NSApp.activationPolicy() == .regular,"closing one of two main windows keeps Dock policy")
            // Settings and utility windows must not count as main windows.
            let utility=NSWindow(contentRect:NSRect(x:0,y:0,width:200,height:100),styleMask:[.titled],backing:.buffered,defer:false)
            utility.isReleasedWhenClosed=false
            utility.makeKeyAndOrderFront(nil)
            third.close()
            await settle()
            check(NSApp.activationPolicy() == .accessory,"utility window does not keep main-window Dock policy alive")
            // A queued close must not win over a reopen in the same run-loop turn.
            _=production.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
            windows.last!.close()
            _=production.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
            await settle()
            check(windows.last!.isVisible && NSApp.activationPolicy() == .regular,"immediate close then reopen retains regular policy")
            for _ in 0..<6 {
                windows.last!.close()
                try? await Task.sleep(nanoseconds:20_000_000)
                _=production.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
                try? await Task.sleep(nanoseconds:20_000_000)
            }
            await settle()
            await checkDock(1,"six rapid close/reopen cycles retain exactly one tile")
            NSApp.hide(nil)
            await settle()
            NSApp.unhide(nil)
            await settle()
            check(windows.last!.isVisible && NSApp.activationPolicy() == .regular,"hide/unhide after rapid reopen retains regular policy")
            await checkDock(1,"hide/unhide after rapid reopen retains exactly one tile")
            windows.last!.close()
            await settle()
            await checkDock(0,"final main-window close leaves no residual tile")
            check(!production.applicationShouldTerminateAfterLastWindowClosed(NSApp),"menu-bar app remains running after closing windows")
            let report:[String:Any]=["passed":passed,"failures":failures,"visualDockAcceptanceRequired":!observingDock]
            try! JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("result.json"),options:.atomic)
            NSApp.terminate(nil)
        }
    }
}

@main struct DockLifecycleMain {
    @MainActor static func main() {
        let app=NSApplication.shared
        let delegate=DockLifecycleCheck()
        app.delegate=delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
