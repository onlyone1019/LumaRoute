import XCTest
@testable import LumaRouteCore

final class AppUpdateHandoffTests: XCTestCase {
    func testRestartRetainsActualNetworkSwitchesWithoutChangingLaunchPreference() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try LocalStore(root:root)
        defer { try? FileManager.default.removeItem(at:root) }
        var database = AppDatabase()
        database.settings.connectOnLaunch = false
        database.settings.systemProxy = true; database.settings.tun = true
        database.customRules = [CustomRule(type:"DOMAIN",payload:"example.com")]
        database.savedChoices = ["default":"test-node"]
        try store.save(database)
        let before = try Data(contentsOf:store.databaseURL)
        try AppUpdateHandoff(targetBuild:38,settings:database.settings).save(in:root)
        let restart = try XCTUnwrap(AppUpdateHandoff.take(in:root,currentBuild:38))
        XCTAssertTrue(restart.systemProxy); XCTAssertTrue(restart.tun)
        XCTAssertNil(try AppUpdateHandoff.take(in:root,currentBuild:38))
        XCTAssertEqual(try Data(contentsOf:store.databaseURL),before)
        XCTAssertFalse(try store.load().settings.connectOnLaunch)
        XCTAssertEqual(try store.load().savedChoices,database.savedChoices)
    }
    func testOldWrongBuildFutureAndMalformedMarkersNeverResumeNetworking() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let now = Date()
        for (build,date) in [(37,now),(38,now.addingTimeInterval(-3601)),(38,now.addingTimeInterval(1))] {
            try AppUpdateHandoff(targetBuild:build,settings:NetworkSettings(),now:date).save(in:root)
            XCTAssertNil(try AppUpdateHandoff.take(in:root,currentBuild:38,now:now))
            XCTAssertNil(try AppUpdateHandoff.take(in:root,currentBuild:38,now:now))
        }
        try Data("invalid".utf8).write(to:root.appendingPathComponent("app-update-restart.json"))
        XCTAssertNil(try AppUpdateHandoff.take(in:root,currentBuild:38))
    }
}
