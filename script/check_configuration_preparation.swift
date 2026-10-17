// Compiled with the production AppStore and the stream fixture's process/XPC doubles.
// CoreRunner.prepareWithMetadata and ConfigurationLoader execute their real code.
@MainActor private enum AppYAMLProbe {
    static var calls = 0
}
enum ConfigComposer {
    @MainActor static func parse(_ yaml: String) throws -> [String:Any] {
        AppYAMLProbe.calls += 1
        return try LumaRouteCore.ConfigComposer.parse(yaml)
    }
    @MainActor static func nodeCount(_ yaml: String) throws -> Int {
        AppYAMLProbe.calls += 1
        return try LumaRouteCore.ConfigComposer.nodeCount(yaml)
    }
    static func compose(source: String?,settings: NetworkSettings,rules: [CustomRule],secret: String) throws -> String {
        try LumaRouteCore.ConfigComposer.compose(source:source,settings:settings,rules:rules,secret:secret)
    }
}
enum CompositionComposer {
    @MainActor static func compose(_ composition: SubscriptionComposition,profiles: [Profile],contents: [UUID:String],settings: NetworkSettings) throws -> String {
        AppYAMLProbe.calls += 1
        return try LumaRouteCore.CompositionComposer.compose(composition,profiles:profiles,contents:contents,settings:settings)
    }
}

@MainActor private final class MainPulse {
    var ticks = 0
    var task: Task<Void,Never>?
    init() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.ticks += 1
                do { try await Task.sleep(nanoseconds:1_000_000) } catch { return }
            }
        }
    }
}

@main struct ConfigurationPreparationCheck {
    @MainActor static func require(_ condition: Bool,_ message: String) {
        if !condition { FileHandle.standardError.write(Data(("FAIL "+message+"\n").utf8)); exit(1) }
    }
    @MainActor static func main() async throws {
        let port = Int(CommandLine.arguments[1])!,root = URL(fileURLWithPath:CommandLine.arguments[2])
        let app = AppStore()
        app.store = try LocalStore(root:root)
        app.runner = CoreRunner(binary:CoreRunner.bundledBinary(),home:root.appendingPathComponent("runtime"),secret:"fixture-secret")
        app.coreUpdates = try CoreUpdates(root:root.appendingPathComponent("cores"),bundled:CoreRunner.bundledBinary())
        app.secret = "fixture-secret"; app.database.settings.controllerPort = port
        app.busy = true
        let a = Profile(name:"A",isRemote:true),b = Profile(name:"B",isRemote:true)
        var plan = SubscriptionComposition(); plan.profileIDs = [a.id,b.id]; plan.baseProfileID = a.id
        var combined = Profile(name:"combined",isRemote:false); combined.composition = plan
        app.database.profiles = [a,b,combined]; app.database.activeProfileID = combined.id
        let nodes = (0..<6000).map { "  - {name: node-\($0), type: http, server: node-\($0).example.org, port: 443}" }.joined(separator:"\n")
        let source = "proxies:\n"+nodes+"\nproxy-groups: [{name: choice, type: select, proxies: [node-0]}]\nrules: ['MATCH,choice']\n"
        try app.store.commit(app.database,profiles:[a.id:source,b.id:source])
        let pulse = MainPulse()
        defer { pulse.task?.cancel() }
        await Task.yield()
        var before = pulse.ticks
        let composed = try await app.activeSource()
        require(pulse.ticks > before,"composition blocked MainActor")
        require(AppYAMLProbe.calls == 0,"composition was parsed in AppStore")
        require(composed?.contains("[B] node-5999") == true,"composition lost member nodes")
        print("PASS composition stays off MainActor: \(source.utf8.count) source bytes, \(pulse.ticks-before) UI heartbeats")

        let file = root.appendingPathComponent("Imported.yaml")
        try source.write(to:file,atomically:true,encoding:.utf8)
        before = pulse.ticks
        try await app.importFile(file)
        require(pulse.ticks > before,"file import blocked MainActor")
        require(app.database.profiles.last?.nodeCount == 6000,"import did not reuse prepared node count")
        require(AppYAMLProbe.calls == 0,"import reparsed on MainActor")
        print("PASS file import reuses prepared node count while UI heartbeats continue")

        try source.write(to:root.deletingLastPathComponent().appendingPathComponent("subscription.yaml"),atomically:true,encoding:.utf8)
        let small = "proxies: [{name: node-0, type: http, server: example.org, port: 443}]\nproxy-groups: [{name: choice, type: select, proxies: [node-0]}]\nrules: ['MATCH,choice']\n"
        app.database.profiles[1].nodeCount = 1
        let remote = app.database.profiles[1]
        try app.store.commit(app.database,profiles:[remote.id:small],subscriptionAddresses:[remote.id:"http://127.0.0.1:\(port)/subscription"])
        app.coreReady = true
        await app.runner.configure("success")
        app.busy = false
        before = pulse.ticks
        try await app.update(remote,background:true)
        require(pulse.ticks > before,"subscription update blocked MainActor")
        require(app.database.profiles.first(where:{$0.id == remote.id})?.nodeCount == 6000,"update node count is wrong")
        let committed = try await app.store.profileContentAsync(combined.id)
        require(committed.contains("[B] node-5999"),"updated composition was not committed from the member override")
        require(AppYAMLProbe.calls == 0,"update reparsed on MainActor")
        print("PASS active-member background update rebuilds composition and reuses node count while UI heartbeats continue")

        app.busy = true; app.coreReady = true
        await app.runner.configure("success")
        var next = app.database; next.activeProfileID = a.id
        next.savedChoices = ["choice":"node-0"]
        try await app.applyConfiguration(source:small,profileID:a.id,configuration:next)
        require(app.groupOrder == ["choice"],"apply did not use prepared group order")
        require(AppYAMLProbe.calls == 0,"profile switch reparsed prepared YAML on MainActor")
        print("PASS profile switch uses prepared group order and selection metadata without reparsing")

        let old = Task { try await app.applyConfiguration(selectionSnapshot:[],configuration:app.database) }
        await Task.yield()
        var newest = app.database; newest.activeProfileID = a.id
        try await app.applyConfiguration(source:small,profileID:a.id,selectionSnapshot:[],configuration:newest)
        do { try await old.value; require(false,"superseded preparation was applied") } catch is CancellationError {}
        require(app.groupOrder == ["choice"],"superseded preparation replaced current metadata")
        print("PASS superseded background preparation cannot overwrite the newer configuration")
        await app.shutdown()
        print("configuration preparation suite passed: 5 scenarios")
    }
}
