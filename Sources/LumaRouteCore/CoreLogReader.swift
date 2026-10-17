import Foundation

/// FileHandle may deliver a UTF-8 character or a sensitive value across reads.
/// Decode and redact complete lines, and flush the final line only at EOF.
final class CoreLogReader: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var finished = false
    private let onLog: @Sendable (RedactedLogMessage) -> Void

    init(onLog: @escaping @Sendable (RedactedLogMessage) -> Void) { self.onLog = onLog }

    func attach(to handle: FileHandle) {
        handle.readabilityHandler = { [self] handle in
            let bytes = handle.availableData
            // EOF stays readable. Detach immediately to avoid a busy loop.
            if bytes.isEmpty { handle.readabilityHandler = nil }
            consume(bytes)
        }
    }

    func consume(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        if bytes.isEmpty {
            finished = true
            if !pending.isEmpty { emitLine() }
            return
        }
        var start = bytes.startIndex
        for index in bytes.indices where bytes[index] == 0x0a {
            pending.append(contentsOf:bytes[start...index])
            emitLine()
            start = bytes.index(after:index)
        }
        pending.append(contentsOf:bytes[start...])
    }

    private func emitLine() {
        onLog(RedactedLogMessage(String(decoding:pending,as:UTF8.self)))
        pending.removeAll(keepingCapacity:true)
    }
}
