import Foundation
import LumaRouteCore

// Test doubles replace process/network effects while the generated companion
// file exercises the production HelperController, including its catch block.
actor CoreRunner {
    let secret: String
    let home: URL
    var running = false
    var stopCount = 0
    var failure: String?
    init(binary: URL,home: URL,secret: String,geoPolicy: URL? = nil) { self.home = home; self.secret = secret }
    func setFailure(_ value: String) { failure = value }
    func prepare(source: String?,settings: NetworkSettings,rules: [CustomRule],strategies: [GroupStrategy],ruleSubscriptions: [RuleSubscriptionSnapshot]) throws -> (String,URL) {
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        let yaml = try ConfigComposer.compose(source:source,settings:settings,rules:rules,secret:secret)
        let file = home.appendingPathComponent("candidate.yaml")
        try yaml.write(to:file,atomically:true,encoding:.utf8)
        return (yaml,file)
    }
    func validate(file: URL) {}
    func start(yaml: String,settings: NetworkSettings) throws {
        if failure == "restart-request" { throw CoreApplyError(recovery:.rolledBack,original:LumaError.message("fixture start failure")) }
        running = true
    }
    func apply(yaml: String,settings: NetworkSettings) throws {
        if failure == "network-fails" { return }
        if failure == "ordinary" { throw LumaError.message("fixture unexpected error") }
        throw CoreApplyError(recovery:failure == "unknown" ? .stateUnknown:.rolledBack,original:LumaError.message("fixture candidate rejected"))
    }
    func stop() -> Bool { stopCount += 1; running = false; return true }
    func updateRouting(source: String?,settings: NetworkSettings,rules: [CustomRule],strategies: [GroupStrategy],ruleSubscriptions: [RuleSubscriptionSnapshot]) {}
    func updateGeoData(rollback: Bool) {}
    static func recoverAbandonedProcess(binary: URL,home: URL) async throws {}
}

final class SystemNetwork {
    var applyCount = 0
    var restoreCount = 0
    var ownsSettings = true
    var failApply = false
    init(journal: URL) {}
    func verifyOwnership() throws { if !ownsSettings { throw LumaError.message("fixture ownership lost") } }
    func apply(settings: NetworkSettings) throws {
        applyCount += 1
        if failApply { throw LumaError.message("fixture network apply failed") }
    }
    func applySystemProxy(settings: NetworkSettings) throws { try apply(settings:settings) }
    func restore() { restoreCount += 1 }
}

@main struct ApplyRecoveryCheck {
    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("FAIL "+message+"\n").utf8)); exit(1)
    }
    static func main() async {
        do { try await run() } catch { fail(error.localizedDescription) }
    }
    static func run() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1]),uid = getuid()
        let secret = String(repeating:"x",count:40)
        var previous = NetworkSettings(); previous.tun = true; previous.systemProxy = true
        for fault in ["recovered","unknown","ordinary","stopped","ownership-lost","network-fails","restart-request"] {
            let controller = HelperController(app:root.appendingPathComponent("fixture.app"))
            await controller.prepareHealthOnly()
            _ = try await controller.execute(HelperRequest(action:"start",settings:previous,secret:secret),uid:uid)
            guard let original = await controller.runners[uid],let network = await controller.networks[uid] else { fail("fixture not started") }
            await original.setFailure(fault)
            if fault == "stopped" { _ = await original.stop() }
            if fault == "ownership-lost" { network.ownsSettings = false }
            if fault == "network-fails" { network.failApply = true }
            let stops = await original.stopCount,applies = network.applyCount
            var next = previous; next.mode = .global; next.systemProxy = false
            var failed = false
            do { _ = try await controller.execute(HelperRequest(action:fault == "restart-request" ? "start":"apply",settings:next,secret:secret),uid:uid) }
            catch { failed = true }
            guard failed else { fail("candidate unexpectedly accepted: "+fault) }
            let retained = await controller.runners[uid],settings = await controller.appliedSettings[uid],owner = await controller.networkOwner
            let stopCount = await original.stopCount,running = await original.running
            if fault == "recovered" {
                guard retained === original,settings == previous,owner == uid,running,
                      stopCount == stops,network.restoreCount == 0,network.applyCount == applies else {
                    fail("verified rollback tore down or changed network takeover")
                }
                print("PASS verified rollback preserves runner, TUN, proxy settings and network ownership")
            } else {
                guard retained == nil,settings == nil,owner == nil,!running,
                      stopCount > stops,network.restoreCount > 0 else { fail("unsafe takeover retained: "+fault) }
                print("PASS cleanup retained for "+fault)
            }
            try await controller.stop(uid:uid)
        }
        print("helper apply recovery suite passed: 7 scenarios")
    }
}
