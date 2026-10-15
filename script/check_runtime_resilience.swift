import Foundation
import SQLite3
import Darwin
import LumaRouteCore

@main struct RuntimeResilienceCheck {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let root = URL(fileURLWithPath:CommandLine.arguments[2])
        let port = Int(CommandLine.arguments[1])!
        let app = AppStore()
        app.store = try LocalStore(root:root)
        app.database.settings.controllerPort = port
        app.coreReady = true
        func control(_ fault: String) async throws { _ = try await app.api.data(["control",fault]) }
        func stats() async throws -> [String:Int] { try JSONDecoder().decode([String:Int].self,from:await app.api.data(["stats"])) }
        func settle() async throws { try await Task.sleep(nanoseconds:150_000_000) }
        let content = "proxies: []\nproxy-groups: []\nrules: ['MATCH,DIRECT']\n"
        var profile = Profile(name:"loopback",isRemote:true,updateHours:1)
        profile.created = .distantPast
        app.database.profiles = [profile]; app.database.activeProfileID = profile.id
        try app.store.commit(app.database,profiles:[profile.id:content+"# prior\n"],subscriptionAddresses:[profile.id:"http://127.0.0.1:\(port)/subscription"])
        try app.store.commit(app.database,profiles:[profile.id:content])
        // No runner/helper exists here: identical active subscriptions must skip
        // kernel validation/reload entirely while updating metadata and usage.
        let start = Date()
        let download = Task { await app.updateDueSubscriptions() }
        try await settle()
        precondition(!app.busy && app.updatingProfiles.contains(profile.id))
        var preference = app.database.settings; preference.appearance = "dark"
        let saveStart = ProcessInfo.processInfo.systemUptime
        app.busy = true
        try await app.saveSettings(preference)
        app.busy = false
        let saveMS = Int((ProcessInfo.processInfo.systemUptime-saveStart)*1000)
        await app.refresh()
        precondition(app.coreReady && Date().timeIntervalSince(start) < 0.7)
        await download.value
        precondition(app.database.settings.appearance == "dark" && app.database.profiles[0].lastUpdated != nil && app.database.profiles[0].usage != nil)
        let persistedPreferences = try app.store.load()
        precondition(persistedPreferences.settings.appearance == "dark")
        print("PASS slow automatic download leaves preferences/health responsive; preference save \(saveMS) ms")
        print("PASS identical active subscription updates metadata without runner, reload or stream restart")
        // Deleting while the next download runs must never resurrect its rows.
        let stale = Task { try await app.update(app.database.profiles[0],background:true) }
        try await settle()
        app.busy = true
        app.database.activeProfileID = nil; app.database.profiles = []
        try await app.store.commitAsync(app.database,profiles:[:],removingProfiles:[profile.id])
        app.busy = false
        try await stale.value
        let deleted = try app.store.load()
        precondition(app.database.profiles.isEmpty && deleted.profiles.isEmpty)
        print("PASS stale downloaded result cannot resurrect a deleted subscription")
        // A cancelled direct curl must stop promptly and not report a failed update.
        app.database.profiles = [profile]
        try app.store.commit(app.database,profiles:[profile.id:content],subscriptionAddresses:[profile.id:"http://127.0.0.1:\(port)/subscription"])
        let cancelled = Task { try await app.update(profile,background:true) }
        try await settle()
        let cancelledAt = ProcessInfo.processInfo.systemUptime
        cancelled.cancel()
        do { try await cancelled.value; fatalError("expected cancellation") } catch is CancellationError {}
        precondition(ProcessInfo.processInfo.systemUptime-cancelledAt < 0.5 && app.database.profiles[0].lastAttempt == nil && !app.busy)
        print("PASS cancellation stops direct download promptly without changing subscription metadata")
        // A foreground update completed while an earlier download was pending
        // makes a queued subscription no longer due. It must not download again.
        let queueApp = AppStore(); queueApp.store = try LocalStore(root:root.appendingPathComponent("queue"))
        queueApp.database.settings.controllerPort = port; queueApp.coreReady = true
        var queued = Profile(name:"queued",isRemote:true,updateHours:1); queued.created = .distantPast
        queueApp.database.profiles = [profile,queued]
        try queueApp.store.commit(queueApp.database,profiles:[profile.id:content,queued.id:content],subscriptionAddresses:[profile.id:"http://127.0.0.1:\(port)/subscription",queued.id:"http://127.0.0.1:\(port)/subscription"])
        let queueBefore = try await stats()
        let queueUpdate = Task { await queueApp.updateDueSubscriptions() }
        try await settle()
        queueApp.database.profiles[1].lastUpdated = Date()
        await queueUpdate.value
        let queueAfter = try await stats()
        precondition(queueAfter["/subscription",default:0]-queueBefore["/subscription",default:0] == 1 && queueApp.database.profiles[1].lastAttempt == nil)
        await queueApp.shutdown()
        print("PASS queued subscriptions recheck due state after foreground changes and skip redundant downloads")
        // Ordinary endpoint failures retain their last usable view and networking.
        app.database.settings.systemProxy = true
        app.setMainWindowVisible(true); app.page = .connections
        await app.refresh(); try await settle()
        precondition(app.connections.count == 1)
        try await control("connections"); await app.refresh()
        precondition(app.coreReady && app.database.settings.systemProxy && app.connections.first?.id == "retained")
        try await control("proxies"); await app.refresh()
        precondition(app.coreReady && app.database.settings.systemProxy && !app.proxies.isEmpty)
        try await control("version-once"); await app.refresh()
        precondition(app.coreReady && app.database.settings.systemProxy)
        await app.refresh()
        print("PASS connections/proxies/single heartbeat failures preserve core, network settings and last view")
        // Both clean EOF and HTTP failures reconnect; replacement/sleep/exit stop retries.
        let streamApp = AppStore(); streamApp.store = app.store
        streamApp.database = app.database; streamApp.coreReady = true
        let before = try await stats()
        streamApp.restartStreams()
        try await Task.sleep(nanoseconds:3_400_000_000)
        let after = try await stats()
        precondition(after["/traffic",default:0]-before["/traffic",default:0] >= 3 && after["/logs",default:0]-before["/logs",default:0] >= 3 && streamApp.traffic.down == 42)
        try await control("traffic")
        streamApp.restartStreams()
        try await Task.sleep(nanoseconds:1_300_000_000)
        try await control("none")
        try await Task.sleep(nanoseconds:2_200_000_000)
        precondition(streamApp.traffic.down == 42)
        streamApp.prepareForSleep()
        try await settle()
        let sleeping = try await stats()
        try await Task.sleep(nanoseconds:1_200_000_000)
        let stillSleeping = try await stats()
        precondition(sleeping["/traffic"] == stillSleeping["/traffic"] && sleeping["/logs"] == stillSleeping["/logs"])
        print("PASS clean EOF/errors reconnect with backoff; sleep cancels both streams and pending retries")
        streamApp.runner = CoreRunner(binary:URL(fileURLWithPath:"/no-core"),home:root.appendingPathComponent("stream-runtime"),secret:"")
        await streamApp.resumeAfterNetworkChange()
        try await settle()
        await streamApp.shutdown()
        try await control("version-all")
        await app.refresh(); precondition(app.coreReady)
        await app.refresh(); precondition(app.coreReady)
        await app.refresh(); precondition(!app.coreReady && !app.database.settings.systemProxy)
        print("PASS three consecutive heartbeat failures enter recovery and clear network takeover")
        // A confirmed local process exit is acted on immediately (no three strikes).
        try await control("none")
        app.coreReady = true
        app.runner = CoreRunner(binary:URL(fileURLWithPath:"/no-core"),home:root.appendingPathComponent("runtime"),secret:"")
        try await control("version-all"); await app.refresh()
        precondition(!app.coreReady)
        print("PASS confirmed stopped local process enters recovery on the first heartbeat")
        // Force a real SQLite write lock. MainActor must continue running while
        // the serial storage executor waits, then commit when the lock releases.
        var external: OpaquePointer?
        precondition(sqlite3_open(app.store.databaseURL.path,&external) == SQLITE_OK)
        precondition(sqlite3_exec(external,"BEGIN IMMEDIATE",nil,nil,nil) == SQLITE_OK)
        var ticks = 0
        let lockStart = ProcessInfo.processInfo.systemUptime
        let write = Task { try await app.store.saveSettingsAsync(app.database.settings) }
        for _ in 0..<10 { try await Task.sleep(nanoseconds:10_000_000); ticks += 1 }
        precondition(sqlite3_exec(external,"COMMIT",nil,nil,nil) == SQLITE_OK)
        sqlite3_close(external)
        try await write.value
        precondition(ticks == 10 && ProcessInfo.processInfo.systemUptime-lockStart < 0.4)
        print("PASS SQLite lock wait runs off MainActor while 10 UI heartbeat ticks execute")
        let slowBinary = root.appendingPathComponent("slow-validation.sh")
        try "#!/bin/sh\nexec /bin/sleep 10\n".write(to:slowBinary,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:slowBinary.path)
        let validator = CoreRunner(binary:slowBinary,home:root.appendingPathComponent("runtime"),secret:"")
        let validation = Task { try await validator.validate(file:root.appendingPathComponent("unused.yaml")) }
        try await settle()
        let validationCancelStart = ProcessInfo.processInfo.systemUptime
        validation.cancel()
        do { try await validation.value; fatalError("expected cancelled validation") } catch is CancellationError {}
        precondition(ProcessInfo.processInfo.systemUptime-validationCancelStart < 0.5)
        print("PASS validation cancellation terminates its process promptly")
        let revisionHome = root.appendingPathComponent("retention")
        let revisions = revisionHome.appendingPathComponent("revisions")
        var directories: [URL] = []
        let now = Date()
        for index in 0..<35 {
            let directory = revisions.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try FileManager.default.setAttributes([.modificationDate:now.addingTimeInterval(-7200-Double(index))],ofItemAtPath:directory.path)
            directories.append(directory)
        }
        let fresh = revisions.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:fresh,withIntermediateDirectories:true)
        let active = "proxy-providers:\n  fixture:\n    type: file\n    path: '\(directories.last!.path)/provider.yaml'\n"
        try active.write(to:revisionHome.appendingPathComponent("active.yaml"),atomically:true,encoding:.utf8)
        let retention = CoreRunner(binary:URL(fileURLWithPath:"/no-core"),home:revisionHome,secret:"")
        await retention.pruneRevisions(now:now)
        let kept = try FileManager.default.contentsOfDirectory(atPath:revisions.path)
        precondition(kept.count == 21 && kept.contains(directories.last!.lastPathComponent) && kept.contains(fresh.lastPathComponent))
        print("PASS runtime pruning retains active provider references, fresh work and newest 20 revisions (36 → 21)")
        let externalDirectory = root.appendingPathComponent("external-canary")
        try FileManager.default.createDirectory(at:externalDirectory,withIntermediateDirectories:true)
        let unknown = revisions.appendingPathComponent("unmanaged")
        try FileManager.default.createDirectory(at:unknown,withIntermediateDirectories:true)
        let symlink = revisions.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at:symlink,withDestinationURL:externalDirectory)
        await retention.pruneRevisions(now:now.addingTimeInterval(7200))
        precondition(FileManager.default.fileExists(atPath:unknown.path) && FileManager.default.fileExists(atPath:symlink.path) && FileManager.default.fileExists(atPath:externalDirectory.path))
        print("PASS runtime pruning leaves unmanaged directories and symlinks untouched")
        await app.shutdown()
    }
}
