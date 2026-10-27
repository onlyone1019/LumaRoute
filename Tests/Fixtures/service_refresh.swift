import Foundation

enum FixtureError: Error { case restoring, disconnected }
enum LumaError: Error { case message(String) }
enum ServiceStatus { case enabled }
struct HelperRequest { let action:String }
struct HelperResponse {
    let serviceUID = 0,protocolVersion = 1
    let running:Bool
}
struct Installation { let healthOnly = false }
@MainActor final class HelperClient {
    let status:ServiceStatus = .enabled
    let localInstallation:Installation? = Installation()
    let label = "fixture"
    let networkSetup = 1
    var requests:[String] = []
    var disconnected = false
    var restoring = true
    var running = false
    func disconnect() { disconnected = true; running = false }
    func send(_ request:HelperRequest) async throws -> HelperResponse {
        requests.append(request.action)
        if disconnected { throw FixtureError.disconnected }
        if restoring { restoring = false; throw FixtureError.restoring }
        if request.action == "start" { running = true }
        return HelperResponse(running:running)
    }
}
struct GroupSelection { static func capture(_ proxies:[String:Int]) -> [Self] { [] } }
struct Database { var settings = 0 }
struct API {
    func proxies() async throws -> [String:Int] { ["fixture":1] }
    func version() async throws -> String { "fixture-version" }
}
struct Store { func saveSettingsAsync(_ settings:Int) async throws {} }
struct Logger { func info(_ text:String) {} }
enum Redactor { static func clean(_ text:String) -> String { text } }
@MainActor final class AppStore {
    let runner:Int? = 1
    let helper = HelperClient(),api = API(),store = Store(),serviceLogger = Logger()
    var recovering = false,pendingServiceRefresh = true,busy = false,shuttingDown = false
    var helperActive = false,serviceRunning = false,coreReady = false,recoveryNeeded = true,serviceInstalling = true
    var serviceRefreshAttempts = 0,recoveryAttempts = 0,serviceSetup = 0
    var serviceInstallationDeadline:Date? = Date(),nextServiceRefresh = Date.distantPast
    var pendingServiceSettings:Int?
    var proxies:[String:Int] = [:]
    let groups:[Int] = []
    var database = Database()
    var coreVersion = "",serviceLabel = ""
    var error:String?,serviceFailureMessage:String?,notice:String?
    func applyConfiguration(settings:Int,selectionSnapshot:[GroupSelection]?) async throws {
        let result = try await helper.send(HelperRequest(action:"start"))
        coreReady = result.running
    }
    func appendLog(level:String = "info",source:String,message:String) {}
    func report(_ error:Error,source:String) { self.error = error.localizedDescription }
    func retry() async { await refreshInstalledService() }
    // PRODUCTION_REFRESH
}
@main struct Check {
    @MainActor static func main() async {
        let app = AppStore()
        await app.retry()
        precondition(!app.coreReady && app.pendingServiceRefresh,"startup recovery must remain retryable")
        await app.retry()
        precondition(app.coreReady && app.helper.running,"retry must start the core without disconnecting its owner")
        precondition(!app.helper.disconnected)
        precondition(!app.serviceInstalling && app.serviceFailureMessage == nil)
        precondition(app.helper.requests == ["status","status","start"])
        print("PASS production service refresh retries startup recovery on the existing XPC connection and starts the core")
    }
}
