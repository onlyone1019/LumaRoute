import XCTest
@testable import LumaRouteCore

final class PersistenceDecodingTests: XCTestCase {
    private var fixtureRoot: URL {
        URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Persistence/v1")
    }
    private func fixture(_ name: String = "database.json") throws -> Data { try Data(contentsOf:fixtureRoot.appendingPathComponent(name)) }
    private func database() throws -> AppDatabase { try JSONDecoder().decode(AppDatabase.self,from:fixture()) }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        return root
    }
    private func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
    private func assertRoundTrip<T: Codable>(_ value: T,file: StaticString = #filePath,line: UInt = #line) throws {
        let data = try canonical(value)
        XCTAssertEqual(try canonical(JSONDecoder().decode(T.self,from:data)),data,file:file,line:line)
    }

    func testFrozenV1DecodesMissingOptionsWithoutLosingStoredValuesOrIdentities() throws {
        let database = try database()
        XCTAssertEqual(database.profiles.map(\.id.uuidString),["11111111-1111-4111-8111-111111111111","22222222-2222-4222-8222-222222222222","33333333-3333-4333-8333-333333333333"])
        XCTAssertEqual(database.activeProfileID,database.profiles[2].id)
        var settings = NetworkSettings(); settings.mixedPort = 20890; settings.controllerPort = 20891; settings.tun = true; settings.appearance = "dark"
        XCTAssertEqual(database.settings,settings)
        let profile = database.profiles[0]
        XCTAssertEqual(profile.name,"旧订阅 A"); XCTAssertTrue(profile.isRemote)
        XCTAssertEqual(profile.created,Date(timeIntervalSinceReferenceDate:0))
        XCTAssertEqual(database.profiles[1].created,Date(timeIntervalSince1970:0),"missing dates use a stable historical value")
        XCTAssertEqual(profile.displaySource,"本地配置"); XCTAssertEqual(profile.updateHours,6); XCTAssertEqual(profile.nodeCount,0)
        XCTAssertNil(profile.userAgent); XCTAssertNil(profile.lastUpdated); XCTAssertNil(profile.lastError)
        XCTAssertEqual(profile.usage?.upload,12); XCTAssertEqual(profile.usage?.download,0); XCTAssertNil(profile.usage?.total)
        XCTAssertEqual(profile.lastChange?.addedNodes,["新增节点"]); XCTAssertEqual(profile.lastChange?.changedNodes,[])
        XCTAssertEqual(profile.lastChange?.containsProviders,false); XCTAssertEqual(profile.lastChange?.uriNamesOnly,false)
        let rule = try XCTUnwrap(database.customRules.first)
        XCTAssertEqual(rule.type,"DOMAIN-SUFFIX"); XCTAssertTrue(rule.enabled); XCTAssertEqual(rule.target,"DIRECT")
        let strategy = try XCTUnwrap(database.groupStrategies?.first)
        XCTAssertEqual(strategy.mode,.subscription); XCTAssertEqual(strategy.candidateFilter,""); XCTAssertEqual(strategy.interval,60); XCTAssertEqual(strategy.tolerance,50)
        let composition = try XCTUnwrap(database.profiles[2].composition)
        XCTAssertEqual(composition.profileIDs,Array(database.profiles.prefix(2).map(\.id)))
        XCTAssertNil(composition.fallbackProfileID); XCTAssertTrue(composition.customRules.isEmpty)
        XCTAssertTrue(composition.domainRoutes[0].enabled); XCTAssertEqual(composition.domainRoutes[0].type,"DOMAIN-SUFFIX")
        XCTAssertEqual(composition.domainRoutes[0].profileID,database.profiles[1].id)
        try composition.validate(profiles:database.profiles)
        let subscription = try XCTUnwrap(database.ruleSubscriptions?.first)
        XCTAssertEqual(subscription.profileID,database.activeProfileID)
        XCTAssertTrue(subscription.enabled); XCTAssertTrue(subscription.autoUpdate); XCTAssertEqual(subscription.intervalHours,24)
        XCTAssertEqual(subscription.priority,.supplement); XCTAssertEqual(subscription.ruleCount,0); XCTAssertNil(subscription.revision)
        try subscription.validate()
        try assertRoundTrip(database)
    }

    func testEmptyAndNullOptionsUseCurrentInitializationDefaults() throws {
        XCTAssertEqual(try JSONDecoder().decode(NetworkSettings.self,from:Data("{}".utf8)),NetworkSettings())
        XCTAssertEqual(try JSONDecoder().decode(NetworkSettings.self,from:Data("{\"tun\":null,\"mode\":null}".utf8)),NetworkSettings())
        let empty = try JSONDecoder().decode(AppDatabase.self,from:Data("{}".utf8))
        XCTAssertTrue(empty.profiles.isEmpty); XCTAssertTrue(empty.customRules.isEmpty); XCTAssertTrue(empty.savedChoices.isEmpty)
        XCTAssertNil(empty.activeProfileID); XCTAssertNil(empty.groupStrategies); XCTAssertNil(empty.ruleSubscriptions)
        XCTAssertEqual(empty.settings,NetworkSettings())
        let configured = try JSONDecoder().decode(AppDatabase.self,from:Data("{\"groupStrategies\":[],\"ruleSubscriptions\":[]}".utf8))
        XCTAssertEqual(configured.groupStrategies,[]); XCTAssertEqual(configured.ruleSubscriptions,[])
    }

    func testMalformedPresentValuesAndRequiredIdentitiesStillFail() throws {
        for json in ["{\"tun\":\"yes\"}","{\"mode\":\"unknown-mode\"}","{\"testTimeout\":{}}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(NetworkSettings.self,from:Data(json.utf8)))
        }
        let data = try fixture()
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        let profile = try XCTUnwrap((original["profiles"] as? [[String:Any]])?.first)
        for field in ["id","name","isRemote"] {
            var missing = profile; missing.removeValue(forKey:field)
            XCTAssertThrowsError(try JSONDecoder().decode(Profile.self,from:JSONSerialization.data(withJSONObject:missing)),field)
        }
        for (type,json) in [("rule","{\"id\":\"55555555-5555-4555-8555-555555555555\",\"payload\":\"example.org\"}"),
                            ("strategy","{\"group\":\"choice\"}")] {
            if type == "rule" { XCTAssertThrowsError(try JSONDecoder().decode(CustomRule.self,from:Data(json.utf8))) }
            else { XCTAssertThrowsError(try JSONDecoder().decode(GroupStrategy.self,from:Data(json.utf8))) }
        }
    }

    func testExplicitNondefaultValuesAndOptionalMetadataRoundTrip() throws {
        var value = try database()
        var settings = NetworkSettings()
        settings.mixedPort = 20900; settings.controllerPort = 20901; settings.mode = .global
        settings.tun = true; settings.stack = "gvisor"; settings.autoRoute = false; settings.autoDetectInterface = false
        settings.excludeLAN = false; settings.mtu = 2048; settings.dnsHijack = false; settings.fakeIP = false
        settings.ipv6 = true; settings.systemProxy = true; settings.bypass = []
        settings.autoLaunch = true; settings.connectOnLaunch = true; settings.testURL = "https://example.org/probe"
        settings.testTimeout = 4321; settings.testConcurrency = 9; settings.appearance = "light"; settings.updateIntervalHours = 1.5
        value.settings = settings
        var profile = value.profiles[0]
        profile.displaySource = "显示来源"; profile.created = Date(timeIntervalSince1970:1234567890)
        profile.lastUpdated = Date(timeIntervalSince1970:1234567891); profile.lastAttempt = Date(timeIntervalSince1970:1234567892)
        profile.lastError = "合成错误"; profile.nodeCount = 42; profile.updateHours = 2.5; profile.userAgent = "Custom/2.0"
        profile.usage = SubscriptionUsage(header:"upload=5; download=9; total=100; expire=1800000000")
        var change = try XCTUnwrap(profile.lastChange)
        change.removedNodes = ["removed"]; change.changedNodes = ["changed"]; change.addedGroups = ["added"]
        change.removedGroups = ["removed"]; change.changedProviders = ["provider"]; change.selectedNodesRemoved = ["selected"]
        change.containsProviders = true; change.uriNamesOnly = true; profile.lastChange = change
        value.profiles[0] = profile
        value.customRules[0].enabled = false; value.customRules[0].type = "DOMAIN"; value.customRules[0].target = "REJECT"
        value.groupStrategies?[0].mode = .lowestLatency; value.groupStrategies?[0].candidateFilter = "node"
        value.groupStrategies?[0].interval = 35; value.groupStrategies?[0].tolerance = 7
        value.ruleSubscriptions?[0].enabled = false; value.ruleSubscriptions?[0].autoUpdate = false
        value.ruleSubscriptions?[0].intervalHours = 7; value.ruleSubscriptions?[0].priority = .override
        value.ruleSubscriptions?[0].revision = UUID(); value.ruleSubscriptions?[0].ruleCount = 15
        value.ruleSubscriptions?[0].lastUpdated = profile.lastUpdated; value.ruleSubscriptions?[0].lastAttempt = profile.lastAttempt
        value.ruleSubscriptions?[0].lastError = "rule fixture"
        let fallbackID = value.profiles[1].id
        value.profiles[2].composition?.fallbackProfileID = fallbackID
        value.profiles[2].composition?.customRules = value.customRules
        value.profiles[2].composition?.domainRoutes[0].enabled = false
        value.profiles[2].composition?.domainRoutes[0].type = "DOMAIN"
        value.profiles[2].composition?.domainRoutes[0].target = "REJECT"
        try assertRoundTrip(value)
        let wire = try JSONDecoder().decode(HelperRequest.self,from:JSONEncoder().encode(HelperRequest(action:"apply",settings:settings)))
        XCTAssertEqual(wire.settings,settings,"persistence defaults must preserve explicit XPC settings")
    }

    private func assertEncodingKeys<T: Encodable>(_ value: T,file: StaticString = #filePath,line: UInt = #line) throws {
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with:canonical(value)) as? [String:Any])
        for field in Mirror(reflecting:value).children {
            let reflection = Mirror(reflecting:field.value)
            if reflection.displayStyle == .optional && reflection.children.isEmpty { continue }
            let name = try XCTUnwrap(field.label)
            XCTAssertNotNil(encoded[name],"stored property \(T.self).\(name) needs a CodingKey",file:file,line:line)
        }
    }

    func testPersistedFieldsKeepEncodingKeysWhenModelsGrow() throws {
        let value = try database()
        try assertEncodingKeys(value); try assertEncodingKeys(value.settings)
        for profile in value.profiles { try assertEncodingKeys(profile) }
        try assertEncodingKeys(try XCTUnwrap(value.profiles[0].usage))
        try assertEncodingKeys(try XCTUnwrap(value.profiles[0].lastChange))
        try assertEncodingKeys(try XCTUnwrap(value.profiles[2].composition))
        try assertEncodingKeys(try XCTUnwrap(value.profiles[2].composition?.domainRoutes.first))
        try assertEncodingKeys(try XCTUnwrap(value.customRules.first))
        try assertEncodingKeys(try XCTUnwrap(value.groupStrategies?.first))
        try assertEncodingKeys(try XCTUnwrap(value.ruleSubscriptions?.first))
    }

    private func seed(_ store: LocalStore,stateFile: String = "sqlite-state.json") throws -> SQLiteDatabase {
        let sqlite = try SQLiteDatabase(file:store.databaseURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with:fixture()) as? [String:Any])
        try sqlite.execute("INSERT INTO app_state(id,payload) VALUES(1,?)",[.blob(try fixture(stateFile))])
        for (field,table) in [("profiles","profiles"),("customRules","custom_rules"),("groupStrategies","group_strategies"),("ruleSubscriptions","rule_subscriptions")] {
            if stateFile == "sqlite-state-minimal.json" && ["groupStrategies","ruleSubscriptions"].contains(field) { continue }
            let records = try XCTUnwrap(object[field] as? [[String:Any]])
            for (ordinal,record) in records.enumerated() {
                let id = record["id"] as? String ?? ((record["profileID"] as! String)+"/"+(record["group"] as! String))
                try sqlite.execute("INSERT INTO \(table)(id,ordinal,payload) VALUES(?,?,?)",[.text(id),.integer(ordinal),.blob(try JSONSerialization.data(withJSONObject:record))])
                if table == "profiles" {
                    try sqlite.execute("INSERT INTO profile_contents(profile_id,version,content) VALUES(?,'current',?)",[.text(id),.text("proxies: []\nrules: ['MATCH,DIRECT']\n")])
                }
            }
        }
        for (name,node) in try XCTUnwrap(object["savedChoices"] as? [String:String]) {
            try sqlite.execute("INSERT INTO choices(name,node) VALUES(?,?)",[.text(name),.text(node)])
        }
        return sqlite
    }

    func testFrozenV1SQLiteLoadsWithoutRewritingThenSurvivesSaveBackupAndRestore() throws {
        let store = try LocalStore(root:root()),sqlite = try seed(store)
        let original = try Data(contentsOf:store.databaseURL)
        let loaded = try store.load()
        XCTAssertEqual(try canonical(loaded),try canonical(database()))
        XCTAssertEqual(try Data(contentsOf:store.databaseURL),original,"default decoding must not rewrite the source database")
        XCTAssertEqual(try sqlite.rows("PRAGMA user_version").first?.first,Data("1".utf8))
        try store.secrets.write("synthetic-controller",key:"controller-secret")
        try store.save(loaded)
        XCTAssertEqual(try canonical(LocalStore(root:store.root).load()),try canonical(loaded))
        let backup = try store.backup(loaded)
        let (restored,contents) = try store.readBackup(backup)
        XCTAssertEqual(try canonical(restored),try canonical(loaded)); XCTAssertEqual(contents.count,3)
        XCTAssertEqual(try store.secrets.read("controller-secret"),"synthetic-controller")
    }

    func testMissingSQLiteSettingsAndFlagsUseDefaultsAndCanSaveSettingsAsync() async throws {
        let store = try LocalStore(root:root())
        _ = try seed(store,stateFile:"sqlite-state-minimal.json")
        let loaded = try store.load()
        XCTAssertEqual(loaded.settings,NetworkSettings()); XCTAssertNil(loaded.groupStrategies); XCTAssertNil(loaded.ruleSubscriptions)
        var next = loaded.settings; next.appearance = "light"
        try await store.saveSettingsAsync(next)
        let reopened = try LocalStore(root:store.root).load()
        XCTAssertEqual(reopened.settings,next); XCTAssertEqual(reopened.activeProfileID,loaded.activeProfileID)
        XCTAssertEqual(reopened.profiles,loaded.profiles); XCTAssertNil(reopened.groupStrategies); XCTAssertNil(reopened.ruleSubscriptions)
    }

    func testMalformedSQLitePayloadFailsWithoutReplacingStoredData() throws {
        let store = try LocalStore(root:root()),sqlite = try seed(store)
        try sqlite.execute("UPDATE app_state SET payload=? WHERE id=1",[.blob(Data("{\"settings\":{\"tun\":\"yes\"}}".utf8))])
        let before = try Data(contentsOf:store.databaseURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf:store.databaseURL),before)
    }
}
