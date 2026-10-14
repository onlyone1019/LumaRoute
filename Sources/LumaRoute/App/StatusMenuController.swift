import AppKit
import Combine
import OSLog
import LumaRouteCore

/// AppKit owns the menu presentation; AppStore remains the single source of proxy state.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private weak var store: AppStore?
    private let openMainWindow: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength:72)
    private let menu = NSMenu(title:"LumaRoute")
    private var observation: AnyCancellable?
    private var buttonUpdatePending = false
    private var buttonSignature = ""
    private let menuLogger = Logger(subsystem:"app.lumaroute.desktop",category:"MenuBar")
    private var columns: [ObjectIdentifier:(String,String,CGFloat)] = [:]
    private var benchmarkItems: [NSMenuItem] = []
    private var nodeItems: [(NSMenuItem,String)] = []
    private var openMenus = Set<ObjectIdentifier>()
    private var trackingTimer: Timer?
    private var showSpeed: Bool {
        UserDefaults.standard.object(forKey:"menuBarShowSpeed") as? Bool ?? true
    }
    private let icon = Bundle.main.url(forResource:"ClashX-menu-icon@2x",withExtension:"png").flatMap(NSImage.init(contentsOf:))

    init(store:AppStore,openMainWindow:@escaping ()->Void) {
        self.store = store; self.openMainWindow = openMainWindow
        super.init()
        menu.autoenablesItems = false; menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.setAccessibilityLabel("LumaRoute")
        observation = store.objectWillChange.merge(with:store.menuStateDidChange).sink { [weak self] _ in self?.scheduleButtonUpdate() }
        updateButton()
    }

    private func scheduleButtonUpdate() {
        guard !buttonUpdatePending else { return }
        buttonUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            self?.buttonUpdatePending = false
            self?.updateButton()
        }
    }

    private func updateButton() {
        guard let store else { return }
        let up = MenuBarRateLayout.format(store.traffic.up), down = MenuBarRateLayout.format(store.traffic.down)
        let signature = "\(showSpeed):\(store.connected):\(up):\(down):\(store.activeNode):\(store.coreReady)"
        guard signature != buttonSignature else { return }
        buttonSignature = signature
        let width:CGFloat = showSpeed ? MenuBarRateLayout.width:25
        if statusItem.length != width {
            statusItem.length = width
            menuLogger.info("Status item width changed: \(width) showSpeed=\(self.showSpeed)")
        }
        let icon = self.icon ?? NSImage(systemSymbolName:"network",accessibilityDescription:nil)
        let image = MenuBarRateLayout.image(up:up,down:down,icon:icon,connected:store.connected,showSpeed:showSpeed)
        statusItem.button?.image = image
        statusItem.button?.imageScaling = .scaleNone
        statusItem.button?.toolTip = "LumaRoute · \(store.connected ? "已接管网络":"未接管网络")\n上传 \(up) · 下载 \(down)\n\(store.activeNode)"
    }

    func menuNeedsUpdate(_ menu:NSMenu) {
        guard menu === self.menu, let store else { return }
        menu.removeAllItems(); columns.removeAll(); benchmarkItems.removeAll(); nodeItems.removeAll()
        let ready = store.coreReady && !store.busy
        let mode = NSMenu(title:"出站模式"); mode.autoenablesItems = false
        for (value,title,key) in [(RouteMode.global,"全局连接","g"),(.rule,"规则判断","r"),(.direct,"直接连接","d")] {
            let item = add(title,to:mode,key:key,enabled:ready,checked:store.database.settings.mode == value) { store.setMode(value) }
            item.keyEquivalentModifierMask = .option
        }
        submenu("出站模式 (\(store.database.settings.mode.label))",menu:mode)
        menu.addItem(.separator())
        for group in store.groups {
            addGroup(group,store:store,enabled:ready)
        }
        if !store.groups.isEmpty { menu.addItem(.separator()) }
        add("设置为系统代理",key:"s",enabled:ready,checked:store.database.settings.systemProxy) { store.setNetwork(systemProxy:!store.database.settings.systemProxy) }
        add("增强模式 (TUN)",key:"e",enabled:ready,checked:store.database.settings.tun) { store.setNetwork(tun:!store.database.settings.tun) }
        add("复制终端代理命令",key:"c") {
            let port = store.database.settings.mixedPort
            let command = "export https_proxy=http://127.0.0.1:\(port) http_proxy=http://127.0.0.1:\(port) all_proxy=socks5h://127.0.0.1:\(port);"
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command,forType:.string)
        }
        menu.addItem(.separator())
        add("开机启动",enabled:!store.busy,checked:store.database.settings.autoLaunch) {
            store.perform { var settings = store.database.settings; settings.autoLaunch.toggle(); try await store.saveSettings(settings) }
        }
        add("显示实时速率",checked:showSpeed) { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(!self.showSpeed,forKey:"menuBarShowSpeed")
            self.updateButton()
        }
        menu.addItem(.separator())
        addBenchmark(key:"t",enabled:ready && !store.testRunning) { [weak self] in
            guard let self else { return }; store.testNodes(self.testableNodes(store:store))
        }
        add("控制台",key:"d") { [weak self] in self?.show(.overview) }
        let connections = add("连接查看器",key:"d") { [weak self] in self?.show(.connections) }
        connections.keyEquivalentModifierMask = [.shift,.command]
        menu.addItem(.separator())
        addConfiguration(store:store,enabled:ready)
        add("更多设置…",key:",") { [weak self] in self?.show(.settings) }
        addHelp(store:store)
        add("退出 LumaRoute",key:"q") { NSApp.terminate(nil) }
    }

    private func addGroup(_ group:ProxyNode,store:AppStore,enabled:Bool) {
        let choices = NSMenu(title:group.name); choices.autoenablesItems = false; choices.delegate = self
        // Reserve the complete latency column, including its unit and trailing inset.
        choices.minimumWidth = 324
        let measurable = testableNodes(store:store,names:group.all ?? [])
        if !measurable.isEmpty {
            addBenchmark(to:choices,enabled:enabled && !store.testRunning) { store.testNodes(measurable) }
            choices.addItem(.separator())
        }
        if ["URLTest","Fallback"].contains(group.type) {
            add("自动选择",to:choices,enabled:enabled,checked:group.fixed?.isEmpty != false) { store.resumeAuto(group:group.name) }
            choices.addItem(.separator())
        }
        let selectable = ["Selector","URLTest","Fallback"].contains(group.type)
        for name in group.all ?? [] {
            let node = store.proxies[name]
            let item = add(short(name,width:230),to:choices,enabled:enabled && selectable,checked:group.now == name) { store.select(group:group.name,node:name) }
            item.toolTip = name
            if let node, !node.isGroup {
                nodeItems.append((item,name))
                let detail = node.delay.map { "\($0)\u{00A0}ms" } ?? (node.alive == false ? "超时":"")
                if !detail.isEmpty { setColumns(item,primary:short(name,width:210),secondary:detail) }
                item.toolTip = detail.isEmpty ? name:name+" · "+detail
            }
        }
        let item = submenu(short(group.name,width:120),menu:choices)
        item.toolTip = group.name+" → "+store.selectionChain(for:group)
        setColumns(item,primary:short(group.name,width:100),secondary:short(group.now ?? "未选择",width:100),columnEnd:210)
    }

    private func addConfiguration(store:AppStore,enabled:Bool) {
        let config = NSMenu(title:"配置"); config.autoenablesItems = false
        for profile in store.database.profiles {
            let item = add(short(profile.name,width:240),to:config,enabled:enabled,checked:profile.id == store.database.activeProfileID) {
                store.perform { try await store.activate(profile) }
            }
            item.toolTip = profile.name
        }
        config.addItem(.separator())
        add("打开配置文件夹",to:config,key:"o") {
            if let root = store.store?.root { NSWorkspace.shared.open(root.appendingPathComponent("profiles")) }
        }
        add("重新加载配置",to:config,key:"r",enabled:enabled) { store.perform { try await store.applyConfiguration() } }
        let remote = NSMenu(title:"托管配置"); remote.autoenablesItems = false
        add("管理…",to:remote,key:"m") { [weak self] in self?.show(.subscriptions) }
        add("更新",to:remote,key:"u",enabled:!store.busy && store.database.profiles.contains(where:{$0.isRemote})) { store.perform { try await store.updateAll() } }
        submenu("托管配置",menu:remote,to:config)
        submenu("配置",menu:config)
    }

    private func addHelp(store:AppStore) {
        let help = NSMenu(title:"帮助"); help.autoenablesItems = false
        add("关于 LumaRoute",to:help) { NSApp.orderFrontStandardAboutPanel(nil); NSApp.activate(ignoringOtherApps:true) }
        add("显示日志",to:help,key:"l") { [weak self] in self?.show(.logs) }
        let ports = NSMenu(title:"端口"); ports.autoenablesItems = false
        add("HTTP: \(store.database.settings.mixedPort)",to:ports,enabled:false) {}
        add("SOCKS: \(store.database.settings.mixedPort)",to:ports,enabled:false) {}
        add("API: \(store.database.settings.controllerPort)",to:ports,enabled:false) {}
        submenu("端口",menu:ports,to:help)
        add("内核 \(store.coreVersion)",to:help,enabled:false) {}
        submenu("帮助",menu:help)
    }

    private func testableNodes(store:AppStore,names:[String]? = nil)->[ProxyNode] {
        let candidates = names.map { $0.compactMap { store.proxies[$0] } } ?? Array(store.proxies.values)
        return candidates.filter { !$0.isGroup && !["Direct","Reject","RejectDrop","Pass","Compatible"].contains($0.type) }.sorted { $0.name < $1.name }
    }

    private func show(_ page:AppPage) {
        store?.page = page
        openMainWindow()
    }

    @discardableResult
    private func add(_ title:String,to target:NSMenu? = nil,key:String = "",enabled:Bool = true,checked:Bool = false,action:@escaping ()->Void)->NSMenuItem {
        let item = StatusActionItem(title:title,key:key,handler:action)
        item.isEnabled = enabled; item.state = checked ? .on:.off
        (target ?? menu).addItem(item)
        return item
    }
    @discardableResult
    private func submenu(_ title:String,menu child:NSMenu,to target:NSMenu? = nil)->NSMenuItem {
        let item = NSMenuItem(title:title,action:nil,keyEquivalent:"")
        item.submenu = child; (target ?? menu).addItem(item)
        return item
    }

    private func short(_ value:String,width:CGFloat)->String {
        var text = String(value.replacingOccurrences(of:"\t",with:" ").replacingOccurrences(of:"\n",with:" ").prefix(30))
        let font = NSFont.menuFont(ofSize:0)
        while (text as NSString).size(withAttributes:[.font:font]).width > width && text.count > 1 { text.removeLast() }
        return text == value ? text:text+"…"
    }
    private func setColumns(_ item:NSMenuItem,primary:String,secondary:String,columnEnd:CGFloat = 270,highlighted:Bool = false) {
        columns[ObjectIdentifier(item)] = (primary,secondary,columnEnd)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment:.right,location:columnEnd,options:[:])]
        paragraph.lineBreakMode = .byClipping
        let title = NSMutableAttributedString(string:primary+"\t"+secondary,attributes:[.font:NSFont.menuFont(ofSize:0),.paragraphStyle:paragraph,.foregroundColor:highlighted ? NSColor.selectedMenuItemTextColor:NSColor.labelColor])
        title.addAttributes([.font:NSFont.menuFont(ofSize:11),.foregroundColor:highlighted ? NSColor.selectedMenuItemTextColor:NSColor.secondaryLabelColor],range:NSRange(location:primary.utf16.count+1,length:secondary.utf16.count))
        item.attributedTitle = title
    }
    func menu(_ menu:NSMenu,willHighlight item:NSMenuItem?) {
        for entry in menu.items {
            (entry.view as? PersistentMenuActionView)?.menuHighlighted = entry === item
            if let (primary,secondary,columnEnd) = columns[ObjectIdentifier(entry)] { setColumns(entry,primary:primary,secondary:secondary,columnEnd:columnEnd,highlighted:entry === item) }
        }
    }

    private func addBenchmark(to target:NSMenu? = nil,key:String = "",enabled:Bool,action:@escaping ()->Void) {
        let item = add("延迟测速",to:target,key:key,enabled:enabled,action:action)
        item.view = PersistentMenuActionView(shortcut:key.isEmpty ? "":"⌘T") { [weak self, weak item] in
            guard item?.isEnabled == true else { return }
            action()
            self?.refreshTrackingMenu()
        }
        benchmarkItems.append(item)
    }

    func menuWillOpen(_ menu:NSMenu) {
        openMenus.insert(ObjectIdentifier(menu))
        if trackingTimer == nil {
            let timer = Timer(timeInterval:0.15,target:self,selector:#selector(refreshTrackingMenu),userInfo:nil,repeats:true)
            trackingTimer = timer
            RunLoop.main.add(timer,forMode:.common)
            RunLoop.main.add(timer,forMode:.eventTracking)
        }
        refreshTrackingMenu()
    }
    func menuDidClose(_ menu:NSMenu) {
        for item in menu.items { (item.view as? PersistentMenuActionView)?.menuHighlighted = false }
        openMenus.remove(ObjectIdentifier(menu))
        if menu === self.menu { openMenus.removeAll() }
        if openMenus.isEmpty { trackingTimer?.invalidate(); trackingTimer = nil }
    }
    @objc private func refreshTrackingMenu() {
        guard let store else { return }
        let title = store.testRunning ? "正在测速 (\(store.testProgress)/\(store.testTotal))":"延迟测速"
        for item in benchmarkItems {
            item.title = title
            item.isEnabled = store.coreReady && !store.busy && !store.testRunning
            item.view?.needsDisplay = true
        }
        // Update existing items, preserving the open submenu and its scroll position.
        for (item,name) in nodeItems {
            guard let node = store.proxies[name] else { continue }
            let detail = store.nodeErrors[name] != nil ? "超时":node.delay.map { "\($0)\u{00A0}ms" } ?? (node.alive == false ? "超时":"")
            let primary = short(name,width:210)
            if let old = columns[ObjectIdentifier(item)], old.0 == primary && old.1 == detail { continue }
            setColumns(item,primary:primary,secondary:detail,highlighted:item.isHighlighted)
            item.toolTip = detail.isEmpty ? name:name+" · "+detail
        }
    }
}

/// A view receives the click directly, so AppKit does not dismiss the menu as it
/// does after a regular menu-item action. Node selection still uses native actions.
@MainActor
private final class PersistentMenuActionView: NSView {
    private let shortcut:String
    private let handler:()->Void
    var menuHighlighted = false { didSet { needsDisplay = true } }
    private let selection = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString:"")
    private let shortcutLabel = NSTextField(labelWithString:"")
    init(shortcut:String,handler:@escaping ()->Void) {
        self.shortcut = shortcut; self.handler = handler
        super.init(frame:NSRect(x:0,y:0,width:220,height:22))
        autoresizingMask = [.width]
        selection.material = .selection; selection.state = .active
        selection.blendingMode = .behindWindow; selection.isEmphasized = true
        selection.wantsLayer = true; selection.layer?.cornerRadius = 4
        selection.layer?.masksToBounds = true; selection.isHidden = true
        addSubview(selection); addSubview(titleLabel); addSubview(shortcutLabel)
        titleLabel.font = .menuFont(ofSize:0); shortcutLabel.font = .menuFont(ofSize:0)
        shortcutLabel.stringValue = shortcut
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder:NSCoder) { fatalError("Constructed programmatically") }
    override func layout() {
        super.layout()
        selection.frame = bounds.insetBy(dx:4,dy:0)
        let keyWidth = shortcutLabel.intrinsicContentSize.width
        // Match the native menu's state/checkmark column before the title.
        titleLabel.frame = NSRect(x:28,y:1,width:bounds.width-keyWidth-50,height:20)
        shortcutLabel.frame = NSRect(x:bounds.width-18-keyWidth,y:1,width:keyWidth,height:20)
    }
    override func hitTest(_ point:NSPoint)->NSView? { super.hitTest(point) == nil ? nil:self }
    override func mouseUp(with event:NSEvent) {
        guard bounds.contains(convert(event.locationInWindow,from:nil)),enclosingMenuItem?.isEnabled == true else { return }
        handler()
    }
    override func accessibilityPerformPress()->Bool {
        guard enclosingMenuItem?.isEnabled == true else { return false }
        handler(); return true
    }
    override func draw(_ dirtyRect:NSRect) {
        guard let item = enclosingMenuItem else { return }
        let selected = item.isEnabled && menuHighlighted
        selection.isHidden = !selected
        let color:NSColor = !item.isEnabled ? .disabledControlTextColor:selected ? .selectedMenuItemTextColor:.labelColor
        titleLabel.stringValue = item.title
        titleLabel.textColor = color; shortcutLabel.textColor = color
        setAccessibilityLabel(item.title)
        setAccessibilityEnabled(item.isEnabled)
    }
}

@MainActor
private final class StatusActionItem: NSMenuItem {
    private let handler: ()->Void
    init(title:String,key:String,handler:@escaping ()->Void) {
        self.handler = handler
        super.init(title:title,action:#selector(invoke),keyEquivalent:key)
        target = self
    }
    required init(coder:NSCoder) { fatalError("StatusActionItem is constructed programmatically") }
    @objc private func invoke() { handler() }
}
