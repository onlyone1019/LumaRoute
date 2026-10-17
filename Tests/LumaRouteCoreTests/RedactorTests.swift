import XCTest
@testable import LumaRouteCore

final class RedactorTests: XCTestCase {
    func testSubscriptionSchemesKeepTheirPrefixAndHideCredentials() {
        for scheme in ["http","https","ss","ssr","vmess","vless","trojan","hysteria","hysteria2","hy2","tuic","socks","socks5","snell","wireguard","anytls"] {
            XCTAssertEqual(Redactor.clean("中文 \(scheme)://user:credential@example.org/sub?token=private 结束"),"中文 \(scheme)://[已隐藏] 结束",scheme)
        }
        XCTAssertEqual(Redactor.clean("HTTPS://example.org/private"),"HTTPS://[已隐藏]")
    }

    func testAuthorizationAndCredentialFieldsKeepExistingRedaction() {
        for field in ["password","passwd","secret","token","uuid","private-key","client-id","access_token","auth-str","auth","psk"] {
            XCTAssertEqual(Redactor.clean("🚀 \(field)=sensitive 中文"),"🚀 \(field)=[已隐藏] 中文",field)
        }
        for header in ["Authorization: Bearer ","authorization=Basic ","AUTHORIZATION: "] {
            XCTAssertEqual(Redactor.clean(header+"credential"),header+"[已隐藏]")
        }
        XCTAssertEqual(Redactor.clean(#"{"Authorization":"Bearer private","password":"secret","uuid":"private-id"}"#),#"{"Authorization":"Bearer [已隐藏]","password":"[已隐藏]","uuid":"[已隐藏]"}"#)
    }

    func testPlainUnicodeAndEmptyMessagesAreUnchanged() {
        for text in ["","中文日志 🚀：连接成功","level=info msg=\"规则已加载\"","first\r\nsecond\n"] {
            XCTAssertEqual(Redactor.clean(text),text)
        }
    }

    func testSanitizedMessageCanBeSplitAndStoredWithoutLosingMetadata() {
        let message = RedactedLogMessage("\n中文 token=private\r\n\n末尾 password=credential")
        let entries = message.lines.map { LogEntry(level:"warning",source:"内核",message:$0) }
        XCTAssertEqual(entries.map(\.message),["中文 token=[已隐藏]","末尾 password=[已隐藏]"])
        XCTAssertTrue(entries.allSatisfy { $0.level == "warning" && $0.source == "内核" })
        XCTAssertNotEqual(entries[0].id,entries[1].id)
        XCTAssertEqual(LogEntry(source:"应用",message:"token=raw-secret").message,"token=[已隐藏]")
    }

    func testLogEntryCodingFormatRemainsCompatible() throws {
        let entry = LogEntry(level:"error",source:"内核",message:RedactedLogMessage("secret=private"))
        let encoded = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(LogEntry.self,from:encoded)
        XCTAssertEqual(decoded.id,entry.id)
        XCTAssertEqual(decoded.date,entry.date)
        XCTAssertEqual(decoded.level,"error")
        XCTAssertEqual(decoded.source,"内核")
        XCTAssertEqual(decoded.message,"secret=[已隐藏]")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        XCTAssertEqual(Set(object.keys),Set(["id","date","level","source","message"]))
    }

    func testCachedExpressionsCanBeUsedConcurrently() {
        DispatchQueue.concurrentPerform(iterations:300) { index in
            let text = "中文 \(index) https://example.org/sub?token=private Authorization: Bearer credential password=hidden"
            XCTAssertEqual(Redactor.clean(text),"中文 \(index) https://[已隐藏] Authorization: Bearer [已隐藏] password=[已隐藏]")
        }
    }
}
