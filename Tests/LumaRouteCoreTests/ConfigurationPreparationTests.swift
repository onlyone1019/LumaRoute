import XCTest
@testable import LumaRouteCore

final class ConfigurationPreparationTests: XCTestCase {
    private let source = """
    proxies:
      - {name: 中文节点, type: http, server: example.org, port: 443}
      - {name: backup, type: http, server: backup.example.org, port: 443}
    proxy-groups:
      - {name: 手动, type: select, proxies: [中文节点, backup]}
      - {name: 自动, type: url-test, proxies: [中文节点, backup]}
      - {name: 后备, type: fallback, proxies: [中文节点, backup]}
      - {name: 均衡, type: load-balance, proxies: [中文节点, backup]}
    rules: ['MATCH,手动']
    """

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        return root
    }
    private func runner(_ root: URL) -> CoreRunner {
        CoreRunner(binary:root.appendingPathComponent("unused-core"),home:root,secret:"fixture-secret")
    }

    func testPrepareMetadataMatchesTheFinalGroupsAfterStrategyOverrides() async throws {
        let root = try root(),runner = runner(root)
        let strategy = GroupStrategy(profileID:UUID(),group:"手动",mode:.fallback)
        let prepared = try await runner.prepareWithMetadata(source:source,settings:NetworkSettings(),rules:[],strategies:[strategy])
        let parsed = try ConfigComposer.parse(prepared.yaml)
        let groups = try XCTUnwrap(parsed["proxy-groups"] as? [[String:Any]])
        XCTAssertEqual(prepared.metadata.nodeCount,2)
        XCTAssertEqual(prepared.metadata.groupOrder,["手动","自动","后备","均衡"])
        XCTAssertEqual(prepared.metadata.groupOrder,groups.compactMap { $0["name"] as? String })
        let selections = prepared.metadata.selections(savedChoices:["手动":"backup","自动":"中文节点","均衡":"backup"])
        XCTAssertEqual(selections.map(\.group),["手动","自动","后备"])
        XCTAssertEqual(selections.map(\.kind),["Fallback","URLTest","Fallback"])
        XCTAssertEqual(selections.map(\.node),["backup","中文节点",nil])
        XCTAssertEqual(try String(contentsOf:prepared.file,encoding:.utf8),prepared.yaml)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:prepared.file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
    }

    func testURIAndBase64NodeCountsComeFromTheOriginalParsedSource() async throws {
        let uri = "ss://YWVzLTEyOC1nY206cGFzcw@example.org:443#中文\nss://YWVzLTEyOC1nY206cGFzcw@backup.example.org:443#backup"
        let root = try root(),runner = runner(root)
        for input in [uri,Data(uri.utf8).base64EncodedString()] {
            let prepared = try await runner.prepareWithMetadata(source:input,settings:NetworkSettings(),rules:[])
            XCTAssertEqual(prepared.metadata.nodeCount,2)
            XCTAssertEqual(prepared.metadata.groupOrder,["默认代理","自动选择"])
            XCTAssertEqual(try String(contentsOf:prepared.file.deletingLastPathComponent().appendingPathComponent("providers/proxy-0.yaml"),encoding:.utf8),uri)
        }
    }

    func testEmptyAndLegacyPreparationRemainCompatible() async throws {
        let root = try root(),runner = runner(root)
        let prepared = try await runner.prepareWithMetadata(source:nil,settings:NetworkSettings(),rules:[])
        XCTAssertEqual(prepared.metadata.nodeCount,0)
        XCTAssertEqual(prepared.metadata.groupOrder,["默认代理"])
        let (yaml,file) = try await runner.prepare(source:source,settings:NetworkSettings(),rules:[])
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),yaml)
        XCTAssertEqual(try ConfigComposer.nodeCount(yaml),2)
    }

    func testProviderCacheSeedingStillUsesTheComposedProviderPaths() async throws {
        let root = try root(),runner = runner(root)
        let source = "proxy-providers: {remote: {type: http, url: 'https://example.org/sub'}}\nrules: ['MATCH,DIRECT']"
        let first = try await runner.prepareWithMetadata(source:source,settings:NetworkSettings(),rules:[])
        try first.yaml.write(to:root.appendingPathComponent("active.yaml"),atomically:true,encoding:.utf8)
        let cache = first.file.deletingLastPathComponent().appendingPathComponent("providers/proxy-0.yaml")
        try FileManager.default.createDirectory(at:cache.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("cached nodes".utf8).write(to:cache)
        let second = try await runner.prepareWithMetadata(source:source,settings:NetworkSettings(),rules:[])
        XCTAssertEqual(try Data(contentsOf:second.file.deletingLastPathComponent().appendingPathComponent("providers/proxy-0.yaml")),Data("cached nodes".utf8))
        let changed = try await runner.prepareWithMetadata(source:source.replacingOccurrences(of:"example.org",with:"other.example.org"),settings:NetworkSettings(),rules:[])
        XCTAssertFalse(FileManager.default.fileExists(atPath:changed.file.deletingLastPathComponent().appendingPathComponent("providers/proxy-0.yaml").path))
    }

    func testLoaderReadsCurrentMembersAndHonorsOverridesWithoutWritingThem() async throws {
        let store = try LocalStore(root:root()),loader = ConfigurationLoader()
        let a = Profile(name:"A",isRemote:true),b = Profile(name:"B",isRemote:true)
        var plan = SubscriptionComposition(); plan.profileIDs = [a.id,b.id]; plan.baseProfileID = a.id
        var combined = Profile(name:"combined",isRemote:false); combined.composition = plan
        var state = AppDatabase(); state.profiles = [a,b,combined]; state.activeProfileID = combined.id
        try store.commit(state,profiles:[a.id:source,b.id:source])
        let original = try await loader.source(configuration:state,store:store)
        XCTAssertEqual(original,try CompositionComposer.compose(plan,profiles:state.profiles,contents:[a.id:source,b.id:source],settings:state.settings))
        let changed = source.replacingOccurrences(of:"中文节点",with:"changed-node")
        let candidate = try await loader.source(configuration:state,store:store,overrides:[b.id:changed])
        XCTAssertTrue(try XCTUnwrap(candidate).contains("[B] changed-node"))
        XCTAssertEqual(try store.profileContent(b.id),source)
        try store.commit(state,profiles:[b.id:changed])
        let refreshed = try await loader.source(configuration:state,store:store)
        XCTAssertEqual(refreshed,candidate,"loader must reread SQLite instead of retaining stale parsed content")
    }

    func testHTTPRuleCacheSurvivesSwitchingAwayAndRestartingTheRunner() async throws {
        let root = try root(),initial = runner(root)
        let source = "rule-providers: {remote: {type: http, behavior: domain, url: 'https://example.org/rules'}}\nrules: ['RULE-SET,remote,DIRECT', 'MATCH,DIRECT']"
        let first = try await initial.prepareWithMetadata(source:source,settings:NetworkSettings(),rules:[])
        let cache = first.file.deletingLastPathComponent().appendingPathComponent("providers/rule-0.yaml")
        try FileManager.default.createDirectory(at:cache.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("payload: [example.org]".utf8).write(to:cache)
        let other = try await initial.prepareWithMetadata(source:source.replacingOccurrences(of:"example.org/rules",with:"other.example.org/rules"),settings:NetworkSettings(),rules:[])
        try other.yaml.write(to:root.appendingPathComponent("active.yaml"),atomically:true,encoding:.utf8)
        let restored = try await runner(root).prepareWithMetadata(source:source,settings:NetworkSettings(),rules:[])
        let copied = restored.file.deletingLastPathComponent().appendingPathComponent("providers/rule-0.yaml")
        XCTAssertEqual(try Data(contentsOf:copied),try Data(contentsOf:cache))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:copied.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        XCTAssertTrue(FileManager.default.fileExists(atPath:cache.path),"rollback revision must retain its own cache")
    }

    func testHTTPRuleCacheRejectsChangedDefinitionsAndExternalPaths() async throws {
        let root = try root(),runner = runner(root)
        let source = "rule-providers: {remote: {type: http, behavior: domain, url: 'https://example.org/rules', header: {Authorization: [fixture]}}}\nrules: ['RULE-SET,remote,DIRECT', 'MATCH,DIRECT']"
        let first = try await runner.prepareWithMetadata(source:source,settings:NetworkSettings(),rules:[])
        let cache = first.file.deletingLastPathComponent().appendingPathComponent("providers/rule-0.yaml")
        try FileManager.default.createDirectory(at:cache.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("payload: [example.org]".utf8).write(to:cache)
        for changed in [source.replacingOccurrences(of:"example.org/rules",with:"other.example.org/rules"),source.replacingOccurrences(of:"behavior: domain",with:"behavior: classical"),source.replacingOccurrences(of:"[fixture]",with:"[different]")] {
            let next = try await runner.prepareWithMetadata(source:changed,settings:NetworkSettings(),rules:[])
            XCTAssertFalse(FileManager.default.fileExists(atPath:next.file.deletingLastPathComponent().appendingPathComponent("providers/rule-0.yaml").path))
        }
        let external = try self.root().appendingPathComponent("external.yaml")
        try Data("payload: [private.example]".utf8).write(to:external)
        let externalYAML = first.yaml.replacingOccurrences(of:cache.path,with:external.path)
        try externalYAML.write(to:first.file,atomically:true,encoding:.utf8)
        try externalYAML.write(to:root.appendingPathComponent("active.yaml"),atomically:true,encoding:.utf8)
        let next = try await runner.prepareWithMetadata(source:source,settings:NetworkSettings(),rules:[])
        XCTAssertFalse(FileManager.default.fileExists(atPath:next.file.deletingLastPathComponent().appendingPathComponent("providers/rule-0.yaml").path))
    }

    func testLoaderSingleMissingAndNoActiveProfileBehavior() async throws {
        let store = try LocalStore(root:root()),loader = ConfigurationLoader()
        var state = AppDatabase()
        let empty = try await loader.source(configuration:state,store:store)
        XCTAssertNil(empty)
        let id = UUID(); state.activeProfileID = id
        let overridden = try await loader.source(configuration:state,store:store,overrides:[id:source])
        XCTAssertEqual(overridden,source)
        do { _ = try await loader.source(configuration:state,store:store); XCTFail("missing content must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("订阅配置不存在")) }
    }

    func testCancelledLoadingAndPreparationDoNotPublishResults() async throws {
        let root = try root(),store = try LocalStore(root:root),loader = ConfigurationLoader(),runner = runner(root.appendingPathComponent("runtime"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await loader.source(configuration:AppDatabase(),store:store)
        }
        do { _ = try await task.value; XCTFail("cancelled source loading must fail") } catch is CancellationError {}
        let preparation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.prepareWithMetadata(source:nil,settings:NetworkSettings(),rules:[])
        }
        do { _ = try await preparation.value; XCTFail("cancelled preparation must fail") } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("runtime/revisions").path))
    }
}
