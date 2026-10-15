import Foundation
import LumaRouteCore

enum RoutingSaveSuite {
    static func model() throws -> Int {
        var count = 0
        func check(_ value: Bool,_ name: String) throws { guard value else { throw LumaError.message(name) }; count += 1; print("PASS "+name) }
        func rejected(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
        let home = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("routing-policy-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:home) }
        let initial = "proxies: [{name: keep, type: http, server: 127.0.0.1, port: 18771}]\nproxy-groups: [{name: choice, type: select, proxies: [keep]}]\ndns: {nameserver: [https://dns.alidns.com/dns-query]}\nrules: ['MATCH,choice']\n"
        let changedRules = initial.replacingOccurrences(of:"'MATCH,choice'",with:"'DOMAIN,a.test,DIRECT', 'MATCH,choice'")
        try RoutingUpdatePolicy.validate(previous:initial,candidate:changedRules,home:home)
        try check(true,"规则快速更新允许仅规则列表变化")
        for candidate in [initial.replacingOccurrences(of:"18771",with:"18773"),initial.replacingOccurrences(of:"dns.alidns.com",with:"doh.pub"),initial+"mixed-port: 19900\n",initial+"tun: {enable: true}\n",initial.replacingOccurrences(of:"proxies: [keep]",with:"proxies: [DIRECT, keep]")] {
            try check(rejected { try RoutingUpdatePolicy.validate(previous:initial,candidate:candidate,home:home) },"快速规则更新拒绝节点、DNS、端口、TUN 或策略组变化")
        }
        let oldFile=home.appendingPathComponent("revisions/"+UUID().uuidString+"/providers/feed.yaml"),newFile=home.appendingPathComponent("revisions/"+UUID().uuidString+"/providers/feed.yaml")
        for file in [oldFile,newFile] { try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true);try Data("http://127.0.0.1:18771#node".utf8).write(to:file) }
        let old=initial+"proxy-providers: {feed: {type: file, path: '\(oldFile.path)'}}\n",next=initial+"proxy-providers: {feed: {type: file, path: '\(newFile.path)'}}\n"
        try RoutingUpdatePolicy.validate(previous:old,candidate:next,home:home)
        try check(true,"相同 URI 或规则缓存允许更换受管 revision 路径")
        try Data("http://127.0.0.1:18773#node".utf8).write(to:newFile)
        try check(rejected { try RoutingUpdatePolicy.validate(previous:old,candidate:next,home:home) },"同名缓存内容变化不能伪装成纯规则更新")
        let original=NetworkSettings()
        var appOnly=original;appOnly.appearance="dark";appOnly.mode = .global
        try check(RoutingUpdatePolicy.networkUnchanged(appOnly,from:original),"应用偏好和独立模式切换不要求重写系统网络")
        for mutate: (inout NetworkSettings)->Void in [{ $0.systemProxy.toggle() },{ $0.tun.toggle() },{ $0.mixedPort += 1 },{ $0.controllerPort += 1 },{ $0.bypass.append("test") },{ $0.dnsHijack.toggle() }] {
            var candidate=original;mutate(&candidate)
            try check(!RoutingUpdatePolicy.networkUnchanged(candidate,from:original),"后台快速规则请求拒绝网络接管参数变化")
        }
        return count
    }
    static func run(binary: URL,home: URL) async throws {
        var count=0
        func check(_ value: Bool,_ name: String) throws { guard value else { throw LumaError.message(name) };count+=1;print("PASS "+name) }
        var settings=NetworkSettings();settings.mixedPort=19960;settings.controllerPort=19961
        let runner=CoreRunner(binary:binary,home:home,secret:"fixture-only-routing-save")
        let api=MihomoAPI(port:settings.controllerPort,secret:"fixture-only-routing-save")
        let source="""
        proxies:
          - {name: A, type: http, server: 127.0.0.1, port: 18771}
          - {name: B, type: http, server: 127.0.0.1, port: 18773}
        proxy-groups:
          - {name: Manual, type: select, proxies: [A, B]}
          - {name: Auto, type: url-test, proxies: [A, B], url: 'http://127.0.0.1:18772/204', lazy: true, interval: 300}
        rules: ['MATCH,Manual']
        """
        let (yaml,file)=try await runner.prepare(source:source,settings:settings,rules:[])
        try await runner.validate(file:file);try await runner.start(yaml:yaml,settings:settings)
        let stream=Process();stream.executableURL=URL(fileURLWithPath:"/usr/bin/curl")
        stream.arguments=["--disable","--silent","--no-buffer","--noproxy","","--proxy","http://127.0.0.1:19960","--max-time","60","http://other.test/hold"]
        stream.standardOutput=FileHandle.nullDevice;stream.standardError=FileHandle.nullDevice
        defer { if stream.isRunning { stream.terminate() } }
        do {
            try await api.select(group:"Manual",node:"B")
            try stream.run()
            var retained: LiveConnection?
            for _ in 0..<40 {
                retained=try await api.connections().connections?.first { $0.metadata.host == "other.test" && $0.download > 0 }
                if retained != nil { break };try await Task.sleep(nanoseconds:50_000_000)
            }
            guard let retained else { throw LumaError.message("fixture stream was not observed") }
            let rules=[CustomRule(type:"DOMAIN",payload:"other.test",target:"A")]
            let began=Date();try await runner.updateRouting(source:source,settings:settings,rules:rules)
            let elapsed=Date().timeIntervalSince(began)*1000
            try check(elapsed < 800,"运行中的真实规则保存不再等待缓存锁（\(Int(elapsed)) ms）")
            try check(try await CompositionSuite.route(19960,"other.test") == "tokyo","新连接使用新增规则指定的 A 出口")
            try await Task.sleep(nanoseconds:600_000_000)
            let live=try await api.connections().connections?.first { $0.id == retained.id }
            try check(stream.isRunning && live?.chains == retained.chains && (live?.download ?? 0) > retained.download,"已有 B 出口长连接保持同一 ID 并继续传输")
            try check(try await api.proxies()["Manual"]?.now == "B","规则保存保留原有手动节点选择")
            try await GroupSelection.restore([GroupSelection(group:"Auto",kind:"URLTest",node:"A")],api:api)
            try check(try await api.proxies()["Auto"]?.fixed == "A","自动组即使当前节点相同也正确设置手动固定")
            try await GroupSelection.restore([GroupSelection(group:"Auto",kind:"URLTest",node:nil)],api:api)
            try check(try await api.proxies()["Auto"]?.fixed?.isEmpty != false,"自动组正确清除手动固定")
            var failed=false
            do { try await runner.updateRouting(source:source,settings:settings,rules:[CustomRule(type:"DOMAIN",payload:"other.test",target:"missing")]) } catch { failed=true }
            let stillRouted = try await CompositionSuite.route(19960,"other.test")
            try check(failed && stillRouted == "tokyo","无效规则被拒绝且旧规则继续服务")
            failed=false
            do { try await runner.updateRouting(source:source.replacingOccurrences(of:"18771",with:"18773"),settings:settings,rules:[]) } catch { failed=true }
            try check(failed,"节点配置变化不能进入快速规则路径")
            settings.mode = .global;try await api.patch(["mode":"global"])
            try await runner.updateRouting(source:source,settings:settings,rules:rules)
            let config=try JSONSerialization.jsonObject(with:await api.data(["configs"])) as! [String:Any]
            try check(config["mode"] as? String == "global","保留通过 PATCH 切换后的实际代理模式")
            stream.terminate();await runner.stop()
        } catch { await runner.stop();throw error }
        settings.mode = .rule
        let providerSource = "proxy-providers: {feed: {type: http, url: 'http://127.0.0.1:18770/provider', interval: 3600}}\nproxy-groups: [{name: choice, type: select, use: [feed]}]\nrules: ['MATCH,choice']"
        for (label,content) in [("URI","http://127.0.0.1:18771#same"),("HTTP provider",providerSource)] {
            let next=CoreRunner(binary:binary,home:home.appendingPathComponent(label == "URI" ? "uri":"provider"),secret:"fixture-only-routing-save")
            do {
                let (yaml,file)=try await next.prepare(source:content,settings:settings,rules:[])
                try await next.validate(file:file);try await next.start(yaml:yaml,settings:settings)
                try await next.updateRouting(source:content,settings:settings,rules:[CustomRule(type:"DOMAIN",payload:"other.test",target:"REJECT")])
                var rejected=false;do { _ = try await CompositionSuite.route(19960,"other.test") } catch { rejected=true }
                try check(rejected,"\(label) 来源通过独立校验目录完成快速分流更新")
                if label == "URI" {
                    rejected=false
                    do { try await next.updateRouting(source:content.replacingOccurrences(of:"18771",with:"18773"),settings:settings,rules:[]) } catch { rejected=true }
                    try check(rejected,"URI 文件内容变化不能绕过纯规则更新检查")
                }
                try await next.updateRouting(source:content,settings:settings,rules:[])
                try check(try await CompositionSuite.route(19960,"other.test") == "tokyo","\(label) 移除规则后恢复原有节点出口")
                await next.stop()
            } catch { await next.stop();throw error }
        }
        let leftovers=try FileManager.default.contentsOfDirectory(atPath:home.path).filter { $0.hasPrefix("validation-") }
        try check(leftovers.isEmpty,"独立校验目录与日志在完成后清理")
        print("routing save integration passed: \(count) assertions")
    }
}
