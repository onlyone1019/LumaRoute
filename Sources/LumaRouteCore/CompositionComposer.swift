import Foundation
import Yams

/// Namespaces each source before merging. Only the selected base contributes
/// global DNS/rules; include-all groups stay scoped to their original source.
public enum CompositionComposer {
    public static func compose(_ composition: SubscriptionComposition,profiles: [Profile],contents: [UUID:String],settings: NetworkSettings = NetworkSettings(),additionalTargets: [String] = []) throws -> String {
        try composition.validate(profiles:profiles)
        let aliases = composition.aliases(profiles:profiles)
        var mergedNodes: [[String:Any]] = [], mergedGroups: [[String:Any]] = []
        var mergedProviders: [String:Any] = [:], rawProviders: [String:String] = [:]
        var base: [String:Any] = [:]
        var allNodes: [String] = [], allProviders: [String] = []
        var memberNodeDNS: [String:[String]] = [:],baseNodeHosts: Set<String> = []
        for id in composition.profileIDs {
            guard let source = contents[id] else { throw LumaError.message("组合中的订阅缓存不存在，请先更新订阅") }
            let parsed = try ConfigComposer.parse(source)
            let prefix = "["+aliases[id]!+"] "
            var providers = parsed["proxy-providers"] as? [String:[String:Any]] ?? [:]
            if let raw = parsed["_lumaroute_raw_provider"] as? String {
                providers = ["订阅节点":["type":"file"]]
                rawProviders[prefix+"订阅节点"] = raw
            }
            let nodes = parsed["proxies"] as? [[String:Any]] ?? []
            let groups = parsed["proxy-groups"] as? [[String:Any]] ?? []
            let defined = (nodes+groups).compactMap { $0["name"] as? String }
            guard Set(defined).count == defined.count else { throw LumaError.message("订阅中的节点或策略组名称重复，请先修正该订阅") }
            let known = Set(defined)
            func reference(_ value: String) -> String {
                if known.contains(value) { return prefix+value }
                return ["DIRECT","REJECT","REJECT-DROP","PASS","COMPATIBLE","GLOBAL"].contains(value) ? value:prefix+value
            }
            func references(_ value: Any) -> Any {
                if let object = value as? [String:Any] {
                    return object.mapValues { child in references(child) }.map { key,child -> (String,Any) in
                        if ["proxy","dialer-proxy","default-selected","empty-fallback"].contains(key),let name = child as? String { return (key,reference(name)) }
                        return (key,child)
                    }.reduce(into:[String:Any]()) { $0[$1.0] = $1.1 }
                }
                if let list = value as? [Any] { return list.map { references($0) } }
                return value
            }
            func dnsReferences(_ value: Any) -> Any {
                if let object = value as? [String:Any] { return object.mapValues { dnsReferences($0) } }
                if let list = value as? [Any] { return list.map { dnsReferences($0) } }
                if let text = value as? String,let hash = text.firstIndex(of:"#") {
                    let parts = text[text.index(after:hash)...].split(separator:"&",omittingEmptySubsequences:false).map(String.init)
                    return String(text[...hash])+parts.map { known.contains($0) ? reference($0):$0 }.joined(separator:"&")
                }
                return value
            }
            let nodeNames = nodes.compactMap { ($0["name"] as? String).map(reference) }
            let providerNames = providers.keys.sorted().map { prefix+$0 }
            if id == composition.baseProfileID {
                baseNodeHosts = Set(nodes.compactMap { ($0["server"] as? String).flatMap(CompositionNodeDNS.host) })
            } else if let dns = parsed["dns"] {
                let policies = CompositionNodeDNS.policies(nodes:nodes,dns:dnsReferences(dns) as? [String:Any] ?? [:])
                for (domain,servers) in policies where memberNodeDNS[domain] == nil { memberNodeDNS[domain] = servers }
            }
            for node in nodes {
                guard let name = node["name"] as? String else { throw LumaError.message("订阅节点缺少名称") }
                var next = references(node) as! [String:Any]; next["name"] = reference(name)
                mergedNodes.append(next)
            }
            for (name,provider) in providers {
                var next = references(provider) as! [String:Any]
                var override = next["override"] as? [String:Any] ?? [:]
                override["additional-prefix"] = prefix+(override["additional-prefix"] as? String ?? "")
                next["override"] = override
                // An empty provider must not try to download through its own
                // yet-empty fallback group. Preserve explicitly configured routes.
                if next["type"] as? String == "http",next["proxy"] == nil { next["proxy"] = "DIRECT" }
                mergedProviders[prefix+name] = next
            }
            for group in groups {
                guard let name = group["name"] as? String else { throw LumaError.message("订阅策略组缺少名称") }
                var next = references(group) as! [String:Any]
                next["name"] = reference(name)
                var members = (group["proxies"] as? [String] ?? []).map(reference)
                var uses = (group["use"] as? [String] ?? []).map { prefix+$0 }
                if group["include-all"] as? Bool == true || group["include-all-proxies"] as? Bool == true { members += nodeNames }
                if group["include-all"] as? Bool == true || group["include-all-providers"] as? Bool == true { uses = providerNames }
                next["proxies"] = unique(members); next["use"] = unique(uses)
                for key in ["include-all","include-all-proxies","include-all-providers"] { next.removeValue(forKey:key) }
                mergedGroups.append(next)
            }
            // Per-subscription groups contain its nodes only, including provider nodes.
            mergedGroups.append(["name":composition.group(for:id,profiles:profiles),"type":"select","proxies":nodeNames,"use":providerNames,"empty-fallback":"REJECT"])
            allNodes += nodeNames; allProviders += providerNames
            if id == composition.baseProfileID {
                base = references(parsed) as! [String:Any]
                if let dns = parsed["dns"] { base["dns"] = dnsReferences(dns) }
                func rule(_ text: String) -> String {
                    var fields = text.components(separatedBy:",")
                    guard fields.count >= 2,fields[0].uppercased() != "SUB-RULE" else { return text }
                    let index = fields.last?.lowercased() == "no-resolve" ? fields.count-2:fields.count-1
                    fields[index] = reference(fields[index].trimmingCharacters(in:.whitespaces))
                    return fields.joined(separator:",")
                }
                var rules = (parsed["rules"] as? [String] ?? []).map(rule)
                let fallback = composition.fallbackProfileID.map { composition.group(for:$0,profiles:profiles) } ?? SubscriptionComposition.aggregateGroup
                if let index = rules.firstIndex(where:{["MATCH","FINAL"].contains($0.components(separatedBy:",")[0].uppercased())}) {
                    rules = Array(rules[..<index])+["MATCH,"+fallback]
                } else { rules.append("MATCH,"+fallback) }
                base["rules"] = rules
                if var ruleProviders = base["rule-providers"] as? [String:[String:Any]] {
                    for name in Array(ruleProviders.keys) where ruleProviders[name]?["type"] as? String == "http" && ruleProviders[name]?["proxy"] == nil {
                        ruleProviders[name]?["proxy"] = "DIRECT"
                    }
                    base["rule-providers"] = ruleProviders
                }
                if let subrules = parsed["sub-rules"] as? [String:[String]] { base["sub-rules"] = subrules.mapValues { $0.map(rule) } }
            }
        }
        mergedGroups.append(["name":SubscriptionComposition.automaticGroup,"type":"url-test","proxies":allNodes,"use":allProviders,"url":settings.testURL,"timeout":settings.testTimeout,"interval":300,"lazy":true,"empty-fallback":"REJECT","exclude-type":"Direct|Reject|Pass"])
        mergedGroups.append(["name":SubscriptionComposition.aggregateGroup,"type":"select","proxies":[SubscriptionComposition.automaticGroup]+allNodes,"use":allProviders,"empty-fallback":"REJECT"])
        let targets = Set(mergedGroups.compactMap { $0["name"] as? String } + ["DIRECT","REJECT"] + additionalTargets)
        for route in composition.domainRoutes where route.enabled {
            if let target = route.target,!targets.contains(target) { throw LumaError.message("分流规则的目标策略组已不存在，请重新选择或停用规则") }
        }
        let primary = [SubscriptionComposition.aggregateGroup,SubscriptionComposition.automaticGroup] + composition.profileIDs.map { composition.group(for:$0,profiles:profiles) }
        let ordered = primary.compactMap { name in mergedGroups.first { $0["name"] as? String == name } } + mergedGroups.filter { !primary.contains($0["name"] as? String ?? "") }
        base["proxies"] = mergedNodes; base["proxy-groups"] = ordered; base["proxy-providers"] = mergedProviders
        base.removeValue(forKey:"_lumaroute_raw_provider")
        let scoped = memberNodeDNS.filter { !baseNodeHosts.contains($0.key) }
        if !scoped.isEmpty {
            var dns = base["dns"] as? [String:Any] ?? [:]
            var policy = dns["proxy-server-nameserver-policy"] as? [String:Any] ?? [:]
            for (domain,servers) in scoped { policy[domain] = servers }
            dns["proxy-server-nameserver-policy"] = policy
            // Mihomo only enables this policy when bootstrap DNS is nonempty.
            if CompositionNodeDNS.servers(dns["proxy-server-nameserver"]) == nil {
                dns["proxy-server-nameserver"] = CompositionNodeDNS.servers(dns["nameserver"]) ?? ["https://dns.alidns.com/dns-query","https://doh.pub/dns-query"]
            }
            base["dns"] = dns
        }
        if !rawProviders.isEmpty { base["_lumaroute_raw_providers"] = rawProviders }
        let yaml = try Yams.dump(object:base,allowUnicode:true,sortKeys:true)
        guard yaml.utf8.count <= 8*1024*1024 else { throw LumaError.message("组合配置超过 8 MB，请减少参与的订阅") }
        return yaml
    }
    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []; return values.filter { seen.insert($0).inserted }
    }
}
