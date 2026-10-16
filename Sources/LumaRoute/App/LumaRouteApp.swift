import AppKit
import SwiftUI
import OSLog

@main
struct LumaRouteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppStore()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        WindowGroup("LumaRoute",id:"main") {
            RootView().environmentObject(store)
                .background(MainWindowAccessor { delegate.registerMainWindow($0) })
                .frame(minWidth:1050,minHeight:720)
                .preferredColorScheme(store.database.settings.appearance == "light" ? .light : store.database.settings.appearance == "dark" ? .dark:nil)
                .task {
                    delegate.configure(store:store,openMainWindow:{ openWindow(id:"main") })
                    if store.runner == nil { await store.bootstrap() }
                }
                .alert("操作未完成",isPresented:Binding(get:{store.error != nil},set:{if !$0 { store.error=nil }})) {
                    Button("好",role:.cancel) { store.error=nil }
                } message: { Text(store.error ?? "") }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width:1280,height:850)
        .commands {
            CommandGroup(after:.appInfo) {
                Button("检查更新…") {
                    store.page = .settings; store.settingsTab = "更新与备份"; openWindow(id:"main")
                    Task { await store.checkAppUpdate() }
                }.disabled(store.checkingAppUpdate)
            }
            CommandGroup(replacing:.newItem) {
                Button("添加订阅") { store.page = .subscriptions; store.addingSubscription = true }.keyboardShortcut("n")
            }
            CommandMenu("代理") {
                Button(store.connected ? "暂停连接":"连接") { store.toggleConnection() }.keyboardShortcut("p",modifiers:[.command,.shift])
                ForEach(LumaRouteCore.RouteMode.allCases) { mode in Button(mode.label+"模式") { store.setMode(mode) } }
            }
        }
        Settings { SettingsWindowContent().environmentObject(store) }
    }
}
import LumaRouteCore

@MainActor
final class AppDelegate: NSObject,NSApplicationDelegate {
    weak var store: AppStore?
    private var statusMenu: StatusMenuController?
    private var terminating = false
    private var terminationSignal: DispatchSourceSignal?
    private var workspaceObservers: [NSObjectProtocol] = []
    private let mainWindows = NSHashTable<NSWindow>.weakObjects()
    // Visibility changes during Hide, occlusion and window animation are not
    // closes. Only willClose ends a main window's presented lifetime.
    private let openMainWindows = NSHashTable<NSWindow>.weakObjects()
    private var pendingDockHide: DispatchWorkItem?
    private var createMainWindow: (() -> Void)?
    // The primary SwiftUI scene is presented asynchronously at launch. Keep the
    // app regular until it appears (or is explicitly closed), including the gap
    // before MainWindowAccessor has registered its NSWindow.
    private var presentationPending = true
    private var visibilityUpdatePending = false
    private var launchFinished = false
    private var initialWindowActivation = true
    private let windowLogger = Logger(subsystem:"app.lumaroute.desktop",category:"Windowing")
    func configure(store:AppStore,openMainWindow:@escaping ()->Void) {
        self.store = store
        scheduleVisibilityUpdate()
        createMainWindow = openMainWindow
        if statusMenu == nil { statusMenu = StatusMenuController(store:store,openMainWindow:{ [weak self] in self?.presentMainWindow() }) }
    }
    func registerMainWindow(_ window:NSWindow) {
        guard !mainWindows.contains(window) else { return }
        mainWindows.add(window)
        openMainWindows.add(window)
        scheduleVisibilityUpdate()
    }
    func applicationWillFinishLaunching(_ notification:Notification) {
        setDockPolicy(.regular)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        launchFinished = true
        scheduleVisibilityUpdate()
        NotificationCenter.default.addObserver(self,selector:#selector(mainWindowWillClose(_:)),name:NSWindow.willCloseNotification,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(mainWindowDidBecomeKey(_:)),name:NSWindow.didBecomeKeyNotification,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(mainWindowVisibilityChanged(_:)),name:NSWindow.didChangeOcclusionStateNotification,object:nil)
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal:SIGTERM, queue:.main)
        source.setEventHandler {
            // Finish cleanup before entering AppKit termination, including when
            // an error sheet is open. terminateNow avoids a nested dispatch loop.
            guard !self.terminating else { return }
            self.terminating = true
            self.cancelDockHide()
            Task { @MainActor in
                self.store?.error = nil
                await self.store?.shutdown()
                NSApp.terminate(nil)
            }
        }
        source.resume()
        terminationSignal = source
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.store?.prepareForSleep() }
        })
        workspaceObservers.append(center.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in await self?.store?.resumeAfterNetworkChange() }
        })
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
    @objc private func mainWindowWillClose(_ notification:Notification) {
        guard let window = notification.object as? NSWindow, mainWindows.contains(window), !terminating else { return }
        openMainWindows.remove(window)
        presentationPending = false
        scheduleVisibilityUpdate()
    }
    @objc private func mainWindowDidBecomeKey(_ notification:Notification) {
        if let window = notification.object as? NSWindow, mainWindows.contains(window), !terminating {
            openMainWindows.add(window)
        }
        mainWindowVisibilityChanged(notification)
    }
    @objc private func mainWindowVisibilityChanged(_ notification:Notification) {
        guard let window = notification.object as? NSWindow, mainWindows.contains(window), !terminating else { return }
        if window.isVisible || window.isMiniaturized { presentationPending = false }
        scheduleVisibilityUpdate()
    }
    private func scheduleVisibilityUpdate() {
        guard !visibilityUpdatePending else { return }
        visibilityUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.visibilityUpdatePending = false
            self.updateDockVisibility()
        }
    }
    private func updateDockVisibility() {
        guard launchFinished, !terminating else { return }
        let visible = mainWindows.allObjects.filter { $0.isVisible || $0.isMiniaturized }.count
        if visible > 0 { presentationPending = false }
        store?.setMainWindowVisible(mainWindows.allObjects.contains {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        })
        if !openMainWindows.allObjects.isEmpty || presentationPending {
            cancelDockHide()
            setDockPolicy(.regular)
            if initialWindowActivation && visible > 0 {
                initialWindowActivation = false
                NSApp.activate(ignoringOtherApps:true)
            }
        } else if pendingDockHide == nil && NSApp.activationPolicy() == .regular {
            // AppKit's process transformations reach Dock asynchronously. A
            // quick close/reopen should not send opposing transformations while
            // the close animation and scene notifications are still in flight.
            let hide = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingDockHide = nil
                guard !self.terminating, !self.presentationPending, self.openMainWindows.allObjects.isEmpty else { return }
                self.setDockPolicy(.accessory)
            }
            pendingDockHide = hide
            DispatchQueue.main.asyncAfter(deadline:.now() + .milliseconds(300),execute:hide)
        }
    }
    private func cancelDockHide() {
        pendingDockHide?.cancel()
        pendingDockHide = nil
    }
    private func setDockPolicy(_ policy:NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        let success = NSApp.setActivationPolicy(policy)
        windowLogger.info("Dock policy changed: open=\(self.openMainWindows.allObjects.count) regular=\(policy == .regular) success=\(success)")
    }
    private func presentMainWindow() {
        guard !terminating else { return }
        presentationPending = true
        cancelDockHide()
        setDockPolicy(.regular)
        if let window = openMainWindows.allObjects.first {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else { createMainWindow?() }
        // SwiftUI creates/reuses its scene asynchronously. Activate after it has
        // had a chance to attach the window, rather than during menu tracking.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.terminating else { return }
            self.updateDockVisibility()
            NSApp.activate(ignoringOtherApps:true)
            self.windowLogger.info("Main window presentation: count=\(self.mainWindows.allObjects.count) regular=\(NSApp.activationPolicy() == .regular)")
        }
    }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        terminating = true
        cancelDockHide()
        Task { await store?.shutdown(); sender.reply(toApplicationShouldTerminate:true) }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {
        presentMainWindow()
        return false
    }
}

/// Identifies only the main SwiftUI scene without replacing SwiftUI's delegate
/// or relying on the hidden window title to recognize lifecycle notifications.
private struct MainWindowAccessor:NSViewRepresentable {
    var onWindow:(NSWindow)->Void
    func makeNSView(context:Context)->WindowView { WindowView(onWindow:onWindow) }
    func updateNSView(_ view:WindowView,context:Context) {
        view.onWindow = onWindow
        if let window = view.window { onWindow(window) }
    }
    final class WindowView:NSView {
        var onWindow:(NSWindow)->Void
        init(onWindow:@escaping (NSWindow)->Void) { self.onWindow = onWindow; super.init(frame:.zero) }
        required init?(coder:NSCoder) { fatalError("Constructed programmatically") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow(window) }
        }
    }
}

