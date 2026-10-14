import AppKit
import Combine
import Foundation
import ServiceManagement
import Network
import OSLog
import LumaRouteCore

enum AppPage: String, CaseIterable, Identifiable {
    case overview = "概览", subscriptions = "订阅", proxies = "代理", connections = "连接", rules = "规则", logs = "日志", settings = "设置"
    var id: String { rawValue }
    var icon: String {
        switch self { case .overview:return "house"; case .subscriptions:return "doc.text"; case .proxies:return "point.3.connected.trianglepath.dotted"; case .connections:return "wifi"; case .rules:return "list.bullet.rectangle"; case .logs:return "terminal"; case .settings:return "gearshape" }
    }
}
// Keep a named result: the tuple variant crashes TaskGroup completion in the
// Release AppStore regression on the current toolchain (check_latency_batch.py).
private struct NodeTestResult: Sendable {
    let name: String
    let delay: Int?
    let error: String?
}

@MainActor
final class AppStore: ObservableObject {
    @Published var database = AppDatabase()
    @Published var page: AppPage = .overview
    @Published var settingsTab = "网络"
    @Published var addingSubscription = false
    @Published var coreReady = false
    @Published var coreVersion = "尚未运行"
    var proxies:[String:ProxyNode] {
        get { runtime.proxies }
        set { if runtime.proxies != newValue { runtime.proxies = newValue; menuStateDidChange.send() } }
    }
    @Published var groupOrder: [String] = []
    let runtime = RuntimeData()
    let menuStateDidChange = PassthroughSubject<Void,Never>()
    var connections:[LiveConnection] { get { runtime.connections } set { runtime.connections = newValue } }
    var liveRules:[LiveRule] { get { runtime.liveRules } set { if runtime.liveRules != newValue { runtime.liveRules = newValue } } }
    var traffic:Traffic {
        get { runtime.traffic }
        set { if runtime.traffic != newValue { runtime.traffic = newValue; menuStateDidChange.send() } }
    }
    var trafficHistory:[Traffic] { get { runtime.trafficHistory } set { if runtime.trafficHistory != newValue { runtime.trafficHistory = newValue } } }
    var logs:[LogEntry] { get { runtime.logs } set { runtime.logs = newValue } }
    @Published var error: String?
    @Published var busy = false
    @Published var serviceLabel = "未安装"
    @Published var serviceRunning = false
    @Published var serviceInstalling = false
    var testProgress:Int { get { runtime.testProgress } set { runtime.testProgress = newValue } }
    var testTotal:Int { get { runtime.testTotal } set { runtime.testTotal = newValue } }
    var testRunning:Bool { get { runtime.testRunning } set { runtime.testRunning = newValue } }
    var nodeErrors:[String:String] { get { runtime.nodeErrors } set { runtime.nodeErrors = newValue } }
    @Published var notice: String?
    @Published var availableCore: CoreRelease?
    @Published var canRollbackCore = false
    @Published var canRollbackGeo = false
    var coreUpdates: CoreUpdates!
    var store: LocalStore!
    var runner: CoreRunner!
    let helper = HelperClient()
    var secret = ""
    var helperActive = false
    var refreshTask: Task<Void,Never>?
    var trafficTask: Task<Void,Never>?
    var logTask: Task<Void,Never>?
    var testTask: Task<Void,Never>?
    private var testGeneration = UUID()
    var shuttingDown = false
    private var sleeping = false
    private var recoveryNeeded = false
    private var recovering = false
    private var recoveryAttempts = 0
    private var nextRecovery = Date.distantPast
    private var pathMonitor: NWPathMonitor?
    private var lastPathFingerprint: String?
    private var bootstrapping = false
    private var logStreamAvailable = false
    private var configurationRevision = UUID()
    private var refreshing = false
    private var observedServiceState: HelperClient.InstallationState?
    private var pendingServiceRefresh = false
    private var serviceRefreshAttempts = 0
    private var nextServiceRefresh = Date.distantPast
    private var serviceInstallationDeadline: Date?
    private var serviceFailureMessage: String?
    private let serviceLogger = Logger(subsystem:"app.lumaroute.desktop",category:"ServiceInstallation")
    private let systemProxyLogger = Logger(subsystem:"app.lumaroute.desktop",category:"SystemProxy")
    private var pendingLogs:[LogEntry] = []
    private var logFlushTask:Task<Void,Never>?
    var api: MihomoAPI { MihomoAPI(port:database.settings.controllerPort,secret:secret) }
    var activeProfile: Profile? { database.profiles.first { $0.id == database.activeProfileID } }
    var groups: [ProxyNode] {
        let available = proxies.values.filter { $0.isGroup && $0.hidden != true && $0.name != "GLOBAL" }
        let ordered = groupOrder.compactMap { name in available.first { $0.name == name } }
        let sourceGroups = ordered + available.filter { !groupOrder.contains($0.name) }.sorted { $0.name < $1.name }
        if database.settings.mode == .global,let global = proxies["GLOBAL"] { return [global]+sourceGroups }
        return sourceGroups
    }
    func selectionChain(for group: ProxyNode) -> String {
        var names: [String] = []
        var visited: Set<String> = [group.name]
        var next = group.now
        while let name = next, visited.insert(name).inserted {
            names.append(name)
            next = proxies[name]?.isGroup == true ? proxies[name]?.now : nil
        }
        return names.isEmpty ? "按组策略选择" : names.joined(separator:" → ")
    }
    var connected: Bool { coreReady && (database.settings.tun || database.settings.systemProxy) }
    var activeNode: String {
        guard coreReady else { return "未选择" }
        if database.settings.mode == .direct { return "DIRECT" }
        if database.settings.mode == .global { return proxies["GLOBAL"]?.now ?? "未选择" }
        return groups.first(where:{$0.name == "默认代理"})?.now ?? groups.first?.now ?? "未选择"
    }

    func bootstrap() async {
        guard !bootstrapping,runner == nil else { return }
        bootstrapping = true; busy = true
        defer { bootstrapping = false; busy = false }
        do {
            store = try LocalStore(root:LocalStore.applicationRoot())
            database = try store.load()
            if !database.settings.connectOnLaunch {
                database.settings.tun = false; database.settings.systemProxy = false
            }
            let key = "controller-secret"
            if let existing = try await store.secrets.readAsync(key) { secret = existing }
            else { secret = UUID().uuidString + UUID().uuidString; try await store.secrets.writeAsync(secret,key:key) }
            coreUpdates = try CoreUpdates(root:store.root.appendingPathComponent("cores"),bundled:CoreRunner.bundledBinary())
            try await coreUpdates.recoverPendingSwitch(runtime:store.root.appendingPathComponent("runtime"))
            canRollbackCore = try coreUpdates.selection().canRollback
            canRollbackGeo = try GeoDataUpdates(home:store.root.appendingPathComponent("runtime")).canRollback
            runner = CoreRunner(binary:try coreUpdates.currentBinary(),home:store.root.appendingPathComponent("runtime"),secret:secret)
            await runner.setLogHandler { [weak self] text in Task { @MainActor in self?.captureKernelOutput(text) } }
            serviceLabel = helper.label
            observedServiceState = helper.installationState
            // Keep watching even when the first core start fails because the
            // administrator is still approving or updating the service.
            startRuntimeObservation()
            try await applyConfiguration(settings:database.settings)
        } catch {
            if helper.status != .enabled { serviceFailureMessage = Redactor.clean(error.localizedDescription) }
            report(error,source:"启动")
        }
    }
    private func startRuntimeObservation() {
        if pathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor in
                    guard let self else { return }
                    let fingerprint = [String(describing:path.status),path.availableInterfaces.map(\.name).sorted().joined(separator:","),String(describing:path.gateways),String(path.supportsDNS),String(path.supportsIPv4),String(path.supportsIPv6)].joined(separator:"|")
                    let previous = self.lastPathFingerprint; self.lastPathFingerprint = fingerprint
                    if previous != nil,previous != fingerprint,path.status == .satisfied { await self.resumeAfterNetworkChange() }
                }
            }
            monitor.start(queue:DispatchQueue(label:"app.lumaroute.network")); pathMonitor = monitor
        }
        if refreshTask == nil {
            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    if self?.coreReady == true { await self?.updateDueSubscriptions(); await self?.updateDueRuleSubscriptions() }
                    try? await Task.sleep(nanoseconds:2_000_000_000)
                }
            }
        }
    }
    func appendLog(level: String = "info",source: String,message: String) {
        for line in message.split(whereSeparator:\.isNewline) {
            pendingLogs.append(LogEntry(level:level,source:source,message:String(line)))
        }
        if pendingLogs.count > 2000 { pendingLogs.removeFirst(pendingLogs.count-2000) }
        guard logFlushTask == nil else { return }
        logFlushTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds:150_000_000) } catch { return }
            self?.flushLogs()
        }
    }
    private func flushLogs() {
        logFlushTask?.cancel(); logFlushTask = nil
        guard !pendingLogs.isEmpty else { return }
        var entries = logs
        entries.append(contentsOf:pendingLogs); pendingLogs.removeAll(keepingCapacity:true)
        if entries.count > 2000 { entries.removeFirst(entries.count-2000) }
        logs = entries
    }
    private func captureKernelOutput(_ text: String) {
        guard !coreReady || !logStreamAvailable else { return }
        for line in text.split(whereSeparator:\.isNewline) {
            let value = String(line)
            let level = value.contains("level=error") ? "error":value.contains("level=warning") ? "warning":"info"
            appendLog(level:level,source:"内核",message:value)
        }
    }
    func report(_ caught: Error,source: String = "应用") {
        let text = Redactor.clean(caught.localizedDescription)
        error = text; appendLog(level:"error",source:source,message:text)
    }
    func perform(_ operation: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task { defer { busy = false }; do { try await operation() } catch { report(error) } }
    }
    func activeSource(_ id: UUID? = nil) throws -> String? {
        guard let id = id ?? database.activeProfileID else { return nil }
        return try store.profileContent(id)
    }
    func applyConfiguration(settings: NetworkSettings? = nil,source: String? = nil,rules: [CustomRule]? = nil,strategies: [GroupStrategy]? = nil,profileID: UUID? = nil,selectionSnapshot: [GroupSelection]? = nil,ruleSubscriptions: [RuleSubscriptionSnapshot]? = nil) async throws {
        configurationRevision = UUID()
        cancelTests(); nodeErrors = [:]; testProgress = 0; testTotal = 0
        let keepSelection = (profileID ?? database.activeProfileID) == database.activeProfileID
        let selections:[GroupSelection]
        if let selectionSnapshot { selections = selectionSnapshot }
        else if coreReady && keepSelection { selections = GroupSelection.capture((try? await api.proxies()) ?? proxies) }
        else { selections = [] }
        trafficTask?.cancel(); logTask?.cancel()
        let proposed = settings ?? database.settings
        let content = try source ?? activeSource()
        let customRules = rules ?? database.customRules
        let strategyProfile = profileID ?? database.activeProfileID
        let groupStrategies = strategies ?? (database.groupStrategies ?? []).filter { $0.profileID == strategyProfile }
        let ruleSnapshots = try ruleSubscriptions ?? store.ruleSubscriptionSnapshots(database,profileID:strategyProfile)
        let (yaml,file) = try await runner.prepare(source:content,settings:proposed,rules:customRules,strategies:groupStrategies,ruleSubscriptions:ruleSnapshots)
        try await runner.validate(file:file)
        // Keep port ownership stable once the full service is installed. On
        // macOS, root-owned closing TCP sockets can prevent a user-owned core
        // from rebinding even after the old process has exited.
        let serviceBackend = helper.localInstallation.map { !$0.healthOnly } ?? (helper.status == .enabled)
        let needsHelper = proposed.tun || proposed.systemProxy || helperActive || serviceBackend
        if needsHelper {
            try helper.requireSupportedSigning()
            guard helper.status == .enabled else { throw LumaError.message("请在设置 → 网络中安装并授权后台服务后开启 TUN 或系统代理") }
            if !helperActive, !(await runner.stop()) { throw LumaError.message("本机内核尚未退出，请稍后重新检查") }
            let version = try coreUpdates.activationVersion()
            let result = try await helper.send(HelperRequest(action:helperActive ? "apply":"start",source:content,rules:customRules,settings:proposed,secret:secret,strategies:groupStrategies,coreVersion:version,selections:selections,ruleSubscriptions:ruleSnapshots))
            helperActive = true; serviceRunning = result.running
        } else {
            if helperActive { _ = try await helper.send(HelperRequest(action:"stop")); helperActive = false; serviceRunning = false }
            try await runner.apply(yaml:yaml,settings:proposed)
            try await GroupSelection.restore(selections,api:MihomoAPI(port:proposed.controllerPort,secret:secret))
        }
        database.settings = proposed
        groupOrder = ((try ConfigComposer.parse(yaml))["proxy-groups"] as? [[String:Any]] ?? []).compactMap { $0["name"] as? String }
        coreReady = true
        restartStreams()
        await refresh()
    }
    func setMode(_ mode: RouteMode) {
        perform {
            let previous = self.database
            do {
                try await self.api.patch(["mode":mode.rawValue])
                self.database.settings.mode = mode
                try self.store.save(self.database)
                self.appendLog(source:"代理",message:"已切换为\(mode.label)模式")
            } catch { self.database = previous; try? await self.api.patch(["mode":previous.settings.mode.rawValue]); throw error }
        }
    }
    func setNetwork(tun: Bool? = nil,systemProxy: Bool? = nil) {
        perform {
            var settings = self.database.settings
            if let tun { settings.tun = tun }
            if let systemProxy { settings.systemProxy = systemProxy }
            let previous = self.database
            guard settings != previous.settings else { return }
            if self.coreReady && self.helperActive && settings.isSystemProxyOnlyChange(from:previous.settings) {
                try await self.saveSystemProxy(settings.systemProxy)
                return
            }
            do { try await self.applyConfiguration(settings:settings); try self.store.save(self.database) }
            catch { self.database = previous; try? await self.applyConfiguration(); throw error }
        }
    }
    private func saveSystemProxy(_ enabled: Bool) async throws {
        let started = ProcessInfo.processInfo.systemUptime
        let previous = database
        let response = try await helper.send(HelperRequest(action:"system-proxy",systemProxyEnabled:enabled))
        database.settings.systemProxy = enabled
        serviceRunning = response.running
        do { try store.save(database) }
        catch {
            let original = error
            do {
                _ = try await helper.send(HelperRequest(action:"system-proxy",systemProxyEnabled:previous.settings.systemProxy))
                database = previous
            } catch {
                coreReady = false; recoveryNeeded = true
                throw LumaError.message("系统代理设置保存失败，回退未完成，请重新检查后台服务："+Redactor.clean(error.localizedDescription))
            }
            throw original
        }
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime-started)*1000)
        systemProxyLogger.info("System proxy enabled=\(enabled) completed in \(milliseconds) ms")
    }
    func toggleConnection() {
        if connected { setNetwork(tun:false,systemProxy:false) } else { setNetwork(systemProxy:true) }
    }
    func refresh() async {
        let label = helper.label
        if serviceLabel != label { serviceLabel = label }
        observeServiceInstallation()
        guard !busy,!sleeping,!shuttingDown,!refreshing else { return }
        if pendingServiceRefresh,Date() >= nextServiceRefresh {
            await refreshInstalledService()
            return
        }
        guard coreReady else {
            if recoveryNeeded { await recoverLocalCore() }
            return
        }
        refreshing = true
        defer { refreshing = false }
        let revision = configurationRevision
        do {
            async let nodeResult = api.proxies()
            async let connectionResult = api.connections()
            let freshProxies = try await nodeResult
            var availableProxies = freshProxies
            if let providers = try? await api.providers() {
                for (name, provider) in providers where provider.vehicleType != "Compatible" {
                    for var node in provider.proxies ?? [] where availableProxies[node.name]?.isGroup != true {
                        node.providerName = name
                        availableProxies[node.name] = node
                    }
                }
            }
            if proxies != availableProxies { proxies = availableProxies }
            let response = try await connectionResult
            connections = await ConnectionProcesses.enrich(response.connections ?? [],mixedPort:database.settings.mixedPort)
            if let rules = try? await api.rules(),rules != liveRules { liveRules = rules }
            if let version = try? await api.version(),version != coreVersion { coreVersion = version }
            if helperActive {
                guard !busy,revision == configurationRevision,!shuttingDown else { return }
                let status = try await helper.send(HelperRequest(action:"status"))
                guard !busy,revision == configurationRevision,!shuttingDown else { return }
                if serviceRunning != status.running { serviceRunning = status.running }
                let rollback = status.canRollbackGeo ?? false
                if canRollbackGeo != rollback { canRollbackGeo = rollback }
                guard serviceRunning else { throw LumaError.message("后台内核已退出") }
            }
        } catch {
            // An observation started before a configuration change is stale.
            // It must never stop the new core or undo the user's new settings.
            guard !busy,revision == configurationRevision,!shuttingDown else { return }
            coreReady = false
            recoveryNeeded = true; recoveryAttempts = 0; nextRecovery = Date().addingTimeInterval(1)
            trafficTask?.cancel(); logTask?.cancel()
            appendLog(level:"error",source:"内核",message:"内核连接中断，正在检查网络恢复状态："+Redactor.clean(error.localizedDescription))
            if helperActive {
                do { _ = try await helper.send(HelperRequest(action:"stop")); helperActive = false; serviceRunning = false }
                catch { appendLog(level:"error",source:"网络恢复",message:"后台服务恢复尚未确认，将重试："+Redactor.clean(error.localizedDescription)) }
            }
            database.settings.tun = false; database.settings.systemProxy = false
            try? store.save(database)
            self.notice = helperActive ? "内核中断，正在确认网络设置恢复":"内核中断，网络接管已停止，正在恢复本机内核"
        }
    }
    private func observeServiceInstallation() {
        let current = helper.installationState
        if let previous = observedServiceState, previous != current {
            if current.status == .enabled {
                pendingServiceRefresh = true
                serviceRefreshAttempts = 0; nextServiceRefresh = .distantPast
                serviceLogger.info("Service installation changed; automatic refresh scheduled")
            } else { pendingServiceRefresh = false }
        }
        observedServiceState = current
        if let deadline = serviceInstallationDeadline,Date() >= deadline {
            serviceInstalling = false; serviceInstallationDeadline = nil
            notice = "尚未检测到安装完成；可在终端继续安装，完成后仍会自动刷新"
        }
    }
    private func refreshInstalledService() async {
        guard runner != nil,helper.status == .enabled,!recovering else { return }
        pendingServiceRefresh = false
        serviceRefreshAttempts += 1
        busy = true
        defer { busy = false }
        do {
            helper.disconnect()
            let status = try await helper.send(HelperRequest(action:"status"))
            guard status.serviceUID == 0,status.protocolVersion == 1 else { throw LumaError.message("后台服务身份或协议不符") }
            try Task.checkCancellation()
            guard !shuttingDown else { return }
            let selections = GroupSelection.capture(proxies)
            let fullService = helper.localInstallation?.healthOnly != true
            if fullService || !coreReady {
                coreReady = false
                helperActive = fullService && status.running
                serviceRunning = status.running
                try await applyConfiguration(settings:database.settings,selectionSnapshot:selections)
            }
            // Keep the operation lock while confirming the API and publishing
            // the new nodes; normal periodic refresh resumes after this returns.
            let nodes = try await api.proxies()
            let version = try await api.version()
            try Task.checkCancellation()
            guard !shuttingDown else { return }
            proxies = nodes; coreVersion = version; serviceLabel = helper.label
            recoveryNeeded = false; recoveryAttempts = 0
            serviceInstalling = false; serviceInstallationDeadline = nil
            if error == serviceFailureMessage { error = nil }
            serviceFailureMessage = nil
            serviceRefreshAttempts = 0
            notice = "后台服务已更新，内核和节点已自动刷新"
            appendLog(source:"后台服务",message:"安装完成，已自动重连内核并刷新节点；网络开关保持原状态")
            serviceLogger.info("Automatic service refresh completed: proxies=\(self.proxies.count) groups=\(self.groups.count)")
        } catch is CancellationError {
            pendingServiceRefresh = false
        } catch {
            coreReady = false; serviceRunning = false
            appendLog(level:"warning",source:"后台服务",message:"安装后重连暂未完成："+Redactor.clean(error.localizedDescription))
            if serviceRefreshAttempts < 3 {
                pendingServiceRefresh = true
                nextServiceRefresh = Date().addingTimeInterval(Double(serviceRefreshAttempts*3))
            } else {
                serviceInstalling = false; serviceInstallationDeadline = nil
                serviceFailureMessage = Redactor.clean(error.localizedDescription)
                report(error,source:"后台服务")
            }
        }
    }
    private func recoverLocalCore() async {
        guard runner != nil,!recovering,recoveryAttempts < 3,Date() >= nextRecovery else { return }
        recovering = true; defer { recovering = false }
        recoveryAttempts += 1
        do {
            if helperActive {
                _ = try await helper.send(HelperRequest(action:"stop"))
                helperActive = false; serviceRunning = false
            }
            await runner.stop()
            var settings = database.settings; settings.tun = false; settings.systemProxy = false
            try await applyConfiguration(settings:settings)
            try store.save(database)
            recoveryNeeded = false; recoveryAttempts = 0
            notice = "本机内核已恢复；网络接管保持关闭"
            appendLog(source:"恢复",message:"内核已恢复，可手动重新连接")
        } catch {
            coreReady = false
            nextRecovery = Date().addingTimeInterval(Double(recoveryAttempts*3))
            appendLog(level:"error",source:"恢复",message:Redactor.clean(error.localizedDescription))
            if recoveryAttempts >= 3 { self.error = "内核恢复失败，请检查日志、端口和后台服务后点击重新检查" }
        }
    }
    func prepareForSleep() {
        sleeping = true; trafficTask?.cancel(); logTask?.cancel()
    }
    func recheck() async {
        if runner == nil { await bootstrap(); return }
        startRuntimeObservation()
        recoveryAttempts = 0; nextRecovery = .distantPast
        if !coreReady {
            if helper.status == .enabled {
                pendingServiceRefresh = true; serviceRefreshAttempts = 0; nextServiceRefresh = .distantPast
            } else { recoveryNeeded = true }
        }
        await refresh()
        if helper.localInstallation != nil {
            do {
                let response = try await helper.send(HelperRequest(action:"status"))
                guard response.serviceUID == 0,response.protocolVersion == 1 else { throw LumaError.message("后台服务身份或协议不符") }
                notice = "本机后台服务检查通过 · 无需开发者证书"
                appendLog(source:"后台服务",message:"本机服务健康检查通过（UID 0，协议 1）")
            } catch { report(error,source:"后台服务") }
        }
    }
    func resumeAfterNetworkChange() async {
        guard !shuttingDown,runner != nil else { return }
        sleeping = false; recoveryAttempts = 0; nextRecovery = .distantPast
        await refresh()
        if coreReady { restartStreams(); appendLog(source:"网络",message:"已重新检查网络与内核连接") }
    }
    func restartStreams() {
        trafficTask?.cancel(); logTask?.cancel()
        let client = api
        trafficTask = Task { [weak self] in
            do {
                try await client.stream("traffic") { data in
                    guard let sample = try? JSONDecoder().decode(Traffic.self,from:data) else { return }
                    await MainActor.run {
                        self?.traffic = sample; self?.trafficHistory.append(Traffic(up:sample.up,down:sample.down))
                        if (self?.trafficHistory.count ?? 0) > 60 { self?.trafficHistory.removeFirst() }
                    }
                }
            } catch { if !Task.isCancelled { self?.appendLog(level:"warning",source:"流量",message:"状态流已断开") } }
        }
        logTask = Task { [weak self] in
            self?.logStreamAvailable = true
            do {
                try await client.stream("logs") { data in
                    guard let object = try? JSONSerialization.jsonObject(with:data) as? [String:String],let text = object["payload"] else { return }
                    await MainActor.run { self?.appendLog(level:object["type"] ?? "info",source:"内核",message:text) }
                }
            } catch { if !Task.isCancelled { self?.logStreamAvailable = false; self?.appendLog(level:"warning",source:"日志",message:"日志流已断开") } }
        }
    }
    func importRemote(name: String,url: String,userAgent: String = "") async throws {
        let agent = try SubscriptionFetcher.normalizedUserAgent(userAgent)
        let download = try await SubscriptionFetcher.fetch(url,userAgent:agent)
        var profile = Profile(name:name.isEmpty ? URL(string:url)?.host ?? "新订阅":name,isRemote:true,displaySource:SubscriptionFetcher.displayURL(URL(string:url)!))
        profile.userAgent = agent
        profile.usage = download.usage
        profile.updateHours = max(1,download.interval ?? database.settings.updateIntervalHours)
        try await validateRemoteSource(download.content)
        profile.nodeCount = try ConfigComposer.nodeCount(download.content)
        profile.lastUpdated = Date()
        try await commitImportedProfile(profile,content:download.content,address:url)
    }
    func importFile(_ url: URL) async throws {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let content = try String(contentsOf:url,encoding:.utf8)
        try await validateSource(content)
        var profile = Profile(name:url.deletingPathExtension().lastPathComponent,isRemote:false)
        profile.nodeCount = try ConfigComposer.nodeCount(content); profile.lastUpdated = Date()
        try await commitImportedProfile(profile,content:content,address:nil)
    }
    private func commitImportedProfile(_ profile: Profile,content: String,address: String?) async throws {
        let previous = database
        var applied = false
        do {
            if let address { try await store.secrets.writeAsync(address,key:"subscription-\(profile.id.uuidString)") }
            if previous.activeProfileID == nil { try await applyConfiguration(source:content,profileID:profile.id); applied = true }
            var next = previous; next.settings = database.settings
            next.profiles.append(profile)
            if previous.activeProfileID == nil { next.activeProfileID = profile.id }
            try store.commit(next,profiles:[profile.id:content])
            database = next
            appendLog(source:profile.name,message:"订阅导入成功")
        } catch {
            database = previous
            if applied { try? await applyConfiguration() }
            if address != nil { try? await store.secrets.deleteAsync("subscription-\(profile.id.uuidString)") }
            throw error
        }
    }
    func validateSource(_ source: String) async throws {
        var settings = database.settings; settings.tun = false
        let (_,file) = try await runner.prepare(source:source,settings:settings,rules:[])
        try await runner.validate(file:file)
    }
    private func validateRemoteSource(_ source: String) async throws {
        do { try await validateSource(source) }
        catch is CancellationError { throw CancellationError() }
        catch { throw SubscriptionError.configuration(error.localizedDescription) }
    }
    func saveSubscriptionOptions(_ profile: Profile,userAgent: String) throws {
        let agent = try SubscriptionFetcher.normalizedUserAgent(userAgent)
        guard let index = database.profiles.firstIndex(where:{$0.id == profile.id}),database.profiles[index].isRemote else { throw LumaError.message("此远程订阅已不存在") }
        var next = database
        next.profiles[index].userAgent = agent
        try store.save(next)
        database = next
    }
    func activate(_ profile: Profile) async throws {
        let previous = database
        let source = try store.profileContent(profile.id)
        do {
            try await applyConfiguration(source:source,profileID:profile.id)
            database.activeProfileID = profile.id
            try store.save(database)
            appendLog(source:"订阅",message:"已启用 \(profile.name)")
        } catch { database = previous; try? await applyConfiguration(); throw error }
    }
    func update(_ profile: Profile) async throws {
        guard profile.isRemote else { return }
        guard let index = database.profiles.firstIndex(where:{$0.id == profile.id}) else { return }
        let profile = database.profiles[index]
        let previous = database
        var previousSource: String?
        var applied = false
        do {
            guard let url = try await store.secrets.readAsync("subscription-\(profile.id.uuidString)") else { throw LumaError.message("此订阅的链接未保存在当前钥匙串，请重新导入") }
            previousSource = try store.profileContent(profile.id)
            let download = try await SubscriptionFetcher.fetch(url,userAgent:profile.userAgent)
            try await validateRemoteSource(download.content)
            if profile.id == database.activeProfileID { try await applyConfiguration(source:download.content); applied = true }
            var next = previous; next.settings = database.settings
            next.profiles[index].usage = download.usage
            next.profiles[index].nodeCount = try ConfigComposer.nodeCount(download.content)
            next.profiles[index].lastUpdated = Date()
            next.profiles[index].lastAttempt = Date()
            next.profiles[index].lastError = nil
            try store.commit(next,profiles:[profile.id:download.content])
            database = next
            appendLog(source:profile.name,message:"订阅更新成功")
        } catch {
            database = previous
            if applied, let previousSource { try? await applyConfiguration(source:previousSource) }
            database.profiles[index].lastAttempt = Date()
            database.profiles[index].lastError = Redactor.clean(error.localizedDescription)
            try? store.save(database)
            appendLog(level:"warning",source:profile.name,message:"更新失败，已保留上次可用配置")
            throw error
        }
    }
    func updateAll() async throws {
        var failed = 0
        for profile in database.profiles where profile.isRemote { do { try await update(profile) } catch { failed += 1 } }
        if failed > 0 { throw LumaError.message("\(failed) 个订阅更新失败，已保留原配置") }
    }
    func updateDueSubscriptions() async {
        guard !busy else { return }
        let due = database.profiles.filter {
            $0.isRemote && Date().timeIntervalSince($0.lastAttempt ?? $0.lastUpdated ?? $0.created) >= $0.updateHours*3600
        }
        guard !due.isEmpty else { return }
        busy = true; defer { busy = false }
        for profile in due { try? await update(profile) }
    }
    func deleteProfile(_ profile: Profile) async throws {
        guard database.activeProfileID != profile.id else { throw LumaError.message("请先启用其他配置，再删除当前配置") }
        _ = try store.backup(database)
        var next = database
        next.profiles.removeAll { $0.id == profile.id }
        next.groupStrategies?.removeAll { $0.profileID == profile.id }
        next.ruleSubscriptions?.removeAll { $0.profileID == profile.id }
        // Commit metadata first; a failed write must not erase a usable source.
        try store.save(next)
        database = next
        do { try await store.secrets.deleteAsync("subscription-\(profile.id.uuidString)"); try store.removeProfileFiles(profile.id) }
        catch { appendLog(level:"warning",source:"订阅",message:"订阅已从列表移除；本机备份已保留，文件清理失败："+Redactor.clean(error.localizedDescription)) }
    }
    func select(group: String,node: String) {
        perform {
            try await self.api.select(group:group,node:node)
            self.database.savedChoices[group] = node
            try self.store.save(self.database)
            self.proxies = try await self.api.proxies()
        }
    }
    func strategy(for group: String) -> GroupStrategy? {
        guard let profileID = database.activeProfileID else { return nil }
        return (database.groupStrategies ?? []).first { $0.profileID == profileID && $0.group == group }
    }
    func saveStrategy(_ strategy: GroupStrategy) async throws {
        try strategy.validate()
        guard strategy.profileID == database.activeProfileID else { throw LumaError.message("订阅已切换，请重新打开策略设置") }
        let previous = database
        var next = (database.groupStrategies ?? []).filter { $0.profileID != strategy.profileID || $0.group != strategy.group }
        if strategy.mode != .subscription { next.append(strategy) }
        do {
            try await applyConfiguration(strategies:next.filter { $0.profileID == strategy.profileID })
            if strategy.mode != .subscription { try await api.clearFixed(group:strategy.group) }
            database.groupStrategies = next
            database.savedChoices.removeValue(forKey:strategy.group)
            try store.save(database)
            await refresh()
            appendLog(source:"策略",message:"\(strategy.group)：\(strategy.mode.label)")
        } catch {
            database = previous
            try? await applyConfiguration(strategies:(previous.groupStrategies ?? []).filter { $0.profileID == strategy.profileID })
            throw error
        }
    }
    func resumeAuto(group: String) {
        perform {
            try await self.api.clearFixed(group:group)
            self.database.savedChoices.removeValue(forKey:group)
            try self.store.save(self.database)
            self.proxies = try await self.api.proxies()
        }
    }
    func testNodes(_ nodes: [ProxyNode]) {
        testTask?.cancel(); testProgress = 0; testTotal = nodes.count; nodeErrors = [:]
        let generation = UUID(); testGeneration = generation; testRunning = !nodes.isEmpty
        let client = api; let settings = database.settings
        testTask = Task {
            defer { if testGeneration == generation { testRunning = false; testTask = nil } }
            await withTaskGroup(of:NodeTestResult.self) { group in
                var iterator = nodes.makeIterator()
                func enqueue(_ node: ProxyNode) {
                    group.addTask {
                        do { return NodeTestResult(name:node.name,delay:try await client.latency(node:node,testURL:settings.testURL,timeout:settings.testTimeout),error:nil) }
                        catch { return NodeTestResult(name:node.name,delay:nil,error:Redactor.clean(error.localizedDescription)) }
                    }
                }
                for _ in 0..<max(1,min(settings.testConcurrency,16)) { if let node = iterator.next() { enqueue(node) } }
                while let result = await group.next() {
                    if Task.isCancelled || testGeneration != generation { group.cancelAll(); break }
                    testProgress += 1
                    if let failure = result.error { nodeErrors[result.name] = failure }
                    if var node = proxies[result.name] {
                        node.alive = result.delay != nil
                        node.history = Array(((node.history ?? []) + [DelaySample(time:Date().ISO8601Format(),delay:result.delay ?? 0)]).suffix(10))
                        proxies[result.name] = node
                    }
                    if let node = iterator.next() { enqueue(node) }
                }
            }
            if testGeneration == generation { await refresh() }
        }
    }
    func cancelTests() { testTask?.cancel(); testTask = nil; testRunning = false; testGeneration = UUID() }
    func closeConnection(_ id: String?) { perform { try await self.api.closeConnection(id); await self.refresh() } }
    func applyRules(_ rules: [CustomRule]) async throws {
        for rule in rules where rule.enabled { try rule.validate() }
        let previous = database
        do { try await applyConfiguration(rules:rules); database.customRules = rules; try store.save(database) }
        catch { database = previous; try? await applyConfiguration(); throw error }
    }
    func saveSettings(_ settings: NetworkSettings) async throws {
        let previous = database
        guard settings != previous.settings else { return }
        if coreReady && helperActive && settings.isSystemProxyOnlyChange(from:previous.settings) {
            try await saveSystemProxy(settings.systemProxy)
            return
        }
        let wasEnabled = SMAppService.mainApp.status == .enabled
        do {
            try await applyConfiguration(settings:settings)
            if settings.autoLaunch && !wasEnabled { try SMAppService.mainApp.register() }
            else if !settings.autoLaunch && wasEnabled { try await SMAppService.mainApp.unregister() }
            try store.save(database)
        } catch {
            database = previous; try? await applyConfiguration()
            if wasEnabled && SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
            else if !wasEnabled && SMAppService.mainApp.status == .enabled { try? await SMAppService.mainApp.unregister() }
            throw error
        }
    }
    func installService(networkReady:Bool = false) {
        guard !serviceInstalling else { return }
        perform {
            try self.helper.register(networkReady:networkReady)
            self.serviceInstalling = true
            self.serviceInstallationDeadline = Date().addingTimeInterval(600)
            self.serviceLabel = self.helper.label
            self.notice = "请在终端完成安装；完成后将自动刷新，无需重启应用"
        }
    }
    func checkCoreUpdate() async throws {
        availableCore = try await CoreRelease.latest()
        notice = availableCore?.version == coreVersion ? "当前已是最新稳定版":"已找到官方稳定版"
    }
    func updateGeoData(rollback: Bool = false) async throws {
        trafficTask?.cancel(); logTask?.cancel(); cancelTests()
        defer { restartStreams() }
        if helperActive {
            let result = try await helper.send(HelperRequest(action:rollback ? "geo-rollback":"geo-update"))
            serviceRunning = result.running; canRollbackGeo = result.canRollbackGeo ?? false
        } else {
            try await runner.updateGeoData(rollback:rollback)
            canRollbackGeo = try GeoDataUpdates(home:store.root.appendingPathComponent("runtime")).canRollback
        }
        notice = rollback ? "规则数据库已回退":"规则数据库已更新，旧版本已备份"
        appendLog(source:"维护",message:notice!)
    }
    func updateCore() async throws {
        guard !connected else { throw LumaError.message("请先暂停系统代理和 TUN 后更新内核") }
        guard let release = availableCore else { throw LumaError.message("请先检查内核更新") }
        let artifact = try await coreUpdates.stage(release)
        try await switchCore(to:artifact)
        notice = "内核已更新，可回退到上次版本"
    }
    func rollbackCore() async throws {
        guard !connected else { throw LumaError.message("请先暂停系统代理和 TUN 后回退内核") }
        let selection = try coreUpdates.selection()
        guard selection.canRollback else { throw LumaError.message("没有可回退的内核版本") }
        try await switchCore(to:selection.previous)
        notice = "内核已回退"
    }
    private func switchCore(to artifact: CoreArtifact?) async throws {
        let previous = runner!
        let candidate = CoreRunner(binary:try coreUpdates.binary(for:artifact),home:store.root.appendingPathComponent("runtime"),secret:secret)
        let strategies = (database.groupStrategies ?? []).filter { $0.profileID == database.activeProfileID }
        let snapshots = try store.ruleSubscriptionSnapshots(database,profileID:database.activeProfileID)
        let (yaml,file) = try await previous.prepare(source:activeSource(),settings:database.settings,rules:database.customRules,strategies:strategies,ruleSubscriptions:snapshots)
        try await candidate.validate(file:file)
        if helperActive {
            trafficTask?.cancel(); logTask?.cancel(); cancelTests()
            _ = try await helper.send(HelperRequest(action:"stop"))
            helperActive = false; serviceRunning = false
            try coreUpdates.beginSwitch(to:artifact)
            do {
                try await applyConfiguration()
                let version = try await api.version()
                if let artifact,version != artifact.release.version { throw LumaError.message("新内核版本与官方发布信息不一致") }
                try coreUpdates.finishSwitch()
                coreVersion = version
                canRollbackCore = try coreUpdates.selection().canRollback
                appendLog(source:"更新",message:"内核切换完成：\(coreVersion)")
            } catch {
                let original = error
                _ = try? await helper.send(HelperRequest(action:"stop"))
                helperActive = false; serviceRunning = false
                try? coreUpdates.cancelSwitch()
                do { try await applyConfiguration() }
                catch { coreReady = false; recoveryNeeded = true; recoveryAttempts = 0 }
                throw original
            }
            return
        }
        try coreUpdates.beginSwitch(to:artifact)
        trafficTask?.cancel(); logTask?.cancel(); cancelTests()
        coreReady = false
        await previous.stop()
        do {
            await candidate.setLogHandler { [weak self] text in Task { @MainActor in self?.captureKernelOutput(text) } }
            try await candidate.start(yaml:yaml,settings:database.settings)
            let version = try await api.version()
            if let artifact,version != artifact.release.version { throw LumaError.message("新内核版本与官方发布信息不一致") }
            try coreUpdates.finishSwitch()
            runner = candidate; coreVersion = version; coreReady = true
            canRollbackCore = try coreUpdates.selection().canRollback
            restartStreams()
            appendLog(source:"更新",message:"内核切换完成：\(version)")
        } catch {
            await candidate.stop()
            try? coreUpdates.cancelSwitch()
            runner = previous
            do {
                try await previous.start(yaml:yaml,settings:database.settings)
                coreReady = true; restartStreams()
            } catch { coreReady = false; recoveryNeeded = true; recoveryAttempts = 0 }
            throw error
        }
    }
    func uninstallService() {
        perform {
            if self.helperActive {
                _ = try await self.helper.send(HelperRequest(action:"stop"))
                self.helperActive = false; self.serviceRunning = false; self.coreReady = false
                self.database.settings.tun = false; self.database.settings.systemProxy = false
                self.trafficTask?.cancel(); self.logTask?.cancel()
                try self.store.save(self.database)
            }
            try await self.helper.unregister(); self.serviceLabel = self.helper.label
        }
    }
    func backup() async throws {
        let path = try store.backup(database)
        NSWorkspace.shared.activateFileViewerSelecting([path])
        notice = "本地备份已创建"
    }
    func restoreBackup(_ url: URL) async throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let (restored,contents) = try store.readBackup(url)
        let source = restored.activeProfileID.flatMap { contents[$0] }
        let strategies = (restored.groupStrategies ?? []).filter { $0.profileID == restored.activeProfileID }
        let snapshots = try store.ruleSubscriptionSnapshots(restored,profileID:restored.activeProfileID,from:url)
        let (_,file) = try await runner.prepare(source:source,settings:restored.settings,rules:restored.customRules,strategies:strategies,ruleSubscriptions:snapshots)
        try await runner.validate(file:file)
        let previous = database
        _ = try store.backup(previous)
        try store.restoreRuleSubscriptionFiles(restored,from:url)
        do {
            database = restored
            try await applyConfiguration(settings:restored.settings,source:source,rules:restored.customRules,strategies:strategies,profileID:restored.activeProfileID,ruleSubscriptions:snapshots)
            try store.commit(restored,profiles:contents)
            database = restored
            notice = "备份已恢复，恢复前版本已保存"
            appendLog(source:"备份",message:"备份已恢复，恢复前版本已保存")
        } catch {
            database = previous; try? await applyConfiguration()
            throw error
        }
    }
    func exportDiagnostics(to url: URL) throws {
        flushLogs()
        let body = logs.map { "\($0.date.ISO8601Format()) [\($0.level)] [\($0.source)] \($0.message)" }.joined(separator:"\n")
        try Data(("LumaRoute 0.1.0\nMihomo \(coreVersion)\n" + Redactor.clean(body)).utf8).write(to:url,options:.atomic)
    }
    func shutdown() async {
        guard !shuttingDown else { return }; shuttingDown = true
        refreshTask?.cancel(); trafficTask?.cancel(); logTask?.cancel(); testTask?.cancel()
        flushLogs()
        pathMonitor?.cancel()
        if helperActive { _ = try? await helper.send(HelperRequest(action:"stop")); helperActive = false }
        await runner?.stop()
        helper.disconnect()
    }
}

