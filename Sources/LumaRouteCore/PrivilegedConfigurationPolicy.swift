import Foundation

/// Provider cache paths and listeners are composed by LumaRoute. Certificate
/// files and external commands must not be read/executed as root on a client's
/// behalf. Inline certificates and WireGuard key material remain supported.
public enum PrivilegedConfigurationPolicy {
    public static func validate(_ source:String?) throws {
        guard let source else { return }
        try inspect(ConfigComposer.parse(source))
    }
    private static func inspect(_ value:Any) throws {
        if let object = value as? [String:Any] {
            for (key,value) in object {
                let name = key.lowercased()
                if ["post-up","post-down","script","iptables"].contains(name) {
                    throw LumaError.message("后台服务不支持配置中的外部命令或脚本："+key)
                }
                if ["ca","ca-file","certificate","private-key","client-cert","client-key","cert-file","key-file","client-cert-path","client-key-path"].contains(name),let text = value as? String,!text.isEmpty {
                    let wireGuard = object["type"] as? String == "wireguard" && name == "private-key" && Data(base64Encoded:text)?.count == 32
                    guard wireGuard || text.contains("-----BEGIN ") else { throw LumaError.message("后台服务不读取外部证书或密钥文件："+key) }
                }
                if name == "url",let text = value as? String {
                    guard let scheme = URL(string:text)?.scheme?.lowercased(),["http","https"].contains(scheme) else { throw LumaError.message("后台服务的订阅和规则地址必须使用 HTTP 或 HTTPS") }
                }
                try inspect(value)
            }
        } else if let list = value as? [Any] { for child in list { try inspect(child) } }
    }
}
