import Foundation

/// User-facing stages of a remote subscription import. Never include response bodies or bearer URLs.
public enum SubscriptionError: LocalizedError {
    case invalidAddress
    case invalidUserAgent
    case httpStatus(Int)
    case download(String)
    case emptyResponse
    case tooLarge
    case invalidEncoding
    case htmlResponse
    case invalidFormat(String)
    case configuration(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "订阅地址无效\n请输入完整的 HTTP 或 HTTPS 订阅链接。"
        case .invalidUserAgent:
            return "User-Agent 无效\n请使用单行英文、数字及符号，最多 512 个字符；留空使用默认标识。"
        case .httpStatus(let status):
            let suggestion: String
            switch status {
            case 401,403: suggestion = "服务商拒绝访问，请检查订阅是否过期、链接是否完整，或是否需要指定 User-Agent。"
            case 404: suggestion = "订阅地址不存在，请从服务商重新复制链接。"
            case 429: suggestion = "请求过于频繁，请稍后再试。"
            case 500...599: suggestion = "服务商暂时无法处理请求，请稍后再试。"
            default: suggestion = "服务器未返回可用订阅，请检查链接或联系服务商。"
            }
            return "订阅下载失败（HTTP \(status)）\n"+suggestion
        case .download(let reason):
            return "订阅连接失败\n"+reason
        case .emptyResponse:
            return "订阅内容为空\n服务器没有返回配置，请检查链接、账户状态，或尝试调整 User-Agent。"
        case .tooLarge:
            return "订阅内容过大\n配置超过 8 MB，请检查链接是否返回了其他文件。"
        case .invalidEncoding:
            return "订阅文本编码不支持\n请使用 UTF-8 编码的 Clash / Mihomo 配置或节点订阅。"
        case .htmlResponse:
            return "返回内容是网页\n链接返回了登录页、验证页或错误页，请复制真正的订阅链接，或按服务商要求设置 User-Agent。"
        case .invalidFormat(let reason):
            return "订阅格式无法识别\n请使用 Clash / Mihomo YAML、节点链接或 Base64 节点订阅。\n详情："+Self.detail(reason)
        case .configuration(let reason):
            return "订阅配置校验失败\n节点、策略组引用或协议配置不被当前内核接受。请检查详情，尝试调整 User-Agent，或向服务商获取兼容配置。\n详情："+Self.detail(reason)
        }
    }

    private static func detail(_ text: String) -> String { String(Redactor.clean(text).prefix(620)) }

    static func transport(_ error: Error) -> SubscriptionError {
        guard let error = error as? URLError else { return .download("无法完成下载，请检查网络连接后重试。") }
        switch error.code {
        case .timedOut: return .download("连接超时，请检查网络或稍后重试。")
        case .cannotFindHost, .dnsLookupFailed: return .download("无法解析服务商域名，请检查链接及 DNS 设置。")
        case .notConnectedToInternet, .networkConnectionLost: return .download("网络不可用或连接中断，请恢复联网后重试。")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return .download("无法验证服务商的 HTTPS 证书，请检查系统时间或联系服务商。")
        default: return .download("无法连接订阅服务器，请检查网络及服务商状态。")
        }
    }
}
