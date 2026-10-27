import Foundation
import AppKit
import ServiceManagement
import Security
import LumaRouteCore

@MainActor
final class HelperClient {
    struct InstallationState: Equatable {
        let status: SMAppService.Status
        let modified: Date?
        let healthOnly: Bool?
    }
    private lazy var service = SMAppService.daemon(plistName:HelperConstants.plistName)
    private var connection: NSXPCConnection?
    private var cachedLocalRecord:LocalServiceInstallation?
    private var cachedLocalStamp:Date?
    private var cachedLocalAccepted = false
    private var cachedHelperRequirement:String?
    var installationState: InstallationState {
        let local = localInstallation
        return InstallationState(status:status,modified:cachedLocalStamp,healthOnly:local?.healthOnly)
    }
    var localInstallation:LocalServiceInstallation? {
        let stamp = (try? FileManager.default.attributesOfItem(atPath:LocalServiceInstallation.record.path))?[.modificationDate] as? Date
        guard let stamp else { cachedLocalRecord = nil; cachedLocalStamp = nil; cachedLocalAccepted = false; cachedHelperRequirement = nil; return nil }
        if cachedLocalStamp != stamp {
            cachedLocalStamp = stamp
            cachedLocalRecord = try? LocalServiceInstallation.load()
            cachedLocalAccepted = cachedLocalRecord?.acceptsCurrentApp() ?? false
            cachedHelperRequirement = try? cachedLocalRecord?.helperRequirement
            connection?.invalidate(); connection = nil
        }
        return cachedLocalRecord
    }
    let supportsPrivilegedService: Bool = {
        var code: SecStaticCode?; var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL,[],&code) == errSecSuccess,let code,
              SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&information) == errSecSuccess,
              let team = (information as? [String:Any])?[kSecCodeInfoTeamIdentifier as String] as? String else { return false }
        return !team.isEmpty
    }()
    var status: SMAppService.Status {
        if localInstallation != nil { return cachedLocalAccepted ? .enabled:.requiresApproval }
        return service.status
    }
    var label: String {
        if let local = localInstallation {
            guard cachedLocalAccepted else { return "待完成更新" }
            return local.healthOnly ? "本机服务 · 启动验证":"已安装（本机）"
        }
        guard supportsPrivilegedService else { return "本机服务未配置" }
        switch status {
        case .enabled: return "已授权"
        case .requiresApproval: return "等待管理员授权"
        case .notRegistered: return "未安装"
        default: return "服务不可用"
        }
    }
    var networkSetup: NetworkServiceSetup {
        if let local = localInstallation {
            return .resolve(installed:true,accepted:cachedLocalAccepted,healthOnly:local.healthOnly)
        }
        return supportsPrivilegedService && service.status == .enabled ? .ready:.install
    }
    func register(networkReady:Bool = false) async throws {
        if !supportsPrivilegedService || localInstallation != nil {
            _ = try LocalServiceInstallation.requirement(for:Bundle.main.bundleURL)
            // Retire a managed registration when the signing identity supports
            // it. Ad-hoc builds lack the removal entitlement and must use the
            // administrator installer, whose independent label avoids overlap.
            if supportsPrivilegedService { try await unregisterManagedService(allowMissing:true) }
            try await LocalServiceAuthorization.install(app:Bundle.main.bundleURL,ownerUID:getuid(),networkReady:networkReady)
            connection?.invalidate(); connection = nil
            cachedLocalStamp = nil
            _ = localInstallation
            return
        }
        try requireSupportedSigning()
        do { try service.register() }
        catch {
            // Some macOS versions report EPERM while registration is pending approval.
            guard service.status == .requiresApproval || service.status == .enabled else { throw error }
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
    func unregister() async throws {
        if localInstallation != nil {
            let installer = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/uninstall-local-service.command")
            guard NSWorkspace.shared.open(installer) else { throw LumaError.message("无法打开本机服务卸载终端") }
            return
        }
        _ = try? await send(HelperRequest(action:"stop"))
        connection?.invalidate(); connection = nil
        try await unregisterManagedService()
    }
    private func unregisterManagedService(allowMissing:Bool = false) async throws {
        // Keep the non-Sendable service on MainActor on older SDKs too.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            service.unregister { error in
                if let error = error as NSError?,allowMissing,
                   // The named domain constant is only available on macOS 15;
                   // its string value also works on our macOS 14 minimum.
                   error.domain == "SMAppServiceErrorDomain",error.code == kSMErrorJobNotFound {
                    continuation.resume(); return
                }
                if let error { continuation.resume(throwing:error) }
                else { continuation.resume() }
            }
        }
    }
    func openApproval() {
        SMAppService.openSystemSettingsLoginItems()
    }
    func send(_ request: HelperRequest,responseTimeout: TimeInterval? = nil) async throws -> HelperResponse {
        try requireAvailableService()
        guard status == .enabled else { throw LumaError.message("请先在设置中安装并授权后台服务") }
        if connection == nil {
            let new = NSXPCConnection(machServiceName:localInstallation == nil ? HelperConstants.serviceID:HelperConstants.localServiceID,options:.privileged)
            new.remoteObjectInterface = NSXPCInterface(with:LumaRouteHelperProtocol.self)
            if localInstallation != nil {
                guard let requirement = cachedHelperRequirement else { throw LumaError.message("本机服务签名快照无效") }
                new.setCodeSigningRequirement(requirement)
            }
            new.invalidationHandler = { [weak self,weak new] in
                Task { @MainActor in if self?.connection === new { self?.connection = nil } }
            }
            new.interruptionHandler = { [weak new] in new?.invalidate() }
            new.resume(); connection = new
        }
        guard let connection else { throw LumaError.message("无法连接后台服务") }
        let data = try JSONEncoder().encode(request)
        let response: HelperResponse = try await withCheckedThrowingContinuation { continuation in
            let gate = ReplyGate(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in gate.fail(LumaError.message("后台服务连接失败：\(error.localizedDescription)")) }
            guard let proxy = proxy as? LumaRouteHelperProtocol else { gate.fail(LumaError.message("后台服务接口不可用")); return }
            proxy.perform(data) { result in
                do { gate.finish(try JSONDecoder().decode(HelperResponse.self,from:result)) } catch { gate.fail(error) }
            }
            let timeout: TimeInterval = responseTimeout ?? (["start","geo-update"].contains(request.action) ? 480:45)
            DispatchQueue.global().asyncAfter(deadline:.now()+timeout) { gate.fail(LumaError.message("后台服务请求超时")) }
        }
        guard response.success else { throw LumaError.message(response.message) }
        return response
    }
    func disconnect() { connection?.invalidate(); connection = nil }
    func requireSupportedSigning() throws {
        try requireAvailableService()
        if localInstallation?.healthOnly == true { throw LumaError.message("本机服务尚在启动验证阶段，网络接管暂未开放；请先完成服务检查。") }
    }
    private func requireAvailableService() throws {
        if localInstallation != nil {
            guard cachedLocalAccepted else { throw LumaError.message("应用已重新构建，请更新本机服务以重新授权此版本。") }
            return
        }
        guard supportsPrivilegedService else { throw LumaError.message("此本地构建尚未配置可用的管理员后台服务，暂时无法接管系统代理或启用 TUN。订阅、测速和普通代理可以使用；本机服务安装仍需管理员授权。") }
    }
}
private final class ReplyGate: @unchecked Sendable {
    let lock = NSLock()
    var continuation: CheckedContinuation<HelperResponse, Error>?
    init(_ continuation: CheckedContinuation<HelperResponse, Error>) { self.continuation = continuation }
    func finish(_ value: HelperResponse) { lock.lock(); let c = continuation; continuation = nil; lock.unlock(); c?.resume(returning:value) }
    func fail(_ error: Error) { lock.lock(); let c = continuation; continuation = nil; lock.unlock(); c?.resume(throwing:error) }
}

