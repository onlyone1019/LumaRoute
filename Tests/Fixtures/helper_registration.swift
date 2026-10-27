import Foundation
import ServiceManagement

enum LumaError: Error { case message(String) }
enum FixtureError: Error { case install }
enum HelperConstants { static let plistName = "fixture.plist" }
@MainActor enum Events { static var values:[String] = [] }
@MainActor final class FakeService {
    var error: Error?
    var status:SMAppService.Status = .notRegistered
    func unregister(completionHandler: @escaping @Sendable (Error?) -> Void) {
        Events.values.append("unregister")
        completionHandler(error)
    }
    func register() throws { Events.values.append("managed-register"); status = .enabled }
}
@MainActor final class FakeConnection {
    var invalidated = false
    func invalidate() { invalidated = true }
}
struct LocalServiceInstallation {
    static func requirement(for url:URL) throws -> String { "fixture-requirement" }
}
@MainActor enum LocalServiceAuthorization {
    static var failure: Error?
    static func install(app:URL,ownerUID:UInt32,networkReady:Bool) async throws {
        Events.values.append("install")
        if let failure { throw failure }
    }
}
@MainActor final class HelperClient {
    let service = FakeService()
    var supportsPrivilegedService = false
    var localInstallation:LocalServiceInstallation?
    var connection:FakeConnection? = FakeConnection()
    var cachedLocalStamp:Date? = Date()
    func requireSupportedSigning() throws {}
    // PRODUCTION_REGISTER
    // PRODUCTION_MANAGED_UNREGISTER
}
@main struct RegistrationCheck {
    @MainActor static func main() async throws {
        for failure in [nil,
                        NSError(domain:"SMAppServiceErrorDomain",code:kSMErrorJobNotFound),
                        NSError(domain:"OtherDomain",code:kSMErrorJobNotFound),
                        NSError(domain:"SMAppServiceErrorDomain",code:kSMErrorAuthorizationFailure)] {
            let client = HelperClient(),connection = client.connection!
            client.supportsPrivilegedService = true
            client.localInstallation = LocalServiceInstallation()
            client.service.error = failure
            Events.values = []
            let mayInstall = failure == nil || failure?.domain == "SMAppServiceErrorDomain" && failure?.code == kSMErrorJobNotFound
            do {
                try await client.register(networkReady:true)
                precondition(mayInstall)
                precondition(Events.values == ["unregister","install"])
                precondition(connection.invalidated && client.connection == nil && client.cachedLocalStamp == nil)
            } catch {
                precondition(!mayInstall)
                precondition(Events.values == ["unregister"])
                precondition(!connection.invalidated)
            }
        }
        let managed = HelperClient()
        managed.supportsPrivilegedService = true
        Events.values = []
        try await managed.register()
        precondition(Events.values == ["managed-register"])
        // An ad-hoc build has no SMAppService removal entitlement. It must
        // reach the administrator installer even when managed removal fails.
        let adHoc = HelperClient(),adHocConnection = adHoc.connection!
        adHoc.service.error = NSError(domain:NSPOSIXErrorDomain,code:144)
        Events.values = []
        try await adHoc.register()
        precondition(Events.values == ["install"])
        precondition(adHocConnection.invalidated)
        let local = HelperClient()
        local.supportsPrivilegedService = true
        local.localInstallation = LocalServiceInstallation()
        Events.values = []
        try await local.register()
        precondition(Events.values == ["unregister","install"])
        print("PASS registration migration: managed cleanup precedes install; missing registration is idempotent; authorization errors stop installation; existing local installs stay local")
    }
}
