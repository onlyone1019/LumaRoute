import Foundation

/// A rule update cannot silently become a topology or system network update.
public enum RoutingUpdatePolicy {
    public static func networkUnchanged(_ candidate: NetworkSettings,from previous: NetworkSettings) -> Bool {
        var compared = candidate
        // Mode is managed by the core's PATCH API, independently of the helper.
        compared.mode = previous.mode
        return compared == previous || compared.isApplicationOnlyChange(from:previous)
    }
    public static func validate(previous: String,candidate: String,home: URL) throws {
        func topology(_ yaml: String) throws -> [String:Any] {
            var config = try ConfigComposer.parse(yaml)
            config.removeValue(forKey:"rules")
            config.removeValue(forKey:"mode") // updateRouting checks the live mode separately.
            let prefix = home.path+"/revisions/"
            for key in ["proxy-providers","rule-providers"] {
                if var providers = config[key] as? [String:[String:Any]] {
                    for name in providers.keys {
                        guard let path = providers[name]?["path"] as? String,path.hasPrefix(prefix) else { continue }
                        let suffix = String(path.dropFirst(prefix.count)).split(separator:"/",maxSplits:1)
                        if suffix.count == 2,UUID(uuidString:String(suffix[0])) != nil {
                            providers[name]?["path"] = prefix+"<revision>/"+suffix[1]
                            if providers[name]?["type"] as? String == "file" {
                                let file = URL(fileURLWithPath:path).resolvingSymlinksInPath()
                                guard file.path.hasPrefix(home.resolvingSymlinksInPath().path+"/revisions/") else { throw LumaError.message("分流缓存路径无效") }
                                // URI nodes and managed rule sets live in new revision
                                // files. Equal basenames alone do not imply equal contents.
                                providers[name]?["_routingContent"] = try Data(contentsOf:file)
                            }
                        }
                    }
                    config[key] = providers
                }
            }
            return config
        }
        guard try NSDictionary(dictionary:topology(previous)).isEqual(to:topology(candidate)) else {
            throw LumaError.message("节点、DNS 或其他配置已改变，请通过完整配置更新应用这些修改")
        }
    }
}
