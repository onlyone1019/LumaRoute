import AppKit
import SwiftUI
import LumaRouteCore

/// Compiled with the actual store and views. The Python runner changes only
/// service selection in a generated AppStore copy, keeping tests off installed XPC.
@main struct ProxyChainsCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                let store = try await check()
                if CommandLine.arguments.contains("--ui") {
                    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:820,height:720),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
                    window.title = "LumaRoute · 链式代理验证"
                    let hosted = NSHostingView(rootView:ProxiesPage().environmentObject(store).padding(28).controlSize(.large))
                    hosted.sizingOptions = []
                    window.contentView = hosted
                    window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps:true)
                    // NSApplication retains its windows until this fixture exits.
                    window.isReleasedWhenClosed = false
                } else { await store.shutdown(); exit(0) }
            } catch { FileHandle.standardError.write(Data(("FAIL \(error)\n").utf8)); exit(1) }
        }
        app.run()
    }
    @MainActor static func check() async throws -> AppStore {
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath:args[1]),binary = URL(fileURLWithPath:args[2])
        let upstream = Int(args[3])!,landing = Int(args[4])!,origin = Int(args[5])!
        let app = AppStore(); app.store = try LocalStore(root:root)
        app.secret = "isolated-chain-fixture"
        app.database.settings.mixedPort = Int(args[6])!; app.database.settings.controllerPort = Int(args[7])!
        app.database.settings.testURL = "http://127.0.0.1:\(origin)/204"
        app.runner = CoreRunner(binary:binary,home:root.appendingPathComponent("runtime"),secret:app.secret)
        app.page = .proxies
        let nodes = """
        proxies:
          - {name: HK, type: http, server: 127.0.0.1, port: \(upstream)}
          - {name: 'VPS.(美国)+', type: http, server: 127.0.0.1, port: \(landing)}
        """
        let sources = [
            nodes+"\nproxy-groups: [{name: Airport, type: select, proxies: [HK]}]\nrules: ['MATCH,Airport']",
            "proxy-providers: {Remote: {type: inline, payload: [{name: HK, type: http, server: 127.0.0.1, port: \(upstream)}, {name: 'VPS.(美国)+', type: http, server: 127.0.0.1, port: \(landing)}], override: {additional-prefix: '[P] '}}}\nproxy-groups: [{name: Airport, type: select, use: [Remote], filter: HK}]\nrules: ['MATCH,Airport']",
            "http://127.0.0.1:\(upstream)#HK\nhttp://127.0.0.1:\(landing)#VPS.(美国)+",
            "proxy-providers: {Remote: {type: http, url: 'http://127.0.0.1:\(origin)/provider', interval: 3600}}\nproxy-groups: [{name: Airport, type: select, use: [Remote], filter: HK}]\nrules: ['MATCH,Airport']"
        ]
        do { for (index,source) in sources.enumerated() {
            let profile = Profile(name:["本地节点","提供器节点","URI 节点","远程提供器"][index],isRemote:false)
            app.database.profiles = [profile]; app.database.activeProfileID = profile.id
            var chain = ProxyChain(); chain.name = "香港到美国 VPS"; chain.upstream = "Airport"; chain.landing = "VPS.(美国)+"
            if index == 1 { chain.upstream = "[P] HK"; chain.upstreamProvider = "Remote"; chain.landing = "[P] VPS.(美国)+"; chain.landingProvider = "Remote" }
            if index == 2 { chain.upstream = "HK"; chain.upstreamProvider = "订阅节点"; chain.landingProvider = "订阅节点" }
            if index == 3 { chain.landingProvider = "Remote" }
            app.database.customRules = [CustomRule(type:"DOMAIN",payload:"origin.fixture.test",target:chain.groupName)]
            try app.store.commit(app.database,profiles:[profile.id:source])
            try await app.saveProxyChains([chain],profileID:profile.id)
            let live = try await app.api.proxies()
            guard let group = live[chain.groupName],group.all?.count == 1,group.all?.first != "REJECT" else { throw LumaError.message("链路未精确选中提供器落地节点：\(index)") }
            _ = try request(origin:origin,path:"reset")
            let response = try request(proxy:app.database.settings.mixedPort,origin:origin,path:"chain")
            let metrics = try request(origin:origin,path:"events")
            guard response == "origin",metrics.contains("upstream:127.0.0.1:\(landing)"),metrics.contains("landing:origin.fixture.test:80") else { throw LumaError.message("链路没有经过两跳：\(index) \(metrics)") }
            let saved = try LocalStore(root:root).load()
            guard saved.profiles.first?.proxyChains == [chain],try app.store.profileContent(profile.id) == source else { throw LumaError.message("保存修改了原订阅") }
            print("PASS \(profile.name): actual Mihomo traffic traverses upstream → landing → origin; original subscription and SQLite state verified")
            // Referenced chains cannot silently disappear or fall through to DIRECT.
            do { try await app.saveProxyChains([],profileID:profile.id); throw CheckFailure.expectedRejection } catch CheckFailure.expectedRejection { throw CheckFailure.expectedRejection } catch {}
            guard app.activeProfile?.proxyChains == [chain] else { throw CheckFailure.expectedRejection }
            var invalid = chain; invalid.landing = "missing"; invalid.landingProvider = nil
            do { try await app.saveProxyChains([invalid],profileID:profile.id); throw CheckFailure.expectedRejection } catch CheckFailure.expectedRejection { throw CheckFailure.expectedRejection } catch {}
            guard app.activeProfile?.proxyChains == [chain] else { throw CheckFailure.expectedRejection }
            if index == 0 {
                app.store = try LocalStore(root:root,readOnly:true)
                var modified = chain; modified.upstream = "HK"
                do { try await app.saveProxyChains([modified],profileID:profile.id); throw CheckFailure.expectedRejection } catch CheckFailure.expectedRejection { throw CheckFailure.expectedRejection } catch {}
                let active = try ConfigComposer.parse(String(contentsOf:root.appendingPathComponent("runtime/active.yaml"),encoding:.utf8))
                let clone = (active["proxies"] as? [[String:Any]])?.first { $0["name"] as? String == chain.nodePrefix+chain.landing }
                guard app.activeProfile?.proxyChains == [chain],clone?["dialer-proxy"] as? String == "Airport" else { throw LumaError.message("SQLite 保存失败未恢复原链路") }
                app.store = try LocalStore(root:root)
                print("PASS failed SQLite save rolls back the running core and committed chain; invalid and referenced removals preserve state")
            }
            if index == 3 {
                var removedNode = chain; removedNode.id = UUID(); removedNode.name = "落地已移除"; removedNode.landing = "removed-node"
                try await app.saveProxyChains([chain,removedNode],profileID:profile.id)
                let missing = try await app.api.proxies()
                guard missing[removedNode.groupName]?.all == ["REJECT"] else { throw LumaError.message("消失的落地节点回退为直连") }
                try await app.saveProxyChains([chain],profileID:profile.id)
                print("PASS a removed provider landing produces REJECT instead of a direct fallback")
            }
            if index < sources.count-1 {
                app.database.customRules = []
                try await app.saveProxyChains([],profileID:profile.id)
                let afterRemoval = try await app.api.proxies()
                guard afterRemoval[chain.groupName] == nil else { throw LumaError.message("删除链路后仍残留策略组") }
            }
        } } catch { await app.shutdown(); throw error }
        return app
    }
    enum CheckFailure: Error { case expectedRejection }
    static func request(proxy: Int? = nil,origin: Int,path: String) throws -> String {
        let task = Process(),output = Pipe()
        task.executableURL = URL(fileURLWithPath:"/usr/bin/curl")
        task.arguments = ["--disable","--silent","--show-error","--fail","--max-time","8","--noproxy",proxy == nil ? "*":""]
            + (proxy.map { ["--proxy","http://127.0.0.1:\($0)"] } ?? [])
            + [proxy == nil ? "http://127.0.0.1:\(origin)/\(path)":"http://origin.fixture.test/\(path)"]
        task.standardOutput = output
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw LumaError.message("本地链路请求失败") }
        return String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
    }
}
