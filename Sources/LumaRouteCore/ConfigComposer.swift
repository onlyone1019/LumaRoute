import Foundation
import Yams

public enum ConfigComposer {
    // Subscriptions supply routing content and safe client options. New core
    // features must be reviewed here before a subscription can enable them.
    private static let subscriptionKeys: Set<String> = [
        "proxies", "proxy-groups", "proxy-providers", "rule-providers", "rules", "sub-rules",
        "dns", "hosts", "sniffer", "global-client-fingerprint", "global-ua",
        "tcp-concurrent", "unified-delay", "keep-alive-idle", "keep-alive-interval", "disable-keep-alive",
        "geodata-mode", "geodata-loader", "geosite-matcher", "etag-support"
    ]
    public static func parse(_ yaml: String) throws -> [String: Any] {
        guard yaml.utf8.count <= 8 * 1024 * 1024, !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw LumaError.message("配置为空或超过 8 MB") }
        var text = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
        if let decoded = Data(base64Encoded: text, options: .ignoreUnknownCharacters), let decodedText = String(data: decoded, encoding: .utf8), decodedText.contains("://") { text = decodedText }
        let uriLines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !uriLines.isEmpty && uriLines.allSatisfy({ $0.contains("://") && !$0.contains(" ") }) {
            return [
                "_lumaroute_raw_provider": text,
                "proxy-providers": ["订阅节点": ["type": "file", "path": "providers/proxy-0.yaml"]],
                "proxy-groups": [
                    ["name": "默认代理", "type": "select", "proxies": ["自动选择"], "use": ["订阅节点"]],
                    ["name": "自动选择", "type": "url-test", "use": ["订阅节点"], "tolerance": 50]
                ],
                "rules": ["MATCH,默认代理"]
            ]
        }
        let document:Any?
        do { document = try Yams.load(yaml:text) }
        catch { throw LumaError.message("配置文件不是有效的 YAML，请检查缩进、冒号和列表格式") }
        guard let object = document as? [String: Any], !object.isEmpty
        else { throw LumaError.message("不是有效的 YAML 或节点订阅") }
        guard object["proxies"] != nil || object["proxy-providers"] != nil || object["proxy-groups"] != nil || object["rules"] != nil
        else { throw LumaError.message("配置中没有节点、策略组或规则") }
        return object
    }
    public static func nodeCount(_ yaml: String) throws -> Int {
        countNodes(in:try parse(yaml))
    }
    private static func countNodes(in config: [String:Any]) -> Int {
        if let raw = config["_lumaroute_raw_provider"] as? String { return raw.split(whereSeparator: \.isNewline).count }
        return (config["proxies"] as? [Any])?.count ?? 0
    }
    public static func compose(source: String?, settings: NetworkSettings, rules: [CustomRule], secret: String, resourceRoot: URL? = nil, strategies: [GroupStrategy] = [], ruleSubscriptions: [RuleSubscriptionSnapshot] = []) throws -> String {
        try composeDocument(source:source,settings:settings,rules:rules,secret:secret,resourceRoot:resourceRoot,strategies:strategies,ruleSubscriptions:ruleSubscriptions).yaml
    }
    static func composeDocument(source: String?, settings: NetworkSettings, rules: [CustomRule], secret: String, resourceRoot: URL? = nil, strategies: [GroupStrategy] = [], ruleSubscriptions: [RuleSubscriptionSnapshot] = []) throws -> (yaml: String,configuration: [String:Any],metadata: ConfigurationMetadata) {
        guard (1024...65535).contains(settings.mixedPort), (1024...65535).contains(settings.controllerPort),
              settings.mixedPort != settings.controllerPort, (1280...9000).contains(settings.mtu),
              ["system", "mixed", "gvisor", "mips"].contains(settings.stack)
        else { throw LumaError.message("端口、MTU 或协议栈设置无效") }
        var config: [String: Any] = try source.map(parse) ?? [
            "proxies": [], "proxy-groups": [["name": "默认代理", "type": "select", "proxies": ["DIRECT"]]], "rules": ["MATCH,DIRECT"]
        ]
        let nodeCount = countNodes(in:config)
        // Consume internal URI-provider data separately; it is never a core option.
        let raw = config["_lumaroute_raw_provider"] as? String
        let rawProviders = config["_lumaroute_raw_providers"] as? [String:String]
        config = config.filter { subscriptionKeys.contains($0.key) }
        // Listeners, system integration and file paths belong to LumaRoute.
        config["mixed-port"] = settings.mixedPort
        config["external-controller"] = "127.0.0.1:\(settings.controllerPort)"
        config["secret"] = secret
        config["allow-lan"] = false
        config["bind-address"] = "127.0.0.1"
        config["mode"] = settings.mode.rawValue
        config["ipv6"] = settings.ipv6
        config["log-level"] = "info"
        config["find-process-mode"] = "always"
        config["geo-auto-update"] = false
        config["profile"] = ["store-selected": true, "store-fake-ip": true]
        if let raw, let resourceRoot {
            let directory = resourceRoot.appendingPathComponent("providers")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("proxy-0.yaml")
            try Data(raw.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        if let rawProviders,let resourceRoot {
            let providers = config["proxy-providers"] as? [String:Any] ?? [:]
            for (index,name) in providers.keys.sorted().enumerated() {
                if let content = rawProviders[name] {
                    let file = resourceRoot.appendingPathComponent("providers/proxy-\(index).yaml")
                    try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                    try Data(content.utf8).write(to:file,options:.atomic)
                    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
                }
            }
        }
        normalizeProviders(&config, key: "proxy-providers", prefix: "proxy", settings: settings, resourceRoot: resourceRoot)
        normalizeProviders(&config, key: "rule-providers", prefix: "rule", settings: settings, resourceRoot: resourceRoot)
        if config["proxy-groups"] == nil {
            let names = (config["proxies"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            let providers = Array((config["proxy-providers"] as? [String:Any] ?? [:]).keys).sorted()
            if names.isEmpty && providers.isEmpty {
                config["proxy-groups"] = [["name":"默认代理","type":"select","proxies":["DIRECT"]]]
            } else { config["proxy-groups"] = [
                ["name": "默认代理", "type": "select", "proxies": ["自动选择"] + names],
                ["name": "自动选择", "type": "url-test", "proxies": names,"use":providers, "url": settings.testURL, "interval": 60, "tolerance": 50]
            ] }
            if config["rules"] == nil { config["rules"] = ["MATCH,默认代理"] }
        }
        try applyGroupStrategies(strategies,config:&config,settings:settings)
        var tun: [String: Any] = [
            "enable": settings.tun, "stack": settings.stack,
            "auto-route": settings.autoRoute, "auto-detect-interface": settings.autoDetectInterface,
            "mtu": settings.mtu
        ]
        if settings.dnsHijack { tun["dns-hijack"] = ["any:53", "tcp://any:53"] }
        if settings.excludeLAN { tun["route-exclude-address"] = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"] }
        config["tun"] = tun
        var dns = config["dns"] as? [String: Any] ?? [:]
        dns["enable"] = true; dns["ipv6"] = settings.ipv6
        dns.removeValue(forKey: "listen")
        dns["enhanced-mode"] = settings.fakeIP ? "fake-ip" : "redir-host"
        if dns["nameserver"] == nil { dns["nameserver"] = ["https://dns.alidns.com/dns-query", "https://doh.pub/dns-query"] }
        if dns["proxy-server-nameserver"] == nil { dns["proxy-server-nameserver"] = ["https://dns.alidns.com/dns-query"] }
        config["dns"] = dns
        try applyRuleSubscriptions(ruleSubscriptions,config:&config,resourceRoot:resourceRoot)
        let sourceRules = config["rules"] as? [String] ?? ["MATCH,DIRECT"]
        let activeRules = rules.filter(\.enabled)
        for rule in activeRules { try rule.validate() }
        config["rules"] = activeRules.map(\.yamlRule) + sourceRules
        return (try Yams.dump(object:config,allowUnicode:true,sortKeys:true),config,ConfigurationMetadata(nodeCount:nodeCount,configuration:config))
    }
    private static func normalizeProviders(_ config: inout [String: Any], key: String, prefix: String, settings: NetworkSettings, resourceRoot: URL?) {
        guard var providers = config[key] as? [String: Any] else { return }
        for (index, name) in providers.keys.sorted().enumerated() {
            guard var provider = providers[name] as? [String: Any] else { continue }
            let relative = "providers/\(prefix)-\(index).yaml"
            provider["path"] = resourceRoot.map { $0.appendingPathComponent(relative).path } ?? relative
            if key == "proxy-providers" && provider["health-check"] == nil {
                provider["health-check"] = ["enable": true, "url": settings.testURL, "interval": 60, "timeout": settings.testTimeout, "lazy": false]
            }
            providers[name] = provider
        }
        config[key] = providers
    }
}

