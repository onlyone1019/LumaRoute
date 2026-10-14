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
            CommandGroup(replacing:.newItem) {
                Button("添加订阅") { store.page = .subscriptions; store.addingSubscription = true }.keyboardShortcut("n")
            }
            CommandMenu("代理") {
                Button(store.connected ? "暂停连接":"连接") { store.toggleConnection() }.keyboardShortcut("p",modifiers:[.command,.shift])
                ForEach(LumaRouteCore.RouteMode.allCases) { mode in Button(mode.label+"模式") { store.setMode(mode) } }
            }
        }
        Settings { SettingsPage().environmentObject(store).frame(width:780,height:760) }
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
    private var createMainWindow: (() -> Void)?
    private var presentationPending = false
    private var visibilityUpdatePending = false
    private var launchFinished = false
    private var initialWindowActivation = true
    private let windowLogger = Logger(subsystem:"app.lumaroute.desktop",category:"Windowing")
    func configure(store:AppStore,openMainWindow:@escaping ()->Void) {
        self.store = store
        createMainWindow = openMainWindow
        if statusMenu == nil { statusMenu = StatusMenuController(store:store,openMainWindow:{ [weak self] in self?.presentMainWindow() }) }
    }
    func registerMainWindow(_ window:NSWindow) {
        guard !mainWindows.contains(window) else { return }
        mainWindows.add(window)
        scheduleVisibilityUpdate()
    }
    func applicationWillFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.accessory)
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
        presentationPending = false
        scheduleVisibilityUpdate()
    }
    @objc private func mainWindowDidBecomeKey(_ notification:Notification) {
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
        // Inspect actual registered windows after the event has completed. A
        // queued close must not hide the Dock for an already reopened window.
        let visible = mainWindows.allObjects.filter { $0.isVisible || $0.isMiniaturized }.count
        let policy:NSApplication.ActivationPolicy = visible > 0 || presentationPending ? .regular:.accessory
        if NSApp.activationPolicy() != policy {
            let success = NSApp.setActivationPolicy(policy)
            windowLogger.info("Dock policy changed: visible=\(visible) regular=\(policy == .regular) success=\(success)")
        }
        if policy == .regular {
            NSApp.dockTile.display()
            if initialWindowActivation {
                initialWindowActivation = false
                NSApp.activate(ignoringOtherApps:true)
            }
        }
    }
    private func presentMainWindow() {
        guard !terminating else { return }
        presentationPending = true
        NSApp.setActivationPolicy(.regular)
        if let window = mainWindows.allObjects.first(where:{$0.isVisible || $0.isMiniaturized}) {
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

