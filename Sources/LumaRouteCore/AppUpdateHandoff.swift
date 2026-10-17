import Foundation

/// One-use state for the restart performed by Sparkle. Business data stays in SQLite.
public struct AppUpdateHandoff: Codable, Equatable, Sendable {
    public var targetBuild: Int
    public var created: Date
    public var systemProxy: Bool
    public var tun: Bool

    public init(targetBuild: Int,settings: NetworkSettings,now: Date = Date()) {
        self.targetBuild = targetBuild; created = now
        systemProxy = settings.systemProxy; tun = settings.tun
    }
    private static func file(in root: URL) -> URL { root.appendingPathComponent("app-update-restart.json") }
    public func save(in root: URL) throws {
        guard targetBuild > 0 else { throw LumaError.message("更新版本无效") }
        let file = Self.file(in:root)
        try JSONEncoder().encode(self).write(to:file,options:[.atomic,.completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    public static func clear(in root: URL) throws {
        let file = file(in:root)
        if FileManager.default.fileExists(atPath:file.path) { try FileManager.default.removeItem(at:file) }
    }
    public static func take(in root: URL,currentBuild: Int,now: Date = Date()) throws -> Self? {
        let file = file(in:root)
        guard FileManager.default.fileExists(atPath:file.path) else { return nil }
        let state = try? JSONDecoder().decode(Self.self,from:Data(contentsOf:file))
        try clear(in:root)
        guard let state,state.targetBuild == currentBuild,
              (0...3600).contains(now.timeIntervalSince(state.created)) else { return nil }
        return state
    }
}
