import Observation
import LumaRouteCore

/// SwiftUI tracks only the live properties read by each visible view. Runtime
/// samples and logs must not invalidate the app's unrelated forms and sidebars.
@Observable @MainActor
final class RuntimeData {
    var proxies:[String:ProxyNode] = [:]
    var liveRules:[LiveRule] = []
    var traffic = Traffic()
    var trafficHistory:[Traffic] = []
    var logs:[LogEntry] = []
    var connections:[LiveConnection] = []
    var testProgress = 0
    var testTotal = 0
    var testRunning = false
    var nodeErrors:[String:String] = [:]
}
