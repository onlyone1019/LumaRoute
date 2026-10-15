import Foundation

/// Keep the base's client DNS, but resolve each member's statically declared
/// node servers using that member's explicit bootstrap DNS configuration.
enum CompositionNodeDNS {
    static func host(_ value: String) -> String? {
        var route = SubscriptionDomainRoute(); route.domain = value
        return try? route.normalizedDomain()
    }
    static func policies(nodes: [[String:Any]],dns: [String:Any]) -> [String:[String]] {
        guard let defaults = servers(dns["proxy-server-nameserver"]),!defaults.isEmpty else { return [:] }
        let overrides = dns["proxy-server-nameserver-policy"] as? [String:Any] ?? [:]
        var result: [String:[String]] = [:]
        for node in nodes {
            guard let server = node["server"] as? String,let domain = host(server) else { continue }
            let matching = overrides.keys.compactMap { key -> (String,Int)? in
                let pattern = key.lowercased()
                if pattern == domain { return (key,10000+pattern.count) }
                if pattern.hasPrefix("+.") || pattern.hasPrefix("*.") || pattern.hasPrefix(".") {
                    let suffix = String(pattern.dropFirst(pattern.hasPrefix(".") ? 1:2))
                    if domain.hasSuffix("."+suffix) || pattern.hasPrefix("+.") && domain == suffix { return (key,suffix.count) }
                }
                return nil
            }.sorted { $0.1 == $1.1 ? $0.0 < $1.0:$0.1 > $1.1 }
            result[domain] = matching.first.flatMap { servers(overrides[$0.0]) } ?? defaults
        }
        return result
    }
    static func servers(_ value: Any?) -> [String]? {
        if let values = value as? [String] { return values.isEmpty ? nil:values }
        if let value = value as? String,!value.isEmpty { return [value] }
        return nil
    }
}
