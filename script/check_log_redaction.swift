import Foundation

enum RedactionProbe {
    private static let lock = NSLock()
    private static var cleans = 0
    private static var compilations = 0
    static var counts: (Int,Int) { lock.lock(); defer { lock.unlock() }; return (cleans,compilations) }
    static func recordClean() { lock.lock(); defer { lock.unlock() }; cleans += 1 }
    static func compile(pattern: String) throws -> NSRegularExpression {
        lock.lock(); compilations += 1; lock.unlock()
        return try NSRegularExpression(pattern:pattern)
    }
}

@main struct LogRedactionCheck {
    static func require(_ condition: Bool,_ message: String) {
        if !condition { FileHandle.standardError.write(Data(("FAIL "+message+"\n").utf8)); exit(1) }
    }
    @MainActor static func main() async throws {
        require(RedactionProbe.counts == (0,0),"probe starts before lazy regex initialization")
        // First access is concurrent to also exercise lazy initialization safety.
        DispatchQueue.concurrentPerform(iterations:500) { _ in
            require(Redactor.clean("中文 token=private") == "中文 token=[已隐藏]","concurrent redaction")
        }
        require(RedactionProbe.counts == (500,3),"regexes must compile exactly once across concurrent calls")
        print("PASS 500 concurrent redactions compile only 3 regexes")

        var before = RedactionProbe.counts.0
        let message = RedactedLogMessage("中文 token=private\n末尾 password=credential")
        let entries = message.lines.map { LogEntry(level:"warning",source:"内核",message:$0) }
        require(entries.map(\.message) == ["中文 token=[已隐藏]","末尾 password=[已隐藏]"],"split messages remain sanitized")
        require(RedactionProbe.counts.0 == before+1,"splitting and LogEntry construction must reuse sanitized text")
        print("PASS sanitized message splitting and LogEntry reuse add no redaction passes")

        before = RedactionProbe.counts.0
        let rawEntry = LogEntry(source:"应用",message:"secret=raw-secret")
        require(rawEntry.message == "secret=[已隐藏]" && RedactionProbe.counts.0 == before+1,"raw LogEntry must still redact once")
        print("PASS ordinary LogEntry still redacts raw input once")

        before = RedactionProbe.counts.0
        let app = AppStore()
        let reader = CoreLogReader { text in
            require(!text.text.contains("private") && !text.text.contains("credential"),"core callback must already be sanitized")
            Task { @MainActor in app.capture(text) }
        }
        reader.consume(Data("level=warning 中文 token=pri".utf8))
        require(RedactionProbe.counts.0 == before,"incomplete lines must not run regexes")
        reader.consume(Data("vate\n末尾 password=credential".utf8))
        reader.consume(Data())
        for _ in 0..<100 {
            if app.pendingLogs.count == 2 { break }
            try await Task.sleep(nanoseconds:1_000_000)
        }
        app.flush()
        require(app.logs.map(\.message) == ["level=warning 中文 token=[已隐藏]","末尾 password=[已隐藏]"],"core messages reach the production AppStore buffer")
        require(app.logs.map(\.level) == ["warning","info"],"kernel levels remain intact")
        require(RedactionProbe.counts.0 == before+2,"core-to-AppStore pipeline must redact each line exactly once")
        print("PASS core-to-AppStore pipeline redacts each complete line only once")

        before = RedactionProbe.counts.0
        app.appendLog(source:"内核",message:"token=stream-secret\npassword=stream-password")
        app.flush()
        require(app.logs.suffix(2).map(\.message) == ["token=[已隐藏]","password=[已隐藏]"],"raw stream logs must stay sanitized")
        require(RedactionProbe.counts.0 == before+2,"raw stream log lines must each redact once")
        require(RedactionProbe.counts.1 == 3,"later log ingestion must reuse compiled regexes")
        print("PASS raw stream logs redact once per line and reuse compiled regexes")
        print("log redaction suite passed: 5 scenarios")
    }
}
