import Foundation
import LumaRouteCore

enum RoutingToolsSuite {
    static func connection(host: String = "api.fixture.test",process: String? = "curl",path: String? = "/usr/bin/curl",chains: [String] = ["node","group"]) throws -> LiveConnection {
        var metadata: [String:Any] = ["host":host]
        metadata["process"] = process; metadata["processPath"] = path
        return try JSONDecoder().decode(LiveConnection.self,from:JSONSerialization.data(withJSONObject:["id":"fixture","metadata":metadata,"upload":0,"download":0,"chains":chains]))
    }
    static func model() throws -> Int {
        var count = 0
        func check(_ condition: Bool,_ name: String) throws { guard condition else { throw LumaError.message(name) }; count += 1; print("PASS "+name) }
        let c = try connection()
        try check(try RoutingTools.domainRule(for:c).yamlRule == "DOMAIN,api.fixture.test,DIRECT","连接创建精确域名规则")
        try check(try RoutingTools.domainRule(for:connection(host:"1.2.3.4")).yamlRule == "IP-CIDR,1.2.3.4/32,DIRECT,no-resolve","无域名连接创建精确 IPv4 规则")
        try check(try RoutingTools.domainRule(for:connection(host:"2001:db8::1")).type == "IP-CIDR6","IPv6 连接创建 IPv6 规则")
        try check(try RoutingTools.applicationRule(for:c).yamlRule == "PROCESS-PATH,/usr/bin/curl,DIRECT","应用分流优先使用完整进程路径")
        try check(try RoutingTools.applicationRule(for:connection(path:nil)).type == "PROCESS-NAME","只有进程名称时可创建应用规则")
        var rejected = false; do { _ = try RoutingTools.applicationRule(for:connection(process:nil,path:nil)) } catch { rejected = true }
        try check(rejected,"未知进程不能误创建规则")
        for rule in [CustomRule(type:"PROCESS-NAME",payload:"curl\rMATCH"),CustomRule(type:"PROCESS-PATH",payload:"relative"),CustomRule(type:"PROCESS-NAME",payload:"/usr/bin/curl")] {
            rejected = false; do { try rule.validate() } catch { rejected = true }; try check(rejected,"应用规则拒绝注入和不正确的路径格式")
        }
        let prior = CustomRule(payload:"fixture.test"),broad = CustomRule(type:"DOMAIN-KEYWORD",payload:"fixture")
        let saved = try RoutingTools.saving(CustomRule(payload:"fixture.test",target:"REJECT"),in:[broad,prior])
        try check(saved.count == 2 && saved.first?.target == "REJECT" && saved.last?.id == broad.id,"快捷规则替换相同匹配且置于首位，不丢失其他规则")
        let a = Profile(name:"A",isRemote:true),b = Profile(name:"B",isRemote:true)
        var combo = Profile(name:"组合",isRemote:false),composition = SubscriptionComposition(); composition.profileIDs = [a.id,b.id]; composition.baseProfileID = a.id; combo.composition = composition
        try check(RoutingTools.subscription(for:connection(chains:["[B] shared","聚合节点"]),profiles:[a,b,combo],activeID:combo.id) == "B","聚合出口能够识别真实节点所属订阅")
        try check(RoutingTools.subscription(for:connection(chains:["DIRECT"]),profiles:[a],activeID:a.id) == "直连","直连不误显示为代理订阅")
        let old = "proxies: [{name: keep, type: http, server: 127.0.0.1, port: 18771, password: old-secret}, {name: gone, type: direct}]\nproxy-groups: [{name: before, type: select, proxies: [keep]}]\nrules: ['MATCH,DIRECT']"
        let next = "proxies: [{name: keep, type: http, server: 127.0.0.1, port: 18773, password: new-secret}, {name: added, type: direct}]\nproxy-groups: [{name: after, type: select, proxies: [keep]}]\nrules: ['MATCH,DIRECT']"
        let delta = try SubscriptionChange.compare(old:old,new:next,selectedNodes:["gone"])
        try check(delta.addedNodes == ["added"] && delta.removedNodes == ["gone"] && delta.changedNodes == ["keep"] && delta.selectedNodesRemoved == ["gone"],"订阅差异区分增删和参数变化并提示选中节点移除")
        try check(delta.addedGroups == ["after"] && delta.removedGroups == ["before"] && !String(decoding:try JSONEncoder().encode(delta),as:UTF8.self).contains("secret"),"差异持久化不包含节点凭据")
        let uri = try SubscriptionChange.compare(old:"http://127.0.0.1:18771#Tokyo",new:"http://127.0.0.1:18773#Osaka")
        try check(uri.addedNodes == ["Osaka"] && uri.removedNodes == ["Tokyo"] && uri.uriNamesOnly,"URI 节点差异使用名称而非暴露链接")
        let provider = try SubscriptionChange.compare(old:"proxy-providers: {p: {type: http, url: 'https://a.test/feed'}}",new:"proxy-providers: {p: {type: http, url: 'https://b.test/feed'}}")
        try check(provider.changedProviders == ["p"] && provider.containsProviders,"提供者差异明确范围，不伪造远程节点变化")
        try check(NetworkDiagnostics.dnsResult(["Status":0,"Answer":[["type":1,"data":"1.2.3.4"]]]).state == .passed && NetworkDiagnostics.dnsResult(["Status":3]).state == .failed,"DNS 诊断依据有效地址记录判断")
        var settings = NetworkSettings(); settings.systemProxy = true
        try check(NetworkDiagnostics.systemProxy(settings:settings,actual:["HTTPEnable":1]).state == .failed,"系统代理地址不一致时报告接管异常")
        settings.systemProxy = false
        try check(NetworkDiagnostics.systemProxy(settings:settings,actual:[:]).state == .warning,"未接管网络不误报全部连通")
        rejected = false; do { _ = try NetworkDiagnostics.target("https://user:password@example.com") } catch { rejected = true }
        try check(rejected,"诊断测试地址拒绝携带账号密码")
        return count
    }
    static func run(binary: URL,home: URL) async throws {
        var passed = 0
        func check(_ value: Bool,_ name: String) throws { guard value else { throw LumaError.message(name) }; passed += 1; print("PASS "+name) }
        var settings = NetworkSettings(); settings.mixedPort = 19940; settings.controllerPort = 19941
        let runner = CoreRunner(binary:binary,home:home,secret:"fixture-only-controller")
        let api = MihomoAPI(port:settings.controllerPort,secret:"fixture-only-controller")
        let source = """
        proxies:
          - {name: A, type: http, server: 127.0.0.1, port: 18771}
          - {name: B, type: http, server: 127.0.0.1, port: 18773}
        proxy-groups: [{name: default, type: select, proxies: [A, B]}]
        dns:
          nameserver: ['udp://127.0.0.1:18774']
        rules: ['MATCH,A']
        """
        func apply(_ rules: [CustomRule]) async throws {
            let (yaml,file) = try await runner.prepare(source:source,settings:settings,rules:rules)
            try await runner.validate(file:file); try await runner.apply(yaml:yaml,settings:settings)
        }
        func request() async throws -> String {
            try await Task.detached {
                let process = Process(),output = Pipe(); process.executableURL = URL(fileURLWithPath:"/usr/bin/curl")
                process.arguments = ["--disable","--silent","--fail","--noproxy","","--proxy","http://127.0.0.1:19940","--max-time","5","http://other.test/route"]
                process.standardOutput = output; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                guard process.terminationStatus == 0,let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],let route = object["route"] as? String else { throw LumaError.message("route failed") }
                return route
            }.value
        }
        do {
            try await apply([]); try check(try await request() == "tokyo","普通配置的真实默认请求走 A")
            try await apply([CustomRule(type:"PROCESS-NAME",payload:"curl",target:"B")]); try check(try await request() == "osaka","真实 curl 进程名称规则走 B")
            try await apply([CustomRule(type:"PROCESS-PATH",payload:"/usr/bin/curl",target:"B")]); try check(try await request() == "osaka","真实可执行文件路径规则走 B")
            try await apply([CustomRule(type:"PROCESS-NAME",payload:"unmatched-process",target:"B")]); try check(try await request() == "tokyo","不匹配的应用规则不影响其他进程")
            try await apply([CustomRule(type:"PROCESS-NAME",payload:"curl",target:"B",enabled:false)]); try check(try await request() == "tokyo","停用应用分流恢复基础规则")
            let checks = try await NetworkDiagnostics.run(api:api,settings:settings,url:NetworkDiagnostics.target("http://diagnostic.fixture.test:18772/204"))
            for item in checks { print("DIAGNOSTIC \(item.title): \(item.state.rawValue) \(item.detail)") }
            try check(checks.first(where:{$0.title == "代理内核"})?.state == .passed && checks.first(where:{$0.title == "实际出口访问"})?.state == .passed,"诊断验证真实内核和本机代理 HTTP 出口")
            try check(checks.first(where:{$0.title == "DNS 解析"})?.state == .passed,"诊断通过内核 DNS API 验证解析")
            await runner.stop()
            let stopped = try await NetworkDiagnostics.run(api:api,settings:settings,url:NetworkDiagnostics.target("http://diagnostic.fixture.test:18772/204"))
            try check(stopped.first(where:{$0.title == "代理内核"})?.state == .failed && stopped.first(where:{$0.title == "实际出口访问"})?.state == .failed,"内核停止时诊断不会误报出口正常")
        } catch { await runner.stop(); throw error }
        print("routing tools integration passed: \(passed) assertions")
    }
}
