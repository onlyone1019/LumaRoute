import XCTest
@testable import LumaRouteCore

final class CoreLogReaderTests: XCTestCase {
    private final class Logs: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func append(_ value: String) { lock.lock(); defer { lock.unlock() }; entries.append(value) }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    func testChineseAndEmojiSurviveEveryPossibleChunkBoundary() {
        let line = "level=info msg=\"中文日志：连接成功 🇨🇳 🚀\"\n"
        let bytes = Data(line.utf8)
        for boundary in 1..<bytes.count {
            let logs = Logs(),reader = CoreLogReader { logs.append($0.text) }
            reader.consume(bytes.prefix(boundary))
            XCTAssertTrue(logs.values.isEmpty,"incomplete line at byte \(boundary)")
            reader.consume(bytes.suffix(from:boundary))
            reader.consume(Data())
            XCTAssertEqual(logs.values,[line],"split at byte \(boundary)")
        }
    }

    func testMultipleLinesAndByteByByteInputPreserveOrderAndFinalFragment() {
        let logs = Logs(),reader = CoreLogReader { logs.append($0.text) }
        reader.consume(Data("第一行\r\n第二行\n末尾没有换行：".utf8))
        for byte in "中文".utf8 { reader.consume(Data([byte])) }
        XCTAssertEqual(logs.values,["第一行\r\n","第二行\n"])
        reader.consume(Data())
        reader.consume(Data())
        reader.consume(Data("ignored\n".utf8))
        XCTAssertEqual(logs.values,["第一行\r\n","第二行\n","末尾没有换行：中文"])
    }

    func testSplitSecretsAreRedactedBeforeAnyCallback() {
        let logs = Logs(),reader = CoreLogReader { logs.append($0.text) }
        for chunk in ["中文 https://example.org/sub?tok","en=super","secret password=abc","def\n末尾 secret=tail","secret"] {
            reader.consume(Data(chunk.utf8))
        }
        reader.consume(Data())
        XCTAssertEqual(logs.values.count,2)
        XCTAssertFalse(logs.values.joined().contains("supersecret"))
        XCTAssertFalse(logs.values.joined().contains("abcdef"))
        XCTAssertFalse(logs.values.joined().contains("tailsecret"))
        XCTAssertTrue(logs.values[0].hasPrefix("中文 "))
    }

    func testMalformedUTF8DoesNotDropTheRestOfALine() {
        let logs = Logs(),reader = CoreLogReader { logs.append($0.text) }
        reader.consume(Data([0xff])+Data("中文\n".utf8))
        XCTAssertEqual(logs.values,["�中文\n"])
    }

    func testProcessExitDetachesEOFHandlerAndFlushesFinalFragment() async throws {
        let logs = Logs(),pipe = Pipe(),task = Process()
        let completed = expectation(description:"final fragment delivered at EOF")
        let exited = expectation(description:"fixture process exited")
        task.terminationHandler = { _ in exited.fulfill() }
        CoreLogReader {
            logs.append($0.text)
            if $0.text == "末尾中文" { completed.fulfill() }
        }.attach(to:pipe.fileHandleForReading)
        defer { pipe.fileHandleForReading.readabilityHandler = nil }
        task.executableURL = URL(fileURLWithPath:"/usr/bin/printf")
        task.arguments = ["第一行\\n末尾中文"]
        task.standardOutput = pipe; task.standardError = pipe
        try task.run()
        await fulfillment(of:[completed,exited],timeout:3)
        XCTAssertNil(pipe.fileHandleForReading.readabilityHandler,"EOF must not remain readable with an active handler")
        XCTAssertEqual(logs.values,["第一行\n","末尾中文"])
        XCTAssertFalse(task.isRunning)
        XCTAssertEqual(task.terminationStatus,0)
    }

    func testEmptyProcessExitAlsoDetachesEOFHandler() async throws {
        let logs = Logs(),pipe = Pipe(),task = Process()
        let exited = expectation(description:"empty fixture process exited")
        task.terminationHandler = { _ in exited.fulfill() }
        CoreLogReader { logs.append($0.text) }.attach(to:pipe.fileHandleForReading)
        defer { pipe.fileHandleForReading.readabilityHandler = nil }
        task.executableURL = URL(fileURLWithPath:"/usr/bin/true")
        task.standardOutput = pipe; task.standardError = pipe
        try task.run()
        await fulfillment(of:[exited],timeout:3)
        for _ in 0..<100 {
            if pipe.fileHandleForReading.readabilityHandler == nil { break }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        XCTAssertNil(pipe.fileHandleForReading.readabilityHandler)
        XCTAssertTrue(logs.values.isEmpty)
        XCTAssertFalse(task.isRunning)
    }
}
