import XCTest
@testable import LumaRouteCore

final class GeoSitePolicyTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func policy() throws -> GeoSitePolicy { try GeoSitePolicy.load(from:root.appendingPathComponent("Resources/GeoData/GeoSite-policy.json")) }
    private func message(_ field: UInt8,_ data: Data) -> Data {
        var size = data.count,bytes: [UInt8] = [field << 3 | 2]
        while size >= 128 { bytes.append(UInt8(size & 127)|128); size >>= 7 }
        bytes.append(UInt8(size)); return Data(bytes)+data
    }
    private func category(_ code: String,_ domain: String) -> Data {
        let rule = Data([8,2])+message(2,Data(domain.utf8))
        return message(1,message(1,Data(code.utf8))+message(2,rule))
    }
    private var stale: Data { category("BILIINTL","unreviewed.invalid")+category("KEEP","unchanged.invalid")+category("SHAREPOINT","old.invalid") }
    private func payloads(_ site: Data) -> [String:Data] { ["GeoSite.dat":site,"GeoIP.dat":Data("ip".utf8),"geoip.metadb":Data("meta".utf8)] }
    func testBothStaleCategoriesAreReplacedAndOtherFieldsPreserved() throws {
        let unknown = Data([0x78,0x01,0x81,0x01,1,2,3,4,5,6,7,8,0x8d,0x01,1,2,3,4])
        let output = try policy().applying(to:stale+unknown)
        XCTAssertNil(output.range(of:Data("unreviewed.invalid".utf8)))
        XCTAssertNil(output.range(of:Data("old.invalid".utf8)))
        XCTAssertNotNil(output.range(of:category("KEEP","unchanged.invalid")))
        XCTAssertNotNil(output.range(of:unknown))
        XCTAssertNotNil(output.range(of:Data("bilibili.tv".utf8)))
        XCTAssertNotNil(output.range(of:Data("sharepointonline.com".utf8)))
        XCTAssertEqual(try policy().applying(to:output),output)
    }
    func testAbsentCategoriesAreAddedAndIPFilesRemainUnchanged() throws {
        let input = payloads(category("KEEP","unchanged.invalid"))
        let output = try policy().protect(input)
        XCTAssertEqual(output["GeoIP.dat"],input["GeoIP.dat"])
        XCTAssertEqual(output["geoip.metadb"],input["geoip.metadb"])
        XCTAssertNotNil(output["GeoSite.dat"]?.range(of:Data("BILIINTL".utf8)))
        XCTAssertNotNil(output["GeoSite.dat"]?.range(of:Data("SHAREPOINT".utf8)))
        XCTAssertEqual(try policy().protect(output),output)
    }
    func testTamperedPolicyAndIncompleteUpdateAreRejected() throws {
        var data = try Data(contentsOf:root.appendingPathComponent("Resources/GeoData/GeoSite-policy.json")); data.append(32)
        XCTAssertThrowsError(try GeoSitePolicy(data:data))
        XCTAssertThrowsError(try policy().protect(["GeoSite.dat":stale]))
    }
    func testMalformedAndDuplicateProtobufIsRejected() throws {
        let values = [Data(),Data([0x0a]),Data([0x0a,0x20,1]),Data(repeating:0xff,count:10),
                      Data([0x08,0x01]),Data([0x0b,0x0c]),category("BILIINTL","x.invalid")+category("biliintl","y.invalid"),
                      message(1,message(1,Data("KEEP".utf8))+message(1,Data("BILIINTL".utf8)))]
        for value in values { XCTAssertThrowsError(try policy().applying(to:value)) }
    }
    func testVerifiedOnlineDownloadAppliesPolicyAfterUpstreamDigestCheck() async throws {
        let input = payloads(stale)
        let assets = input.map { GeoAsset(name:$0.key,url:URL(string:"https://example.invalid/"+$0.key)!,sha256:CoreUpdates.digest($0.value),size:$0.value.count) }
        let output = try await GeoAsset.verified(assets,policy:policy()) { input[$0.name]! }
        XCTAssertEqual(output,try policy().protect(input))
        XCTAssertNotEqual(CoreUpdates.digest(output["GeoSite.dat"]!),CoreUpdates.digest(input["GeoSite.dat"]!))
        do {
            _ = try await GeoAsset.verified(assets,policy:policy()) { _ in Data("tampered".utf8) }
            XCTFail("A digest mismatch must fail before applying data")
        } catch {}
        do {
            _ = try await GeoAsset.verified(assets,policy:policy()) { _ in throw URLError(.timedOut) }
            XCTFail("A failed download must not return a partial update")
        } catch {}
    }
    func testLegacyRollbackSanitizesBeforeWritingAndPreservesBackup() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:home) }
        let files = try GeoDataUpdates(home:home),approved = try policy().protect(payloads(stale))
        try files.beginUpdate(payloads(stale)); try files.finish()
        try files.beginUpdate(approved); try files.finish()
        let snapshots = try FileManager.default.contentsOfDirectory(at:home.appendingPathComponent("geo-history"),includingPropertiesForKeys:nil)
        let legacy = try XCTUnwrap(snapshots.first { (try? Data(contentsOf:$0.appendingPathComponent("GeoSite.dat"))) == stale })
        try files.beginRollback(policy:policy()); try files.finish()
        XCTAssertEqual(try Data(contentsOf:home.appendingPathComponent("GeoSite.dat")),approved["GeoSite.dat"])
        XCTAssertEqual(try Data(contentsOf:legacy.appendingPathComponent("GeoSite.dat")),stale)
    }
    func testInvalidLegacyRollbackLeavesActiveFilesAndJournalUntouched() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:home) }
        let files = try GeoDataUpdates(home:home),approved = try policy().protect(payloads(stale))
        try files.beginUpdate(payloads(Data([0x0a]))); try files.finish()
        try files.beginUpdate(approved); try files.finish()
        let before = try files.fingerprints()
        XCTAssertThrowsError(try files.beginRollback(policy:policy()))
        XCTAssertEqual(try files.fingerprints(),before)
        XCTAssertFalse(FileManager.default.fileExists(atPath:home.appendingPathComponent("geo-history/pending.json").path))
    }
}
