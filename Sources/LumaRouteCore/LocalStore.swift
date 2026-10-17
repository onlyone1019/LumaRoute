import Foundation

public final class LocalStore: Sendable {
    private let ioQueue = DispatchQueue(label:"app.lumaroute.storage",qos:.userInitiated)
    public let root: URL
    public let databaseURL: URL
    public let secrets: SecretStore
    private let sqlite: SQLiteDatabase
    private struct State: Codable {
        var settings: NetworkSettings
        var activeProfileID: UUID?
        var hasStrategies: Bool
        var hasRuleSubscriptions: Bool
        enum CodingKeys: String, CodingKey { case settings, activeProfileID, hasStrategies, hasRuleSubscriptions }
        init(settings: NetworkSettings,activeProfileID: UUID? = nil,hasStrategies: Bool,hasRuleSubscriptions: Bool) {
            self.settings = settings; self.activeProfileID = activeProfileID
            self.hasStrategies = hasStrategies; self.hasRuleSubscriptions = hasRuleSubscriptions
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy:CodingKeys.self)
            settings = try values.decodeIfPresent(NetworkSettings.self,forKey:.settings) ?? NetworkSettings()
            activeProfileID = try values.decodeIfPresent(UUID.self,forKey:.activeProfileID)
            hasStrategies = try values.decodeIfPresent(Bool.self,forKey:.hasStrategies) ?? false
            hasRuleSubscriptions = try values.decodeIfPresent(Bool.self,forKey:.hasRuleSubscriptions) ?? false
        }
    }
    public init(root: URL,secrets: SecretStore? = nil,readOnly: Bool = false) throws {
        self.root = root
        databaseURL = root.appendingPathComponent("lumaroute.sqlite")
        if !readOnly {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path)
            for directory in ["runtime","backups","cores"] {
                try FileManager.default.createDirectory(at:root.appendingPathComponent(directory),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            }
        }
        sqlite = try SQLiteDatabase(file:databaseURL,readOnly:readOnly)
        self.secrets = secrets ?? SQLiteSecrets(database:sqlite)
    }
    public static func applicationRoot() -> URL {
        if let custom = ProcessInfo.processInfo.environment["LUMAROUTE_DATA_DIR"] { return URL(fileURLWithPath:custom) }
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("LumaRoute")
    }
    public func load() throws -> AppDatabase {
        try sqlite.transaction(write:false) {
            guard let data = try sqlite.rows("SELECT payload FROM app_state WHERE id=1").first?.first else { return AppDatabase() }
            let state = try JSONDecoder().decode(State.self,from:data)
            var database = AppDatabase()
            database.settings = state.settings; database.activeProfileID = state.activeProfileID
            database.profiles = try records(Profile.self,table:"profiles")
            database.customRules = try records(CustomRule.self,table:"custom_rules")
            if state.hasStrategies { database.groupStrategies = try records(GroupStrategy.self,table:"group_strategies") }
            if state.hasRuleSubscriptions { database.ruleSubscriptions = try records(RuleSubscription.self,table:"rule_subscriptions") }
            for row in try sqlite.rows("SELECT name,node FROM choices") {
                database.savedChoices[String(decoding:row[0],as:UTF8.self)] = String(decoding:row[1],as:UTF8.self)
            }
            return database
        }
    }
    private func records<T: Decodable>(_ type: T.Type,table: String) throws -> [T] {
        try sqlite.rows("SELECT payload FROM \(table) ORDER BY ordinal").map { try JSONDecoder().decode(type,from:$0[0]) }
    }
    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
    private func replaceRecords<T: Encodable>(_ records: [T],table: String,id: (T)->String) throws {
        var existing = Set(try sqlite.rows("SELECT id FROM \(table)").map { String(decoding:$0[0],as:UTF8.self) })
        var incoming: Set<String> = []
        for (ordinal,record) in records.enumerated() {
            let key = id(record)
            guard incoming.insert(key).inserted else { throw LumaError.message("业务记录标识重复，已保留原数据") }
            existing.remove(key)
            try sqlite.execute("INSERT INTO \(table)(id,ordinal,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET ordinal=excluded.ordinal,payload=excluded.payload WHERE ordinal<>excluded.ordinal OR payload<>excluded.payload",[.text(key),.integer(ordinal),.blob(try encoded(record))])
        }
        for key in existing { try sqlite.execute("DELETE FROM \(table) WHERE id=?",[.text(key)]) }
    }
    private func writeDatabase(_ database: AppDatabase) throws {
        let state = State(settings:database.settings,activeProfileID:database.activeProfileID,hasStrategies:database.groupStrategies != nil,hasRuleSubscriptions:database.ruleSubscriptions != nil)
        try sqlite.execute("INSERT INTO app_state(id,payload) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload WHERE payload<>excluded.payload",[.blob(try encoded(state))])
        try replaceRecords(database.profiles,table:"profiles",id:{$0.id.uuidString})
        try replaceRecords(database.customRules,table:"custom_rules",id:{$0.id.uuidString})
        try replaceRecords(database.groupStrategies ?? [],table:"group_strategies",id:{$0.profileID.uuidString+"/"+$0.group})
        try replaceRecords(database.ruleSubscriptions ?? [],table:"rule_subscriptions",id:{$0.id.uuidString})
        var existing = Set(try sqlite.rows("SELECT name FROM choices").map { String(decoding:$0[0],as:UTF8.self) })
        for (name,node) in database.savedChoices {
            existing.remove(name)
            try sqlite.execute("INSERT INTO choices(name,node) VALUES(?,?) ON CONFLICT(name) DO UPDATE SET node=excluded.node WHERE node<>excluded.node",[.text(name),.text(node)])
        }
        for name in existing { try sqlite.execute("DELETE FROM choices WHERE name=?",[.text(name)]) }
    }
    public func save(_ database: AppDatabase) throws { try sqlite.transaction { try writeDatabase(database) } }
    // A private serial executor keeps SQLite lock waits and encoding off MainActor.
    // Whole compound operations still use the same connection transaction lock.
    private func io<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { continuation.resume(with:Result { try operation() }) }
        }
    }
    public func saveAsync(_ database: AppDatabase) async throws { try await io { try self.save(database) } }
    public func saveSettingsAsync(_ settings: NetworkSettings) async throws {
        try await io {
            try self.sqlite.transaction {
                let data = try self.sqlite.rows("SELECT payload FROM app_state WHERE id=1").first?.first
                var state = try data.map { try JSONDecoder().decode(State.self,from:$0) } ?? State(settings:settings,hasStrategies:false,hasRuleSubscriptions:false)
                state.settings = settings
                try self.sqlite.execute("INSERT INTO app_state(id,payload) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload WHERE payload<>excluded.payload",[.blob(try self.encoded(state))])
            }
        }
    }
    public func saveChoiceAsync(group: String,node: String?) async throws {
        try await io {
            if let node {
                try self.sqlite.execute("INSERT INTO choices(name,node) VALUES(?,?) ON CONFLICT(name) DO UPDATE SET node=excluded.node WHERE node<>excluded.node",[.text(group),.text(node)])
            } else { try self.sqlite.execute("DELETE FROM choices WHERE name=?",[.text(group)]) }
        }
    }
    public func commitAsync(_ database: AppDatabase,profiles: [UUID:String],subscriptionAddresses: [UUID:String] = [:],ruleContents: [UUID:String] = [:],removingProfiles: [UUID] = []) async throws {
        try await io { try self.commit(database,profiles:profiles,subscriptionAddresses:subscriptionAddresses,ruleContents:ruleContents,removingProfiles:removingProfiles) }
    }
    public func backupAsync(_ database: AppDatabase,automatic: Bool = false,preserving: URL? = nil) async throws -> URL {
        try await io { try self.backup(database,automatic:automatic,preserving:preserving) }
    }
    public func commitBackupAsync(_ database: AppDatabase,profiles: [UUID:String],from backup: URL) async throws {
        try await io { try self.commitBackup(database,profiles:profiles,from:backup) }
    }
    public func profileContentAsync(_ id: UUID) async throws -> String {
        try await io { try self.profileContent(id) }
    }
    public func ruleSubscriptionSnapshotsAsync(_ database: AppDatabase,profileID: UUID?,from root: URL? = nil,pendingContents: [UUID:String] = [:]) async throws -> [RuleSubscriptionSnapshot] {
        try await io { try self.ruleSubscriptionSnapshots(database,profileID:profileID,from:root,pendingContents:pendingContents) }
    }
    public func profileContent(_ id: UUID) throws -> String {
        guard let data = try sqlite.rows("SELECT content FROM profile_contents WHERE profile_id=? AND version='current'",[.text(id.uuidString)]).first?.first else {
            throw LumaError.message("订阅配置不存在，请重新导入")
        }
        return String(decoding:data,as:UTF8.self)
    }
    private func writeProfile(_ content: String,id: UUID) throws {
        guard content.utf8.count <= 8*1024*1024 else { throw LumaError.message("配置超过 8 MB") }
        if let current = try sqlite.rows("SELECT content FROM profile_contents WHERE profile_id=? AND version='current'",[.text(id.uuidString)]).first?.first,
           current == Data(content.utf8) { return }
        try sqlite.execute("INSERT INTO profile_contents(profile_id,version,content) SELECT profile_id,'previous',content FROM profile_contents WHERE profile_id=? AND version='current' ON CONFLICT(profile_id,version) DO UPDATE SET content=excluded.content",[.text(id.uuidString)])
        try sqlite.execute("INSERT INTO profile_contents(profile_id,version,content) VALUES(?,'current',?) ON CONFLICT(profile_id,version) DO UPDATE SET content=excluded.content",[.text(id.uuidString),.text(content)])
    }
    public func saveProfile(_ content: String,id: UUID) throws { try sqlite.transaction { try writeProfile(content,id:id) } }
    /// Subscription content, metadata and URL share the same SQLite transaction.
    public func commit(_ database: AppDatabase,profiles: [UUID:String],subscriptionAddresses: [UUID:String] = [:],ruleContents: [UUID:String] = [:],removingProfiles: [UUID] = []) throws {
        try sqlite.transaction {
            for (id,content) in profiles { try writeProfile(content,id:id) }
            for (revision,content) in ruleContents { try writeRuleContent(content,revision:revision) }
            try writeDatabase(database)
            for (id,address) in subscriptionAddresses { try secrets.write(address,key:"subscription-\(id.uuidString)") }
            for id in removingProfiles {
                try sqlite.execute("DELETE FROM profile_contents WHERE profile_id=?",[.text(id.uuidString)])
                try secrets.delete("subscription-\(id.uuidString)")
            }
        }
    }
    private func writeRuleContent(_ content: String,revision: UUID) throws {
        try sqlite.execute("INSERT INTO rule_contents(revision,content) VALUES(?,?) ON CONFLICT(revision) DO UPDATE SET content=excluded.content",[.text(revision.uuidString),.text(content)])
    }
    public func saveRuleSubscriptionContent(_ content: String) throws -> UUID {
        let revision = UUID()
        try writeRuleContent(content,revision:revision)
        return revision
    }
    public func ruleSubscriptionContent(_ item: RuleSubscription,from root: URL? = nil) throws -> String {
        if let root { return try LocalStore(root:root,readOnly:true).ruleSubscriptionContent(item) }
        guard let revision = item.revision else { throw LumaError.message("规则订阅尚未下载，请先更新") }
        guard let data = try sqlite.rows("SELECT content FROM rule_contents WHERE revision=?",[.text(revision.uuidString)]).first?.first else {
            throw LumaError.message("规则订阅缓存不存在，请重新更新")
        }
        return String(decoding:data,as:UTF8.self)
    }
    public func cleanRuleSubscriptionCacheAsync(_ database: AppDatabase) async {
        _ = try? await io { self.cleanRuleSubscriptionCache(database) }
    }
    public func cleanRuleSubscriptionCache(_ database: AppDatabase) {
        let keep = Set((database.ruleSubscriptions ?? []).compactMap(\.revision).map(\.uuidString))
        try? sqlite.transaction {
            for row in try sqlite.rows("SELECT revision FROM rule_contents") {
                let revision = String(decoding:row[0],as:UTF8.self)
                if !keep.contains(revision) { try sqlite.execute("DELETE FROM rule_contents WHERE revision=?",[.text(revision)]) }
            }
        }
    }
    public func ruleSubscriptionSnapshots(_ database: AppDatabase,profileID: UUID?,from root: URL? = nil,pendingContents: [UUID:String] = [:]) throws -> [RuleSubscriptionSnapshot] {
        let source = try root.map { try LocalStore(root:$0,readOnly:true) } ?? self
        return try (database.ruleSubscriptions ?? []).filter { $0.profileID == profileID && $0.enabled }.map {
            RuleSubscriptionSnapshot(subscription:$0,content:try $0.revision.flatMap { pendingContents[$0] } ?? source.ruleSubscriptionContent($0))
        }
    }
    public func secureWrite(_ data: Data,to url: URL) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    public func backup(_ database: AppDatabase,automatic: Bool = false,preserving: URL? = nil) throws -> URL {
        let destination = root.appendingPathComponent("backups/\(automatic ? "auto-":"")\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6))")
        let staging = root.appendingPathComponent("backups/.pending-\(UUID().uuidString)")
        let target = try LocalStore(root:staging)
        do {
            // Build a consistent, filtered snapshot through SQL transactions.
            // Never copy the live database: backups exclude secret rows.
            try sqlite.transaction(write:false) {
                var contents: [UUID:String] = [:]
                for profile in database.profiles { contents[profile.id] = try profileContent(profile.id) }
                let rules = try ruleContentsFor(database)
                try target.commit(database,profiles:contents,ruleContents:rules)
                for profile in database.profiles {
                    if let row = try sqlite.rows("SELECT content FROM profile_contents WHERE profile_id=? AND version='previous'",[.text(profile.id.uuidString)]).first {
                        try target.sqlite.execute("INSERT INTO profile_contents(profile_id,version,content) VALUES(?,'previous',?)",[.text(profile.id.uuidString),.text(String(decoding:row[0],as:UTF8.self))])
                    }
                }
            }
            try FileManager.default.moveItem(at:staging,to:destination)
            if automatic { pruneAutomaticBackups(keeping:destination,preserving:preserving) }
            return destination
        } catch { try? FileManager.default.removeItem(at:staging); throw error }
    }
    private func pruneAutomaticBackups(keeping destination: URL,preserving: URL?) {
        let parent = root.appendingPathComponent("backups")
        guard let entries = try? FileManager.default.contentsOfDirectory(at:parent,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey]) else { return }
        var protected = Set([destination.lastPathComponent])
        if let preserving,preserving.deletingLastPathComponent().standardizedFileURL.path == parent.standardizedFileURL.path {
            protected.insert(preserving.lastPathComponent)
        }
        let automatic = entries.filter {
            let parts = $0.lastPathComponent.split(separator:"-")
            guard parts.count == 3,parts[0] == "auto",Int(parts[1]) != nil,parts[2].count == 6,
                  let values = try? $0.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true && FileManager.default.fileExists(atPath:$0.appendingPathComponent("lumaroute.sqlite").path)
        }.filter { !protected.contains($0.lastPathComponent) }.sorted {
            let first = (try? $0.resourceValues(forKeys:[.creationDateKey]).creationDate) ?? .distantPast
            let second = (try? $1.resourceValues(forKeys:[.creationDateKey]).creationDate) ?? .distantPast
            return first > second
        }
        for entry in automatic.dropFirst(max(0,10-protected.count)) { try? FileManager.default.removeItem(at:entry) }
    }
    private func ruleContentsFor(_ database: AppDatabase) throws -> [UUID:String] {
        var contents: [UUID:String] = [:]
        for item in database.ruleSubscriptions ?? [] {
            if let revision = item.revision { contents[revision] = try ruleSubscriptionContent(item) }
        }
        return contents
    }
    public func readBackup(_ backup: URL) throws -> (AppDatabase,[UUID:String]) {
        guard FileManager.default.fileExists(atPath:backup.appendingPathComponent("lumaroute.sqlite").path) else {
            throw LumaError.message("请选择包含 lumaroute.sqlite 的新版备份目录")
        }
        let source = try LocalStore(root:backup,readOnly:true)
        let database = try source.load()
        var contents: [UUID:String] = [:]
        for profile in database.profiles {
            let content = try source.profileContent(profile.id)
            _ = try ConfigComposer.parse(content)
            contents[profile.id] = content
        }
        if let active = database.activeProfileID,!database.profiles.contains(where:{$0.id == active}) { throw LumaError.message("备份中的活动订阅不存在") }
        for profile in database.profiles {
            if let composition = profile.composition { try composition.validate(profiles:database.profiles) }
        }
        for item in database.ruleSubscriptions ?? [] {
            try item.validate()
            if item.revision != nil { _ = try RuleSubscriptionDownload.payload(source.ruleSubscriptionContent(item)) }
        }
        return (database,contents)
    }
    public func commitBackup(_ database: AppDatabase,profiles: [UUID:String],from backup: URL) throws {
        let source = try LocalStore(root:backup,readOnly:true)
        let rules = try source.ruleContentsFor(database)
        for (revision,content) in rules {
            if let existing = try sqlite.rows("SELECT content FROM rule_contents WHERE revision=?",[.text(revision.uuidString)]).first?.first,
               String(decoding:existing,as:UTF8.self) != content { throw LumaError.message("备份中的规则集版本与本机缓存冲突") }
        }
        try commit(database,profiles:profiles,ruleContents:rules)
    }
    public func restoreBackup(_ backup: URL) throws -> AppDatabase {
        let (database,contents) = try readBackup(backup)
        _ = try self.backup(load(),automatic:true,preserving:backup)
        try commitBackup(database,profiles:contents,from:backup)
        return database
    }
}
