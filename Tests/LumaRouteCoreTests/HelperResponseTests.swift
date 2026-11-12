import XCTest
@testable import LumaRouteCore

final class HelperResponseTests: XCTestCase {
    func testOldStatusResponseDoesNotImplyOwnershipLoss() throws {
        let old = Data(#"{"success":true,"message":"","running":true,"serviceUID":0,"protocolVersion":1}"#.utf8)
        let response = try JSONDecoder().decode(HelperResponse.self,from:old)
        XCTAssertTrue(response.running)
        XCTAssertNil(response.networkOwnershipLost)
    }
    func testOwnershipConflictSurvivesTransportEncoding() throws {
        let response = HelperResponse(success:true,running:true,networkOwnershipLost:true)
        let decoded = try JSONDecoder().decode(HelperResponse.self,from:JSONEncoder().encode(response))
        XCTAssertTrue(decoded.success)
        XCTAssertTrue(decoded.running)
        XCTAssertEqual(decoded.networkOwnershipLost,true)
    }
}
