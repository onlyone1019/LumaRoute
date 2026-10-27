import Foundation
import Yams

/// An overlay owned by one profile; subscription refreshes never overwrite it.
public struct ProxyChain: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name = ""
    public var enabled = true
    public var upstream = ""
    public var upstreamProvider: String?
    public var landing = ""
    public var landingProvider: String?
    public init() {}
    public var groupName: String { "链式 · " + name }
    public var nodePrefix: String { "链路落地 · " + name + " → " }
    public var providerName: String { "链路来源 · " + name }
    public func validate() throws {
        guard !name.isEmpty,name == name.trimmingCharacters(in:.whitespacesAndNewlines),name.count <= 40,
              !name.contains(","),!name.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
              !upstream.isEmpty,!landing.isEmpty,upstream != landing,
              !["DIRECT","REJECT","REJECT-DROP","PASS","PASS-RULE","COMPATIBLE","GLOBAL"].contains(upstream) else {
            throw LumaError.message("请填写 1 至 40 个字的链路名称，并选择不同的前置和落地节点")
        }
    }
}

public enum ProxyChainComposer {
    public static func compose(source: String,chains: [ProxyChain],settings: NetworkSettings = NetworkSettings()) throws -> String {
        guard !chains.isEmpty else { return source }
        guard chains.count <= 32,Set(chains.map(\.id)).count == chains.count,
              Set(chains.map(\.groupName)).count == chains.count else { throw LumaError.message("链路名称不能重复，每个配置最多保存 32 条链路") }
        for chain in chains { try chain.validate() }
        let active = chains.filter(\.enabled)
        guard !active.isEmpty else { return source }
        var config = try ConfigComposer.parse(source)
        var nodes = config["proxies"] as? [[String:Any]] ?? []
        var groups = config["proxy-groups"] as? [[String:Any]] ?? []
        var providers = config["proxy-providers"] as? [String:[String:Any]] ?? [:]
        let originalNodes = nodes,originalProviders = providers
        let nodeNames = nodes.compactMap { $0["name"] as? String }
        if config["proxy-groups"] == nil {
            groups = [
                ["name":"默认代理","type":"select","proxies":["自动选择"]+nodeNames],
                ["name":"自动选择","type":"url-test","proxies":nodeNames,"use":providers.keys.sorted(),"url":settings.testURL,"interval":60,"tolerance":50]
            ]
            if config["rules"] == nil { config["rules"] = ["MATCH,默认代理"] }
        }
        let defined = Set(nodeNames + groups.compactMap { $0["name"] as? String })
        let chainNames = Set(chains.map(\.groupName))
        guard defined.isDisjoint(with:chainNames) else { throw LumaError.message("链路名称与已有策略组或节点重名，请更换名称") }
        guard active.allSatisfy({ !defined.contains($0.nodePrefix+$0.landing) && !defined.contains($0.providerName+" · 前置") && originalProviders[$0.providerName] == nil }) else {
            throw LumaError.message("链路生成的节点或来源与已有配置重名，请更换链路名称")
        }

        // Freeze automatic membership before adding copies, so original groups
        // cannot accidentally select a chain or recurse through its landing node.
        for index in groups.indices {
            if groups[index]["include-all"] as? Bool == true || groups[index]["include-all-proxies"] as? Bool == true {
                let members = groups[index]["proxies"] as? [String] ?? []
                groups[index]["proxies"] = members + nodeNames.filter { !members.contains($0) }
            }
            if groups[index]["include-all"] as? Bool == true || groups[index]["include-all-providers"] as? Bool == true {
                groups[index]["use"] = originalProviders.keys.sorted()
            }
            for key in ["include-all","include-all-proxies","include-all-providers"] { groups[index].removeValue(forKey:key) }
        }
        var rawProviders = config["_lumaroute_raw_providers"] as? [String:String] ?? [:]
        if let raw = config["_lumaroute_raw_provider"] as? String { rawProviders["订阅节点"] = raw }

        func checkUpstream(_ chain: ProxyChain) throws {
            if let provider = chain.upstreamProvider {
                guard originalProviders[provider] != nil else { throw LumaError.message("前置节点的订阅来源已不存在，请编辑链路："+chain.name) }
            } else if !defined.contains(chain.upstream) { throw LumaError.message("前置节点或策略组已不存在，请编辑链路："+chain.name) }
            // Existing references may name a new chain even before it is generated.
            // Include provider download routes as they are also dial dependencies.
            var pending = [chain.upstream],seen: Set<String> = []
            if let provider = chain.upstreamProvider { pending.append("provider:"+provider) }
            while let name = pending.popLast() {
                guard seen.insert(name).inserted else { continue }
                if chainNames.contains(name) { throw LumaError.message("前置策略不能引用链式代理，请选择独立的机场节点或策略组") }
                if name.hasPrefix("provider:"),let provider = originalProviders[String(name.dropFirst(9))] {
                    if let proxy = provider["proxy"] as? String { pending.append(proxy) }
                    if let dialer = (provider["override"] as? [String:Any])?["dialer-proxy"] as? String { pending.append(dialer) }
                }
                if let node = originalNodes.first(where:{$0["name"] as? String == name}),let dialer = node["dialer-proxy"] as? String { pending.append(dialer) }
                if let group = groups.first(where:{$0["name"] as? String == name}) {
                    pending += group["proxies"] as? [String] ?? []
                    pending += (group["use"] as? [String] ?? []).map { "provider:"+$0 }
                }
            }
        }
        for chain in active {
            try checkUpstream(chain)
            var dialer = chain.upstream
            if let provider = chain.upstreamProvider {
                // Provider nodes are not global outbound names in Mihomo.
                // A one-node selector makes them addressable by dialer-proxy.
                dialer = chain.providerName+" · 前置"
                groups.append(["name":dialer,"type":"select","hidden":true,"use":[provider],"filter":"^"+NSRegularExpression.escapedPattern(for:chain.upstream)+"$","empty-fallback":"REJECT"])
            }
            var group: [String:Any] = ["name":chain.groupName,"type":"select","empty-fallback":"REJECT"]
            if let node = originalNodes.first(where:{$0["name"] as? String == chain.landing}),chain.landingProvider == nil {
                guard !["direct","reject","pass","pass-rule","passrule"].contains((node["type"] as? String ?? "").lowercased()) else { throw LumaError.message("落地必须选择代理节点") }
                var copy = node
                copy["name"] = chain.nodePrefix+chain.landing
                copy["dialer-proxy"] = dialer
                nodes.append(copy)
                group["proxies"] = [chain.nodePrefix+chain.landing]
            } else if let providerName = chain.landingProvider,var provider = originalProviders[providerName] {
                // Keep provider filters and protocol options intact. Filter the
                // chain group after renaming, using the node's displayed name.
                var override = provider["override"] as? [String:Any] ?? [:]
                override["dialer-proxy"] = dialer
                override["additional-prefix"] = chain.nodePrefix+(override["additional-prefix"] as? String ?? "")
                provider["override"] = override
                // Only the selected landing is tested via the chain group.
                // A duplicate provider must not probe every airport node again.
                provider["health-check"] = ["enable":false]
                if provider["type"] as? String == "http",provider["proxy"] == nil { provider["proxy"] = "DIRECT" }
                providers[chain.providerName] = provider
                if let raw = rawProviders[providerName] { rawProviders[chain.providerName] = raw }
                group["use"] = [chain.providerName]
                group["filter"] = "^"+NSRegularExpression.escapedPattern(for:chain.nodePrefix+chain.landing)+"$"
            } else { throw LumaError.message("落地节点或订阅来源已不存在，请编辑链路："+chain.name) }
            groups.append(group)
        }
        config["proxies"] = nodes; config["proxy-groups"] = groups; config["proxy-providers"] = providers
        if !rawProviders.isEmpty {
            config.removeValue(forKey:"_lumaroute_raw_provider")
            config["_lumaroute_raw_providers"] = rawProviders
        }
        return try Yams.dump(object:config,allowUnicode:true,sortKeys:true)
    }
}
