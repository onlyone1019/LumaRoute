import Foundation
import LumaRouteCore

actor HelperController {
    let app: URL
    private let usersDirectory: URL
    private let directoryOwner: uid_t
    var runners: [uid_t:CoreRunner] = [:]
    var networks: [uid_t:SystemNetwork] = [:]
    var appliedSettings: [uid_t:NetworkSettings] = [:]
    var networkOwner: uid_t?
    var startupReady = false
    var operations: Set<uid_t> = []
    var pendingStops: Set<uid_t> = []
    var pendingRestores: Set<uid_t> = []
    var shuttingDown = false
    init(app: URL) {
        self.app = app
        usersDirectory = URL(fileURLWithPath:"/Library/Application Support/LumaRoute/users")
        directoryOwner = 0
    }
    #if HELPER_RECOVERY_TEST
    init(app: URL, usersDirectory: URL) {
        self.app = app
        self.usersDirectory = usersDirectory
        directoryOwner = getuid()
    }
    #endif

    private func userDirectory(_ uid: uid_t) -> URL {
        usersDirectory.appendingPathComponent(String(uid), isDirectory:true)
    }
    func prepareHealthOnly() { startupReady = true }
    func restoreNetworkForMaintenance(uid:uid_t) throws {
        let directory=userDirectory(uid)
        try checkOwnership(directory)
        try SystemNetwork(journal:directory.appendingPathComponent("network-journal.plist")).restore()
    }
    func shutdown() async {
        shuttingDown = true
        let deadline = Date().addingTimeInterval(20)
        while !operations.isEmpty && Date() < deadline { try? await Task.sleep(nanoseconds:100_000_000) }
        for uid in Set(runners.keys).union(networks.keys).union(pendingRestores) {
            do { try await stop(uid:uid) }
            catch { FileHandle.standardError.write(Data(("退出恢复未完成："+Redactor.clean(error.localizedDescription)+"\n").utf8)) }
        }
    }
    func recoverStartup() async {
        let directories = (try? FileManager.default.contentsOfDirectory(at:usersDirectory,includingPropertiesForKeys:nil)) ?? []
        for directory in directories {
            guard let uid = uid_t(directory.lastPathComponent),uid > 0 else { continue }
            do {
                try checkOwnership(directory)
                let network = try SystemNetwork(journal:directory.appendingPathComponent("network-journal.plist"))
                networks[uid] = network
                // Restore before stopping the orphan so DNS/proxy never point at a dead core.
                try network.restore()
                let updates = try coreUpdates(directory)
                try await updates.recoverPendingSwitch(runtime:directory.appendingPathComponent("runtime"))
                try await CoreRunner.recoverAbandonedProcess(binary:updates.currentBinary(),home:directory.appendingPathComponent("runtime"))
            } catch {
                pendingRestores.insert(uid); networkOwner = uid
                FileHandle.standardError.write(Data(("恢复待重试："+Redactor.clean(error.localizedDescription)+"\n").utf8))
            }
        }
        startupReady = true
    }
    private func checkOwnership(_ directory: URL) throws {
        for path in [directory.deletingLastPathComponent().deletingLastPathComponent(),directory.deletingLastPathComponent(),directory] {
            guard path.resolvingSymlinksInPath() == path,
                  let owner = try FileManager.default.attributesOfItem(atPath:path.path)[.ownerAccountID] as? NSNumber,owner.uint32Value == directoryOwner,
                  let permissions = try FileManager.default.attributesOfItem(atPath:path.path)[.posixPermissions] as? NSNumber,permissions.intValue & 0o022 == 0 else {
                throw LumaError.message("后台服务目录必须由 root 拥有，且不能是符号链接")
            }
        }
    }
    private func coreUpdates(_ directory: URL) throws -> CoreUpdates {
        try CoreUpdates(root:directory.appendingPathComponent("cores"),bundled:app.appendingPathComponent("Contents/Resources/mihomo"))
    }
    func watchdog() async {
        guard startupReady else { return }
        for uid in Set(runners.keys).union(pendingRestores) where !operations.contains(uid) {
            let running = await runners[uid]?.running ?? false
            if pendingRestores.contains(uid) || !running {
                await clientDisconnected(uid:uid)
            }
        }
    }
    func clientDisconnected(uid: uid_t) async {
        if operations.contains(uid) { pendingStops.insert(uid); return }
        operations.insert(uid); defer { operations.remove(uid) }
        try? await stop(uid:uid)
    }
    func execute(_ request: HelperRequest,uid: uid_t) async throws -> HelperResponse {
        guard !shuttingDown else { throw LumaError.message("后台服务正在退出并恢复网络") }
        guard startupReady else { throw LumaError.message("后台服务正在恢复上次网络状态，请稍后重试") }
        guard !operations.contains(uid) else { throw LumaError.message("后台服务正在处理上一项操作") }
        operations.insert(uid)
        defer {
            operations.remove(uid)
            if pendingStops.remove(uid) != nil { Task { await self.clientDisconnected(uid:uid) } }
        }
        let directory = userDirectory(uid)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try checkOwnership(directory)
        switch request.action {
        case "status":
            var ownershipLost = false
            do { try networks[uid]?.verifyOwnership() }
            catch is NetworkOwnershipError { ownershipLost = true }
            return HelperResponse(success:true,running:await runners[uid]?.running ?? false,canRollbackGeo:try GeoDataUpdates(home:directory.appendingPathComponent("runtime")).canRollback,serviceUID:geteuid(),protocolVersion:1,networkOwnershipLost:ownershipLost)
        case "geo-update", "geo-rollback":
            guard let core = runners[uid],await core.running else { throw LumaError.message("授权内核尚未运行") }
            do { try await core.updateGeoData(rollback:request.action == "geo-rollback") }
            catch {
                let original = error
                if !(await core.running) { try? await stop(uid:uid) }
                throw original
            }
            return HelperResponse(success:true,running:await core.running,canRollbackGeo:try GeoDataUpdates(home:directory.appendingPathComponent("runtime")).canRollback)
        case "stop", "restore":
            try await stop(uid:uid)
            return HelperResponse(success:true)
        case "system-proxy":
            guard networkOwner == nil || networkOwner == uid else { throw LumaError.message("另一位用户正在使用 LumaRoute 网络接管") }
            guard !pendingRestores.contains(uid) else { throw LumaError.message("原网络设置仍待恢复，暂不能重新接管") }
            guard let enabled = request.systemProxyEnabled,
                  let previous = appliedSettings[uid],let network = networks[uid],
                  let core = runners[uid],await core.running else { throw LumaError.message("授权内核尚未运行，请先重新检查后台服务") }
            var settings = previous
            settings.systemProxy = enabled
            do { try network.applySystemProxy(settings:settings) }
            catch {
                let original = error
                do { try network.applySystemProxy(settings:previous) }
                catch { try? await stop(uid:uid) }
                throw original
            }
            appliedSettings[uid] = settings
            if settings.tun || settings.systemProxy { networkOwner = uid } else if networkOwner == uid { networkOwner = nil }
            return HelperResponse(success:true,running:await core.running)
        case "apply-routing":
            guard networkOwner == nil || networkOwner == uid,!pendingRestores.contains(uid),
                  let settings = request.settings,let previous = appliedSettings[uid],
                  RoutingUpdatePolicy.networkUnchanged(settings,from:previous),
                  let core = runners[uid],await core.running,request.secret == (await core.secret),
                  (request.source?.utf8.count ?? 0) <= 8*1024*1024 else {
                throw LumaError.message("后台运行或网络参数已变化，请重新打开分流编辑器")
            }
            let selection = try coreUpdates(directory).selection()
            guard selection.active?.release.version == request.coreVersion else { throw LumaError.message("内核版本已变化，请重新保存分流规则") }
            try networks[uid]?.verifyOwnership()
            try PrivilegedConfigurationPolicy.validate(request.source)
            try await core.updateRouting(source:request.source,settings:settings,rules:request.rules ?? [],strategies:request.strategies ?? [],ruleSubscriptions:request.ruleSubscriptions ?? [])
            appliedSettings[uid] = settings
            return HelperResponse(success:true,running:await core.running)
        case "start", "apply":
            guard networkOwner == nil || networkOwner == uid else { throw LumaError.message("另一位用户正在使用 LumaRoute 网络接管") }
            guard !pendingRestores.contains(uid) else { throw LumaError.message("原网络设置仍待恢复，暂不能重新接管") }
            guard let settings = request.settings, let secret = request.secret, secret.count >= 32,
                  (request.source?.utf8.count ?? 0) <= 8*1024*1024 else { throw LumaError.message("服务请求参数无效") }
            try PrivilegedConfigurationPolicy.validate(request.source)
            let updates = try coreUpdates(directory)
            let selection = try updates.selection()
            let changed = selection.active?.release.version != request.coreVersion
            guard !changed || runners[uid] == nil else { throw LumaError.message("请先暂停接管再切换内核版本") }
            var artifact = selection.active
            if changed {
                if let version = request.coreVersion {
                    // The helper downloads and verifies official code itself; no user executable path is accepted.
                    if let cached = try updates.cachedArtifact(version:version) { artifact = cached }
                    else { artifact = try await updates.stage(CoreRelease.version(version)) }
                } else { artifact = nil }
            }
            let core = try runners[uid] ?? CoreRunner(binary:updates.binary(for:artifact),home:directory.appendingPathComponent("runtime"),secret:secret,geoPolicy:app.appendingPathComponent("Contents/Resources/GeoData/GeoSite-policy.json"))
            let network = try networks[uid] ?? SystemNetwork(journal:directory.appendingPathComponent("network-journal.plist"))
            networks[uid] = network
            let (yaml,file) = try await core.prepare(source:request.source,settings:settings,rules:request.rules ?? [],strategies:request.strategies ?? [],ruleSubscriptions:request.ruleSubscriptions ?? [])
            try await core.validate(file:file)
            if changed { try updates.beginSwitch(to:artifact) }
            do {
            if request.action == "start" {
                await core.stop()
                try await core.start(yaml:yaml,settings:settings)
            } else { try await core.apply(yaml:yaml,settings:settings) }
            runners[uid] = core
            if let artifact {
                let api = MihomoAPI(port:settings.controllerPort,secret:secret)
                guard try await api.version() == artifact.release.version else { throw LumaError.message("授权内核版本与官方发布信息不一致") }
            }
            try await GroupSelection.restore(request.selections ?? [],api:MihomoAPI(port:settings.controllerPort,secret:secret))
            do {
                guard !shuttingDown else { throw LumaError.message("后台服务正在退出，已取消网络接管") }
                try network.apply(settings:settings)
            }
            catch { let original = error; try? await stop(uid:uid); throw original }
            if changed { try updates.finishSwitch() }
            appliedSettings[uid] = settings
            if settings.tun || settings.systemProxy { networkOwner = uid } else if networkOwner == uid { networkOwner = nil }
            return HelperResponse(success:true,running:await core.running)
            } catch {
                var preserveTakeover = false
                if let failure = error as? CoreApplyError,failure.recovery == .rolledBack,
                   request.action == "apply",!changed,!shuttingDown,
                   runners[uid] === core,appliedSettings[uid] != nil,await core.running {
                    // A rejected candidate did not replace the old network settings.
                    // Keep them only while their ownership is still confirmed.
                    do { try network.verifyOwnership(); preserveTakeover = true } catch {}
                }
                if !preserveTakeover { await core.stop(); try? await stop(uid:uid) }
                if changed { try? updates.cancelSwitch() }
                throw error
            }
        default: throw LumaError.message("不支持的服务操作")
        }
    }
    func stop(uid: uid_t) async throws {
        var failure: Error?
        do { try networks[uid]?.restore() } catch { failure = error; pendingRestores.insert(uid); networkOwner = uid }
        // A restore failure must never leave privileged packet interception running.
        if let runner = runners[uid],!(await runner.stop()) { throw LumaError.message("授权内核尚未退出，网络设置已恢复，将继续清理进程") }
        if runners[uid] == nil {
            do {
                let directory = userDirectory(uid)
                let updates = try coreUpdates(directory)
                try await updates.recoverPendingSwitch(runtime:directory.appendingPathComponent("runtime"))
                try await CoreRunner.recoverAbandonedProcess(binary:updates.currentBinary(),home:directory.appendingPathComponent("runtime"))
            }
            catch { failure = failure ?? error; pendingRestores.insert(uid); networkOwner = uid }
        }
        runners.removeValue(forKey:uid)
        appliedSettings.removeValue(forKey:uid)
        if let failure { throw failure }
        pendingRestores.remove(uid)
        if networkOwner == uid { networkOwner = nil }
    }
}
