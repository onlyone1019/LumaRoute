import XCTest
@testable import LumaRouteCore

final class ConfigComposerSecurityTests: XCTestCase {
    private let maliciousSource = """
    proxies: [{name: node, type: direct}]
    proxy-groups: [{name: Manual, type: select, proxies: [node]}]
    rules: ['MATCH,Manual']
    ss-config: 'ss://YWVzLTEyOC1nY206cGFzc3dvcmQ=@0.0.0.0:18994'
    vmess-config: 'vmess://00000000-0000-0000-0000-000000000001@0.0.0.0:18995'
    tuic-server: {enable: true, listen: '0.0.0.0:18997'}
    tunnels:
      - {network: [tcp], address: '0.0.0.0:18996', target: '127.0.0.1:22', proxy: DIRECT}
    ntp: {enable: true, write-to-system: true, server: time.example.org}
    authentication: ['attacker:password']
    external-doh-server: '0.0.0.0:18998'
    geox-url: {geoip: 'https://example.org/untrusted.dat'}
    dns: {listen: '0.0.0.0:53', nameserver: ['1.1.1.1']}
    mixed-port: 80
    allow-lan: true
    bind-address: '*'
    external-controller: '0.0.0.0:9090'
    secret: attacker-secret
    tun: {enable: true, auto-route: false}
    profile: {store-selected: false, store-fake-ip: false}
    geo-auto-update: true
    """
    private let dangerousKeys = ["ss-config","vmess-config","tuic-server","tunnels","ntp","authentication","external-doh-server","geox-url"]

    private func assertOwnedConfiguration(_ config: [String:Any],settings: NetworkSettings,file: StaticString = #filePath,line: UInt = #line) throws {
        XCTAssertEqual(config["mixed-port"] as? Int,settings.mixedPort,file:file,line:line)
        XCTAssertEqual(config["external-controller"] as? String,"127.0.0.1:\(settings.controllerPort)",file:file,line:line)
        XCTAssertEqual(config["secret"] as? String,"local-secret",file:file,line:line)
        XCTAssertEqual(config["allow-lan"] as? Bool,false,file:file,line:line)
        XCTAssertEqual(config["bind-address"] as? String,"127.0.0.1",file:file,line:line)
        XCTAssertEqual(config["geo-auto-update"] as? Bool,false,file:file,line:line)
        let tun = try XCTUnwrap(config["tun"] as? [String:Any],file:file,line:line)
        XCTAssertEqual(tun["enable"] as? Bool,settings.tun,file:file,line:line)
        XCTAssertEqual(tun["auto-route"] as? Bool,settings.autoRoute,file:file,line:line)
        let profile = try XCTUnwrap(config["profile"] as? [String:Bool],file:file,line:line)
        XCTAssertEqual(profile,["store-selected":true,"store-fake-ip":true],file:file,line:line)
        let dns = try XCTUnwrap(config["dns"] as? [String:Any],file:file,line:line)
        XCTAssertNil(dns["listen"],file:file,line:line)
        for key in dangerousKeys { XCTAssertNil(config[key],key,file:file,line:line) }
    }

    func testMaliciousSubscriptionCannotAddListenersOrSystemServices() throws {
        // This previously passed the helper's validation and survived composition.
        try PrivilegedConfigurationPolicy.validate(maliciousSource)
        var settings = NetworkSettings(); settings.mixedPort = 20390; settings.controllerPort = 20391
        let yaml = try ConfigComposer.compose(source:maliciousSource,settings:settings,rules:[],secret:"local-secret")
        let config = try ConfigComposer.parse(yaml)
        try assertOwnedConfiguration(config,settings:settings)
        XCTAssertEqual(config["rules"] as? [String],["MATCH,Manual"])
    }

    func testUnapprovedTopLevelFieldsAreDroppedByDefault() throws {
        let fields = [
            "port","socks-port","redir-port","tproxy-port","listeners",
            "external-ui","external-ui-url","external-ui-name","external-controller-unix",
            "external-controller-pipe","external-controller-tls","external-controller-cors",
            "external-controller-routing-mark","skip-auth-prefixes","lan-allowed-ips","lan-disallowed-ips",
            "geo-update-interval","interface-name","routing-mark","tls","experimental",
            "post-up","post-down","iptables","script","future-listener"
        ]
        let source = "rules: ['MATCH,DIRECT']\n" + fields.map { $0+": {enabled: true}" }.joined(separator:"\n")
        let config = try ConfigComposer.parse(ConfigComposer.compose(source:source,settings:NetworkSettings(),rules:[],secret:"local-secret"))
        for key in fields { XCTAssertNil(config[key],key) }
    }

    func testNormalSubscriptionRetainsRoutingDNSAndSafeOptions() throws {
        let source = """
        proxies: [{name: node, type: http, server: proxy.example.org, port: 443}]
        proxy-groups: [{name: Manual, type: select, proxies: [node], use: [remote]}]
        proxy-providers:
          remote: {type: http, url: 'https://example.org/nodes', path: /tmp/foreign-nodes, interval: 3600}
        rule-providers:
          sites: {type: http, behavior: domain, url: 'https://example.org/rules', path: /tmp/foreign-rules, interval: 7200}
        rules: ['RULE-SET,sites,Manual', 'SUB-RULE,(NETWORK,TCP),tcp-rules', 'MATCH,Manual']
        sub-rules: {tcp-rules: ['DOMAIN-SUFFIX,example.org,Manual']}
        dns:
          nameserver: ['https://dns.example.org/dns-query']
          fallback: ['1.1.1.1']
          nameserver-policy: {'+.example.org': ['8.8.8.8']}
          proxy-server-nameserver: ['9.9.9.9']
          fake-ip-filter: ['+.lan']
        hosts: {example.org: '192.0.2.1'}
        sniffer: {enable: true, sniff: {TLS: {ports: [443]}}}
        global-client-fingerprint: chrome
        global-ua: NormalSubscription/1.0
        tcp-concurrent: true
        unified-delay: true
        keep-alive-idle: 60
        keep-alive-interval: 15
        disable-keep-alive: false
        geodata-mode: true
        geodata-loader: memconservative
        geosite-matcher: succinct
        etag-support: true
        """
        try PrivilegedConfigurationPolicy.validate(source)
        let original = try ConfigComposer.parse(source)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = try ConfigComposer.parse(ConfigComposer.compose(source:source,settings:NetworkSettings(),rules:[],secret:"local-secret",resourceRoot:root))
        for key in ["proxies","proxy-groups","rules","sub-rules","hosts","sniffer","global-client-fingerprint","global-ua","tcp-concurrent","unified-delay","keep-alive-idle","keep-alive-interval","disable-keep-alive","geodata-mode","geodata-loader","geosite-matcher","etag-support"] {
            let expected = try XCTUnwrap(original[key],key)
            let actual = try XCTUnwrap(config[key],key)
            XCTAssertTrue(NSDictionary(dictionary:[key:expected]).isEqual(to:[key:actual]),key)
        }
        let dns = try XCTUnwrap(config["dns"] as? [String:Any])
        for (key,value) in try XCTUnwrap(original["dns"] as? [String:Any]) {
            let actual = try XCTUnwrap(dns[key],key)
            XCTAssertTrue(NSDictionary(dictionary:[key:value]).isEqual(to:[key:actual]),key)
        }
        for (key,name,file) in [("proxy-providers","remote","proxy-0.yaml"),("rule-providers","sites","rule-0.yaml")] {
            let provider = try XCTUnwrap((config[key] as? [String:[String:Any]])?[name])
            let expected = try XCTUnwrap((original[key] as? [String:[String:Any]])?[name])
            XCTAssertEqual(provider["path"] as? String,root.appendingPathComponent("providers/"+file).path)
            XCTAssertEqual(provider["url"] as? String,expected["url"] as? String)
            XCTAssertEqual(provider["interval"] as? Int,expected["interval"] as? Int)
        }
        try assertOwnedConfiguration(config,settings:NetworkSettings())
    }

    func testCompositionRetainsBaseDNSAndRawURIMemberWithoutServiceFields() throws {
        let base = Profile(name:"Base",isRemote:true),member = Profile(name:"URI",isRemote:true)
        let profiles = [base,member]
        var plan = SubscriptionComposition(); plan.profileIDs = [base.id,member.id]; plan.baseProfileID = base.id
        let uri = "ss://dGVzdA@example.org:443#test"
        let source = try CompositionComposer.compose(plan,profiles:profiles,contents:[base.id:maliciousSource,member.id:Data(uri.utf8).base64EncodedString()])
        try PrivilegedConfigurationPolicy.validate(source)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let config = try ConfigComposer.parse(ConfigComposer.compose(source:source,settings:NetworkSettings(),rules:[],secret:"local-secret",resourceRoot:root))
        try assertOwnedConfiguration(config,settings:NetworkSettings())
        let groups = try XCTUnwrap(config["proxy-groups"] as? [[String:Any]])
        XCTAssertTrue(groups.contains { $0["name"] as? String == "[Base] Manual" })
        let dns = try XCTUnwrap(config["dns"] as? [String:Any])
        XCTAssertEqual(dns["nameserver"] as? [String],["1.1.1.1"])
        let providers = try XCTUnwrap(config["proxy-providers"] as? [String:[String:Any]])
        let path = try XCTUnwrap(providers["[URI] 订阅节点"]?["path"] as? String)
        XCTAssertEqual(try String(contentsOfFile:path,encoding:.utf8),uri)
        XCTAssertNil(config["_lumaroute_raw_provider"])
        XCTAssertNil(config["_lumaroute_raw_providers"])
    }

    func testCorePreparationUsesSameBoundaryForHelperValidatedSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try PrivilegedConfigurationPolicy.validate(maliciousSource)
        // prepare only writes a candidate; no executable or network takeover is started.
        let runner = CoreRunner(binary:root.appendingPathComponent("unused-core"),home:root,secret:"local-secret")
        let (yaml,file) = try await runner.prepare(source:maliciousSource,settings:NetworkSettings(),rules:[])
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),yaml)
        try assertOwnedConfiguration(ConfigComposer.parse(yaml),settings:NetworkSettings())
    }
}
