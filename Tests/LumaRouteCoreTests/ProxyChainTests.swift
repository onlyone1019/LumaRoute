import XCTest
@testable import LumaRouteCore

@MainActor final class ProxyChainTests: XCTestCase {
    private let source = """
    proxies:
      - {name: HK, type: http, server: 127.0.0.1, port: 18871}
      - {name: VPS, type: http, server: 127.0.0.1, port: 18872, password: 'fixture#password'}
    proxy-groups:
      - {name: Airport, type: select, include-all: true}
    rules: ['MATCH,Airport']
    """
    private func chain() -> ProxyChain {
        var chain = ProxyChain(); chain.name = "香港到美国"; chain.upstream = "Airport"; chain.landing = "VPS"
        return chain
    }
    private func root() throws -> URL {
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("work/proxy-chains-tests/"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        return root
    }
    func testInlineChainPreservesOriginalNodesRulesAndAutomaticMembership() throws {
        let chain = chain(),config = try ConfigComposer.parse(ProxyChainComposer.compose(source:source,chains:[chain]))
        let nodes = try XCTUnwrap(config["proxies"] as? [[String:Any]])
        XCTAssertNil(nodes[1]["dialer-proxy"])
        XCTAssertEqual(nodes[2]["dialer-proxy"] as? String,"Airport")
        XCTAssertEqual(nodes[2]["password"] as? String,"fixture#password")
        let groups = try XCTUnwrap(config["proxy-groups"] as? [[String:Any]])
        XCTAssertEqual(groups[0]["proxies"] as? [String],["HK","VPS"])
        XCTAssertNil(groups[0]["include-all"])
        XCTAssertEqual(groups.last?["name"] as? String,chain.groupName)
        XCTAssertEqual(groups.last?["proxies"] as? [String],[chain.nodePrefix+"VPS"])
        XCTAssertEqual(config["rules"] as? [String],["MATCH,Airport"])
    }
    func testProviderChainKeepsFiltersAndOverridesWithExactGroupFilter() throws {
        let input = """
        proxy-providers:
          Remote:
            type: http
            url: https://example.org/sub
            filter: 'US|HK'
            override: {additional-prefix: '[A] ', udp: true}
        proxy-groups: [{name: Airport, type: select, include-all-providers: true}]
        rules: ['MATCH,Airport']
        """
        var chain = chain(); chain.landing = "[A] US.(VPS)+"; chain.landingProvider = "Remote"
        let config = try ConfigComposer.parse(ProxyChainComposer.compose(source:input,chains:[chain]))
        let providers = try XCTUnwrap(config["proxy-providers"] as? [String:[String:Any]])
        let copy = try XCTUnwrap(providers[chain.providerName])
        XCTAssertEqual(copy["filter"] as? String,"US|HK")
        let override = try XCTUnwrap(copy["override"] as? [String:Any])
        XCTAssertEqual(override["additional-prefix"] as? String,chain.nodePrefix+"[A] ")
        XCTAssertEqual(override["dialer-proxy"] as? String,"Airport")
        XCTAssertEqual(override["udp"] as? Bool,true)
        XCTAssertNil((providers["Remote"]?["override"] as? [String:Any])?["dialer-proxy"])
        let groups = try XCTUnwrap(config["proxy-groups"] as? [[String:Any]])
        XCTAssertEqual(groups[0]["use"] as? [String],["Remote"])
        let regex = try NSRegularExpression(pattern:try XCTUnwrap(groups.last?["filter"] as? String))
        let expected = chain.nodePrefix+chain.landing
        XCTAssertNotNil(regex.firstMatch(in:expected,range:NSRange(expected.startIndex...,in:expected)))
        XCTAssertNil(regex.firstMatch(in:expected+"extra",range:NSRange(location:0,length:(expected+"extra").utf16.count)))
        XCTAssertEqual(groups.last?["empty-fallback"] as? String,"REJECT")
    }
    func testRawURIProviderCopiesItsContentIntoBothRevisionCaches() throws {
        let input = "http://127.0.0.1:18871#HK\nhttp://127.0.0.1:18872#VPS"
        var chain = chain(); chain.upstream = "HK"; chain.upstreamProvider = "订阅节点"; chain.landingProvider = "订阅节点"
        let overlay = try ProxyChainComposer.compose(source:input,chains:[chain])
        let parsed = try ConfigComposer.parse(overlay)
        let upstream = (parsed["proxy-groups"] as? [[String:Any]])?.first { $0["name"] as? String == chain.providerName+" · 前置" }
        XCTAssertEqual(upstream?["use"] as? [String],["订阅节点"])
        XCTAssertEqual(upstream?["filter"] as? String,"^HK$")
        XCTAssertEqual(upstream?["hidden"] as? Bool,true)
        let root = try root()
        let final = try ConfigComposer.parse(ConfigComposer.compose(source:overlay,settings:NetworkSettings(),rules:[],secret:"test",resourceRoot:root))
        let providers = try XCTUnwrap(final["proxy-providers"] as? [String:[String:Any]])
        for name in ["订阅节点",chain.providerName] {
            let path = try XCTUnwrap(providers[name]?["path"] as? String)
            XCTAssertEqual(try String(contentsOfFile:path,encoding:.utf8),input)
        }
    }
    func testValidationRejectsDuplicateNamesMissingNodesAndRecursiveUpstream() throws {
        let chain = chain()
        var duplicate = chain; duplicate.id = UUID()
        XCTAssertThrowsError(try ProxyChainComposer.compose(source:source,chains:[chain,duplicate]))
        for (upstream,landing) in [("missing","VPS"),("Airport","missing"),("VPS","VPS"),("GLOBAL","VPS"),("PASS-RULE","VPS")] {
            var broken = chain; broken.upstream = upstream; broken.landing = landing
            XCTAssertThrowsError(try ProxyChainComposer.compose(source:source,chains:[broken]))
        }
        let recursive = source.replacingOccurrences(of:"include-all: true",with:"proxies: ['\(chain.groupName)']")
        XCTAssertThrowsError(try ProxyChainComposer.compose(source:recursive,chains:[chain]))
        var disabled = chain; disabled.enabled = false; disabled.landing = "missing"
        XCTAssertEqual(try ProxyChainComposer.compose(source:source,chains:[disabled]),source)
    }
    func testNodeOnlyConfigurationRetainsDefaultGroupsAndRouting() throws {
        let input = "proxies: [{name: HK, type: http, server: 127.0.0.1, port: 18871}, {name: VPS, type: http, server: 127.0.0.1, port: 18872}]"
        var chain = chain(); chain.upstream = "默认代理"
        let config = try ConfigComposer.parse(ProxyChainComposer.compose(source:input,chains:[chain]))
        XCTAssertEqual(config["rules"] as? [String],["MATCH,默认代理"])
        XCTAssertEqual((config["proxy-groups"] as? [[String:Any]])?.count,3)
    }
    func testProfileCompatibilityPersistenceAndBackup() throws {
        let profile = Profile(name:"机场",isRemote:false)
        XCTAssertNil(try JSONDecoder().decode(Profile.self,from:JSONEncoder().encode(profile)).proxyChains)
        let store = try LocalStore(root:root())
        var saved = profile; saved.proxyChains = [chain()]
        var state = AppDatabase(); state.profiles = [saved]; state.activeProfileID = saved.id
        try store.commit(state,profiles:[saved.id:source])
        XCTAssertEqual(try LocalStore(root:store.root).load().profiles.first?.proxyChains,saved.proxyChains)
        let (backup,_) = try store.readBackup(store.backup(state))
        XCTAssertEqual(backup.profiles.first?.proxyChains,saved.proxyChains)
    }
    func testLoaderRebuildsOverlayAfterRefreshAndKeepsOtherProfilesIndependent() async throws {
        let store = try LocalStore(root:root()),loader = ConfigurationLoader()
        var a = Profile(name:"A",isRemote:true); a.proxyChains = [chain()]
        let b = Profile(name:"B",isRemote:true)
        var state = AppDatabase(); state.profiles = [a,b]; state.activeProfileID = a.id
        try store.commit(state,profiles:[a.id:source,b.id:source])
        let changed = source.replacingOccurrences(of:"18872",with:"18873")
        let result = try await loader.source(configuration:state,store:store,overrides:[a.id:changed])
        let nodes = try XCTUnwrap(ConfigComposer.parse(XCTUnwrap(result))["proxies"] as? [[String:Any]])
        XCTAssertEqual(nodes.last?["port"] as? Int,18873)
        XCTAssertEqual(try store.profileContent(a.id),source)
        let other = try await loader.source(b.id,configuration:state,store:store)
        XCTAssertEqual(other,source)
    }
    func testCompositionCanRouteToChainAcrossNamespacedSubscriptions() async throws {
        let store = try LocalStore(root:root()),loader = ConfigurationLoader()
        let a = Profile(name:"A",isRemote:true),b = Profile(name:"B",isRemote:true)
        var composition = SubscriptionComposition(); composition.profileIDs = [a.id,b.id]; composition.baseProfileID = a.id
        var chain = chain(); chain.upstream = "[A] Airport"; chain.landing = "[B] VPS"
        var route = SubscriptionDomainRoute(); route.domain = "example.com"; route.target = chain.groupName
        composition.domainRoutes = [route]
        var combined = Profile(name:"组合",isRemote:false); combined.composition = composition; combined.proxyChains = [chain]
        var state = AppDatabase(); state.profiles = [a,b,combined]; state.activeProfileID = combined.id
        try store.commit(state,profiles:[a.id:source,b.id:source])
        let result = try await loader.source(configuration:state,store:store)
        let config = try ConfigComposer.parse(XCTUnwrap(result))
        XCTAssertEqual((config["proxies"] as? [[String:Any]])?.last?["dialer-proxy"] as? String,"[A] Airport")
        XCTAssertTrue((config["proxy-groups"] as? [[String:Any]] ?? []).contains { $0["name"] as? String == chain.groupName })
    }
}
