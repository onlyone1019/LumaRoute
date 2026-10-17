import Foundation
import Security

/// Administrator-owned metadata binds a local service to one approved build
/// and user. The GUI cannot update this trust record over RPC.
public struct LocalServiceInstallation: Codable, Sendable {
    public static let root = URL(fileURLWithPath:"/Library/Application Support/LumaRoute/service")
    public static var bundle:URL { root.appendingPathComponent("LumaRoute.app") }
    public static var record:URL { root.appendingPathComponent("installation.plist") }
    public let ownerUID:UInt32
    public let protocolVersion:Int
    public let healthOnly:Bool
    public static func load() throws -> Self {
        for path in [root.deletingLastPathComponent(),root,bundle,record] {
            let attributes = try FileManager.default.attributesOfItem(atPath:path.path)
            guard path.resolvingSymlinksInPath() == path,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
                  let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue,mode & 0o022 == 0
            else { throw LumaError.message("本机服务安装目录或权限无效") }
        }
        let value = try PropertyListDecoder().decode(Self.self,from:Data(contentsOf:record))
        guard value.ownerUID > 0,value.protocolVersion == 1 else { throw LumaError.message("本机服务安装记录不兼容") }
        return value
    }
    public static func requirement(for path:URL) throws -> String {
        var code:SecStaticCode?; var requirement:SecRequirement?; var text:CFString?
        guard SecStaticCodeCreateWithPath(path as CFURL,[],&code) == errSecSuccess,let code,
              SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate),nil) == errSecSuccess,
              SecCodeCopyDesignatedRequirement(code,[],&requirement) == errSecSuccess,let requirement,
              SecRequirementCopyString(requirement,[],&text) == errSecSuccess,let text
        else { throw LumaError.message("无法验证本机构建的完整性") }
        return text as String
    }
    public static func currentProcessMatches(_ text:String) -> Bool {
        var requirement:SecRequirement?; var code:SecCode?
        return SecRequirementCreateWithString(text as CFString,[],&requirement) == errSecSuccess &&
            SecCodeCopySelf([],&code) == errSecSuccess &&
            code.map { SecCodeCheckValidity($0,[],requirement) == errSecSuccess } == true
    }
    public func acceptsCurrentApp() -> Bool {
        ownerUID == getuid() && (try? Self.requirement(for:Self.bundle)).map(Self.currentProcessMatches) == true
    }
    public var helperRequirement:String {
        get throws { try Self.requirement(for:Self.bundle.appendingPathComponent("Contents/Library/LaunchServices/LumaRouteHelper")) }
    }
}
