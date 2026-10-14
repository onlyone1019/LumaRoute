import Foundation
import LumaRouteCore

@main
struct LumaRouteCLI {
    static func main() async {
        do {
            let arguments=Array(CommandLine.arguments.dropFirst())
            guard let action=arguments.first else { print("usage: LumaRouteCLI validate <config> <core> | smoke <core> <workdir>"); return }
            if action=="verify" {
                try RegressionSuite.run()
            } else if ["rule-subscription-check","rule-catalog-check"].contains(action),arguments.count==3 {
                try await RuleSubscriptionSuite.run(binary:URL(fileURLWithPath:arguments[1]),home:URL(fileURLWithPath:arguments[2]),official:action=="rule-catalog-check")
            } else if action=="geo-check",arguments.count==5 {
                try await GeoSuite.run(binary:URL(fileURLWithPath:arguments[1]),bundled:URL(fileURLWithPath:arguments[2]),manifest:URL(fileURLWithPath:arguments[3]),home:URL(fileURLWithPath:arguments[4]))
            } else if action=="maintenance-check",arguments.count==5 {
                try await MaintenanceSuite.run(manifest:URL(fileURLWithPath:arguments[1]),archive:URL(fileURLWithPath:arguments[2]),binary:URL(fileURLWithPath:arguments[3]),home:URL(fileURLWithPath:arguments[4]))
            } else if action=="lifecycle-check",arguments.count==3 {
                try await LifecycleSuite.run(binary:URL(fileURLWithPath:arguments[1]),home:URL(fileURLWithPath:arguments[2]))
            } else if action=="lifecycle-hold",arguments.count==3 {
                try await LifecycleSuite.hold(binary:URL(fileURLWithPath:arguments[1]),home:URL(fileURLWithPath:arguments[2]))
            } else if action=="fixture-check",arguments.count==3 {
                try await FunctionalSuite.run(binary:URL(fileURLWithPath:arguments[1]),home:URL(fileURLWithPath:arguments[2]))
            } else if action=="subscription-check",arguments.count==3 {
                guard let address=readLine(),!address.isEmpty else { throw LumaError.message("通过标准输入提供订阅地址") }
                let download=try await SubscriptionFetcher.fetch(address)
                let count=try ConfigComposer.nodeCount(download.content)
                print("subscription downloaded: nodes=\(count), usage=\(download.usage != nil)")
                var settings=NetworkSettings(); settings.mixedPort=19890; settings.controllerPort=19891
                let secret=UUID().uuidString+UUID().uuidString
                let runner=CoreRunner(binary:URL(fileURLWithPath:arguments[1]),home:URL(fileURLWithPath:arguments[2]),secret:secret)
                let (yaml,file)=try await runner.prepare(source:download.content,settings:settings,rules:[])
                try await runner.validate(file:file)
                print("real subscription configuration validated")
                try await runner.start(yaml:yaml,settings:settings)
                do {
                    let api=MihomoAPI(port:settings.controllerPort,secret:secret)
                    let proxies=try await api.proxies()
                    let nodes=proxies.values.filter { !$0.isGroup && $0.name.range(of:"日本|东京|大阪|japan|tokyo|osaka|🇯🇵",options:[.regularExpression,.caseInsensitive]) != nil }.sorted { $0.name < $1.name }
                    var tested=0; var passed=0
                    for node in nodes.prefix(6) {
                        tested += 1
                        do { let delay=try await api.latency(node:node,testURL:settings.testURL,timeout:settings.testTimeout); passed += 1; print("latency \(Redactor.clean(node.name)): \(delay) ms") }
                        catch { print("latency \(Redactor.clean(node.name)): \(Redactor.clean(error.localizedDescription))") }
                    }
                    if let group=proxies.values.first(where:{["URLTest","Fallback"].contains($0.type) && !($0.all ?? []).isEmpty}),let name=group.all?.first {
                        try await api.select(group:group.name,node:name)
                        let fixed=try await api.proxies()[group.name]
                        guard fixed?.now == name else { throw LumaError.message("手动节点切换未生效") }
                        try await api.clearFixed(group:group.name)
                        let resumed=try await api.proxies()[group.name]
                        guard resumed?.fixed?.isEmpty != false else { throw LumaError.message("恢复自动选择未生效") }
                        print("manual selection and resume automatic: passed")
                    }
                    print("real core subscription check: nodes=\(count), Japanese samples=\(tested), reachable=\(passed), groups=\(proxies.values.filter(\.isGroup).count)")
                    await runner.stop()
                } catch { await runner.stop(); throw error }
            } else if action=="validate",arguments.count==3 {
                let home=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("LumaRoute-validate-"+UUID().uuidString)
                let runner=CoreRunner(binary:URL(fileURLWithPath:arguments[2]),home:home,secret:UUID().uuidString+UUID().uuidString)
                var settings=NetworkSettings(); settings.mode = .direct
                let source=try String(contentsOfFile:arguments[1],encoding:.utf8)
                let (_,file)=try await runner.prepare(source:source,settings:settings,rules:[])
                try await runner.validate(file:file)
                print("configuration valid")
            } else if action=="smoke",arguments.count==3 {
                let home=URL(fileURLWithPath:arguments[2])
                var settings=NetworkSettings(); settings.mixedPort=19890; settings.controllerPort=19891; settings.mode = .direct
                let secret=UUID().uuidString+UUID().uuidString
                let runner=CoreRunner(binary:URL(fileURLWithPath:arguments[1]),home:home,secret:secret)
                let (yaml,file)=try await runner.prepare(source:nil,settings:settings,rules:[])
                try await runner.validate(file:file)
                try await runner.start(yaml:yaml,settings:settings)
                do {
                    let api=MihomoAPI(port:settings.controllerPort,secret:secret)
                    let version=try await api.version()
                    let proxies=try await api.proxies()
                    let connections=try await api.connections()
                    _ = try await api.rules()
                    try await api.patch(["mode":"rule"])
                    try await api.select(group:"默认代理",node:"DIRECT")
                    print("version=\(version) proxies=\(proxies.count) connections=\(connections.connections?.count ?? 0)")
                    await runner.stop()
                    print("isolated core smoke test passed")
                } catch { await runner.stop(); throw error }
            } else { throw LumaError.message("无效命令参数") }
        } catch { FileHandle.standardError.write(Data((Redactor.clean(error.localizedDescription)+"\n").utf8)); exit(1) }
    }
}

