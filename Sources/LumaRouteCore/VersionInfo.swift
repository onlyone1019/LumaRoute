import Foundation

/// Bundle metadata describes this app and its bundled core. A selected/running
/// core may override the latter after an update without changing the app bundle.
public struct VersionInfo: Sendable {
    private static let applicationBundle: Bundle = {
        let main = Bundle.main,location = main.bundleURL
        // SMAppService launches the executable in Contents/Library/LaunchServices,
        // where Bundle.main has no Info.plist of its own. Use the containing app.
        let library = location.deletingLastPathComponent(),contents = library.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard location.lastPathComponent == "LaunchServices",library.lastPathComponent == "Library",
              contents.lastPathComponent == "Contents",app.pathExtension == "app" else { return main }
        return Bundle(url:app) ?? main
    }()
    public static let current = VersionInfo()
    public let application: AppVersion?
    public let core: String?

    public init(bundle: Bundle? = nil,coreVersion: String? = nil) {
        let bundle = bundle ?? Self.applicationBundle
        application = AppVersion(bundle:bundle)
        let version = coreVersion ?? bundle.object(forInfoDictionaryKey:"LumaRouteCoreVersion") as? String
        let normalized = version.map { $0.hasPrefix("v") ? String($0.dropFirst()):$0 }
        core = normalized.flatMap { AppVersion(version:$0,build:0)?.version }
    }
    public var userAgent: String { "LumaRoute/\(application?.version ?? "unknown")" }
    public var subscriptionUserAgent: String { "clash.meta/\(core ?? "unknown") \(userAgent)" }

    public func diagnostics(logs: [LogEntry],coreStatus: String) -> String {
        let body = logs.map { "\($0.date.ISO8601Format()) [\($0.level)] [\($0.source)] \($0.message)" }.joined(separator:"\n")
        return Redactor.clean("LumaRoute \(application?.label ?? "开发版本")\nMihomo \(coreStatus)\n"+body)
    }
}
