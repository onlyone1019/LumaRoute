import XCTest
@testable import LumaRouteCore

@MainActor final class SubscriptionDownloadRouteTests: XCTestCase {
    func testRoutePersistsAcrossSQLiteReopenAndOlderProfilesRemainDirect() throws {
        var profile = Profile(name:"VPS",isRemote:true); profile.downloadRoute = .systemProxy
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(profile)) as? [String:Any])
        legacy.removeValue(forKey:"downloadRoute")
        XCTAssertEqual(try JSONDecoder().decode(Profile.self,from:JSONSerialization.data(withJSONObject:legacy)).downloadRoute,.direct)
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("work/subscription-proxy-20261027/persistence-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try LocalStore(root:root)
        var database = AppDatabase(); database.profiles = [profile]
        try store.commit(database,profiles:[profile.id:"proxies: []"])
        XCTAssertEqual(try LocalStore(root:root).load().profiles.first?.downloadRoute,.systemProxy)
        let (backup,_) = try store.readBackup(store.backup(database))
        XCTAssertEqual(backup.profiles.first?.downloadRoute,.systemProxy)
    }

    func testSystemProxyUsesTargetProtocolAndSupportsSOCKSFallback() throws {
        let settings: [String:Any] = ["HTTPEnable":1,"HTTPProxy":"127.0.0.1","HTTPPort":17890,"HTTPSEnable":1,"HTTPSProxy":"127.0.0.1","HTTPSPort":17891,"SOCKSEnable":1,"SOCKSProxy":"127.0.0.1","SOCKSPort":17892]
        let http = URL(string:"http://example.org/sub")!,https = URL(string:"https://example.org/sub")!
        XCTAssertEqual(try SubscriptionDownloadRoute.systemProxy.proxyURL(for:http,localProxyPort:nil,systemProxies:settings)?.port,17890)
        XCTAssertEqual(try SubscriptionDownloadRoute.systemProxy.proxyURL(for:https,localProxyPort:nil,systemProxies:settings)?.port,17891)
        var socks = settings; socks["HTTPSEnable"] = 0
        XCTAssertEqual(try SubscriptionDownloadRoute.systemProxy.proxyURL(for:https,localProxyPort:nil,systemProxies:socks)?.absoluteString,"socks5h://127.0.0.1:17892")
        XCTAssertThrowsError(try SubscriptionDownloadRoute.systemProxy.proxyURL(for:https,localProxyPort:nil,systemProxies:[:]))
        XCTAssertNil(try SubscriptionDownloadRoute.direct.proxyURL(for:https,localProxyPort:nil,systemProxies:settings))
        XCTAssertThrowsError(try SubscriptionDownloadRoute.lumaRoute.proxyURL(for:https,localProxyPort:nil))
    }

    func testSelectedProxyImportsAnUnreachableSubscriptionWhileDirectFails() async throws {
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("work/subscription-proxy-20261027/fixture-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let process = Process()
        defer { if process.isRunning { process.terminate() }; try? FileManager.default.removeItem(at:root) }
        process.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
        process.arguments = [URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/subscription_proxy_http.py").path,root.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let file = root.appendingPathComponent("port")
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath:file.path) { break }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        let port = try XCTUnwrap(Int(String(contentsOf:file,encoding:.utf8)))
        let address = "http://127.0.0.1:1/sub/fixture-token"
        do { _ = try await SubscriptionFetcher.fetch(address); XCTFail("unreachable direct endpoint succeeded") } catch let error as SubscriptionError {
            XCTAssertTrue(error.localizedDescription.contains("订阅连接失败"))
            XCTAssertFalse(error.localizedDescription.contains("fixture-token"))
        }
        let result = try await SubscriptionFetcher.fetch(address,route:.lumaRoute,localProxyPort:port)
        XCTAssertEqual(try ConfigComposer.parse(result.content)["fixture-route"] as? String,"proxy")
    }
}
