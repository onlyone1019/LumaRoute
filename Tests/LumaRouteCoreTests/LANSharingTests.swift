import XCTest
@testable import LumaRouteCore

final class LANSharingTests: XCTestCase {
    private func settings(allowLAN: Bool, password: String = "pass-1234", username: String = "lumaroute") -> NetworkSettings {
        var value = NetworkSettings()
        value.allowLAN = allowLAN
        value.lanUsername = username
        value.lanPassword = password
        return value
    }

    func testLocalOnlyByDefault() throws {
        let config = try ConfigComposer.parse(ConfigComposer.compose(source:nil,settings:NetworkSettings(),rules:[],secret:"local-secret"))
        XCTAssertEqual(config["allow-lan"] as? Bool, false)
        XCTAssertEqual(config["bind-address"] as? String, "127.0.0.1")
        XCTAssertNil(config["authentication"])
        XCTAssertNil(config["lan-allowed-ips"])
    }

    func testLANSharingBindsProxyWithCredentialAndKeepsControllerLocal() throws {
        let config = try ConfigComposer.parse(ConfigComposer.compose(source:nil,settings:settings(allowLAN:true),rules:[],secret:"local-secret"))
        XCTAssertEqual(config["allow-lan"] as? Bool, true)
        XCTAssertEqual(config["bind-address"] as? String, "*")
        XCTAssertEqual(config["authentication"] as? [String], ["lumaroute:pass-1234"])
        XCTAssertEqual(config["skip-auth-prefixes"] as? [String], ["127.0.0.1/32", "::1/128"])
        XCTAssertEqual(config["lan-allowed-ips"] as? [String], ["127.0.0.0/8", "::1/128", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "fc00::/7", "fe80::/10"])
        XCTAssertEqual(config["mixed-port"] as? Int, NetworkSettings().mixedPort)
        XCTAssertEqual(config["external-controller"] as? String, "127.0.0.1:\(NetworkSettings().controllerPort)")
    }

    func testLANSharingRequiresCredentials() {
        XCTAssertThrowsError(try ConfigComposer.compose(source:nil,settings:settings(allowLAN:true,password:""),rules:[],secret:"local-secret"))
        XCTAssertThrowsError(try ConfigComposer.compose(source:nil,settings:settings(allowLAN:true,username:"  "),rules:[],secret:"local-secret"))
        XCTAssertThrowsError(try ConfigComposer.compose(source:nil,settings:settings(allowLAN:true,username:"a:b"),rules:[],secret:"local-secret"))
    }

    func testSubscriptionCannotInjectListenerOrCredentials() throws {
        let source = """
        proxies: [{name: node, type: direct}]
        proxy-groups: [{name: Manual, type: select, proxies: [node]}]
        rules: ['MATCH,Manual']
        allow-lan: true
        bind-address: '*'
        authentication: ['attacker:password']
        skip-auth-prefixes: ['0.0.0.0/0']
        lan-allowed-ips: ['0.0.0.0/0']
        """
        let config = try ConfigComposer.parse(ConfigComposer.compose(source:source,settings:NetworkSettings(),rules:[],secret:"local-secret"))
        XCTAssertEqual(config["allow-lan"] as? Bool, false)
        XCTAssertEqual(config["bind-address"] as? String, "127.0.0.1")
        XCTAssertNil(config["authentication"])
        XCTAssertNil(config["skip-auth-prefixes"])
        XCTAssertNil(config["lan-allowed-ips"])
    }

    func testOlderSettingsDecodeWithLANOff() throws {
        let decoded = try JSONDecoder().decode(NetworkSettings.self,from:Data("{\"mixedPort\":19790}".utf8))
        XCTAssertFalse(decoded.allowLAN)
        XCTAssertEqual(decoded.lanUsername, "lumaroute")
        XCTAssertEqual(decoded.lanPassword, "")
    }

    func testGeneratedPasswordIsSixteenUnambiguousCharacters() {
        let password = NetworkSettings.makeLANPassword()
        XCTAssertEqual(password.count, 16)
        XCTAssertTrue(password.allSatisfy { "abcdefghjkmnpqrstuvwxyz23456789".contains($0) })
        XCTAssertNotEqual(password, NetworkSettings.makeLANPassword())
    }
}
