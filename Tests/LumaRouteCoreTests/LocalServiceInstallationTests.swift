import XCTest
@testable import LumaRouteCore

final class LocalServiceInstallationTests: XCTestCase {
    private func record(serviceID: String? = nil) throws -> LocalServiceInstallation {
        var values:[String:Any] = ["ownerUID":501,"protocolVersion":1,"healthOnly":false]
        if let serviceID { values["serviceID"] = serviceID }
        let data = try PropertyListSerialization.data(fromPropertyList:values,format:.xml,options:0)
        return try PropertyListDecoder().decode(LocalServiceInstallation.self,from:data)
    }
    func testOldInstallationDecodesButRequiresMigrationBeforeConnecting() throws {
        let old = try record()
        XCTAssertNil(old.serviceID)
        XCTAssertTrue(old.needsMigration)
        XCTAssertFalse(old.acceptsCurrentApp())
        XCTAssertEqual(NetworkServiceSetup.resolve(installed:true,accepted:!old.needsMigration,healthOnly:old.healthOnly),.update)
    }
    func testCurrentInstallationUsesIndependentEndpoint() throws {
        XCTAssertNotEqual(HelperConstants.localServiceID,HelperConstants.serviceID)
        let current = try record(serviceID:HelperConstants.localServiceID)
        XCTAssertFalse(current.needsMigration)
        let encoded = try PropertyListEncoder().encode(current)
        XCTAssertEqual(try PropertyListDecoder().decode(LocalServiceInstallation.self,from:encoded).serviceID,HelperConstants.localServiceID)
    }
    func testExplicitLegacyOrUnknownServiceCannotBeMarkedReady() throws {
        for identifier in [HelperConstants.serviceID,"other.helper"] {
            XCTAssertTrue(try record(serviceID:identifier).needsMigration)
        }
    }
}
