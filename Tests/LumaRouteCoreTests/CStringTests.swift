import XCTest
import Darwin
@testable import LumaRouteCore

final class CStringTests: XCTestCase {
    private func chars(_ bytes: [UInt8]) -> [CChar] { bytes.map { CChar(bitPattern:$0) } }

    func testASCIIAndUnicodePreserveSignedCCharBitPatterns() {
        for text in ["127.0.0.1","2001:db8::1","/Applications/中文工具 🚀.app/Contents/MacOS/测试"] {
            let buffer = chars(Array(text.utf8)+[0])
            XCTAssertEqual(CString.decodeUTF8(buffer),text)
        }
    }

    func testStopsAtFirstNULAndIgnoresTrailingGarbage() {
        let buffer = chars(Array("中文".utf8)+[0,0xff,0xfe]+Array("不应读取".utf8)+[0])
        XCTAssertEqual(CString.decodeUTF8(buffer),"中文")
        XCTAssertEqual(CString.decodeUTF8(chars([0,0xff,0xfe])),"")
    }

    func testEmptyAndZeroFilledBuffersDecodeToEmpty() {
        for buffer in [[],[0],Array(repeating:0,count:4096)] as [[CChar]] {
            XCTAssertEqual(CString.decodeUTF8(buffer),"")
        }
    }

    func testUnterminatedInputIsBoundedByTheArray() {
        XCTAssertEqual(CString.decodeUTF8(chars(Array("中文 🚀".utf8))),"中文 🚀")
        XCTAssertEqual(CString.decodeUTF8(chars([0xff])),"�")
    }

    func testInvalidUTF8IsRepairedWithoutDroppingValidText() {
        for (bytes,expected) in [([0xff],"�"),([0xe4,0xb8],"�"),([0xc3,0x28],"�("),([0x80,0xfe],"��")] as [([UInt8],String)] {
            let buffer = chars(Array("前".utf8)+bytes+Array("后".utf8)+[0])
            XCTAssertEqual(CString.decodeUTF8(buffer),"前"+expected+"后")
        }
    }

    func testTerminatedInputsMatchTheNondeprecatedPointerDecoder() {
        for bytes in [Array("中文路径 🚀".utf8),[0xff,0x61,0xc3,0x28],[],[0,0xff]] {
            let buffer = chars(bytes+[0])
            // The pointer overload remains supported. All test arrays have an
            // explicit terminator, so this compares the old decoding semantics.
            let expected = buffer.withUnsafeBufferPointer { String(cString:$0.baseAddress!) }
            XCTAssertEqual(CString.decodeUTF8(buffer),expected)
        }
    }

    func testIPv4AndIPv6NormalizationHasNoTrailingNULOrBufferPadding() throws {
        for (type,input,expected) in [
            ("IP-CIDR","192.168.255.254/16","192.168.0.0/16"),
            ("IP-CIDR","255.255.255.255/0","0.0.0.0/0"),
            ("IP-CIDR","192.0.2.9/32","192.0.2.9/32"),
            ("IP-CIDR6","2001:DB8:1234::1/32","2001:db8::/32"),
            ("IP-CIDR6","ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff/0","::/0"),
            ("IP-CIDR6","ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff/128","ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff/128")
        ] {
            XCTAssertEqual(try CompositionRouting.normalized(type:type,payload:input),expected)
        }
    }

    func testKernelBufferDecodesARealChineseAndEmojiExecutablePath() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
        let root = temporary.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at:root) }
        let binary = root.appendingPathComponent("中文进程 🚀")
        let compiler = Process(),compiled = expectation(description:"fixture compiled")
        compiler.executableURL = URL(fileURLWithPath:"/usr/bin/xcrun")
        let source = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/cstring_process.c")
        compiler.arguments = ["clang",source.path,"-o",binary.path]
        compiler.terminationHandler = { _ in compiled.fulfill() }
        try compiler.run()
        await fulfillment(of:[compiled],timeout:10)
        guard !compiler.isRunning,compiler.terminationStatus == 0 else {
            if compiler.isRunning { compiler.terminate() }
            throw LumaError.message("无法编译中文进程路径测试程序")
        }
        let task = Process(),exited = expectation(description:"fixture process exited")
        task.executableURL = binary; task.arguments = ["30"]
        task.terminationHandler = { _ in exited.fulfill() }
        try task.run()
        defer { if task.isRunning { task.terminate() } }
        // Exercise the same native API used by identity/connection discovery.
        // macOS may return /private/var for a file created through /var, so
        // compare the decoded file rather than assuming one textual path alias.
        var buffer = [CChar](repeating:0,count:4*Int(MAXPATHLEN))
        XCTAssertGreaterThan(proc_pidpath(task.processIdentifier,&buffer,UInt32(buffer.count)),0)
        let decoded = CString.decodeUTF8(buffer)
        XCTAssertTrue(decoded.hasSuffix("/中文进程 🚀"))
        XCTAssertFalse(decoded.contains("\0"))
        XCTAssertTrue(FileManager.default.contentsEqual(atPath:decoded,andPath:binary.path))
        task.terminate()
        await fulfillment(of:[exited],timeout:3)
        XCTAssertFalse(task.isRunning)
    }
}
