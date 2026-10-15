import Foundation
import LumaRouteCore

/// Real kernel routing through two loopback HTTP proxies; source names deliberately collide.
enum CompositionSuite {
    static func fixture(_ port: Int) -> String {
        """
        proxies:
          - {name: shared-node, type: http, server: 127.0.0.1, port: \(port)}
        proxy-groups:
          - {name: shared-group, type: select, include-all: true}
        dns:
          nameserver: [https://dns.alidns.com/dns-query]
        rules:
          - DOMAIN-SUFFIX,base.fixture.test,shared-group
          - MATCH,shared-group
        """
    }
    static func model() throws -> Int {
        var count = 0
        func check(_ value: Bool,_ name: String) throws {
            guard value else { throw LumaError.message("组合验收失败："+name) }; count += 1; print("PASS "+name)
        }
        let a = Profile(name:"订阅 A",isRemote:true), b = Profile(name:"订阅 B",isRemote:true)
        let profiles = [a,b]
        var plan = SubscriptionComposition(); plan.profileIDs = [a.id,b.id]; plan.baseProfileID = a.id
        var route = SubscriptionDomainRoute(profileID:b.id); route.domain = "  EXAMPLE.COM.  "; plan.domainRoutes = [route]
        let contents = [a.id:fixture(18771),b.id:fixture(18773)]
        let source = try CompositionComposer.compose(plan,profiles:profiles,contents:contents)
        let parsed = try ConfigComposer.parse(source)
        let groups = parsed["proxy-groups"] as! [[String:Any]]
        try check((parsed["proxies"] as! [[String:Any]]).count == 2,"组合保留两份同名节点")
        let names = groups.compactMap { $0["name"] as? String }
        try check(Set(names).count == names.count && names.contains(plan.group(for:a.id,profiles:profiles)) && names.contains(plan.group(for:b.id,profiles:profiles)),"同名策略组隔离并提供按订阅选择的分组")
        let scoped = groups.first { $0["name"] as? String == "[订阅 A] shared-group" }!
        try check(scoped["include-all"] == nil && scoped["proxies"] as? [String] == ["[订阅 A] shared-node"],"机场 include-all 不引入另一个订阅的节点")
        let rules = try plan.routingRules(profiles:profiles)
        try check(rules.first?.payload == "example.com" && rules.first?.target == plan.group(for:b.id,profiles:profiles),"域名规范化并绑定目标订阅组")
        let prepared = try ConfigComposer.parse(ConfigComposer.compose(source:source,settings:NetworkSettings(),rules:rules,secret:"synthetic"))
        try check((prepared["rules"] as! [String]).first == "DOMAIN-SUFFIX,example.com,"+plan.group(for:b.id,profiles:profiles),"域名绑定优先于基础订阅的规则和兜底")
        try check((parsed["rules"] as! [String]).last == "MATCH,"+SubscriptionComposition.aggregateGroup,"未匹配流量进入聚合出口")
        var dnsContents = contents
        dnsContents[b.id] = fixture(18773).replacingOccurrences(of:"dns.alidns.com",with:"cloudflare-dns.com")
        let dnsSource = try ConfigComposer.parse(CompositionComposer.compose(plan,profiles:profiles,contents:dnsContents))
        try check((dnsSource["dns"] as? [String:Any])?["nameserver"] as? [String] == ["https://dns.alidns.com/dns-query"],"组合只沿用所选基础订阅的 DNS，避免混合覆盖")
        let credentialFixture = """
        proxies:
          - {name: shared-node, type: http, server: 127.0.0.1, port: 18771, password: 'credential#shared-group', dialer-proxy: shared-group}
        proxy-groups:
          - {name: shared-group, type: select, proxies: [DIRECT]}
        dns:
          nameserver: ['https://dns.alidns.com/dns-query#shared-group&h3=true']
        rules: ['MATCH,shared-group']
        """
        let credentialSource = try ConfigComposer.parse(CompositionComposer.compose(plan,profiles:profiles,contents:[a.id:credentialFixture,b.id:fixture(18773)]))
        let credentialNode = (credentialSource["proxies"] as! [[String:Any]]).first!
        try check(credentialNode["password"] as? String == "credential#shared-group" && credentialNode["dialer-proxy"] as? String == "[订阅 A] shared-group","重命名引用时保留凭据中的井号和原始内容")
        try check((credentialSource["dns"] as? [String:Any])?["nameserver"] as? [String] == ["https://dns.alidns.com/dns-query#[订阅 A] shared-group&h3=true"],"仅在 DNS 出口引用中重命名分组并保留参数")
        let remoteProvider = "proxy-providers:\n  remote:\n    type: http\n    url: http://127.0.0.1:18770/provider\nproxy-groups:\n  - {name: all, type: select, include-all-providers: true, use: [ignored]}\nrules: ['MATCH,all']\n"
        let providerSource = try ConfigComposer.parse(CompositionComposer.compose(plan,profiles:profiles,contents:[a.id:remoteProvider,b.id:remoteProvider]))
        let providers = providerSource["proxy-providers"] as! [String:[String:Any]]
        try check(providers.values.allSatisfy { $0["proxy"] as? String == "DIRECT" },"未指定下载出口的 HTTP 来源使用直连引导，避免空组循环依赖")
        let providerGroups = providerSource["proxy-groups"] as! [[String:Any]]
        try check(providerGroups.first(where:{$0["name"] as? String == "[订阅 A] all"})?["use"] as? [String] == ["[订阅 A] remote"],"include-all-providers 保持原有覆盖 use 的语义并限制来源范围")
        var invalid = plan; invalid.profileIDs = [a.id,a.id]
        var rejected = false; do { try invalid.validate(profiles:profiles) } catch { rejected = true }
        try check(rejected,"拒绝重复成员，避免重复聚合")
        invalid = plan; invalid.domainRoutes[0].domain = "https://example.com/path"
        rejected = false; do { try invalid.validate(profiles:profiles) } catch { rejected = true }
        try check(rejected,"域名编辑拒绝协议、路径和规则注入")
        invalid = plan; invalid.domainRoutes.append(route)
        rejected = false; do { try invalid.validate(profiles:profiles) } catch { rejected = true }
        try check(rejected,"重复的有效域名绑定不允许产生歧义")
        invalid = plan; invalid.domainRoutes[0].profileID = UUID()
        rejected = false; do { try invalid.validate(profiles:profiles) } catch { rejected = true }
        try check(rejected,"目标订阅移出组合时要求重新指定或停用")
        invalid.domainRoutes[0].enabled = false
        try invalid.validate(profiles:profiles)
        try check(true,"停用的域名规则可保留以便重新启用")
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("work/composition-store-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try LocalStore(root:root)
        var composite = Profile(name:"组合",isRemote:false); composite.composition = plan
        var database = AppDatabase(); database.profiles = [a,b,composite]; database.activeProfileID = composite.id
        database.customRules = [CustomRule(payload:"single.test",target:"shared-group")]
        try store.commit(database,profiles:[a.id:contents[a.id]!,b.id:contents[b.id]!,composite.id:source])
        try check(try LocalStore(root:root).load().profiles.last?.composition == plan,"组合成员和域名规则在 SQLite 重开后保留")
        let backup = try store.backup(database)
        let (restored,_) = try store.readBackup(backup)
        try check(restored.profiles.last?.composition == plan && restored.customRules == database.customRules,"备份保留组合定义及独立的单订阅自定义规则")
        let old = "{\"name\":\"legacy\",\"isRemote\":false,\"displaySource\":\"local\",\"created\":0,\"updateHours\":6,\"nodeCount\":0,\"id\":\"\(a.id)\"}"
        try check(try JSONDecoder().decode(Profile.self,from:Data(old.utf8)).composition == nil,"旧版单订阅数据无需迁移即可读取")
        var duplicateNames = profiles; duplicateNames[1].name = duplicateNames[0].name
        let aliases = plan.aliases(profiles:duplicateNames)
        try check(aliases[a.id] != aliases[b.id],"订阅本身同名时仍能区分来源")
        return count
    }
    static func run(binary: URL,home: URL) async throws {
        var passed = 0
        func check(_ value: Bool,_ name: String) throws {
            guard value else { throw LumaError.message("组合集成失败："+name) }; passed += 1; print("PASS "+name)
        }
        let a = Profile(name:"A",isRemote:false), b = Profile(name:"B",isRemote:false)
        var plan = SubscriptionComposition(); plan.profileIDs = [a.id,b.id]; plan.baseProfileID = a.id
        var ra = SubscriptionDomainRoute(profileID:a.id); ra.domain = "a.fixture.test"
        var rb = SubscriptionDomainRoute(profileID:b.id); rb.domain = "b.fixture.test"
        plan.domainRoutes = [ra,rb]
        let profiles = [a,b]
        var settings = NetworkSettings(); settings.controllerPort = 19931; settings.mixedPort = 19930; settings.testURL = "http://127.0.0.1:18772/204"
        let secret = UUID().uuidString+UUID().uuidString
        let runner = CoreRunner(binary:binary,home:home,secret:secret)
        let api = MihomoAPI(port:settings.controllerPort,secret:secret)
        func apply(_ inputs: [UUID:String],composition: SubscriptionComposition) async throws {
            let source = try CompositionComposer.compose(composition,profiles:profiles,contents:inputs,settings:settings)
            try PrivilegedConfigurationPolicy.validate(source)
            let (yaml,file) = try await runner.prepare(source:source,settings:settings,rules:composition.routingRules(profiles:profiles))
            try await runner.validate(file:file); try await runner.apply(yaml:yaml,settings:settings)
        }
        let inputs = [a.id:fixture(18771),b.id:fixture(18773)]
        try await apply(inputs,composition:plan)
        do {
            try check(try await route(settings.mixedPort,"a.fixture.test") == "tokyo","域名 A 的真实请求使用订阅 A")
            try check(try await route(settings.mixedPort,"child.b.fixture.test") == "osaka","域名 B 及子域名的真实请求使用订阅 B")
            try check(try await route(settings.mixedPort,"base.fixture.test") == "tokyo","保留基础订阅的原有分流")
            let nodes = try await api.proxies()
            try check(nodes["[A] shared-group"]?.all == ["[A] shared-node"] && nodes["[B] shared-group"]?.all == ["[B] shared-node"],"真实内核中源策略组没有跨订阅混入")
            try await api.select(group:SubscriptionComposition.aggregateGroup,node:"[B] shared-node")
            try check(try await route(settings.mixedPort,"other.test") == "osaka","聚合节点可选择另一个订阅作为兜底")
            var changed = inputs; changed[b.id] = fixture(18771)
            try await apply(changed,composition:plan)
            try check(try await route(settings.mixedPort,"b.fixture.test") == "tokyo","成员内容更新后组合采用新节点配置")
            try check(try await route(settings.mixedPort,"a.fixture.test") == "tokyo","成员更新保持其他订阅的域名绑定")
            plan.domainRoutes[1].enabled = false; plan.fallbackProfileID = b.id
            try await apply(inputs,composition:plan)
            try check(try await route(settings.mixedPort,"b.fixture.test") == "osaka","停用域名绑定后使用显式配置的兜底订阅")
            var bad = inputs; bad[b.id] = "proxies: [{name: broken, type: unknown}]"
            var failed = false; do { try await apply(bad,composition:plan) } catch { failed = true }
            let retainedRoute = try await route(settings.mixedPort,"a.fixture.test")
            try check(failed && retainedRoute == "tokyo","无效成员候选被拒绝，原有配置继续服务")
            let provider = "proxy-providers:\n  same-provider:\n    type: http\n    url: http://127.0.0.1:18770/provider\n    interval: 3600\nproxy-groups:\n  - {name: same-group, type: select, use: [same-provider]}\nrules: ['MATCH,same-group']\n"
            try await apply([a.id:provider,b.id:provider],composition:plan)
            let providerNodes = try await api.proxies()
            try check(providerNodes["[A] same-group"]?.all?.isEmpty == false && providerNodes["[B] same-group"]?.all?.isEmpty == false && providerNodes["[A] same-group"]?.all?.allSatisfy {$0.hasPrefix("[A] ")} == true && providerNodes["[B] same-group"]?.all?.allSatisfy {$0.hasPrefix("[B] ")} == true,"同名 HTTP provider 及其节点分别加载并加来源前缀")
            try check(try await route(settings.mixedPort,"a.fixture.test") == "tokyo","HTTP provider 来源的域名分流真实生效")
            try await apply([a.id:"http://127.0.0.1:18771#same",b.id:"http://127.0.0.1:18773#same"],composition:plan)
            let uriA = try await route(settings.mixedPort,"a.fixture.test"), uriB = try await route(settings.mixedPort,"b.fixture.test")
            try check(uriA == "tokyo" && uriB == "osaka","两份 URI 节点订阅生成独立缓存并正确分流")
            try await apply([a.id:provider,b.id:"http://127.0.0.1:18773#same"],composition:plan)
            let mixedA = try await route(settings.mixedPort,"a.fixture.test"), mixedB = try await route(settings.mixedPort,"b.fixture.test")
            try check(mixedA == "tokyo" && mixedB == "osaka","HTTP provider 与 URI 订阅混合聚合时缓存路径和分流正确")
            let single = inputs[a.id]!
            let (singleYAML,singleFile) = try await runner.prepare(source:single,settings:settings,rules:[])
            try await runner.validate(file:singleFile); try await runner.apply(yaml:singleYAML,settings:settings)
            try check(try await route(settings.mixedPort,"b.fixture.test") == "tokyo","切回单订阅后恢复该订阅的原始分流")
            let singles = try await api.proxies()
            try check(singles["shared-node"] != nil && singles["[B] shared-node"] == nil,"单订阅不带组合来源前缀或其他订阅节点")
            await runner.stop()
        } catch { await runner.stop(); throw error }
        print("composition integration passed: \(passed) assertions")
    }
    static func route(_ port: Int,_ host: String) async throws -> String {
        try await Task.detached {
            let process = Process(); let output = Pipe()
            process.executableURL = URL(fileURLWithPath:"/usr/bin/curl")
            process.arguments = ["--disable","--silent","--fail","--noproxy","","--proxy","http://127.0.0.1:\(port)","--max-time","5","http://\(host)/route?fresh=\(UUID().uuidString)"]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw LumaError.message("组合代理请求失败") }
            guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],let route = object["route"] as? String else { throw LumaError.message("测试出口返回无效响应") }
            return route
        }.value
    }
}
