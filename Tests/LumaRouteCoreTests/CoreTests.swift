import XCTest
import Yams
@testable import LumaRouteCore

final class CoreTests:XCTestCase {
    func testConfigRetainsDNSGroupsAndRulesButOwnsListeners()throws {
        let input="""
        mixed-port: 7890
        external-controller: 0.0.0.0:9090
        external-controller-unix: /tmp/foreign.sock
        external-ui: /tmp/foreign
        proxies:
          - {name: node, type: direct}
        proxy-groups:
          - {name: 自定义组, type: select, proxies: [node]}
        dns:
          nameserver: [https://dns.example.org/dns-query]
          proxy-server-nameserver: [1.1.1.1]
        rules:
          - DOMAIN-SUFFIX,example.org,自定义组
          - MATCH,自定义组
        """
        let rule=CustomRule(payload:"github.com",target:"自定义组")
        let yaml=try ConfigComposer.compose(source:input,settings:NetworkSettings(),rules:[rule],secret:"test")
        let parsed=try Yams.load(yaml:yaml) as! [String:Any]
        XCTAssertEqual(parsed["mixed-port"] as? Int,19790)
        XCTAssertEqual(parsed["external-controller"] as? String,"127.0.0.1:19791")
        XCTAssertNil(parsed["external-controller-unix"]); XCTAssertNil(parsed["external-ui"])
        XCTAssertEqual((parsed["dns"] as? [String:Any])?["nameserver"] as? [String],["https://dns.example.org/dns-query"])
        XCTAssertEqual((parsed["rules"] as? [String])?.first,"DOMAIN-SUFFIX,github.com,自定义组")
        XCTAssertEqual((parsed["proxy-groups"] as? [[String:Any]])?.first?["name"] as? String,"自定义组")
    }
    func testProviderPathsCannotEscapeRuntime()throws {
        let yaml=try ConfigComposer.compose(source:"""
        proxy-providers:
          evil: {type: http, url: https://example.org/nodes, path: /etc/sudoers}
        proxy-groups:
          - {name: group, type: select, use: [evil]}
        rules: [MATCH,group]
        """,settings:NetworkSettings(),rules:[],secret:"test",resourceRoot:URL(fileURLWithPath:"/tmp/owned-runtime"))
        let parsed=try Yams.load(yaml:yaml) as! [String:Any]
        let providers=parsed["proxy-providers"] as! [String:[String:Any]]
        XCTAssertEqual(providers["evil"]?["path"] as? String,"/tmp/owned-runtime/providers/proxy-0.yaml")
        XCTAssertNotNil(providers["evil"]?["health-check"])
    }
    func testURISubscriptionIsDelegatedToNativeProviderParser()throws {
        let uri="ss://dGVzdA@example.org:443#test"
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let encoded=Data(uri.utf8).base64EncodedString()
        let yaml=try ConfigComposer.compose(source:encoded,settings:NetworkSettings(),rules:[],secret:"test",resourceRoot:root)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("providers/proxy-0.yaml")),uri)
        XCTAssertFalse(yaml.contains("_lumaroute_raw_provider"))
        XCTAssertEqual(try ConfigComposer.nodeCount(encoded),1)
    }
    func testEmptyAndInvalidProfilesAreRejected() {
        XCTAssertThrowsError(try ConfigComposer.parse(""))
        XCTAssertThrowsError(try ConfigComposer.parse("<html>not a subscription</html>"))
        XCTAssertThrowsError(try ConfigComposer.parse("proxies: ["))
        XCTAssertThrowsError(try CustomRule(payload:"safe.com,DIRECT").validate())
    }
    func testMetadataAndSecretsDoNotMix() {
        let usage=SubscriptionUsage(header:"upload=12; download=34; total=100; expire=1799999999")
        XCTAssertEqual(usage.upload+usage.download,46); XCTAssertEqual(usage.total,100); XCTAssertNotNil(usage.expire)
        let redacted=Redactor.clean("failed https://example.org/sub?token=supersecret secret=abcdef password=abcdef")
        XCTAssertFalse(redacted.contains("supersecret")); XCTAssertFalse(redacted.contains("abcdef"))
    }
    func testAPIPathNamesAreEncodedAsOneSegment() {
        let api=MihomoAPI(port:19791,secret:"private")
        let url=api.url(["proxies","日本 / 东京?01"])
        XCTAssertTrue(url.absoluteString.contains("%2F")); XCTAssertTrue(url.absoluteString.contains("%3F"))
        XCTAssertFalse(url.absoluteString.contains("private"))
    }
    func testBackupRestoresSettingsRulesAndProfileSnapshots()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try LocalStore(root:root,secrets:MemorySecrets())
        var db=AppDatabase(); let profile=Profile(name:"local",isRemote:false)
        db.profiles=[profile]; db.activeProfileID=profile.id
        db.customRules=[CustomRule(payload:"example.org",target:"DIRECT")]
        let source="proxies: []\nproxy-groups: []\nrules: [MATCH,DIRECT]\n"
        try store.saveProfile(source,id:profile.id); try store.save(db)
        let backup=try store.backup(db)
        db.customRules=[]; try store.save(db)
        let restored=try store.restoreBackup(backup)
        XCTAssertEqual(restored.customRules.count,1)
        XCTAssertEqual(try store.profileContent(profile.id),source)
        let attrs=try FileManager.default.attributesOfItem(atPath:store.profileURL(profile.id).path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue,0o600)
    }
}

