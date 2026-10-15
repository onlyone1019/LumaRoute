import Foundation
import LumaRouteCore

enum CompositionRoutingSuite {
    static func model() throws -> Int {
        var count = 0
        func check(_ value: Bool,_ name: String) throws { guard value else { throw LumaError.message(name) }; count += 1; print("PASS "+name) }
        func rejects(_ operation: () throws -> Void) -> Bool { do { try operation(); return false } catch { return true } }
        func rule(_ type: String,_ value: String,_ target: String = "DIRECT") -> CustomRule { CustomRule(type:type,payload:value,target:target) }
        func hit(_ rules: [CustomRule],_ host: String,ip: String = "",process: String = "") throws -> String? {
            if case .matched(_,let matched) = try CompositionRouting.preview(rules:rules,host:host,ip:ip,process:process) { return matched.target }; return nil
        }
        let legacy = "{\"id\":\"\(UUID())\",\"enabled\":true,\"type\":\"DOMAIN-SUFFIX\",\"domain\":\"example.com\",\"profileID\":\"\(UUID())\"}"
        let decoded = try JSONDecoder().decode(SubscriptionDomainRoute.self,from:Data(legacy.utf8))
        try check(decoded.target == nil && decoded.profileID != nil,"旧域名规则兼容读取原有订阅出口")
        for (type,input,output) in [("DOMAIN-KEYWORD"," ViDeO ","video"),("IP-CIDR","192.168.2.9/16","192.168.0.0/16"),("IP-CIDR6","2001:DB8:1::1/32","2001:db8::/32"),("PROCESS-PATH","/Applications/My App.app/Contents/MacOS/My App","/Applications/My App.app/Contents/MacOS/My App")] {
            try check(try CompositionRouting.normalized(type:type,payload:input) == output,"规范化 \(type) 且保留进程路径空格")
        }
        for (type,input) in [("IP-CIDR","1.2.3.4/33"),("IP-CIDR6","1.2.3.4/24"),("IP-CIDR","2001:db8::/32"),("IP-CIDR6","2001:db8::/129"),("DOMAIN-KEYWORD","video,MATCH"),("PROCESS-PATH","relative"),("PROCESS-NAME","/usr/bin/curl"),("DOMAIN","https://example.com"),("DOMAIN","127.0.0.1")] {
            try check(rejects { _ = try CompositionRouting.normalized(type:type,payload:input) },"拒绝无效匹配 \(type) \(input)")
        }
        let suffix = rule("DOMAIN-SUFFIX","example.com","B"), exact = rule("DOMAIN","api.example.com","A")
        try check(try hit([suffix],"a.example.com") == "B" && hit([suffix],"example.com") == "B" && hit([suffix],"notexample.com") == nil,"后缀匹配保持域名边界")
        try check(try hit([exact,suffix],"API.EXAMPLE.COM.") == "A" && hit([suffix,exact],"api.example.com") == "B","验证严格遵循首条命中顺序")
        try check(try hit([rule("DOMAIN-KEYWORD","video","B")],"myvideo.test") == "B","域名关键词预览")
        try check(try hit([rule("IP-CIDR","10.2.0.0/16","B")],"10.2.255.255") == "B" && hit([rule("IP-CIDR","10.2.0.0/16")],"10.3.0.0") == nil,"IPv4 掩码边界")
        try check(try hit([rule("IP-CIDR6","2001:db8::/32","B")],"2001:db8:ffff::1") == "B" && hit([rule("IP-CIDR6","::/0","B")],"::1") == "B","IPv6 网段含零位前缀")
        try check(try hit([rule("PROCESS-NAME","curl","B")],"",process:"/usr/bin/curl") == "B" && hit([rule("PROCESS-PATH","/usr/bin/curl","B")],"",process:"/usr/bin/curl") == "B","应用名称与可执行路径预览")
        if case .needs = try CompositionRouting.preview(rules:[rule("IP-CIDR","10.0.0.0/8"),suffix],host:"example.com") { try check(true,"缺少前序 IP 信息不误报后续规则") } else { throw LumaError.message("missing IP preview") }
        if case .needs = try CompositionRouting.preview(rules:[rule("PROCESS-PATH","/usr/bin/curl"),suffix],host:"example.com",process:"curl") { try check(true,"缺少前序应用路径不误报后续规则") } else { throw LumaError.message("missing path preview") }
        try check(try hit([rule("PROCESS-NAME","CURL","B")],"",process:"curl") == "B" && hit([rule("PROCESS-PATH","/USR/BIN/CURL","B")],"",process:"/usr/bin/curl") == "B","应用预览与内核保持大小写不敏感")
        var off = suffix; off.enabled = false
        try check(try hit([off,exact],"api.example.com") == "A","停用规则不参与预览")
        let batch = try CompositionRouting.batch("\n EXAMPLE.COM.\nDOMAIN-KEYWORD,video\nIP-CIDR,10.2.3.4/16\n",type:"DOMAIN-SUFFIX",profileID:nil,target:"REJECT",existing:[])
        try check(batch.count == 3 && batch[0].domain == "example.com" && batch[2].domain == "10.2.0.0/16" && batch.allSatisfy {$0.target == "REJECT"},"混合批量粘贴规范化并统一出口")
        try check(rejects { _ = try CompositionRouting.batch("ok.test\nIP-CIDR,10.0.0.0/999",type:"DOMAIN",profileID:nil,target:"DIRECT",existing:[]) },"批量中的错误使整批失败")
        try check(rejects { _ = try CompositionRouting.batch("10.2.99.0/16",type:"IP-CIDR",profileID:nil,target:"DIRECT",existing:batch) },"批量识别等价网段重复")
        let a = Profile(name:"A",isRemote:false), b = Profile(name:"B",isRemote:false)
        var plan = SubscriptionComposition(); plan.profileIDs = [a.id,b.id]; plan.baseProfileID = a.id; plan.domainRoutes = batch
        let profiles = [a,b],contents = [a.id:CompositionSuite.fixture(18771),b.id:CompositionSuite.fixture(18773)]
        _ = try CompositionComposer.compose(plan,profiles:profiles,contents:contents)
        try check(try plan.routingRules(profiles:profiles).allSatisfy {$0.target == "REJECT"},"统一规则支持拒绝出口")
        plan.domainRoutes[0].target = "[B] shared-group"
        _ = try CompositionComposer.compose(plan,profiles:profiles,contents:contents)
        try check(true,"统一规则支持已命名空间隔离的策略组")
        plan.domainRoutes[0].target = "[missing] group"
        try check(rejects { _ = try CompositionComposer.compose(plan,profiles:profiles,contents:contents) },"拒绝已不存在的策略组出口")
        plan.domainRoutes[0].enabled = false
        _ = try CompositionComposer.compose(plan,profiles:profiles,contents:contents)
        try check(true,"允许保留停用的失效策略组规则")
        let reopened = try JSONDecoder().decode(SubscriptionComposition.self,from:JSONEncoder().encode(plan))
        try check(reopened == plan,"所有新匹配与出口可持久化往返")
        return count
    }

    static func run(binary: URL,home: URL) async throws {
        var count = 0
        func check(_ condition: Bool,_ name: String) throws { guard condition else { throw LumaError.message(name) }; count += 1; print("PASS "+name) }
        let a = Profile(name:"A",isRemote:false),b = Profile(name:"B",isRemote:false), profiles = [a,b]
        var plan = SubscriptionComposition(); plan.profileIDs = [a.id,b.id]; plan.baseProfileID = a.id; plan.fallbackProfileID = a.id
        var settings = NetworkSettings(); settings.mixedPort = 19980; settings.controllerPort = 19981
        let runner = CoreRunner(binary:binary,home:home,secret:"fixture-only-unified-routing")
        let api = MihomoAPI(port:settings.controllerPort,secret:"fixture-only-unified-routing")
        func apply(_ type: String,_ payload: String,target: String? = nil,enabled: Bool = true) async throws {
            var route = SubscriptionDomainRoute(profileID:b.id); route.type = type; route.domain = payload; route.target = target; route.enabled = enabled
            plan.domainRoutes = [route]
            let source = try CompositionComposer.compose(plan,profiles:profiles,contents:[a.id:CompositionSuite.fixture(18771),b.id:CompositionSuite.fixture(18773)])
            let (yaml,file) = try await runner.prepare(source:source,settings:settings,rules:plan.routingRules(profiles:profiles))
            try await runner.validate(file:file); try await runner.apply(yaml:yaml,settings:settings)
        }
        do {
            for (type,payload,host) in [("DOMAIN","b.fixture.test","b.fixture.test"),("DOMAIN-SUFFIX","b.fixture.test","child.b.fixture.test"),("DOMAIN-KEYWORD","other","other.test"),("PROCESS-NAME","curl","other.test"),("PROCESS-PATH","/usr/bin/curl","other.test"),("PROCESS-NAME","CURL","other.test"),("PROCESS-PATH","/USR/BIN/CURL","other.test")] {
                try await apply(type,payload)
                try check(try await CompositionSuite.route(19980,host) == "osaka","组合内真实请求命中 \(type) 并走订阅 B")
            }
            try await apply("DOMAIN","other.test",target:"[B] shared-group")
            try check(try await CompositionSuite.route(19980,"other.test") == "osaka","组合策略组出口实际生效")
            try await apply("DOMAIN","other.test",enabled:false)
            try check(try await CompositionSuite.route(19980,"other.test") == "tokyo","停用统一规则后恢复基础兜底")
            try await apply("IP-CIDR","127.0.0.0/8",target:"DIRECT")
            try check(try await CompositionSuite.route(19980,"127.0.0.1:18772") == "direct","IPv4 网段命中后真实直连")
            try await apply("IP-CIDR6","2001:db8::/32")
            let rules = try await api.rules()
            let ipv6 = try await CompositionSuite.route(19980,"[2001:db8::1]")
            try check(rules.first?.payload == "2001:db8::/32" && ipv6 == "osaka","IPv6 网段由真实内核匹配并走订阅 B")
            try await apply("DOMAIN","other.test",target:"REJECT")
            var failed = false; do { _ = try await CompositionSuite.route(19980,"other.test") } catch { failed = true }
            try check(failed,"拒绝出口真实阻断请求")
            await runner.stop()
        } catch { await runner.stop(); throw error }
        print("composition routing integration passed: \(count) assertions")
    }
}
