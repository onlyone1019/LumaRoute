import XCTest
@testable import LumaRouteCore

final class VersionInfoTests: XCTestCase {
    private func bundle(_ metadata: [String:Any] = [:]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".bundle")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at:contents,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        var info = metadata; info["CFBundleIdentifier"] = "test.lumaroute."+UUID().uuidString
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url:root))
    }
    private var metadata: [String:Any] {
        ["CFBundleShortVersionString":"9.8.7","CFBundleVersion":"123","LumaRouteCoreVersion":"v1.88.4"]
    }
    func testBundleIsTheSourceForAppBuildAndBundledCore() throws {
        let info = VersionInfo(bundle:try bundle(metadata))
        XCTAssertEqual(info.application?.label,"9.8.7 · Build 123")
        XCTAssertEqual(info.userAgent,"LumaRoute/9.8.7")
        XCTAssertEqual(info.subscriptionUserAgent,"clash.meta/1.88.4 LumaRoute/9.8.7")
        var next = metadata; next["CFBundleShortVersionString"] = "10.2.3"; next["CFBundleVersion"] = "456"
        next["LumaRouteCoreVersion"] = "v2.3.4"
        let updated = VersionInfo(bundle:try bundle(next))
        XCTAssertEqual(updated.application?.label,"10.2.3 · Build 456")
        XCTAssertEqual(updated.subscriptionUserAgent,"clash.meta/2.3.4 LumaRoute/10.2.3")
    }
    func testSelectedOrRunningCoreOverridesTheBundledVersionWithoutStaleCache() throws {
        let source = try bundle(metadata)
        for version in ["v2.4.6","3.5.7","v1.88.4"] {
            let info = VersionInfo(bundle:source,coreVersion:version)
            XCTAssertEqual(info.subscriptionUserAgent,"clash.meta/\(version.hasPrefix("v") ? String(version.dropFirst()):version) LumaRoute/9.8.7")
        }
    }
    func testMissingOrInvalidMetadataNeverInventsAReleaseVersionOrUnsafeHeader() throws {
        let missing = VersionInfo(bundle:try bundle())
        XCTAssertNil(missing.application); XCTAssertNil(missing.core)
        XCTAssertEqual(missing.subscriptionUserAgent,"clash.meta/unknown LumaRoute/unknown")
        XCTAssertTrue(missing.diagnostics(logs:[],coreStatus:"尚未运行").hasPrefix("LumaRoute 开发版本\nMihomo 尚未运行\n"))
        for value in ["", "1.2", "v1.2.3\r\nInjected: value", "尚未运行", "v1.2.3-beta"] {
            var bad = metadata; bad["CFBundleShortVersionString"] = value; bad["LumaRouteCoreVersion"] = value
            let info = VersionInfo(bundle:try bundle(bad))
            XCTAssertEqual(info.subscriptionUserAgent,"clash.meta/unknown LumaRoute/unknown",value)
            XCTAssertNil(VersionInfo(bundle:try bundle(metadata),coreVersion:value).core,value)
        }
    }
    func testDiagnosticsIncludesAppBuildRuntimeCoreAndRedactedSnapshot() throws {
        let info = VersionInfo(bundle:try bundle(metadata))
        var entry = LogEntry(level:"warning",source:"测试",message:"placeholder")
        // Export also protects decoded/mutated log entries that bypassed init.
        entry.message = "中文 https://example.org/sub?token=private password=credential"
        let text = info.diagnostics(logs:[entry],coreStatus:"v2.4.6")
        XCTAssertTrue(text.hasPrefix("LumaRoute 9.8.7 · Build 123\nMihomo v2.4.6\n"))
        XCTAssertTrue(text.contains("[warning] [测试] 中文"))
        XCTAssertTrue(text.contains("[已隐藏]"))
        XCTAssertFalse(text.contains("private")); XCTAssertFalse(text.contains("credential"))
        XCTAssertFalse(text.contains("1.88.4"),"diagnostics must report runtime core rather than bundled core")
    }
    func testSubscriptionSessionUsesBundleMetadataAndPreservesCustomUserAgent() async throws {
        let fixture = HTTPFixture { _ in throw URLError(.badServerResponse) }
        defer { fixture.close() }
        let source = try bundle(metadata)
        for version in [nil,"v2.4.6"] as [String?] {
            let info = VersionInfo(bundle:source,coreVersion:version)
            for custom in [nil,"   "," Provider-A/2.0 "] as [String?] {
                let expected = custom?.contains("Provider-A") == true ? "Provider-A/2.0":info.subscriptionUserAgent
                fixture.setHandler { request in
                    XCTAssertEqual(request.value(forHTTPHeaderField:"User-Agent"),expected)
                    return (200,Data("proxies: []\nproxy-groups: []\nrules: []\n".utf8))
                }
                _ = try await SubscriptionFetcher.fetch("https://fixture.example/sub",userAgent:custom,session:fixture.session,versionInfo:info)
            }
        }
        XCTAssertEqual(SubscriptionFetcher.defaultUserAgent,VersionInfo.current.subscriptionUserAgent)
    }
    func testDirectAndSessionTransportsSendTheSameDynamicUserAgent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let process = Process()
        defer { if process.isRunning { process.terminate() }; try? FileManager.default.removeItem(at:root) }
        process.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
        process.arguments = [URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/version_http.py").path,root.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let portFile = root.appendingPathComponent("port")
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath:portFile.path) { break }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        let port = try XCTUnwrap(Int(String(contentsOf:portFile,encoding:.utf8)))
        let info = VersionInfo(bundle:try bundle(metadata),coreVersion:"v2.4.6")
        let session = URLSession(configuration:.ephemeral)
        defer { session.invalidateAndCancel() }
        for transport in [nil,session] as [URLSession?] {
            for custom in [nil,"   "," Custom-Agent/4.0 \"quoted\" \\route "] as [String?] {
                let result = try await SubscriptionFetcher.fetch("http://127.0.0.1:\(port)/subscription",userAgent:custom,session:transport,versionInfo:info)
                let observed = try ConfigComposer.parse(result.content)["fixture-user-agent"] as? String
                XCTAssertEqual(observed,try SubscriptionFetcher.normalizedUserAgent(custom) ?? info.subscriptionUserAgent)
            }
        }
    }
    func testConcurrentSubscriptionSessionsKeepTheirOwnUserAgentsAndResponses() async throws {
        let source = try bundle(metadata)
        let cases = (0..<24).map { index in
            (index,VersionInfo(bundle:source,coreVersion:"v\(index).2.3"),index.isMultiple(of:2) ? "Provider-\(index)/1.0":nil)
        }
        try await withThrowingTaskGroup(of:Void.self) { group in
            for (index,info,custom) in cases {
                group.addTask {
                    let expected = custom ?? info.subscriptionUserAgent
                    let fixture = HTTPFixture { request in
                        XCTAssertEqual(request.value(forHTTPHeaderField:"User-Agent"),expected)
                        return (200,Data("proxies: []\nfixture-identifier: \(index)\n".utf8))
                    }
                    defer { fixture.close() }
                    await Task.yield()
                    let result = try await SubscriptionFetcher.fetch("https://fixture.example/sub",userAgent:custom,session:fixture.session,versionInfo:info)
                    XCTAssertEqual(try ConfigComposer.parse(result.content)["fixture-identifier"] as? Int,index)
                }
            }
            try await group.waitForAll()
        }
    }
}
