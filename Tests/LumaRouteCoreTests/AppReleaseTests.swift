import XCTest
@testable import LumaRouteCore

final class AppReleaseTests: XCTestCase {
    private func release(tag: String = "v0.1.0",build: Int = 30,architecture: String = "arm64") -> [String:Any] {
        let name = "LumaRoute-0.1.0-build.\(build)-macos-\(architecture).dmg"
        return ["tag_name":tag,"draft":false,"prerelease":false,
                "html_url":"https://github.com/onlyone1019/LumaRoute/releases/tag/\(tag)",
                "assets":[["name":name,"size":1024,"browser_download_url":"https://github.com/onlyone1019/LumaRoute/releases/download/\(tag)/\(name)"]]]
    }
    private func parse(_ value: [String:Any],architecture: String = "arm64") throws -> AppRelease {
        try AppRelease.parse(JSONSerialization.data(withJSONObject:value),architecture:architecture)
    }
    func testNumericVersionAndBuildOrdering() throws {
        let old = try XCTUnwrap(AppVersion(version:"0.1.0",build:29))
        let current = try XCTUnwrap(AppVersion(version:"0.1.0",build:30))
        XCTAssertLessThan(old,current)
        XCTAssertEqual(current,AppVersion(version:"0.1.0",build:30))
        XCTAssertLessThan(try XCTUnwrap(AppVersion(version:"0.9.0",build:999)),try XCTUnwrap(AppVersion(version:"0.10.0",build:1)))
        XCTAssertLessThan(try XCTUnwrap(AppVersion(version:"0.1.0",build:999)),try XCTUnwrap(AppVersion(version:"0.1.1",build:1)))
        for value in ["", "1.2", "01.2.3", "1.2.3-beta", "1.2.3.4", "1.2.999999999999999999999999999"] {
            XCTAssertNil(AppVersion(version:value,build:30))
        }
        XCTAssertNil(AppVersion(version:"0.1.0",build:-1))
    }
    func testStableReleaseSelectsCurrentArchitectureAndReadsBuildFromAsset() throws {
        let arm = release(),intel = release(architecture:"x86_64")
        var both = arm; both["assets"] = (arm["assets"] as! [[String:Any]])+(intel["assets"] as! [[String:Any]])
        let parsed = try parse(both)
        XCTAssertEqual(parsed.version,AppVersion(version:"0.1.0",build:30))
        XCTAssertTrue(parsed.downloadURL.lastPathComponent.hasSuffix("arm64.dmg"))
        XCTAssertTrue(try parse(both,architecture:"x86_64").downloadURL.lastPathComponent.hasSuffix("x86_64.dmg"))
        XCTAssertThrowsError(try parse(arm,architecture:"x86_64"))
        XCTAssertThrowsError(try parse(arm,architecture:"universal"))
    }
    func testBuildTagMustAgreeWithInstaller() throws {
        XCTAssertNoThrow(try parse(release(tag:"v0.1.0-build.30")))
        XCTAssertThrowsError(try parse(release(tag:"v0.1.0-build.31")))
        XCTAssertThrowsError(try parse(release(tag:"v0.1.0-beta")))
        XCTAssertThrowsError(try parse(release(tag:"v0.1.0/other")))
    }
    func testNextStableVersionIsNewerThanInstalledRelease() throws {
        var next = release(tag:"v0.1.1",build:31)
        let name = "LumaRoute-0.1.1-build.31-macos-arm64.dmg"
        next["assets"] = [["name":name,"size":1024,"browser_download_url":"https://github.com/onlyone1019/LumaRoute/releases/download/v0.1.1/\(name)"]]
        let parsed = try parse(next)
        XCTAssertEqual(parsed.version,AppVersion(version:"0.1.1",build:31))
        XCTAssertGreaterThan(parsed.version,try XCTUnwrap(AppVersion(version:"0.1.0",build:30)))
    }
    func testDraftPrereleaseAndForeignReleasePageAreRejected() throws {
        for key in ["draft","prerelease"] {
            var value = release(); value[key] = true
            XCTAssertThrowsError(try parse(value))
        }
        var foreign = release(); foreign["html_url"] = "https://github.com/other/LumaRoute/releases/tag/v0.1.0"
        XCTAssertThrowsError(try parse(foreign))
    }
    func testUntrustedMissingAndAmbiguousInstallersAreRejected() throws {
        let valid = release()
        let installer = (valid["assets"] as! [[String:Any]])[0]
        for url in ["http://github.com/onlyone1019/LumaRoute/file.dmg", "https://example.com/file.dmg", "https://github.com/other/LumaRoute/releases/download/v0.1.0/file.dmg"] {
            var value = valid,asset = installer; asset["browser_download_url"] = url; value["assets"] = [asset]
            XCTAssertThrowsError(try parse(value))
        }
        for size in [0,-1,513*1024*1024] {
            var value = valid,asset = installer; asset["size"] = size; value["assets"] = [asset]
            XCTAssertThrowsError(try parse(value))
        }
        var missing = valid; missing["assets"] = []
        XCTAssertThrowsError(try parse(missing))
        var duplicate = valid; duplicate["assets"] = [installer,installer]
        XCTAssertThrowsError(try parse(duplicate))
        XCTAssertThrowsError(try AppRelease.parse(Data("not json".utf8)))
    }
    func testLatestUsesPublicStableEndpointAndHandlesFailures() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppReleaseProtocol.self]
        let session = URLSession(configuration:configuration)
        defer { session.invalidateAndCancel(); AppReleaseProtocol.handler = nil }
        let data = try JSONSerialization.data(withJSONObject:release(architecture:AppRelease.architecture))
        AppReleaseProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString,"https://api.github.com/repos/onlyone1019/LumaRoute/releases/latest")
            XCTAssertEqual(request.value(forHTTPHeaderField:"Accept"),"application/vnd.github+json")
            XCTAssertNil(request.value(forHTTPHeaderField:"Authorization"))
            return (200,data)
        }
        let latest = try await AppRelease.latest(session:session)
        XCTAssertEqual(latest.version.build,30)
        for (status,message) in [(403,"受到限制"),(429,"受到限制"),(404,"没有可用"),(500,"无法读取")] {
            AppReleaseProtocol.handler = { _ in (status,Data()) }
            do { _ = try await AppRelease.latest(session:session); XCTFail("HTTP \(status) should fail") }
            catch { XCTAssertTrue(error.localizedDescription.contains(message)) }
        }
        AppReleaseProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await AppRelease.latest(session:session); XCTFail("Offline should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("检查网络")) }
    }
}

private final class AppReleaseProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int,Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status,data) = try handler(request)
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}
