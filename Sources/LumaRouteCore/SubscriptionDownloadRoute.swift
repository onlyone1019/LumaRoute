import Foundation
import SystemConfiguration

public enum SubscriptionDownloadRoute: String, Codable, CaseIterable, Identifiable, Sendable {
    case direct, systemProxy, lumaRoute
    public var id: String { rawValue }
    public var label: String {
        switch self { case .direct:return "直连"; case .systemProxy:return "系统代理"; case .lumaRoute:return "LumaRoute 代理" }
    }
    public var detail: String {
        switch self {
        case .direct:return "直接访问订阅服务器。直连超时时，可选择系统代理或已就绪的 LumaRoute 代理。"
        case .systemProxy:return "使用 macOS 当前配置的代理下载，可借助其他代理客户端访问 VPS；系统代理需已开启。"
        case .lumaRoute:return "通过 LumaRoute 当前节点和分流规则下载；需先启用可用的机场配置，避免依赖尚未下载的 VPS 节点。"
        }
    }
    func proxyURL(for target: URL,localProxyPort: Int?,systemProxies: [String:Any]? = nil) throws -> URL? {
        if self == .direct { return nil }
        if self == .lumaRoute {
            guard let port = localProxyPort,(1024...65535).contains(port) else { throw SubscriptionError.download("LumaRoute 代理尚未就绪，请先启用可用配置，或改用系统代理。") }
            return URL(string:"http://127.0.0.1:\(port)")!
        }
        let settings = systemProxies ?? SCDynamicStoreCopyProxies(nil) as? [String:Any] ?? [:]
        let protocolName = target.scheme?.lowercased() == "https" ? "HTTPS":"HTTP"
        for (key,scheme) in [(protocolName,"http"),("SOCKS","socks5h")] {
            guard settings[key+"Enable"] as? Int == 1,
                  let host = settings[key+"Proxy"] as? String,!host.isEmpty,
                  let port = settings[key+"Port"] as? Int,(1...65535).contains(port),
                  !host.contains("/"),!host.contains("@"),!host.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { continue }
            var components = URLComponents(); components.scheme = scheme
            components.host = host; components.port = port
            if let url = components.url { return url }
        }
        throw SubscriptionError.download("系统未配置可用的 \(protocolName) 或 SOCKS 代理，请先在现有代理客户端开启系统代理，或选择其他下载方式。")
    }
}
