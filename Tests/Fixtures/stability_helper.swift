import Foundation
import ServiceManagement
import LumaRouteCore

// No XPC connection or system network mutation is permitted in this fixture.
@MainActor final class HelperClient {
    struct InstallationState: Equatable { let status: SMAppService.Status }
    var status: SMAppService.Status = .notRegistered
    var installationState: InstallationState { .init(status:status) }
    var localInstallation: LocalServiceInstallation? { nil }
    var label: String { "isolated fixture" }
    var networkSetup: NetworkServiceSetup = .install
    var calls: [String] = []
    var requests: [HelperRequest] = []
    var startFailures = 0
    var running = true
    var enforceOwnership = false
    var ownershipLost = false
    var statusUnavailable = false
    var stopUnavailable = false
    func send(_ request: HelperRequest,responseTimeout: TimeInterval? = nil) async throws -> HelperResponse {
        calls.append(request.action)
        requests.append(request)
        if request.action == "status",statusUnavailable { throw LumaError.message("fixture transport unavailable") }
        if request.action == "stop",stopUnavailable { throw LumaError.message("fixture restore unavailable") }
        if ["start","apply"].contains(request.action) {
            if startFailures > 0 { startFailures -= 1; throw LumaError.message("fixture startup temporarily unavailable") }
            if enforceOwnership && ownershipLost {
                // The real helper restores/stops after an apply ownership
                // failure. A subsequent apply can then acquire a new journal.
                ownershipLost = false; running = false
                throw LumaError.message("fixture apply rejected due to ownership loss")
            }
            running = true
        }
        if request.action == "stop" { running = false; ownershipLost = false }
        // Encoding the additive field also lets this test run against the old
        // contract, where the decoder ignores it and exposes the regression.
        let response: [String:Any] = ["success":true,"message":"","running":running,
            "serviceUID":0,"protocolVersion":1,"networkOwnershipLost":ownershipLost]
        return try JSONDecoder().decode(HelperResponse.self,from:JSONSerialization.data(withJSONObject:response))
    }
    func requireSupportedSigning() throws {}
    func register(networkReady: Bool = false) async throws {}
    func unregister() async throws {}
    func disconnect() {}
    func openApproval() {}
}
