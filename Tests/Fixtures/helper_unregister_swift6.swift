import Foundation
import ServiceManagement

enum FixtureError: Error { case unregister, stop }
enum LumaError: Error { case message(String) }
struct HelperRequest { let action: String }
@MainActor final class NSWorkspace {
    static let shared = NSWorkspace()
    func open(_ url: URL) -> Bool { fatalError("must not launch a real installer") }
}
final class FakeService {
    var fail = false
    var calls = 0
    // Model the older SDK's nonisolated async method on a non-Sendable class.
    func unregister() async throws {}
    func unregister(completionHandler: @escaping @Sendable (Error?) -> Void) {
        calls += 1
        let fail = fail
        DispatchQueue.global().async {
            completionHandler(fail ? FixtureError.unregister:nil)
        }
    }
}
@MainActor final class FakeConnection {
    var invalidated = false
    func invalidate() { invalidated = true }
}
@MainActor final class HelperClient {
    let service = FakeService()
    var localInstallation: Int? { nil }
    var connection: FakeConnection? = FakeConnection()
    var actions: [String] = []
    var stopFails = false
    func send(_ request: HelperRequest) async throws {
        actions.append(request.action)
        if stopFails { throw FixtureError.stop }
    }
    // PRODUCTION_UNREGISTER
}
@main struct UnregisterCheck {
    @MainActor static func main() async throws {
        for scenario in 0..<3 {
            let client = HelperClient(),connection = client.connection!
            client.service.fail = scenario == 1
            client.stopFails = scenario == 2
            do {
                try await client.unregister()
                precondition(scenario != 1,"unregister error was swallowed")
            } catch FixtureError.unregister { precondition(scenario == 1) }
            precondition(client.actions == ["stop"])
            precondition(connection.invalidated && client.connection == nil)
            precondition(client.service.calls == 1)
        }
        print("PASS Swift 6 legacy non-Sendable service: success, unregister failure and stop failure")
    }
}
