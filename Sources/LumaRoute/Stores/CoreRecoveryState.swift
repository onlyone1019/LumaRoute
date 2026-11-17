import Foundation

/// Retry bookkeeping for the core. AppStore owns network effects and commits
/// recovery only after the resulting settings have been saved.
struct CoreRecoveryState {
    enum Reason { case startup, interrupted }

    var reason: Reason?
    private(set) var isRunning = false
    private var attempts = 0
    private var retryAt = Date.distantPast
    private static let limit = 3

    mutating func schedule(_ reason: Reason, now: Date) {
        self.reason = reason
        attempts = 0
        retryAt = now.addingTimeInterval(1)
    }

    mutating func resetAttempts() { attempts = 0 }

    mutating func allowImmediateRetry() {
        resetAttempts()
        retryAt = .distantPast
    }

    mutating func begin(now: Date) -> Reason? {
        guard let reason, !isRunning, attempts < Self.limit, now >= retryAt else { return nil }
        isRunning = true
        attempts += 1
        return reason
    }

    mutating func end() { isRunning = false }

    mutating func complete() {
        reason = nil
        resetAttempts()
    }

    mutating func configurationApplied() {
        // A recovery attempt still needs to persist the configuration.
        if !isRunning { reason = nil }
    }

    mutating func recordFailure(now: Date) -> Bool {
        retryAt = now.addingTimeInterval(Double(attempts * 3))
        return attempts >= Self.limit
    }
}
