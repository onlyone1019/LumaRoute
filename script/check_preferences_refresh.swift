import Foundation
import LumaRouteCore

@main struct PreferencesRefreshCheck {
    @MainActor static func main() async throws {
        let app = AppStore()
        app.store = try LocalStore(root:URL(fileURLWithPath:CommandLine.arguments[2]),secrets:MemorySecrets())
        app.database.settings.controllerPort = Int(CommandLine.arguments[1])!
        app.page = .settings
        app.coreReady = true
        let start = Date()
        for tick in 0..<30 {
            #if OPTIMIZED
            await app.refresh(force:false,now:start.addingTimeInterval(Double(tick)*2))
            #else
            await app.refresh()
            #endif
            precondition(app.coreReady)
        }
        print("PASS 60 seconds of hidden/settings polling")
        #if OPTIMIZED
        print("HIDDEN \(String(data:try await app.api.data(["checkpoint","hidden"]),encoding:.utf8)!)")
        // No runner, updates or helper: a preference save must not touch them.
        var settings = app.database.settings
        settings.appearance = "dark"; settings.connectOnLaunch = true
        settings.testConcurrency = 8; settings.updateIntervalHours = 12
        let traffic = Task<Void,Never> { try? await Task.sleep(nanoseconds:60_000_000_000) }
        app.trafficTask = traffic
        let began = ProcessInfo.processInfo.systemUptime
        try await app.saveSettings(settings)
        let saved = try app.store.load()
        precondition(app.database.settings == settings && saved.settings == settings)
        precondition(!traffic.isCancelled && app.coreReady)
        print("PASS preferences persisted without runner/helper/stream restart: \(Int((ProcessInfo.processInfo.systemUptime-began)*1000)) ms")
        // An atomic save failure leaves the live settings and streams intact.
        app.store = try LocalStore(root:app.store.root,secrets:MemorySecrets(),readOnly:true)
        var failed = settings; failed.appearance = "light"
        do { try await app.saveSettings(failed); fatalError("expected write failure") } catch {}
        precondition(app.database.settings == settings && !traffic.isCancelled && app.coreReady)
        traffic.cancel()
        print("PASS failed preference persistence preserves current settings")
        // Virtual time advances only deadlines; actual AppStore network calls
        // still go through URLSession and the loopback server.
        for (index, page) in [AppPage.proxies,.connections,.rules].enumerated() {
            app.setMainWindowVisible(true)
            app.page = page
            await app.refresh()
            try await Task.sleep(nanoseconds:300_000_000)
            _ = try await app.api.data(["checkpoint","discard"])
            for tick in 0..<30 {
                await app.refresh(force:false,now:start.addingTimeInterval(Double((index+1)*60+tick*2)))
            }
            print("VISIBLE \(page.rawValue) \(String(data:try await app.api.data(["checkpoint",String(index)]),encoding:.utf8)!)")
        }
        app.setMainWindowVisible(true)
        app.page = .connections
        await app.refresh()
        try await Task.sleep(nanoseconds:300_000_000)
        precondition(app.connections.count == 1 && app.connections[0].processName == "fixture")
        app.page = .rules
        await app.refresh()
        try await Task.sleep(nanoseconds:300_000_000)
        precondition(app.liveRules.count == 1)
        precondition(app.proxies["provider-node"]?.providerName == "fixture-provider")
        precondition(app.proxies["provider-node"]?.delay == 42)
        print("PASS entering connections/rules immediately loads their data and provider metadata")
        // In-flight requests started before a configuration change cannot publish.
        let stale = Task { await app.refresh() }
        try await Task.sleep(nanoseconds:5_000_000)
        app.busy = true
        app.proxies = [:]
        await stale.value
        precondition(app.proxies.isEmpty && app.coreReady)
        app.busy = false
        await app.refresh()
        print("PASS stale observations cannot overwrite new configuration state")
        // Even with no window visible, a dead controller must trigger recovery.
        app.setMainWindowVisible(false)
        app.database.settings.controllerPort = 1
        await app.refresh(force:false)
        precondition(app.coreReady)
        await app.refresh(force:false)
        precondition(app.coreReady)
        await app.refresh(force:false)
        precondition(!app.coreReady)
        print("PASS background health failure still detects a stopped core")
        #endif
    }
}
