import Foundation

public final class LocalStore {
    public let root: URL
    public let secrets: SecretStore
    public init(root: URL, secrets: SecretStore = KeychainSecrets()) throws {
        self.root = root; self.secrets = secrets
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for directory in ["profiles", "runtime", "backups", "cores", "rule-subscriptions"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try recoverPendingCommit()
    }
    public static func applicationRoot() -> URL {
        if let custom = ProcessInfo.processInfo.environment["LUMAROUTE_DATA_DIR"] { return URL(fileURLWithPath: custom) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LumaRoute")
    }
    public func load() throws -> AppDatabase {
        let url = root.appendingPathComponent("database.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return AppDatabase() }
        return try JSONDecoder().decode(AppDatabase.self, from: Data(contentsOf: url))
    }
    public func save(_ database: AppDatabase) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try secureWrite(encoder.encode(database), to: root.appendingPathComponent("database.json"))
    }
    public func profileURL(_ id: UUID) -> URL { root.appendingPathComponent("profiles/\(id.uuidString).yaml") }
    public func profileContent(_ id: UUID) throws -> String { try String(contentsOf: profileURL(id), encoding: .utf8) }
    public func ruleSubscriptionContent(_ item: RuleSubscription, from root: URL? = nil) throws -> String {
        guard let revision = item.revision else { throw LumaError.message("规则订阅尚未下载，请先更新") }
        let file = (root ?? self.root).appendingPathComponent("rule-subscriptions/\(revision.uuidString).yaml")
        return try String(contentsOf:file,encoding:.utf8)
    }
    public func saveRuleSubscriptionContent(_ content: String) throws -> UUID {
        let revision = UUID()
        try secureWrite(Data(content.utf8),to:root.appendingPathComponent("rule-subscriptions/\(revision.uuidString).yaml"))
        return revision
    }
    public func cleanRuleSubscriptionCache(_ database: AppDatabase) {
        let keep = Set((database.ruleSubscriptions ?? []).compactMap(\.revision))
        let directory = root.appendingPathComponent("rule-subscriptions")
        for file in (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? [] {
            guard file.pathExtension == "yaml",let id = UUID(uuidString:file.deletingPathExtension().lastPathComponent),!keep.contains(id) else { continue }
            try? FileManager.default.removeItem(at:file)
        }
    }
    public func ruleSubscriptionSnapshots(_ database: AppDatabase, profileID: UUID?, from root: URL? = nil) throws -> [RuleSubscriptionSnapshot] {
        try (database.ruleSubscriptions ?? []).filter { $0.profileID == profileID && $0.enabled }.map {
            RuleSubscriptionSnapshot(subscription:$0,content:try ruleSubscriptionContent($0,from:root))
        }
    }
    public func restoreRuleSubscriptionFiles(_ database: AppDatabase, from backup: URL) throws {
        for item in database.ruleSubscriptions ?? [] {
            guard let revision = item.revision else { continue }
            let content = try ruleSubscriptionContent(item,from:backup)
            _ = try RuleSubscriptionDownload.payload(content)
            let file = root.appendingPathComponent("rule-subscriptions/\(revision.uuidString).yaml")
            if FileManager.default.fileExists(atPath:file.path) {
                guard try String(contentsOf:file,encoding:.utf8) == content else { throw LumaError.message("备份中的规则集版本与本机缓存冲突") }
            } else { try secureWrite(Data(content.utf8),to:file) }
        }
    }
    public func saveProfile(_ content: String, id: UUID) throws {
        let url = profileURL(id)
        if FileManager.default.fileExists(atPath: url.path) {
            try secureWrite(Data(contentsOf: url), to: url.deletingPathExtension().appendingPathExtension("previous.yaml"))
        }
        try secureWrite(Data(content.utf8), to: url)
    }
    /// A crash before the journal is removed restores the last complete database and snapshots.
    public func commit(_ database: AppDatabase, profiles: [UUID:String]) throws {
        guard !FileManager.default.fileExists(atPath:commitJournal.path) else { throw LumaError.message("有待恢复的配置事务，请重新启动应用") }
        var snapshots = [try snapshot(kind:"database",id:nil)]
        for id in profiles.keys.sorted(by:{$0.uuidString < $1.uuidString}) {
            guard profiles[id]!.utf8.count <= 8*1024*1024 else { throw LumaError.message("配置超过 8 MB") }
            snapshots.append(try snapshot(kind:"profile",id:id))
            snapshots.append(try snapshot(kind:"previous",id:id))
        }
        try secureWrite(JSONEncoder().encode(snapshots),to:commitJournal)
        do {
            for (id,content) in profiles { try saveProfile(content,id:id) }
            try save(database)
            try FileManager.default.removeItem(at:commitJournal)
        } catch {
            let original = error
            do { try recoverPendingCommit() }
            catch { throw LumaError.message("保存失败且磁盘恢复尚未完成，请重新启动："+Redactor.clean(original.localizedDescription)) }
            throw original
        }
    }
    private struct Snapshot: Codable {
        var kind: String
        var id: UUID?
        var data: Data?
    }
    private var commitJournal: URL { root.appendingPathComponent("pending-commit.json") }
    private func target(kind: String,id: UUID?) throws -> URL {
        if kind == "database",id == nil { return root.appendingPathComponent("database.json") }
        guard let id else { throw LumaError.message("配置恢复记录无效") }
        if kind == "profile" { return profileURL(id) }
        if kind == "previous" { return profileURL(id).deletingPathExtension().appendingPathExtension("previous.yaml") }
        throw LumaError.message("配置恢复记录包含未知类型")
    }
    private func snapshot(kind: String,id: UUID?) throws -> Snapshot {
        let file = try target(kind:kind,id:id)
        let data = FileManager.default.fileExists(atPath:file.path) ? try Data(contentsOf:file) : nil
        return Snapshot(kind:kind,id:id,data:data)
    }
    private func recoverPendingCommit() throws {
        guard FileManager.default.fileExists(atPath:commitJournal.path) else { return }
        let snapshots = try JSONDecoder().decode([Snapshot].self,from:Data(contentsOf:commitJournal))
        // Validate every path before touching any file.
        let targets = try snapshots.map { try target(kind:$0.kind,id:$0.id) }
        for (snapshot,file) in zip(snapshots,targets) {
            if let data = snapshot.data {
                if (try? Data(contentsOf:file)) != data { try secureWrite(data,to:file) }
            }
            else if FileManager.default.fileExists(atPath:file.path) { try FileManager.default.removeItem(at:file) }
        }
        try FileManager.default.removeItem(at:commitJournal)
    }
    public func secureWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func deleteProfile(_ id: UUID) throws {
        try removeProfileFiles(id)
        try secrets.delete("subscription-\(id.uuidString)")
    }
    public func removeProfileFiles(_ id: UUID) throws {
        for url in [profileURL(id), profileURL(id).deletingPathExtension().appendingPathExtension("previous.yaml")] {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    public func backup(_ database: AppDatabase) throws -> URL {
        let destination = root.appendingPathComponent("backups/\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try secureWrite(encoder.encode(database), to: destination.appendingPathComponent("database.json"))
        let profilesDir = destination.appendingPathComponent("profiles")
        try FileManager.default.copyItem(at: root.appendingPathComponent("profiles"), to: profilesDir)
        for item in database.ruleSubscriptions ?? [] {
            guard let revision = item.revision else { continue }
            try secureWrite(Data(try ruleSubscriptionContent(item).utf8),to:destination.appendingPathComponent("rule-subscriptions/\(revision.uuidString).yaml"))
        }
        // URL credentials intentionally remain in the local Keychain.
        return destination
    }
    public func readBackup(_ backup: URL) throws -> (AppDatabase,[UUID:String]) {
        let database = try JSONDecoder().decode(AppDatabase.self, from: Data(contentsOf: backup.appendingPathComponent("database.json")))
        var contents: [UUID:String] = [:]
        for p in database.profiles {
            let path = backup.appendingPathComponent("profiles/\(p.id.uuidString).yaml")
            let content = try String(contentsOf: path, encoding: .utf8)
            _ = try ConfigComposer.parse(content)
            contents[p.id] = content
        }
        if let active = database.activeProfileID,!database.profiles.contains(where:{$0.id == active}) { throw LumaError.message("备份中的活动订阅不存在") }
        for item in database.ruleSubscriptions ?? [] {
            try item.validate()
            if item.revision != nil { _ = try RuleSubscriptionDownload.payload(ruleSubscriptionContent(item,from:backup)) }
        }
        return (database,contents)
    }
    public func restoreBackup(_ backup: URL) throws -> AppDatabase {
        let (database,contents) = try readBackup(backup)
        _ = try self.backup(load())
        try restoreRuleSubscriptionFiles(database,from:backup)
        try commit(database,profiles:contents)
        return database
    }
}

