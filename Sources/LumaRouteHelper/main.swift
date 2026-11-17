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

