import XCTest
@testable import LumaRouteCore

final class ConcurrencyTests: XCTestCase {
    private func sendable<T: Sendable>(_ type: T.Type) {}

    func testBoundaryTypesHaveCheckedSendableContracts() {
        sendable(AppDatabase.self); sendable(Profile.self); sendable(NetworkSettings.self)
        sendable(SubscriptionComposition.self); sendable(SubscriptionChange.self)
        sendable(GroupStrategy.self); sendable(GroupSelection.self)
        sendable(HelperRequest.self); sendable(HelperResponse.self)
        sendable(MihomoAPI.self); sendable(ConnectionsResponse.self)
        sendable(DiagnosticCheck.self); sendable(SubscriptionDownload.self)
        sendable(CoreRelease.self); sendable(CoreArtifact.self); sendable(CoreUpdates.Selection.self)
        sendable(LocalStore.self); sendable(SQLiteSecrets.self); sendable(MemorySecrets.self)
    }

    func testSnapshotsRemainIndependentAcrossTasksAndHelperEncoding() async throws {
        var database = AppDatabase()
        let profile = Profile(name:"原订阅",isRemote:true)
        database.profiles = [profile]; database.activeProfileID = profile.id
        database.customRules = [CustomRule(payload:"example.org",target:"DIRECT")]
        let original = database
        let updated = try await Task.detached { () throws -> AppDatabase in
            var copy = original
            copy.profiles[0].name = "后台副本"
            copy.savedChoices["默认代理"] = "测试节点"
            var settings = copy.settings; settings.mode = .global; copy.settings = settings
            let request = HelperRequest(action:"apply",rules:copy.customRules,settings:settings,
                strategies:[GroupStrategy(profileID:profile.id,group:"默认代理")],
                selections:[GroupSelection(group:"默认代理",kind:"Selector",node:"测试节点")])
            let wire = try JSONDecoder().decode(HelperRequest.self,from:JSONEncoder().encode(request))
            guard wire.settings == settings,wire.rules == copy.customRules,wire.selections?.first?.node == "测试节点" else {
                throw LumaError.message("跨任务请求编码未保留快照")
            }
            return copy
        }.value
        XCTAssertEqual(database.profiles[0].name,"原订阅")
        XCTAssertTrue(database.savedChoices.isEmpty)
        XCTAssertEqual(database.settings.mode,.rule)
        XCTAssertEqual(updated.profiles[0].name,"后台副本")
        XCTAssertEqual(updated.settings.mode,.global)
        XCTAssertEqual(updated.savedChoices["默认代理"],"测试节点")
    }

    func testConcurrentAsyncStorageAndSecretsDoNotLoseIndependentWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try LocalStore(root:root)
        try await store.saveAsync(AppDatabase())
        var settings = NetworkSettings(); settings.mode = .global
        let proposed = settings
        try await withThrowingTaskGroup(of:Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    try await store.saveChoiceAsync(group:"group-\(index)",node:"node-\(index)")
                    try await store.secrets.writeAsync("secret-\(index)",key:"key-\(index)")
                }
            }
            group.addTask { try await store.saveSettingsAsync(proposed) }
            try await group.waitForAll()
        }
        let saved = try store.load()
        XCTAssertEqual(saved.settings,proposed)
        XCTAssertEqual(saved.savedChoices.count,40)
        for index in 0..<40 {
            XCTAssertEqual(saved.savedChoices["group-\(index)"],"node-\(index)")
            let secret = try await store.secrets.readAsync("key-\(index)")
            XCTAssertEqual(secret,"secret-\(index)")
        }
        // Read through another connection, not an in-memory snapshot.
        let reopened = try LocalStore(root:root)
        XCTAssertEqual(try reopened.load().savedChoices,saved.savedChoices)
    }

    func testMemorySecretsSynchronizesConcurrentReadsWritesAndDeletes() async throws {
        let secrets = MemorySecrets()
        try await withThrowingTaskGroup(of:Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    let key = "key-\(index)"
                    try secrets.write("value-\(index)",key:key)
                    guard try secrets.read(key) == "value-\(index)" else { throw LumaError.message("密钥写入丢失") }
                    try secrets.delete(key)
                    guard try secrets.read(key) == nil else { throw LumaError.message("密钥删除丢失") }
                }
            }
            try await group.waitForAll()
        }
    }

    func testRecoveryRetainsExclusiveLeaseUntilItsCallerReleasesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let binary = URL(fileURLWithPath:"/usr/bin/true")
        let owner = CoreProcessLease(home:root,binary:binary),other = CoreProcessLease(home:root,binary:binary)
        try owner.acquire(); defer { owner.release(); other.release() }
        try await CoreProcessLease.recoverOrphan(home:root,binary:binary)
        XCTAssertThrowsError(try other.acquire(),"async recovery must not release the owner's lock")
        owner.release()
        XCTAssertNoThrow(try other.acquire())
    }
}
