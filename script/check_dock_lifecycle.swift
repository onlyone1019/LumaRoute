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
    func check(_ condition:Bool,_ name:String) {
        if condition { passed.append(name) } else { failures.append(name) }
    }
    func settle() async {
        // Let AppKit deliver window notifications and the production delegate's
        // coalesced main-queue update before observing policy.
        try? await Task.sleep(nanoseconds:200_000_000)
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
            first.miniaturize(nil)
            await settle()
            check(first.isMiniaturized && NSApp.activationPolicy() == .regular,"minimized window retains Dock policy")
            _=production.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
            await settle()
            check(!first.isMiniaturized && first.isVisible && windows.count == 1,"Dock reopen restores the existing minimized window")
            first.close()
            await settle()
            check(NSApp.activationPolicy() == .accessory,"closing last main window hides Dock policy")
            _=production.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
            await settle()
            check(windows.count == 2 && windows.last!.isVisible && NSApp.activationPolicy() == .regular,"reopen after close creates a main window and restores Dock policy")
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
            check(!production.applicationShouldTerminateAfterLastWindowClosed(NSApp),"menu-bar app remains running after closing windows")
            let report:[String:Any]=["passed":passed,"failures":failures,"visualDockAcceptanceRequired":true]
            let folder=Bundle.main.bundleURL.deletingLastPathComponent()
            try! JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("result.json"),options:.atomic)
            exit(failures.isEmpty ? 0:1)
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
