import Foundation
import Yams

public struct RuleCatalogEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let behavior: String
    public let defaultTarget: String
    public var url: URL { URL(string:"https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/\(id).txt")! }
    public static let all: [RuleCatalogEntry] = [
        .init(id:"reject",title:"广告拦截",detail:"广告域名",behavior:"domain",defaultTarget:"REJECT"),
        .init(id:"direct",title:"国内直连",detail:"适合直连的域名",behavior:"domain",defaultTarget:"DIRECT"),
        .init(id:"proxy",title:"代理域名",detail:"适合通过代理访问的域名",behavior:"domain",defaultTarget:""),
        .init(id:"private",title:"私有网络域名",detail:"本地及私有网络域名",behavior:"domain",defaultTarget:"DIRECT"),
        .init(id:"apple",title:"Apple",detail:"在中国大陆可直连的 Apple 域名",behavior:"domain",defaultTarget:"DIRECT"),
        .init(id:"icloud",title:"iCloud",detail:"iCloud 域名",behavior:"domain",defaultTarget:"DIRECT"),
        .init(id:"google",title:"Google",detail:"Google 域名；请按实际线路选择策略",behavior:"domain",defaultTarget:""),
        .init(id:"gfw",title:"GFWList",detail:"GFWList 域名",behavior:"domain",defaultTarget:""),
        .init(id:"tld-not-cn",title:"非中国顶级域名",detail:"范围较广，使用前请确认优先级",behavior:"domain",defaultTarget:""),
        .init(id:"telegramcidr",title:"Telegram IP",detail:"Telegram 使用的 IP 网段",behavior:"ipcidr",defaultTarget:""),
        .init(id:"lancidr",title:"局域网 IP",detail:"局域网及保留 IP 网段",behavior:"ipcidr",defaultTarget:"DIRECT"),
        .init(id:"cncidr",title:"中国大陆 IP",detail:"中国大陆 IP 网段",behavior:"ipcidr",defaultTarget:"DIRECT"),
        .init(id:"applications",title:"常见直连应用",detail:"按进程等条件匹配的常见软件",behavior:"classical",defaultTarget:"DIRECT")
    ]
    public static func entry(_ id: String) throws -> RuleCatalogEntry {
        guard let entry = all.first(where:{$0.id == id}) else { throw LumaError.message("未知的规则订阅来源") }
        return entry
    }
}

public enum RuleSubscriptionPriority: String, Codable, CaseIterable, Identifiable, Sendable {
    case supplement, override
    public var id: String { rawValue }
    public var label: String { self == .supplement ? "补充机场规则（推荐）":"优先于机场规则" }
}

public struct RuleSubscription: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var profileID: UUID
    public var catalogID: String
    public var target: String
    public var enabled = true
    public var autoUpdate = true
    public var intervalHours = 24
    public var priority: RuleSubscriptionPriority = .supplement
    public var revision: UUID?
    public var ruleCount = 0
    public var lastUpdated: Date?
    public var lastAttempt: Date?
    public var lastError: String?
    public init(profileID: UUID, catalogID: String, target: String) {
        self.profileID = profileID; self.catalogID = catalogID; self.target = target
    }
    public func validate() throws {
        _ = try RuleCatalogEntry.entry(catalogID)
        guard (1...168).contains(intervalHours),!target.isEmpty,target.utf8.count <= 512,
              !target.contains(","),!target.contains("\n"),!target.contains("\r") else { throw LumaError.message("规则订阅的目标策略或更新间隔无效") }
    }
    public func isDue(at date: Date = Date()) -> Bool {
        enabled && autoUpdate && date.timeIntervalSince(lastAttempt ?? lastUpdated ?? .distantPast) >= Double(intervalHours)*3600
    }
}

/// Content travels across XPC as data, never as a caller-provided privileged file path.
public struct RuleSubscriptionSnapshot: Codable, Sendable {
    public var subscription: RuleSubscription
    public var content: String
    public init(subscription: RuleSubscription, content: String) { self.subscription = subscription; self.content = content }
}

public enum RuleSubscriptionDownload {
    public static func payload(_ content: String) throws -> [String] {
        guard content.utf8.count <= 8*1024*1024 else { throw LumaError.message("规则集超过 8 MB") }
        let object: Any?
        do { object = try Yams.load(yaml:content) }
        catch { throw LumaError.message("规则集不是有效的 YAML，已保留上次可用版本") }
        guard let dictionary = object as? [String:Any], let values = dictionary["payload"] as? [String],
              !values.isEmpty,values.count <= 500_000,
              values.allSatisfy({!$0.isEmpty && !$0.contains("\n") && !$0.contains("\r")}) else {
            throw LumaError.message("规则集缺少有效的 payload 列表，已保留上次可用版本")
        }
        return values
    }
    public static func fetch(_ entry: RuleCatalogEntry, sourceURL: URL? = nil) async throws -> String {
        let url = sourceURL ?? entry.url
        let data: Data
        let response: URLResponse
        do { (data,response) = try await systemDownload(url) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as URLError {
            do { (data,response) = try await DirectSubscriptionDownload.fetch(url,userAgent:"LumaRoute/0.1.0") }
            catch { throw LumaError.message("规则集连接失败，请检查网络后重试；旧规则已保留") }
        }
        guard let http = response as? HTTPURLResponse,(200...299).contains(http.statusCode) else {
            throw LumaError.message("规则集下载失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)），已保留旧版本")
        }
        guard let content = String(data:data,encoding:.utf8) else { throw LumaError.message("规则集不是 UTF-8 文本，已保留旧版本") }
        _ = try await Task.detached { try payload(content) }.value
        return content
    }
    private static func systemDownload(_ url: URL) async throws -> (Data,URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25; configuration.timeoutIntervalForResource = 40
        let session = URLSession(configuration:configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url:url); request.setValue("LumaRoute/0.1.0",forHTTPHeaderField:"User-Agent")
        let (bytes,response) = try await session.bytes(for:request)
        guard response.expectedContentLength <= 8*1024*1024 else { throw LumaError.message("规则集超过 8 MB，已保留旧版本") }
        var data = Data(); data.reserveCapacity(min(8*1024*1024,max(0,Int(response.expectedContentLength))))
        for try await byte in bytes {
            guard data.count < 8*1024*1024 else { throw LumaError.message("规则集超过 8 MB，已保留旧版本") }
            data.append(byte)
            if data.count % 65536 == 0 { try Task.checkCancellation() }
        }
        return (data,response)
    }
}

extension ConfigComposer {
    public static func ruleTargets(source: String?) throws -> [String] {
        let config = try source.map(parse) ?? [:]
        let groups = (config["proxy-groups"] as? [[String:Any]] ?? []).compactMap { $0["name"] as? String }
        return ["DIRECT","REJECT"] + groups.filter { !["DIRECT","REJECT"].contains($0) }
    }
    static func applyRuleSubscriptions(_ snapshots: [RuleSubscriptionSnapshot], config: inout [String:Any], resourceRoot: URL?) throws {
        guard snapshots.count <= 32,Set(snapshots.map { $0.subscription.id }).count == snapshots.count,
              snapshots.reduce(0,{$0+$1.content.utf8.count}) <= 32*1024*1024 else { throw LumaError.message("规则订阅重复、过多或内容超过 32 MB") }
        var providers = config["rule-providers"] as? [String:Any] ?? [:]
        let targets = Set(["DIRECT","REJECT"] + (config["proxy-groups"] as? [[String:Any]] ?? []).compactMap { $0["name"] as? String })
        var before: [String] = [], after: [String] = []
        for snapshot in snapshots where snapshot.subscription.enabled {
            let item = snapshot.subscription
            try item.validate()
            // A provider may remove/rename a group during a subscription update.
            // Pause only this overlay; never reject the provider's new base config.
            guard targets.contains(item.target) else { continue }
            let entry = try RuleCatalogEntry.entry(item.catalogID)
            let payload = try RuleSubscriptionDownload.payload(snapshot.content)
            var name = "lumaroute-rule-"+item.id.uuidString.lowercased()
            while providers[name] != nil { name += "-local" }
            var provider: [String:Any] = ["behavior":entry.behavior,"format":"yaml"]
            if let resourceRoot {
                let file = resourceRoot.appendingPathComponent("rulesets/\(item.id.uuidString).yaml")
                try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                try Data(snapshot.content.utf8).write(to:file,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
                provider["type"] = "file"; provider["path"] = file.path
            } else { provider["type"] = "inline"; provider["payload"] = payload }
            providers[name] = provider
            let rule = "RULE-SET,\(name),\(item.target)" + (entry.behavior == "ipcidr" ? ",no-resolve":"")
            if item.priority == .override { before.append(rule) } else { after.append(rule) }
        }
        let original = config["rules"] as? [String] ?? ["MATCH,DIRECT"]
        let fallback = original.firstIndex { ["MATCH","FINAL"].contains($0.split(separator:",",maxSplits:1).first?.trimmingCharacters(in:.whitespaces).uppercased() ?? "") } ?? original.endIndex
        config["rules"] = before + Array(original[..<fallback]) + after + Array(original[fallback...])
        if !providers.isEmpty { config["rule-providers"] = providers }
    }
}
