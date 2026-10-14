import Foundation
import LumaRouteCore

enum FunctionalSuite {
    static func run(binary: URL, home: URL) async throws {
        var passed = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw LumaError.message("集成验证失败："+name) }
            passed += 1; print("PASS "+name)
        }
        func state(_ values: [String:Bool]) async throws {
            var request = URLRequest(url:URL(string:"http://127.0.0.1:18770/state")!,timeoutInterval:3)
            request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject:values)
            let (_,response) = try await URLSession.shared.data(for:request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LumaError.message("本地测试服务不可用") }
        }
        try await state(["invalid":false,"tokyo_down":false,"osaka_down":false])
        var settings = NetworkSettings(); settings.mixedPort = 19890; settings.controllerPort = 19891
        settings.testURL = "http://127.0.0.1:18772/204"; settings.testTimeout = 1200
        let secret = UUID().uuidString+UUID().uuidString
        let runner = CoreRunner(binary:binary,home:home,secret:secret)
        let api = MihomoAPI(port:settings.controllerPort,secret:secret)
        let session = URLSession(configuration:.ephemeral)
        defer { session.invalidateAndCancel() }
        for (transport, customSession) in [("直连", nil as URLSession?), ("指定会话", session)] {
            for agent in ["Provider-A/1.0", "Provider-B/2.0 \"quoted\" \\route", "   "] {
                let downloaded = try await SubscriptionFetcher.fetch("http://127.0.0.1:18770/subscription-agent-echo",userAgent:agent,session:customSession)
                let observed = try ConfigComposer.parse(downloaded.content)["fixture-user-agent"] as? String
                let expected = try SubscriptionFetcher.normalizedUserAgent(agent) ?? SubscriptionFetcher.defaultUserAgent
                try check(observed == expected,"\(transport)请求使用独立User-Agent且正确转义，长度\(agent.count)")
            }
            for (kind, expected) in [("401","HTTP 401"),("403","HTTP 403"),("404","HTTP 404"),("429","HTTP 429"),("503","HTTP 503"),("html","返回内容是网页"),("empty","订阅内容为空"),("encoding","编码不支持"),("yaml","订阅格式无法识别"),("json","订阅格式无法识别"),("oversize","超过 8 MB")] {
                var message = ""
                do { _ = try await SubscriptionFetcher.fetch("http://127.0.0.1:18770/subscription-error/"+kind,session:customSession) }
                catch { message = error.localizedDescription }
                try check(message.contains(expected) && !message.contains("private") && !message.contains("127.0.0.1"),"\(transport)清晰区分\(kind)错误且不显示响应内容和地址")
            }
            let bom = try await SubscriptionFetcher.fetch("http://127.0.0.1:18770/subscription-error/bom",session:customSession)
            try check(try ConfigComposer.nodeCount(bom.content) == 3,"\(transport)兼容带BOM的订阅文本")
            var connectionFailure = ""
            do { _ = try await SubscriptionFetcher.fetch("http://127.0.0.1:18779/subscription",session:customSession) }
            catch { connectionFailure = error.localizedDescription }
            try check(connectionFailure.contains("订阅连接失败") && !connectionFailure.contains("127.0.0.1"),"\(transport)连接失败提供脱敏提示")
            let custom = try await SubscriptionFetcher.fetch("http://127.0.0.1:18770/subscription-required-agent",userAgent:"LumaRoute-PerProfile/1.0",session:customSession)
            let (_, customCandidate) = try await runner.prepare(source:custom.content,settings:settings,rules:[])
            try await runner.validate(file:customCandidate)
            try check(try ConfigComposer.nodeCount(custom.content) == 3,"\(transport)自定义标识取得专用订阅并通过真实内核校验")
            let negotiated = try await SubscriptionFetcher.fetch("http://127.0.0.1:18770/subscription-client-aware",session:customSession)
            let (_, candidate) = try await runner.prepare(source:negotiated.content,settings:settings,rules:[])
            try await runner.validate(file:candidate)
            try check(try ConfigComposer.nodeCount(negotiated.content) == 3,"\(transport)订阅请求识别为Meta客户端并取得完整节点")
            let groups = try ConfigComposer.parse(negotiated.content)["proxy-groups"] as? [[String:Any]]
            try check(groups?.compactMap { $0["name"] as? String } == ["默认代理","日本自动","OpenAI"],"\(transport)导入保留服务商策略组及引用")
        }
        let profileID = UUID()
        let strategy = GroupStrategy(profileID:profileID,group:"默认代理",mode:.lowestLatency,interval:10,tolerance:0)
        let download = try await SubscriptionFetcher.fetch("http://127.0.0.1:18770/subscription")
        try check(download.usage?.total == 214748364800 && download.interval == 6,"真实 HTTP 订阅额度与更新周期")
        let (yaml,file) = try await runner.prepare(source:download.content,settings:settings,rules:[],strategies:[strategy])
        try await runner.validate(file:file)
        try await runner.start(yaml:yaml,settings:settings)
        do {
            var ipv6Settings = settings; ipv6Settings.ipv6 = true
            let (ipv6YAML,ipv6File) = try await runner.prepare(source:download.content,settings:ipv6Settings,rules:[],strategies:[strategy])
            try await runner.validate(file:ipv6File); try await runner.apply(yaml:ipv6YAML,settings:ipv6Settings)
            let enabledIPv6 = try JSONSerialization.jsonObject(with:await api.data(["configs"])) as! [String:Any]
            try check(enabledIPv6["ipv6"] as? Bool == true && !((enabledIPv6["tun"] as? [String:Any])?["inet6-address"] as? [String] ?? []).isEmpty,"IPv4网络上热启用IPv6仍保留真实内核的TUN IPv6配置")
            try await runner.apply(yaml:yaml,settings:settings)
            let disabledIPv6 = try JSONSerialization.jsonObject(with:await api.data(["configs"])) as! [String:Any]
            try check(disabledIPv6["ipv6"] as? Bool == false && ((disabledIPv6["tun"] as? [String:Any])?["inet6-address"] as? [String] ?? []).isEmpty,"关闭IPv6后真实内核清除TUN IPv6配置")
            var nodes = try await api.proxies()
            try check(nodes["默认代理"]?.type == "URLTest","本地策略覆盖为自动组")
            try check(nodes["默认代理"]?.all == ["日本 · 东京 01","日本 · 大阪 01"],"自动候选保留顺序并排除嵌套组")
            try check(nodes["日本 · 东京 01"]?.providerName == nil,"原生空 provider 名称规范为普通节点")
            let tokyo = try await api.latency(node:nodes["日本 · 东京 01"]!,testURL:settings.testURL,timeout:settings.testTimeout)
            let osaka = try await api.latency(node:nodes["日本 · 大阪 01"]!,testURL:settings.testURL,timeout:settings.testTimeout)
            try check(tokyo > 0 && osaka > tokyo,"真实代理测速与延迟差")
            var rejected = false
            do { _ = try await api.latency(node:nodes["日本 · 东京 04"]!,testURL:settings.testURL,timeout:settings.testTimeout) } catch { rejected = true }
            try check(rejected,"不可用节点测速失败")
            try await health(api,"默认代理")
            try await waitForSelection(api,group:"默认代理",node:"日本 · 东京 01")
            try check(try await route(port:settings.mixedPort) == "tokyo","规则模式请求使用最低延迟节点")
            try await api.select(group:"默认代理",node:"日本 · 大阪 01")
            nodes = try await api.proxies()
            try check(nodes["默认代理"]?.fixed == "日本 · 大阪 01","手动选择固定自动组")
            try check(try await route(port:settings.mixedPort) == "osaka","固定选择影响实际请求")
            try await api.clearFixed(group:"默认代理")
            try await health(api,"默认代理")
            try await waitForSelection(api,group:"默认代理",node:"日本 · 东京 01")
            try check(try await route(port:settings.mixedPort) == "tokyo","清除固定后恢复自动选择")
            try await state(["tokyo_down":true])
            _ = try? await route(port:settings.mixedPort)
            try await health(api,"默认代理")
            try await waitForSelection(api,group:"默认代理",node:"日本 · 大阪 01")
            try check(try await route(port:settings.mixedPort) == "osaka","当前节点断线后切换到大阪")
            try await state(["tokyo_down":false])
            try await health(api,"默认代理")
            try await waitForSelection(api,group:"默认代理",node:"日本 · 东京 01")
            try check(try await route(port:settings.mixedPort) == "tokyo","节点恢复后重新选择最低延迟")

            try await api.patch(["mode":"direct"])
            try check(try await route(port:settings.mixedPort) == "direct","直连模式绕过代理节点")
            try await api.patch(["mode":"global"])
            try await api.select(group:"GLOBAL",node:"日本 · 大阪 01")
            try check(try await route(port:settings.mixedPort) == "osaka","全局模式使用 GLOBAL 选择")
            try await api.patch(["mode":"rule"])

            var badRejected = false
            var validationMessage = ""
            let invalidYAML = "proxies:\n  - {name: invalid, type: invalid}\nrules: [MATCH,DIRECT]\n"
            let invalidFile = home.appendingPathComponent("invalid-validation.yaml")
            try Data(invalidYAML.utf8).write(to:invalidFile)
            do { try await runner.validate(file:invalidFile) } catch { validationMessage = error.localizedDescription }
            try check(validationMessage.contains("配置校验失败") && !validationMessage.contains("level=info") && !validationMessage.contains("configuration file ") && validationMessage.count <= 620,"配置失败只展示有界的实际错误，不夹带启动日志和临时路径")
            do { try await runner.apply(yaml:invalidYAML,settings:settings) } catch { badRejected = true }
            try check(badRejected,"错误配置被内核拒绝")
            try check(try await route(port:settings.mixedPort) == "tokyo","配置应用失败后实际路由恢复")
            try await state(["invalid":true])
            var updateRejected = false
            do { _ = try await SubscriptionFetcher.fetch("http://127.0.0.1:18770/subscription") } catch { updateRejected = true }
            try check(updateRejected,"无效订阅更新被拒绝")
            try check(try await route(port:settings.mixedPort) == "tokyo","无效更新不影响当前配置")
            try await state(["invalid":false])

            let fallback = GroupStrategy(profileID:profileID,group:"默认代理",mode:.fallback,interval:10)
            let (fallbackYAML,fallbackFile) = try await runner.prepare(source:download.content,settings:settings,rules:[],strategies:[fallback])
            try await runner.validate(file:fallbackFile); try await runner.apply(yaml:fallbackYAML,settings:settings)
            try await health(api,"默认代理"); try await waitForSelection(api,group:"默认代理",node:"日本 · 东京 01")
            try await state(["tokyo_down":true]); try await health(api,"默认代理")
            try await waitForSelection(api,group:"默认代理",node:"日本 · 大阪 01")
            try check(try await route(port:settings.mixedPort) == "osaka","Fallback 当前节点失效后使用下一候选")
            try await state(["tokyo_down":false])

            let providerSource = """
            proxy-providers:
              本地节点: {type: http, url: 'http://127.0.0.1:18770/provider', interval: 60}
            proxy-groups:
              - {name: 默认代理, type: select, use: [本地节点]}
            rules: ['MATCH,默认代理']
            """
            let (providerYAML,providerFile) = try await runner.prepare(source:providerSource,settings:settings,rules:[])
            try await runner.validate(file:providerFile); try await runner.apply(yaml:providerYAML,settings:settings)
            let providers = try await api.providers()
            guard var providerNode = providers["本地节点"]?.proxies?.first(where:{$0.name == "日本 · 东京 01"}) else { throw LumaError.message("未加载 HTTP provider 节点") }
            providerNode.providerName = "本地节点"
            try check(try await api.latency(node:providerNode,testURL:settings.testURL,timeout:settings.testTimeout) > 0,"真实 provider 专用测速接口")
            try await state(["invalid":true])
            let (cachedYAML,cachedFile) = try await runner.prepare(source:providerSource,settings:settings,rules:[])
            let cachedDefinitions = try ConfigComposer.parse(cachedYAML)["proxy-providers"] as! [String:[String:Any]]
            try check(FileManager.default.fileExists(atPath:cachedDefinitions["本地节点"]!["path"] as! String),"重建配置时保留同一 provider 的有效缓存")
            try await runner.validate(file:cachedFile); try await runner.apply(yaml:cachedYAML,settings:settings)
            try check(try await route(port:settings.mixedPort) == "tokyo","provider 返回无效数据时缓存仍可代理实际请求")
            try await state(["invalid":false])

            let uri = "http://127.0.0.1:18771#fixture-tokyo"
            let (uriYAML,uriFile) = try await runner.prepare(source:Data(uri.utf8).base64EncodedString(),settings:settings,rules:[])
            try await runner.validate(file:uriFile); try await runner.apply(yaml:uriYAML,settings:settings)
            let uriProviders = try await api.providers()
            try check(uriProviders["订阅节点"]?.proxies?.contains(where:{$0.name == "fixture-tokyo"}) == true,"Base64 URI 由原生内核导入")
            try check(try await route(port:settings.mixedPort) == "tokyo","URI provider 节点可代理实际请求")
            let unavailableProvider = providerSource.replacingOccurrences(of:"/provider'",with:"/missing-provider'")
            let (unavailableYAML,unavailableFile) = try await runner.prepare(source:unavailableProvider,settings:settings,rules:[])
            try await runner.validate(file:unavailableFile)
            var providerRejected = false
            do { try await runner.apply(yaml:unavailableYAML,settings:settings) } catch { providerRejected = true }
            try check(providerRejected,"没有有效节点的 HTTP provider 不提交")
            try check(try await route(port:settings.mixedPort) == "tokyo","provider 初始化失败后恢复可用配置")
            let transfer = Process()
            transfer.executableURL = URL(fileURLWithPath:"/usr/bin/curl")
            transfer.arguments = ["--disable","--silent","--max-time","40","--proxy","http://127.0.0.1:\(settings.mixedPort)","--noproxy","","http://127.0.0.1:18772/hold"]
            transfer.standardOutput = FileHandle.nullDevice; transfer.standardError = FileHandle.nullDevice
            try transfer.run()
            defer { if transfer.isRunning { transfer.terminate() } }
            var captured: LiveConnection?
            for _ in 0..<40 {
                captured = try await api.connections().connections?.first { $0.metadata.destinationPort == "18772" && $0.metadata.type == "HTTP" && $0.download > 0 }
                if captured != nil { break }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            guard let connection = captured else { throw LumaError.message("未捕获真实流式代理连接") }
            let resolved = await ConnectionProcesses.enrich([connection],mixedPort:settings.mixedPort)[0]
            try check(resolved.processName == "curl" && resolved.metadata.processPath?.hasSuffix("/curl") == true,"macOS 查询真实连接进程及路径")
            if connection.metadata.processPath?.isEmpty != false {
                let mismatched = await ConnectionProcesses.enrich([connection],mixedPort:63790)[0]
                try check(mismatched.metadata.processPath?.isEmpty != false,"不同代理端口不错误归属进程")
            }
            try check(connection.metadata.network == "tcp" && connection.rule != nil && !(connection.chains ?? []).isEmpty && connection.download > 0,"真实连接包含协议、命中规则、代理链与流量")
            try await api.closeConnection(connection.id)
            let remaining = try await api.connections().connections ?? []
            try check(!remaining.contains(where:{$0.id == connection.id}),"关闭单个正在传输的真实连接")
            try await runner.apply(yaml:yaml,settings:settings)
            try await api.select(group:"默认代理",node:"日本 · 大阪 01")
            try await api.select(group:"GLOBAL",node:"日本 · 大阪 01")
            let selections = GroupSelection.capture(try await api.proxies())
            try check(await runner.stop(),"切换后台前确认旧内核退出")
            let second = CoreRunner(binary:binary,home:home.appendingPathComponent("transfer-backend"),secret:secret)
            do {
                let (secondYAML,secondFile) = try await second.prepare(source:download.content,settings:settings,rules:[],strategies:[strategy])
                try await second.validate(file:secondFile)
                try await second.start(yaml:secondYAML,settings:settings)
                try await GroupSelection.restore(selections,api:api)
                let restored = try await api.proxies()
                try check(restored["GLOBAL"]?.now == "日本 · 大阪 01","不同后台保留手动选择")
                try check(restored["默认代理"]?.fixed == "日本 · 大阪 01","不同后台保留自动组的手动固定")
                try check(try await route(port:settings.mixedPort) == "osaka","恢复后台选择后实际请求经过原节点")
                try await api.clearFixed(group:"默认代理")
                let automatic = GroupSelection.capture(try await api.proxies())
                try await api.select(group:"默认代理",node:"日本 · 大阪 01")
                try await GroupSelection.restore(automatic,api:api)
                try check(try await api.proxies()["默认代理"]?.fixed?.isEmpty != false,"恢复自动状态时清除后台残留固定")
                let stream = Task { try? await api.stream("traffic") { _ in } }
                _ = try await api.version()
                try check(await second.stop(),"有控制流连接时确认后台内核退出")
                stream.cancel()
                try await runner.start(yaml:yaml,settings:settings)
                try await GroupSelection.restore(automatic,api:api)
                try check(await runner.running,"后台停止后原端口立即可重新启动")
            } catch { await second.stop(); throw error }
            let stopped = await runner.stop()
            let stillRunning = await runner.running
            try check(stopped && !stillRunning,"隔离内核正常退出")
            print("functional integration passed: \(passed) assertions")
        } catch {
            await runner.stop()
            try? await state(["invalid":false,"tokyo_down":false,"osaka_down":false])
            throw error
        }
    }
    private static func health(_ api: MihomoAPI,_ group: String) async throws {
        _ = try await api.data(["providers","proxies",group,"healthcheck"],timeout:5)
    }
    private static func waitForSelection(_ api: MihomoAPI,group: String,node: String) async throws {
        // Mihomo caches URLTest choice for up to 10 seconds; verify eventual
        // switching across that window rather than assuming an immediate label change.
        for _ in 0..<200 {
            if try await api.proxies()[group]?.now == node { return }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        throw LumaError.message("\(group) 未切换到 \(node)")
    }
    private static func route(port: Int) async throws -> String {
        try await Task.detached {
            let process = Process(); let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath:"/usr/bin/curl")
            process.arguments = ["--disable","--silent","--fail","--proxy","http://127.0.0.1:\(port)","--noproxy","","--max-time","5","http://127.0.0.1:18772/data"]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let object = try JSONSerialization.jsonObject(with:data) as? [String:Any], let route = object["route"] as? String else { throw LumaError.message("本地代理请求失败") }
            return route
        }.value
    }
}
