import Foundation
import Darwin
import LumaRouteCore

@main struct RuntimeStabilityCheck {
    @MainActor static var failures = 0
    @MainActor static func expect(_ value: Bool,_ message: String) {
        print("\(value ? "PASS":"FAIL") \(message)")
        if !value { failures += 1 }
    }
    @MainActor static func waitFor(_ message: String,until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try await Task.sleep(for:.milliseconds(20)) }
        expect(condition(),message)
    }
    static func socketPort() throws -> (Int32,Int) {
        let fd = socket(AF_INET,SOCK_STREAM,0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        guard fd >= 0,withUnsafePointer(to:&address,{ $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else {
            if fd >= 0 { close(fd) }; throw LumaError.message("fixture bind failed")
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(fd,$0,&size) } }
        return (fd,Int(UInt16(bigEndian:address.sin_port)))
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let root = URL(fileURLWithPath:CommandLine.arguments[1])
        let binary = URL(fileURLWithPath:CommandLine.arguments[2])
        setenv("LUMAROUTE_CORE",binary.path,1)
        let (occupied,controller) = try socketPort(); _ = listen(occupied,1)
        let (other,mixed) = try socketPort(); close(other)
        let dataRoot = root.appendingPathComponent("bootstrap")
        let disk = try LocalStore(root:dataRoot)
        var db = AppDatabase(); db.settings.controllerPort = controller; db.settings.mixedPort = mixed
        try disk.save(db)
        setenv("LUMAROUTE_DATA_DIR",dataRoot.path,1)
        let app = AppStore()
        await app.bootstrap()
        expect(!app.coreReady && app.runner != nil && app.error != nil,"occupied port produces a recoverable startup failure")
        close(occupied)
        do {
            app.prepareForSleep()
            await app.refresh()
            expect(!app.coreReady,"sleep does not start a recovery")
            await app.resumeAfterNetworkChange()
            // The network event must schedule recovery without a manual recheck.
            let deadline = Date().addingTimeInterval(6)
            while !app.coreReady && Date() < deadline { try await Task.sleep(for:.milliseconds(100)) }
            expect(app.coreReady,"startup recovers after the occupied port is released")
            if !app.coreReady { await app.recheck() } // Continue exercising other failures on the baseline.
            guard app.coreReady else { throw LumaError.message("fixture core did not start") }
            app.refreshTask?.cancel(); await app.refreshTask?.value

            for scenario in ["transport","conflict","restore-failure","healthy"] {
                let check = AppStore(); check.store = try LocalStore(root:root.appendingPathComponent(scenario))
                check.database.settings.controllerPort = controller; check.secret = app.secret
                check.database.settings.systemProxy = true; check.database.settings.tun = true
                check.coreReady = true; check.helperActive = true
                check.helper.status = .enabled; check.helper.networkSetup = .ready
                check.helper.statusUnavailable = scenario == "transport"
                check.helper.ownershipLost = ["conflict","restore-failure"].contains(scenario)
                check.helper.stopUnavailable = scenario == "restore-failure"
                try await check.store.saveAsync(check.database)
                let hasConflict = check.helper.ownershipLost
                await check.refresh()
                if hasConflict {
                    expect(!check.coreReady && !check.database.settings.systemProxy && !check.database.settings.tun && check.helper.calls.contains("stop"),"\(scenario): explicit ownership conflict stops takeover")
                    expect(check.helperActive == check.helper.stopUnavailable,"\(scenario): failed restoration remains pending for retry")
                    let saved = try check.store.load()
                    expect(!saved.settings.systemProxy && !saved.settings.tun,"\(scenario): disabled takeover is persisted")
                } else {
                    expect(check.coreReady && check.database.settings.systemProxy && check.database.settings.tun && !check.helper.calls.contains("stop"),"\(scenario): healthy controller keeps takeover")
                }
                await check.shutdown()
            }

            // Only the helper is simulated: production bootstrap, retry and
            // persistence run against the existing loopback controller.
            for (name,tun,proxy) in [("proxy",false,true),("tun",true,false),("both",true,true)] {
                let startupRoot = root.appendingPathComponent("startup-"+name)
                let startupStore = try LocalStore(root:startupRoot)
                var startupDatabase = db
                startupDatabase.settings.connectOnLaunch = true
                startupDatabase.settings.tun = tun; startupDatabase.settings.systemProxy = proxy
                try startupStore.save(startupDatabase)
                try startupStore.secrets.write(app.secret,key:"controller-secret")
                setenv("LUMAROUTE_DATA_DIR",startupRoot.path,1)
                let startup = AppStore()
                startup.helper.status = .enabled; startup.helper.networkSetup = .ready
                startup.helper.startFailures = 1; startup.helper.running = false
                await startup.bootstrap()
                startup.refreshTask?.cancel(); await startup.refreshTask?.value
                expect(!startup.coreReady,"\(name): authorized initial start fails transiently")
                await startup.resumeAfterNetworkChange()
                let saved = try startup.store.load()
                let request = startup.helper.requests.last { ["start","apply"].contains($0.action) }
                expect(startup.coreReady && request?.settings?.tun == tun && request?.settings?.systemProxy == proxy,"\(name): startup retry restores the requested takeover")
                expect(saved.settings.connectOnLaunch && saved.settings.tun == tun && saved.settings.systemProxy == proxy,"\(name): startup retry preserves saved auto-connect settings")
                let stops = startup.helper.calls.filter { $0 == "stop" }.count
                let requestsBeforeRecovery = startup.helper.requests.count
                startup.helper.ownershipLost = true
                await startup.refresh()
                // refresh() may queue behind a page/heartbeat refresh rather
                // than await it. Observe the completed stop and persistence.
                try await waitFor("\(name): runtime conflict finishes stopping and saving") {
                    !startup.busy && startup.helper.calls.filter { $0 == "stop" }.count > stops &&
                    !startup.database.settings.tun && !startup.database.settings.systemProxy
                }
                await startup.resumeAfterNetworkChange()
                try await waitFor("\(name): interrupted recovery completes without takeover") {
                    startup.coreReady && !startup.busy && startup.helper.requests.dropFirst(requestsBeforeRecovery).contains {
                        ["start","apply"].contains($0.action) && $0.settings?.tun == false && $0.settings?.systemProxy == false
                    }
                }
                let interrupted = try startup.store.load()
                expect(!interrupted.settings.tun && !interrupted.settings.systemProxy,"\(name): later runtime conflict never restores stale startup takeover")
                await startup.shutdown()
            }

            // Enter the real service refresh path, fail its post-apply API read,
            // then report a conflict while the scheduled retry is pending.
            let reconnectRoot = root.appendingPathComponent("service-reconnect")
            let reconnectStore = try LocalStore(root:reconnectRoot)
            let (unavailable,reconnectPort) = try socketPort(); close(unavailable)
            var reconnectDatabase = db
            reconnectDatabase.settings.controllerPort = reconnectPort
            reconnectDatabase.settings.connectOnLaunch = true
            reconnectDatabase.settings.tun = true; reconnectDatabase.settings.systemProxy = true
            try reconnectStore.save(reconnectDatabase)
            setenv("LUMAROUTE_DATA_DIR",reconnectRoot.path,1)
            let reconnect = AppStore(); reconnect.helper.networkSetup = .update
            await reconnect.bootstrap()
            reconnect.refreshTask?.cancel(); await reconnect.refreshTask?.value
            reconnect.helper.status = .enabled; reconnect.helper.networkSetup = .ready
            reconnect.helper.enforceOwnership = true
            await reconnect.recheck()
            expect(reconnect.helper.requests.contains { ["start","apply"].contains($0.action) && $0.settings?.tun == true },"service refresh first applies the requested takeover")
            let requestCount = reconnect.helper.requests.count
            reconnect.helper.ownershipLost = true
            try await Task.sleep(for:.seconds(3.1))
            await reconnect.refresh()
            try await waitFor("service refresh conflict explicitly stops owned takeover") {
                !reconnect.busy && reconnect.helper.calls.contains("stop") &&
                !reconnect.database.settings.tun && !reconnect.database.settings.systemProxy
            }
            try await Task.sleep(for:.seconds(6.1))
            await reconnect.refresh()
            try await waitFor("service refresh recovers the core with takeover off") {
                reconnect.coreReady && !reconnect.busy && reconnect.helper.requests.dropFirst(requestCount).contains {
                    ["start","apply"].contains($0.action) && $0.settings?.tun == false && $0.settings?.systemProxy == false
                }
            }
            let later = reconnect.helper.requests.dropFirst(requestCount)
            expect(!later.contains { ["start","apply"].contains($0.action) && ($0.settings?.tun == true || $0.settings?.systemProxy == true) },"service refresh conflict cancels all automatic takeover retries")
            let reconnectSaved = try reconnect.store.load()
            expect(!reconnectSaved.settings.tun && !reconnectSaved.settings.systemProxy,"service refresh conflict persists takeover off")
            await reconnect.shutdown()

            func liveMode() async throws -> String? {
                let value = try JSONSerialization.jsonObject(with:await app.api.data(["configs"])) as? [String:Any]
                return value?["mode"] as? String
            }
            let payloads = try Dictionary(uniqueKeysWithValues:GeoDataUpdates.names.map { ($0,try Data(contentsOf:dataRoot.appendingPathComponent("runtime/"+$0))) })
            app.setMode(.global)
            while app.busy { try await Task.sleep(for:.milliseconds(10)) }
            expect(try await liveMode() == "global","mode PATCH takes effect before GEO maintenance")
            app.busy = true
            try await app.runner.updateGeoData(payloads:payloads)
            app.busy = false
            expect(try await liveMode() == "global" && app.database.settings.mode == .global,"GEO update preserves global mode in runtime and UI")
            let persisted = try ConfigComposer.parse(String(contentsOf:dataRoot.appendingPathComponent("runtime/active.yaml"),encoding:.utf8))
            expect(persisted["mode"] as? String == "global","maintenance persists the current mode for later restarts")
            app.setMode(.direct)
            while app.busy { try await Task.sleep(for:.milliseconds(10)) }
            app.busy = true
            try await app.updateGeoData(rollback:true)
            app.busy = false
            expect(try await liveMode() == "direct" && app.database.settings.mode == .direct,"GEO rollback preserves direct mode in runtime and UI")

            // A failed validation must keep both the live mode and old GEO files.
            let active = dataRoot.appendingPathComponent("runtime/active.yaml")
            let savedYAML = try Data(contentsOf:active)
            let fingerprints = try GeoDataUpdates(home:dataRoot.appendingPathComponent("runtime")).fingerprints()
            try Data("invalid: [\n".utf8).write(to:active)
            var rejected = false
            do { try await app.runner.updateGeoData(payloads:payloads) } catch { rejected = true }
            try savedYAML.write(to:active)
            let modeAfterFailure = try await liveMode()
            expect(rejected && modeAfterFailure == "direct","failed GEO validation keeps the live mode")
            expect(try GeoDataUpdates(home:dataRoot.appendingPathComponent("runtime")).fingerprints() == fingerprints,"failed GEO validation restores the original files")
        } catch {
            await app.shutdown(); throw error
        }
        await app.shutdown()

        // Keep the failure present for all three retries, then release it.
        // The exhausted loop must wait for a new network event or explicit recheck.
        let retryRoot = root.appendingPathComponent("retry-limit")
        let retryStore = try LocalStore(root:retryRoot)
        let (blocked,retryPort) = try socketPort(); _ = listen(blocked,1)
        var retryDatabase = db; retryDatabase.settings.controllerPort = retryPort
        try retryStore.save(retryDatabase)
        setenv("LUMAROUTE_DATA_DIR",retryRoot.path,1)
        let retry = AppStore()
        await retry.bootstrap()
        retry.refreshTask?.cancel(); await retry.refreshTask?.value
        for delay in [1.1,3.1,6.1] {
            try await Task.sleep(for:.seconds(delay))
            await retry.refresh()
        }
        close(blocked)
        try await Task.sleep(for:.seconds(9.1))
        await retry.refresh()
        expect(!retry.coreReady && retry.error?.contains("内核恢复失败") == true,"startup retries stop after three failures")
        await retry.resumeAfterNetworkChange()
        expect(retry.coreReady,"new network event permits another bounded recovery")
        await retry.shutdown()

        // Authorization remains explicit; the startup retry must not bypass it.
        for (name,setup) in [("install",NetworkServiceSetup.install),("update",.update)] {
            let waitingRoot = root.appendingPathComponent("authorization-"+name)
            let waitingStore = try LocalStore(root:waitingRoot)
            var waitingDatabase = db; waitingDatabase.settings.connectOnLaunch = true; waitingDatabase.settings.tun = true
            try waitingStore.save(waitingDatabase)
            setenv("LUMAROUTE_DATA_DIR",waitingRoot.path,1)
            let waiting = AppStore(); waiting.helper.networkSetup = setup
            await waiting.bootstrap(); await waiting.resumeAfterNetworkChange()
            expect(!waiting.coreReady && waiting.helper.calls.isEmpty,"pending \(name) approval does not auto-start or bypass authorization")
            await waiting.shutdown()
        }
        print("runtime stability failures: \(failures)")
        if failures > 0 { exit(1) }
    }
}
