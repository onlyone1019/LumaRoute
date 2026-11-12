import XCTest
@testable import LumaRouteCore

final class LiveConnectionTests:XCTestCase {
    private let sample:[String:Any] = ["id":"connection","metadata":["host":"example.test","destinationIP":"192.0.2.1","destinationPort":"443","sourceIP":"127.0.0.1","sourcePort":"1234","network":"tcp","type":"HTTP","process":"Browser","processPath":"/Applications/Browser","processSource":"kernel"],"download":10,"upload":20,"start":"2026-11-12T00:00:00Z","chains":["node","group"],"rule":"Domain","rulePayload":"example.test"]
    private func decode(_ fields:[String:Any])throws->LiveConnection {
        try JSONDecoder().decode(LiveConnection.self,from:JSONSerialization.data(withJSONObject:fields))
    }
    func testEquivalentSnapshotsCompareEqual()throws {
        XCTAssertEqual(try decode(sample),try decode(sample))
    }
    func testEveryDisplayedAndDetailFieldInvalidatesSnapshot()throws {
        let original=try decode(sample)
        for key in ["id","download","upload","start","chains","rule","rulePayload"] {
            var changed=sample
            changed[key] = ["download","upload"].contains(key) ? 99:key == "chains" ? ["other"]:"changed"
            XCTAssertNotEqual(original,try decode(changed),key)
        }
        let metadata=try XCTUnwrap(sample["metadata"] as? [String:String])
        for key in metadata.keys {
            var changed=sample,fields=metadata;fields[key]="changed";changed["metadata"]=fields
            XCTAssertNotEqual(original,try decode(changed),key)
            fields[key]=nil;changed["metadata"]=fields
            XCTAssertNotEqual(original,try decode(changed),"missing "+key)
        }
    }
}
