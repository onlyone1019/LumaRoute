import Foundation

public enum LumaError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
public enum RouteMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case rule, global, direct
    public var id: String { rawValue }
    public var label: String { switch self { case .rule: return "规则"; case .global: return "全局"; case .direct: return "直连" } }
}
public struct NetworkSettings: Codable, Equatable, Sendable {
    public var mixedPort = 19790
    public var controllerPort = 19791
    public var mode: RouteMode = .rule
    public var tun = false
    public var stack = "mixed"
    public var autoRoute = true
    public var autoDetectInterface = true
    public var excludeLAN = true
    /// Shares the mixed proxy port with other LAN devices; requires the credential below.
    public var allowLAN = false
    public var lanUsername = "lumaroute"
    public var lanPassword = ""
    public var mtu = 1500
    public var dnsHijack = true
    public var fakeIP = true
    public var ipv6 = false
    public var systemProxy = false
    public var bypass = ["localhost", "*.local", "127.0.0.1", "192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12"]
    public var autoLaunch = false
    public var connectOnLaunch = false
    public var testURL = "https://www.gstatic.com/generate_204"
    public var testTimeout = 5000
    public var testConcurrency = 6
    public var appearance = "system"
    public var updateIntervalHours = 6.0
    public init() {}
    /// Sixteen unambiguous characters, easy to type on TVs and phones.
    public static func makeLANPassword() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<16).map { _ in alphabet.randomElement()! })
    }
    /// Application preferences do not affect YAML or system network settings.
    public func isApplicationOnlyChange(from previous: Self) -> Bool {
        var normalized = self
        normalized.autoLaunch = previous.autoLaunch
        normalized.connectOnLaunch = previous.connectOnLaunch
        normalized.testConcurrency = previous.testConcurrency
        normalized.appearance = previous.appearance
        normalized.updateIntervalHours = previous.updateIntervalHours
        return self != previous && normalized == previous
    }
    public func isSystemProxyOnlyChange(from previous: Self) -> Bool {
        var normalized = self
        normalized.systemProxy = previous.systemProxy
        return systemProxy != previous.systemProxy && normalized == previous
    }
}
public struct SubscriptionUsage: Codable, Equatable, Sendable {
    public var upload: Int64 = 0
    public var download: Int64 = 0
    public var total: Int64?
    public var expire: Date?
    public var usedBytes: Int64 {
        let (sum, overflow) = max(0, upload).addingReportingOverflow(max(0, download))
        return overflow ? Int64.max : sum
    }
    public var usedFraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(usedBytes) / Double(total))
    }
    public init(header: String) {
        for field in header.split(separator: ";") {
            let pair = field.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, let n = Int64(pair[1]), n >= 0 else { continue }
            switch pair[0] {
            case "upload": upload = n
            case "download": download = n
            case "total": total = n > 0 ? n : nil
            case "expire": expire = n > 0 ? Date(timeIntervalSince1970: TimeInterval(n)) : nil
            default: break
            }
        }
    }
}
public struct Profile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var isRemote: Bool
    public var displaySource: String
    public var created: Date
    public var lastUpdated: Date?
    public var lastAttempt: Date?
    public var lastError: String?
    public var usage: SubscriptionUsage?
    public var updateHours: Double
    public var nodeCount: Int
    public var userAgent: String?
    public var downloadRoute: SubscriptionDownloadRoute = .direct
    public var composition: SubscriptionComposition?
    public var proxyChains: [ProxyChain]?
    public var lastChange: SubscriptionChange?
    public init(name: String, isRemote: Bool, displaySource: String = "本地配置", updateHours: Double = 6) {
        id = UUID(); self.name = name; self.isRemote = isRemote
        self.displaySource = displaySource; self.updateHours = updateHours
        created = Date(); nodeCount = 0
    }
}
public struct CustomRule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var enabled: Bool
    public var type: String
    public var payload: String
    public var target: String
    public init(type: String = "DOMAIN-SUFFIX", payload: String = "", target: String = "DIRECT", enabled: Bool = true) {
        id = UUID(); self.type = type; self.payload = payload; self.target = target; self.enabled = enabled
    }
    public var yamlRule: String { "\(type),\(payload),\(target)" + (type.hasPrefix("IP-CIDR") ? ",no-resolve" : "") }
    public func validate() throws {
        guard ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6", "PROCESS-NAME", "PROCESS-PATH"].contains(type),
              !payload.trimmingCharacters(in: .whitespaces).isEmpty, !target.isEmpty,
              !payload.contains(","), !payload.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains), !target.contains(","), !target.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)
        else { throw LumaError.message("规则类型、匹配内容或目标策略无效") }
        if type == "PROCESS-PATH",!payload.hasPrefix("/") { throw LumaError.message("应用路径须为完整的可执行文件路径") }
        if type == "PROCESS-NAME",payload.contains("/") { throw LumaError.message("进程名称不包含路径，请选择完整路径匹配") }
    }
}
public struct AppDatabase: Codable, Sendable {
    public var profiles: [Profile] = []
    public var activeProfileID: UUID?
    public var settings = NetworkSettings()
    public var customRules: [CustomRule] = []
    public var savedChoices: [String: String] = [:]
    public var groupStrategies: [GroupStrategy]?
    public var ruleSubscriptions: [RuleSubscription]?
    public init() {}
}
public struct DelaySample: Codable, Equatable, Sendable {
    public var time: String
    public var delay: Int
    public init(time:String,delay:Int) { self.time = time; self.delay = delay }
}
public struct ProxyNode: Codable, Identifiable, Equatable, Sendable {
    public var name: String
    public var type: String
    public var now: String?
    public var all: [String]?
    public var history: [DelaySample]?
    public var alive: Bool?
    public var fixed: String?
    public var providerName: String?
    public var hidden: Bool?
    public var id: String { name }
    public var isGroup: Bool { all != nil }
    public var delay: Int? { (history?.last?.delay).flatMap { $0 > 0 ? $0 : nil } }
    enum CodingKeys: String, CodingKey { case name, type, now, all, history, alive, fixed, hidden; case providerName = "provider-name" }
}
public struct ProxiesResponse: Codable, Sendable { public var proxies: [String: ProxyNode] }
public struct Provider: Codable, Sendable {
    public var name: String
    public var vehicleType: String?
    public var proxies: [ProxyNode]?
    public var updatedAt: String?
}
public struct ProvidersResponse: Codable, Sendable { public var providers: [String: Provider] }
public struct ConnectionMetadata: Codable, Sendable {
    public var host: String?
    public var destinationIP: String?
    public var destinationPort: String?
    public var sourceIP: String?
    public var sourcePort: String?
    public var network: String?
    public var type: String?
    public var process: String?
    public var processPath: String?
    public var processSource: String?
}
public struct LiveConnection: Codable, Identifiable, Sendable {
    public var id: String
    public var metadata: ConnectionMetadata
    public var upload: Int64
    public var download: Int64
    public var start: String?
    public var chains: [String]?
    public var rule: String?
    public var rulePayload: String?
    public var processName: String {
        if let name = metadata.process,!name.isEmpty { return name }
        if let path = metadata.processPath,!path.isEmpty { return URL(fileURLWithPath:path).lastPathComponent }
        return "未知进程"
    }
    public var policyName: String { chains?.last ?? "未知" }
    public func matches(_ term: String) -> Bool {
        guard !term.isEmpty else { return true }
        let fields = [target,processName,metadata.destinationIP ?? "",metadata.sourceIP ?? "",metadata.processPath ?? "",rule ?? "",rulePayload ?? ""]+(chains ?? [])
        return fields.contains { $0.localizedCaseInsensitiveContains(term) }
    }
    public var target: String { (metadata.host?.isEmpty == false ? metadata.host! : metadata.destinationIP ?? "未知目标") }
}
public struct ConnectionsResponse: Codable, Sendable {
    public var downloadTotal: Int64
    public var uploadTotal: Int64
    public var connections: [LiveConnection]?
}
public struct LiveRule: Codable, Identifiable, Equatable, Sendable {
    public var type: String
    public var payload: String
    public var proxy: String
    public var index: Int?
    public var id: String { "\(index ?? -1):\(type):\(payload):\(proxy)" }
}
public struct RulesResponse: Codable, Sendable { public var rules: [LiveRule] }
public struct Traffic: Codable, Equatable, Sendable {
    public var up: Int64
    public var down: Int64
    public var upTotal: Int64?
    public var downTotal: Int64?
    public init(up: Int64 = 0, down: Int64 = 0) { self.up = up; self.down = down }
}
/// Carries sanitized log text across the core-to-app boundary without another
/// regex pass. Only sanitization and splitting can create instances.
public struct RedactedLogMessage: Sendable {
    public let text: String
    public init(_ rawText: String) { text = Redactor.clean(rawText) }
    private init(redactedText: String) { text = redactedText }
    public var lines: [Self] {
        text.split(whereSeparator:\.isNewline).map { Self(redactedText:String($0)) }
    }
}
public struct LogEntry: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var level: String
    public var source: String
    public var message: String
    public init(level: String = "info", source: String, message: String) {
        self.init(level:level,source:source,message:RedactedLogMessage(message))
    }
    public init(level: String = "info", source: String, message: RedactedLogMessage) {
        self.level = level; self.source = source; self.message = message.text
    }
}
public enum Redactor {
    private static let expressions: [NSRegularExpression] = [
        #"(?i)((?:https?|ssr?|vmess|vless|trojan|hysteria2?|hy2|tuic|socks5?|snell|wireguard|anytls)://)[^\s\"']+"#,
        #"(?i)(authorization[\s\"']*[:=][\s\"']*(?:(?:bearer|basic)\s+)?)[^\s\"',]+"#,
        #"(?i)((?:password|passwd|secret|token|uuid|private-key|client-id|access_token|auth-str|auth|psk)[\s\"']*[:=][\s\"']*)[^\s\",}]+"#
    ].map { try! NSRegularExpression(pattern:$0) }
    public static func clean(_ text: String) -> String {
        var output = text
        for regex in expressions {
            output = regex.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate:"$1[已隐藏]")
        }
        return output
    }
}
public enum Format {
    public static func bytes(_ value: Int64) -> String {
        if value == 0 { return "0 B" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.includesActualByteCount = false
        return formatter.string(fromByteCount: value)
    }
    public static func rate(_ value: Int64) -> String { bytes(value) + "/s" }
}

