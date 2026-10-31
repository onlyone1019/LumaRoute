import Foundation
import Security
import OSLog
import LumaRouteCore

func containingApp() throws -> URL {
    let path = URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath().path
    guard let range = path.range(of:".app/Contents/") else { throw LumaError.message("后台服务必须从签名应用包内启动") }
    return URL(fileURLWithPath:String(path[..<range.lowerBound]) + ".app")
}
final class ClientVerifier {
    private let requirement:String
    private let ownerUID:UInt32?
    init(app: URL,ownerUID:UInt32? = nil) throws {
        self.ownerUID = ownerUID
        var code: SecStaticCode?; var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL,[],&code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate),nil) == errSecSuccess,
              SecCodeCopyDesignatedRequirement(code,[],&requirement) == errSecSuccess, let requirement
        else { throw LumaError.message("应用签名无效，无法启动授权服务") }
        var text:CFString?
        guard SecRequirementCopyString(requirement,[],&text) == errSecSuccess,let text else { throw LumaError.message("服务调用身份无效") }
        self.requirement = text as String
    }
    func accepts(_ connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0,
              ownerUID == nil || ownerUID == connection.effectiveUserIdentifier else { return false }
        connection.setCodeSigningRequirement(requirement)
        return true
    }
}
actor HelperController {
    let app: URL
    var runners: [uid_t:CoreRunner] = [:]
    var networks: [uid_t:SystemNetwork] = [:]
    var appliedSettings: [uid_t:NetworkSettings] = [:]
    var networkOwner: uid_t?
    var startupReady = false
    var operations: Set<uid_t> = []
    var pendingStops: Set<uid_t> = []
    var pendingRestores: Set<uid_t> = []
    var shuttingDown = false
    init(app: URL) { self.app = app }
    func prepareHealthOnly() { startupReady = true }
    func restoreNetworkForMaintenance(uid:uid_t) throws {
        let directory=URL(fileURLWithPath:"/Library/Application Support/LumaRoute/users/\(uid)")
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
        let root = URL(fileURLWithPath:"/Library/Application Support/LumaRoute/users")
        let directories = (try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? []
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
                  let owner = try FileManager.default.attributesOfItem(atPath:path.path)[.ownerAccountID] as? NSNumber,owner.uint32Value == 0,
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
        let directory = URL(fileURLWithPath:"/Library/Application Support/LumaRoute/users/\(uid)")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try checkOwnership(directory)
        switch request.action {
        case "status":
            try networks[uid]?.verifyOwnership()
            return HelperResponse(success:true,running:await runners[uid]?.running ?? false,canRollbackGeo:try GeoDataUpdates(home:directory.appendingPathComponent("runtime")).canRollback,serviceUID:geteuid(),protocolVersion:1)
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
                let directory = URL(fileURLWithPath:"/Library/Application Support/LumaRoute/users/\(uid)")
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
final class ClientHandler: NSObject, LumaRouteHelperProtocol, Sendable {
    let uid: uid_t
    let controller: HelperController
    let healthOnly:Bool
    init(uid: uid_t,controller: HelperController,healthOnly:Bool) { self.uid = uid; self.controller = controller; self.healthOnly = healthOnly }
    func perform(_ request: Data,withReply reply: @escaping @Sendable (Data)->Void) {
        guard request.count <= 10*1024*1024 else { reply((try? JSONEncoder().encode(HelperResponse(success:false,message:"请求过大"))) ?? Data()); return }
        Task {
            let response: HelperResponse
            do {
                let value = try JSONDecoder().decode(HelperRequest.self,from:request)
                guard !healthOnly || value.action == "status" else { throw LumaError.message("本机服务正在进行启动验证，暂未启用网络接管") }
                response = try await controller.execute(value,uid:uid)
            }
            catch { response = HelperResponse(success:false,message:Redactor.clean(error.localizedDescription)) }
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }
}
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let verifier: ClientVerifier
    let controller: HelperController
    let healthOnly:Bool
    init(app: URL,installation:LocalServiceInstallation? = nil) throws { verifier = try ClientVerifier(app:app,ownerUID:installation?.ownerUID); controller = HelperController(app:app); healthOnly = installation?.healthOnly ?? false }
    func listener(_ listener: NSXPCListener,shouldAcceptNewConnection connection: NSXPCConnection)->Bool {
        guard verifier.accepts(connection) else { return false }
        let uid = connection.effectiveUserIdentifier
        connection.exportedInterface = NSXPCInterface(with:LumaRouteHelperProtocol.self)
        connection.exportedObject = ClientHandler(uid:uid,controller:controller,healthOnly:healthOnly)
        connection.invalidationHandler = { [controller] in Task { await controller.clientDisconnected(uid:uid) } }
        connection.resume()
        return true
    }
}
do {
    guard geteuid() == 0 else { throw LumaError.message("后台服务需要 launchd 管理员授权") }
    let app = try containingApp()
    // The administrator installer invokes the staged, verified helper only
    // after stopping the old job. This never exposes a new XPC action.
    if CommandLine.arguments.contains("--restore-network-for-maintenance") {
        let installation=try LocalServiceInstallation.load()
        let controller=HelperController(app:LocalServiceInstallation.bundle)
        Task {
            do { try await controller.restoreNetworkForMaintenance(uid:installation.ownerUID);exit(0) }
            catch {
                FileHandle.standardError.write(Data(("网络恢复未完成："+Redactor.clean(error.localizedDescription)+"\n").utf8))
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(1)
    }
    let local = CommandLine.arguments.contains("--local")
    let installation = local ? try LocalServiceInstallation.load():nil
    guard !local || app == LocalServiceInstallation.bundle else { throw LumaError.message("本机服务必须从管理员安装目录运行") }
    guard installation?.needsMigration != true else { throw LumaError.message("本机服务注册需要更新，请在应用中完成更新") }
    let delegate = try ListenerDelegate(app:app,installation:installation)
    let listener = NSXPCListener(machServiceName:local ? HelperConstants.localServiceID:HelperConstants.serviceID)
    listener.delegate = delegate
    signal(SIGTERM,SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal:SIGTERM,queue:.global())
    termination.setEventHandler { listener.invalidate(); Task { await delegate.controller.shutdown(); exit(0) } }
    termination.resume()
    Task {
        if delegate.healthOnly { await delegate.controller.prepareHealthOnly() }
        else { await delegate.controller.recoverStartup() }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds:2_000_000_000)
            await delegate.controller.watchdog()
        }
    }
    listener.resume()
    RunLoop.main.run()
} catch {
    Logger(subsystem:"app.lumaroute.desktop",category:"helper-startup").error("\(Redactor.clean(error.localizedDescription),privacy:.public)")
    FileHandle.standardError.write(Data(("LumaRouteHelper: " + error.localizedDescription + "\n").utf8))
    exit(1)
}

