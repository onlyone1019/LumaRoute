import Foundation
import LumaRouteCore

/// Different node bootstrap resolvers: the base returns NXDOMAIN for B while
/// B's own resolver resolves its server. No external network is involved.
enum CompositionDNSSuite {
    static func model() throws -> Int {
        let a = Profile(name:"A",isRemote:false),b = Profile(name:"B",isRemote:false)
        var plan = SubscriptionComposition(); plan.profileIDs = [b.id,a.id]; plan.baseProfileID = a.id
        let first = "proxies: [{name: node, type: http, server: node-a.example, port: 80}]\nproxy-groups: [{name: choice, type: select, proxies: [node]}]\ndns:\n  nameserver: [https://base.example/dns-query]\n  proxy-server-nameserver: [udp://127.0.0.1:10053]\n  proxy-server-nameserver-policy: {node-a.example: [udp://127.0.0.1:10054]}\nrules: ['MATCH,choice']"
        let second = "proxies: [{name: node, type: http, server: node-b.example, port: 80}, {name: alt, type: http, server: other.test, port: 80}]\nproxy-groups: [{name: choice, type: select, proxies: [node,alt]}]\ndns:\n  proxy-server-nameserver: ['https://member.test/dns-query#choice']\n  proxy-server-nameserver-policy: {'+.example': [udp://127.0.0.1:10055]}\nrules: ['MATCH,choice']"
        let merged = try ConfigComposer.parse(CompositionComposer.compose(plan,profiles:[a,b],contents:[a.id:first,b.id:second]))
        let dns = merged["dns"] as! [String:Any],policy = dns["proxy-server-nameserver-policy"] as! [String:Any]
        var count = 0
        func check(_ condition: Bool,_ name: String) throws { guard condition else { throw LumaError.message(name) }; count += 1;print("PASS "+name) }
        try check(dns["nameserver"] as? [String] == ["https://base.example/dns-query"],"成员节点 DNS 不覆盖基础订阅的日常 DNS")
        try check(policy["node-b.example"] as? [String] == ["udp://127.0.0.1:10055"],"成员节点服务器采用自己的 DNS 并保留后缀策略")
        try check(policy["other.test"] as? [String] == ["https://member.test/dns-query#[B] choice"],"成员默认节点 DNS 的策略组出口正确重命名")
        let shared = second.replacingOccurrences(of:"node-b.example",with:"node-a.example")
        let parsed = try ConfigComposer.parse(CompositionComposer.compose(plan,profiles:[a,b],contents:[a.id:first,b.id:shared]))
        let sharedPolicy = (parsed["dns"] as! [String:Any])["proxy-server-nameserver-policy"] as! [String:Any]
        try check(sharedPolicy["node-a.example"] as? [String] == ["udp://127.0.0.1:10054"],"同域名冲突保留基础订阅策略，不受勾选顺序影响")
        return count
    }
    static func run(binary: URL,home: URL) async throws {
        let a = Profile(name:"A",isRemote:false),b = Profile(name:"B",isRemote:false)
        var plan = SubscriptionComposition(); plan.profileIDs = [a.id,b.id]; plan.baseProfileID = a.id
        func source(server: String,port: Int,dns: Int) -> String {
            "proxies: [{name: node, type: http, server: \(server), port: \(port)}]\nproxy-groups: [{name: choice, type: select, proxies: [node]}]\ndns:\n  nameserver: [udp://127.0.0.1:18774]\n  proxy-server-nameserver: [udp://127.0.0.1:\(dns)]\nrules: ['MATCH,choice']\n"
        }
        let first = source(server:"127.0.0.1",port:18771,dns:18775)
        let second = source(server:"node-b.fixture.test",port:18773,dns:18774)
        var settings = NetworkSettings(); settings.controllerPort = 19971; settings.mixedPort = 19970; settings.testURL = "http://127.0.0.1:18772/204"; settings.testTimeout = 2000
        func probe(_ source: String,_ name: String,_ stage: String) async throws -> Int {
            let runner = CoreRunner(binary:binary,home:home.appendingPathComponent(stage),secret:"fixture-only")
            do {
                let (yaml,file) = try await runner.prepare(source:source,settings:settings,rules:[])
                try await runner.validate(file:file); try await runner.apply(yaml:yaml,settings:settings)
                let api = MihomoAPI(port:settings.controllerPort,secret:"fixture-only"),nodes = try await api.proxies()
                let delay = try await api.latency(node:nodes[name]!,testURL:settings.testURL,timeout:settings.testTimeout)
                await runner.stop();return delay
            } catch { await runner.stop();throw error }
        }
        _ = try await probe(second,"node","single")
        print("PASS 订阅 B 使用自己的节点 DNS 时可真实测速")
        let combined = try CompositionComposer.compose(plan,profiles:[a,b],contents:[a.id:first,b.id:second],settings:settings)
        _ = try await probe(combined,"[B] node","combined")
        print("PASS 基础 DNS 无法解析 B 时，聚合 B 仍保留自己的节点 DNS 并可测速")
        _ = try await probe(combined,"[A] node","base")
        print("PASS 聚合后基础订阅节点仍可测速")
        print("composition DNS integration passed: 3 assertions")
    }
}
