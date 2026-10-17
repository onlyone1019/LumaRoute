import Foundation
import ServiceManagement
import LumaRouteCore

// Only external effects are replaced. The production AppStore, stream tasks,
// generation checks, traffic updates and log batching run unchanged.
actor CoreRunner {
    let binary: URL
    let home: URL
    let secret: String
    private let preparation: LumaRouteCore.CoreRunner
    var running = true
    var phase = "apply"
    var enteredValidation = false
    var enteredApply = false
    var delay: UInt64 = 0
    init(binary: URL,home: URL,secret: String,geoPolicy: URL? = nil) {
        self.binary = binary; self.home = home; self.secret = secret
        preparation = LumaRouteCore.CoreRunner(binary:binary,home:home,secret:secret,geoPolicy:geoPolicy)
    }
    func configure(_ value: String,delay: UInt64 = 0) { phase = value; self.delay = delay }
    func prepare(source: String?,settings: NetworkSettings,rules: [CustomRule],strategies: [GroupStrategy] = [],ruleSubscriptions: [RuleSubscriptionSnapshot] = []) throws -> (String,URL) {
        let yaml = try ConfigComposer.compose(source:source,settings:settings,rules:rules,secret:secret)
        return (yaml,home.appendingPathComponent("candidate.yaml"))
    }
    func prepareWithMetadata(source: String?,settings: NetworkSettings,rules: [CustomRule],strategies: [GroupStrategy] = [],ruleSubscriptions: [RuleSubscriptionSnapshot] = []) async throws -> (yaml: String,file: URL,metadata: ConfigurationMetadata) {
        return try await preparation.prepareWithMetadata(source:source,settings:settings,rules:rules,strategies:strategies,ruleSubscriptions:ruleSubscriptions)
    }
    func validate(file: URL) async throws {
        enteredValidation = true
        if phase == "validation" { try await Task.sleep(nanoseconds:delay); throw LumaError.message("fixture validation rejected") }
    }
    func apply(yaml: String,settings: NetworkSettings) async throws {
        enteredApply = true
        try await Task.sleep(nanoseconds:delay)
        if phase != "success" { throw CoreApplyError(recovery:.rolledBack,original:LumaError.message("fixture reload rejected")) }
    }
    func start(yaml: String,settings: NetworkSettings) { running = true }
    func stop() -> Bool { running = false; return true }
    func setLogHandler(_ handler: @escaping @Sendable (RedactedLogMessage) -> Void) {}
    func updateRouting(source: String?,settings: NetworkSettings,rules: [CustomRule],strategies: [GroupStrategy],ruleSubscriptions: [RuleSubscriptionSnapshot]) {}
    func updateGeoData(rollback: Bool) {}
    static func bundledBinary() -> URL { URL(fileURLWithPath:"/unused-fixture-core") }
    static func validateRuleSubscription(_ snapshot: RuleSubscriptionSnapshot,binary: URL) async throws {}
}

@MainActor final class HelperClient {
    struct InstallationState: Equatable { let status: SMAppService.Status; let modified: Date? = nil; let healthOnly: Bool? = nil }
    var enabled = false
    var status: SMAppService.Status { enabled ? .enabled:.notRegistered }
    var label: String { "fixture" }
    var localInstallation: LocalServiceInstallation? { nil }
    var installationState: InstallationState { .init(status:status) }
    var networkSetup: NetworkServiceSetup { .ready }
    func requireSupportedSigning() {}
    func register(networkReady: Bool = false) async throws {}
    func unregister() async throws {}
    func disconnect() {}
    func send(_ request: HelperRequest,responseTimeout: TimeInterval? = nil) async throws -> HelperResponse {
        if request.action == "apply" { throw LumaError.message("fixture helper rejected candidate; old core retained") }
        return HelperResponse(success:true,running:true,serviceUID:0,protocolVersion:1)
    }
}

@main struct StreamRecoveryCheck {
    @MainActor static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("FAIL "+message+"\n").utf8)); exit(1)
    }
    @MainActor static func require(_ condition: Bool,_ message: String) { if !condition { fail(message) } }
    @MainActor static func snapshot(_ app: AppStore) -> (Int64,String) {
        (app.traffic.up,app.logs.last(where:{$0.source == "内核" && $0.message.hasPrefix("stream-")})?.message ?? "")
    }
    @MainActor static func progress(_ app: AppStore,after before: (Int64,String)) async throws {
        for _ in 0..<150 {
            let current = snapshot(app)
            if current.0 > before.0,current.1 != before.1,!current.1.isEmpty { return }
            try await Task.sleep(nanoseconds:20_000_000)
        }
        fail("traffic or logs stopped updating after apply failure")
    }
    @MainActor static func main() async {
        do { try await run() } catch { fail(error.localizedDescription) }
    }
    @MainActor static func run() async throws {
        let port = Int(CommandLine.arguments[1])!,root = URL(fileURLWithPath:CommandLine.arguments[2])
        let api = MihomoAPI(port:port,secret:"fixture-secret")
        func stats() async throws -> [String:Int] { try JSONDecoder().decode([String:Int].self,from:await api.data(["stats"])) }
        func create(_ name: String) throws -> AppStore {
            let app = AppStore(),directory = root.appendingPathComponent(name)
            app.store = try LocalStore(root:directory)
            app.coreUpdates = try CoreUpdates(root:directory.appendingPathComponent("cores"),bundled:CoreRunner.bundledBinary())
            app.runner = CoreRunner(binary:CoreRunner.bundledBinary(),home:directory,secret:"fixture-secret")
            app.secret = "fixture-secret"; app.database.settings.controllerPort = port
            app.coreReady = true; app.busy = true
            app.restartStreams()
            return app
        }
        for phase in ["parse","validation","apply","helper"] {
            let app = try create(phase)
            try await progress(app,after:(0,""))
            let before = snapshot(app),settings = app.database.settings
            await app.runner.configure(phase)
            if phase == "helper" { app.helper.enabled = true; app.helperActive = true }
            var next = settings; next.mode = .global; next.controllerPort = port+1
            var failed = false
            do { try await app.applyConfiguration(settings:next,source:phase == "parse" ? "proxies: [":nil,selectionSnapshot:[]) }
            catch { failed = true }
            require(failed,"expected "+phase+" failure")
            require(app.database.settings == settings,"failed apply committed candidate settings")
            try await progress(app,after:before)
            await app.shutdown()
            print("PASS traffic and logs resume on original endpoint after "+phase+" failure")
        }
        for phase in ["validation","apply"] {
            let app = try create("cancel-"+phase)
            try await progress(app,after:(0,""))
            let before = snapshot(app)
            await app.runner.configure(phase,delay:1_000_000_000)
            let task = Task { try await app.applyConfiguration(selectionSnapshot:[]) }
            for _ in 0..<100 {
                let entered = phase == "validation" ? await app.runner.enteredValidation:await app.runner.enteredApply
                if entered { break }
                try await Task.sleep(nanoseconds:10_000_000)
            }
            task.cancel()
            do { try await task.value; fail("expected cancellation") } catch is CancellationError {}
            try await progress(app,after:before)
            await app.shutdown()
            print("PASS cancelled "+phase+" restores independent stream tasks")
        }
        for state in ["sleep","shutdown","not-ready","replacement"] {
            let app = try create(state)
            try await progress(app,after:(0,""))
            await app.runner.configure("apply",delay:600_000_000)
            let task = Task { try await app.applyConfiguration(selectionSnapshot:[]) }
            for _ in 0..<100 {
                if await app.runner.enteredApply { break }
                try await Task.sleep(nanoseconds:10_000_000)
            }
            if state == "sleep" { app.prepareForSleep() }
            if state == "shutdown" { await app.shutdown() }
            if state == "not-ready" { app.coreReady = false }
            let before = snapshot(app)
            if state == "replacement" { app.restartStreams(); try await progress(app,after:before) }
            let prior = try await stats()
            do { try await task.value; fail("expected apply failure") } catch {}
            try await Task.sleep(nanoseconds:250_000_000)
            let after = try await stats()
            require(after["/traffic"] == prior["/traffic"] && after["/logs"] == prior["/logs"],"late failure restarted streams during "+state)
            if state == "replacement" { try await progress(app,after:before) }
            await app.shutdown()
            print("PASS failure respects "+state+" stream owner")
        }
        let routingApp = try create("routing-revision")
        try await progress(routingApp,after:(0,""))
        let routingBefore = snapshot(routingApp)
        await routingApp.runner.configure("apply",delay:300_000_000)
        let routingTask = Task { try await routingApp.applyConfiguration(selectionSnapshot:[]) }
        for _ in 0..<100 {
            if await routingApp.runner.enteredApply { break }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        // Routing-only saves change configurationRevision but intentionally
        // retain the stream generation; the failed full apply must recover it.
        try await routingApp.applyRoutingConfiguration(rules:[])
        do { try await routingTask.value; fail("expected apply failure") } catch {}
        try await progress(routingApp,after:routingBefore)
        await routingApp.shutdown()
        print("PASS routing-only revision change does not suppress failed-apply recovery")
        let app = try create("success")
        try await progress(app,after:(0,""))
        await app.runner.configure("success")
        let before = snapshot(app),prior = try await stats()
        var next = app.database.settings; next.mode = .global
        try await app.applyConfiguration(settings:next,selectionSnapshot:[])
        try await progress(app,after:before)
        let after = try await stats()
        require(app.database.settings == next,"successful apply lost candidate settings")
        require(after["/traffic",default:0] == prior["/traffic",default:0]+1 && after["/logs",default:0] == prior["/logs",default:0]+1,"successful apply started duplicate streams")
        await app.shutdown()
        print("PASS successful apply starts exactly one stream pair")
        print("stream recovery suite passed: 12 scenarios")
    }
}
