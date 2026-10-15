import Foundation
import Darwin

/// Shared validation, batch import and deterministic preview for the composition editor.
public enum CompositionRouting {
    public static let types: [(value:String,label:String,placeholder:String)] = [
        ("DOMAIN-SUFFIX","域名后缀","example.com"),("DOMAIN","完整域名","api.example.com"),
        ("DOMAIN-KEYWORD","域名关键词","example"),("IP-CIDR","IPv4 网段","192.168.0.0/16"),
        ("IP-CIDR6","IPv6 网段","2001:db8::/32"),("PROCESS-NAME","进程名称","curl"),
        ("PROCESS-PATH","进程路径","/usr/bin/curl")]

    public static func normalized(type: String,payload: String) throws -> String {
        let value = payload.trimmingCharacters(in:.whitespacesAndNewlines)
        try CustomRule(type:type,payload:value).validate()
        switch type {
        case "DOMAIN","DOMAIN-SUFFIX":
            var route = SubscriptionDomainRoute(); route.type = type; route.domain = value
            return try route.normalizedDomain()
        case "DOMAIN-KEYWORD":
            guard value.utf8.count <= 253,value.utf8.allSatisfy({ (33...126).contains($0) && !",/\\:#*?".utf8.contains($0) }) else {
                throw LumaError.message("域名关键词不包含空格、协议、路径或通配符")
            }
            return value.lowercased()
        case "IP-CIDR","IP-CIDR6":
            guard let network = network(value),network.bytes.count == (type == "IP-CIDR" ? 4:16) else { throw LumaError.message("请填写有效的 IPv4 / IPv6 网段和前缀长度") }
            var bytes = network.bytes
            for index in bytes.indices { bytes[index] &= mask(network.prefix,index) }
            var buffer = [CChar](repeating:0,count:Int(INET6_ADDRSTRLEN))
            let rendered = bytes.withUnsafeBytes { inet_ntop(bytes.count == 4 ? AF_INET:AF_INET6,$0.baseAddress,&buffer,socklen_t(buffer.count)) }
            guard rendered != nil else { throw LumaError.message("IP 网段无效") }
            return String(cString:buffer)+"/"+String(network.prefix)
        default: return value
        }
    }

    /// All-or-nothing: validate the whole paste before the caller mutates its draft.
    /// Each line is either a payload or TYPE,payload; every line uses the selected exit.
    public static func batch(_ text: String,type: String,profileID: UUID?,target: String?,existing: [SubscriptionDomainRoute]) throws -> [SubscriptionDomainRoute] {
        let lines = text.components(separatedBy:.newlines).enumerated().filter { !$0.element.trimmingCharacters(in:.whitespaces).isEmpty }
        guard !lines.isEmpty,existing.count+lines.count <= 256 else { throw LumaError.message("请填写规则；每个组合最多 256 条") }
        var seen = Set(try existing.filter(\.enabled).map { try matchKey(type:$0.type,payload:$0.normalizedDomain()) })
        return try lines.map { index,line in
            do {
                var route = SubscriptionDomainRoute(profileID:profileID); route.type = type; route.target = target
                let fields = line.split(separator:",",omittingEmptySubsequences:false).map { $0.trimmingCharacters(in:.whitespaces) }
                if fields.count == 2 { route.type = fields[0].uppercased(); route.domain = fields[1] }
                else if fields.count == 1 { route.domain = fields[0] }
                else { throw LumaError.message("每行填写匹配内容，或 TYPE,匹配内容；出口统一在下方选择") }
                route.domain = try route.normalizedDomain()
                guard seen.insert(matchKey(type:route.type,payload:route.domain)).inserted else { throw LumaError.message("匹配条件重复") }
                return route
            } catch { throw LumaError.message("第 \(index+1) 行："+error.localizedDescription) }
        }
    }

    public static func matchKey(type: String,payload: String) -> String {
        type+":"+(type.hasPrefix("PROCESS-") ? payload.lowercased():payload)
    }

    public enum Verdict: Equatable {
        case matched(Int,CustomRule)
        case needs(String)
        case fallsThrough
    }
    /// An incomplete earlier match stops preview instead of falsely claiming a later exit.
    public static func preview(rules: [CustomRule],host: String,ip: String = "",process: String = "") throws -> Verdict {
        let host = host.trimmingCharacters(in:.whitespacesAndNewlines)
        let ip = ip.trimmingCharacters(in:.whitespacesAndNewlines)
        let process = process.trimmingCharacters(in:.whitespacesAndNewlines)
        let address = address(host) ?? address(ip)
        if !ip.isEmpty && self.address(ip) == nil { throw LumaError.message("已解析 IP 格式无效") }
        guard !host.isEmpty || !process.isEmpty || address != nil else { throw LumaError.message("请填写域名、IP 或进程") }
        var domain = ""
        if !host.isEmpty,self.address(host) == nil { domain = try normalized(type:"DOMAIN",payload:host) }
        for (index,rule) in rules.enumerated() where rule.enabled {
            let payload = try normalized(type:rule.type,payload:rule.payload)
            let matched: Bool
            switch rule.type {
            case "DOMAIN": matched = domain == payload
            case "DOMAIN-SUFFIX": matched = domain == payload || domain.hasSuffix("."+payload)
            case "DOMAIN-KEYWORD": matched = !domain.isEmpty && domain.contains(payload)
            case "IP-CIDR","IP-CIDR6":
                guard let address else { return .needs("第 \(index+1) 条是 IP 网段规则，请补充已解析 IP；预览不会发起 DNS 请求。") }
                let net = network(payload)!
                matched = address.count == net.bytes.count && address.indices.allSatisfy { address[$0] & mask(net.prefix,$0) == net.bytes[$0] & mask(net.prefix,$0) }
            case "PROCESS-NAME","PROCESS-PATH":
                guard !process.isEmpty else { return .needs("第 \(index+1) 条是应用规则，请补充进程名称或可执行文件路径。") }
                if rule.type == "PROCESS-PATH",!process.hasPrefix("/") { return .needs("第 \(index+1) 条需要完整进程路径，只有名称无法判断。") }
                let actual = rule.type == "PROCESS-NAME" ? URL(fileURLWithPath:process).lastPathComponent:process
                matched = actual.caseInsensitiveCompare(payload) == .orderedSame
            default: return .needs("第 \(index+1) 条规则无法在本地预览，请通过实际连接核对。")
            }
            if matched { return .matched(index,rule) }
        }
        return .fallsThrough
    }

    private static func address(_ value: String) -> [UInt8]? {
        var bytes = [UInt8](repeating:0,count:16)
        if inet_pton(AF_INET,value,&bytes) == 1 { return Array(bytes.prefix(4)) }
        if inet_pton(AF_INET6,value,&bytes) == 1 { return bytes }
        return nil
    }
    private static func network(_ value: String) -> (bytes:[UInt8],prefix:Int)? {
        let parts = value.split(separator:"/",omittingEmptySubsequences:false)
        guard parts.count == 2,let bytes = address(String(parts[0])),!parts[1].isEmpty,parts[1].allSatisfy(\.isNumber),let prefix = Int(parts[1]),(0...bytes.count*8).contains(prefix) else { return nil }
        return (bytes,prefix)
    }
    private static func mask(_ prefix: Int,_ index: Int) -> UInt8 {
        let bits = min(8,max(0,prefix-index*8))
        return bits == 0 ? 0:UInt8(255 << (8-bits) & 255)
    }
}
