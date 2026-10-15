import Foundation
import SQLite3
import LumaRouteCore

/// Real disk/SQLite transactions; no user database, Keychain or network access.
enum SQLiteStoreSuite {
    static func run() throws -> Int {
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("work/sqlite-regression-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        var count = 0
        func check(_ condition:Bool,_ name:String) throws {
            guard condition else { throw LumaError.message("SQLite 验收失败："+name) }
            count += 1; print("PASS "+name)
        }
        func sql(_ statement: String,at file: URL) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(file.path,&handle) == SQLITE_OK else { throw LumaError.message("无法打开测试数据库") }
            defer { sqlite3_close(handle) }
            guard sqlite3_exec(handle,statement,nil,nil,nil) == SQLITE_OK else { throw LumaError.message("测试 SQL 执行失败") }
        }
        var old = AppDatabase(); old.profiles = [Profile(name:"不得迁移",isRemote:true)]
        let oldFile = root.appendingPathComponent("database.json")
        let oldData = try JSONEncoder().encode(old)
        try oldData.write(to:oldFile)
        let store = try LocalStore(root:root)
        try check(try store.load().profiles.isEmpty && store.secrets.read("controller-secret") == nil,"新库为空，不读取旧 JSON 或钥匙串")
        try check(try Data(contentsOf:oldFile) == oldData,"旧业务文件原样保留")
        let profile = Profile(name:"SQLite 本地验收",isRemote:true)
        let input = "proxies: []\nproxy-groups: []\nrules: ['MATCH,DIRECT']\n"
        var database = AppDatabase()
        database.profiles = [profile]; database.activeProfileID = profile.id
        database.settings.appearance = "dark"; database.settings.testConcurrency = 8
        database.customRules = [CustomRule(payload:"example.org",target:"DIRECT")]
        database.groupStrategies = [GroupStrategy(profileID:profile.id,group:"默认策略")]
        database.savedChoices = ["默认策略":"DIRECT"]
        var rule = RuleSubscription(profileID:profile.id,catalogID:"icloud",target:"DIRECT")
        let content = "payload:\n  - '+.example.org'\n"
        rule.revision = UUID(); database.ruleSubscriptions = [rule]
        let url = "https://example.invalid/subscription?token=synthetic-'中文-🌓"
        let key = "subscription-"+profile.id.uuidString
        try store.commit(database,profiles:[profile.id:input],subscriptionAddresses:[profile.id:url],ruleContents:[rule.revision!:content])
        try store.secrets.write("synthetic-controller",key:"controller-secret")
        let reloaded = try LocalStore(root:root)
        let actual = try reloaded.load()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        try check(try encoder.encode(actual) == encoder.encode(database),"设置、订阅、规则、策略和节点选择重开后完整保留")
        try check(try reloaded.profileContent(profile.id) == input && reloaded.ruleSubscriptionContent(rule) == content,"订阅与规则原文保存在 SQLite")
        try check(try reloaded.secrets.read(key) == url && reloaded.secrets.read("controller-secret") == "synthetic-controller","订阅凭据和控制密钥重开后读取一致")
        try check(!FileManager.default.fileExists(atPath:root.appendingPathComponent("profiles").path) && !FileManager.default.fileExists(atPath:root.appendingPathComponent("rule-subscriptions").path),"业务保存不再生成订阅和规则文件目录")
        let attributes = try FileManager.default.attributesOfItem(atPath:store.databaseURL.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath:root.path)
        try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 && (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,"数据库 0600，数据目录 0700")
        let binarySecret = "字符\0串'🌓"
        try store.secrets.write(binarySecret,key:"empty-test"); try check(try store.secrets.read("empty-test") == binarySecret,"绑定值保留中文、引号和零字符")
        try store.secrets.write("",key:"empty-test"); try check(try store.secrets.read("empty-test") == "","空值与不存在的密钥可区分")
        try store.secrets.delete("empty-test"); try check(try store.secrets.read("empty-test") == nil,"删除密钥后不会从旧存储补回")
        try sql("CREATE TRIGGER reject_delete BEFORE DELETE ON profile_contents BEGIN SELECT RAISE(ABORT,'sensitive-synthetic-credential'); END",at:store.databaseURL)
        var next = database; next.profiles[0].name = "不得残留"; next.settings.testConcurrency = 9
        var rejected = false; var cleanError = false
        do {
            try store.commit(next,profiles:[profile.id:input+"# new\n"],subscriptionAddresses:[profile.id:"synthetic-new-url"],ruleContents:[rule.revision!:"payload: [new]"],removingProfiles:[profile.id])
        } catch { rejected = true; cleanError = !error.localizedDescription.contains("sensitive-synthetic-credential") }
        try sql("DROP TRIGGER reject_delete",at:store.databaseURL)
        try check(rejected && cleanError,"事务末尾失败会报告错误，错误不包含 SQL 凭据")
        try check(try store.load().settings == database.settings && store.load().profiles == database.profiles && store.profileContent(profile.id) == input && store.secrets.read(key) == url && store.ruleSubscriptionContent(rule) == content,"失败回滚内容、元数据、设置、规则缓存和订阅链接")
        try store.commit(database,profiles:[profile.id:input+"# second\n"])
        let backup = try store.backup(database)
        let exported = try LocalStore(root:backup,readOnly:true)
        try check(try exported.secrets.read(key) == nil && exported.secrets.read("controller-secret") == nil,"SQLite 备份排除链接和控制密钥")
        try check(try exported.profileContent(profile.id).hasSuffix("# second\n") && exported.ruleSubscriptionContent(rule) == content,"SQLite 备份包含业务内容和规则缓存")
        try store.commit(next,profiles:[profile.id:input+"# third\n"])
        let restored = try store.restoreBackup(backup)
        try check(restored.settings == database.settings && (try store.profileContent(profile.id)).hasSuffix("# second\n"),"SQLite 备份恢复设置与订阅内容")
        try check(try store.secrets.read(key) == url && store.secrets.read("controller-secret") == "synthetic-controller","恢复备份保留本机密钥，不使用备份覆盖")
        var removed = restored; removed.profiles = []; removed.activeProfileID = nil; removed.ruleSubscriptions = []; removed.groupStrategies = []
        try store.commit(removed,profiles:[:],removingProfiles:[profile.id])
        var missingContent = false
        do { _ = try store.profileContent(profile.id) } catch { missingContent = true }
        try check(try store.load().profiles.isEmpty && store.secrets.read(key) == nil && missingContent,"删除订阅原子删除元数据、内容和链接")
        try check(try store.secrets.read("controller-secret") == "synthetic-controller","删除订阅保留控制密钥")
        let corruptRoot = root.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at:corruptRoot,withIntermediateDirectories:true)
        let corruptFile = corruptRoot.appendingPathComponent("lumaroute.sqlite")
        let corrupt = Data("not-a-database-synthetic".utf8); try corrupt.write(to:corruptFile)
        var corruptRejected = false
        do { _ = try LocalStore(root:corruptRoot) } catch { corruptRejected = true }
        try check(corruptRejected && (try Data(contentsOf:corruptFile)) == corrupt,"损坏数据库报错并保留原文件，不当作空库覆盖")
        let futureRoot = root.appendingPathComponent("future")
        let future = try LocalStore(root:futureRoot)
        try sql("PRAGMA user_version=99",at:future.databaseURL)
        let before = try Data(contentsOf:future.databaseURL)
        var futureRejected = false
        do { _ = try LocalStore(root:futureRoot) } catch { futureRejected = true }
        try check(futureRejected && (try Data(contentsOf:future.databaseURL)) == before,"拒绝未知数据库版本并保留原数据")
        return count
    }
}
