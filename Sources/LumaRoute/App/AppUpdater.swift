import AppKit
import Sparkle
import LumaRouteCore

/// Sparkle owns download, signature validation, replacement and relaunch.
/// AppDelegate retains ownership of asynchronous network cleanup on termination.
@MainActor
final class AppUpdater: NSObject,SPUUpdaterDelegate {
    private weak var store: AppStore?
    private var updater: SPUUpdater!
    private var observation: NSKeyValueObservation?
    private var started = false
    private var foundUpdate = false

    init(store: AppStore,hostBundle: Bundle = .main,userDriver: (any SPUUserDriver)? = nil) {
        self.store = store
        super.init()
        let driver = userDriver ?? SPUStandardUserDriver(hostBundle:hostBundle,delegate:nil)
        updater = SPUUpdater(hostBundle:hostBundle,applicationBundle:hostBundle,userDriver:driver,delegate:self)
        observation = updater.observe(\.sessionInProgress,options:[.new]) { [weak self] _,change in
            let active = change.newValue ?? false
            Task { @MainActor in self?.store?.checkingAppUpdate = active }
        }
    }
    func checkForUpdates() {
        do {
            if !started {
                try updater.start()
                updater.automaticallyChecksForUpdates = false
                updater.automaticallyDownloadsUpdates = false
                updater.sendsSystemProfile = false
                started = true
            }
            updater.checkForUpdates()
        } catch { store?.appUpdateMessage = Self.message(for:error,checkingFeed:!foundUpdate) }
    }
    func updater(_ updater: SPUUpdater,mayPerform updateCheck: SPUUpdateCheck) throws {
        guard let store,store.runner != nil,!store.busy,!store.shuttingDown else {
            throw LumaError.message("请等待当前操作完成后再检查更新")
        }
        foundUpdate = false
        store.appUpdateMessage = "正在检查更新…"
    }
    func updater(_ updater: SPUUpdater,shouldProceedWithUpdate item: SUAppcastItem,updateCheck: SPUUpdateCheck) throws {
        guard item.signingValidationStatus == .succeeded,
              let build = Int(item.versionString),build > (store?.applicationVersion?.build ?? 0),
              item.fileURL?.scheme == "https",item.fileURL?.host == "github.com",
              item.fileURL?.path.hasPrefix("/onlyone1019/LumaRoute/releases/download/") == true,
              item.fileURL?.lastPathComponent.hasSuffix("-macos-\(AppRelease.architecture).zip") == true
        else { throw LumaError.message("更新包的版本、架构或来源无效") }
    }
    func updater(_ updater: SPUUpdater,didFindValidUpdate item: SUAppcastItem) {
        foundUpdate = true
        store?.appUpdateMessage = "发现新版本 \(item.displayVersionString)，请在更新窗口中下载安装"
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { store?.appUpdateMessage = "当前已是最新版本" }
    func userDidCancelDownload(_ updater: SPUUpdater) { store?.appUpdateMessage = "已取消下载，可稍后重新检查" }
    func updater(_ updater: SPUUpdater,willInstallUpdate item: SUAppcastItem) {
        // This is after validation, immediately before Sparkle requests termination.
        store?.appUpdateTargetBuild = Int(item.versionString)
        store?.appUpdateMessage = "正在安装更新，完成后自动重新启动"
    }
    func updater(_ updater: SPUUpdater,didAbortWithError error: Error) {
        store?.appUpdateTargetBuild = nil
        store?.appUpdateMessage = Self.message(for:error,checkingFeed:!foundUpdate)
    }
    func updater(_ updater: SPUUpdater,didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,error: Error?) {
        store?.checkingAppUpdate = false
        if let error {
            store?.appUpdateMessage = Self.message(for:error,checkingFeed:!foundUpdate)
        } else if store?.appUpdateMessage == "正在检查更新…" {
            // Cancelling the check is a successful cycle completion in Sparkle:
            // didAbortWithError is not called, but the status must still settle.
            store?.appUpdateMessage = "已取消检查，可稍后重试"
        }
    }

    static func message(for error: Error,checkingFeed: Bool = true) -> String {
        if let error = error as? LumaError { return Redactor.clean(error.localizedDescription) }
        var chain: [NSError] = []
        var current = error as NSError
        // Sparkle wraps network and validation failures. Bound traversal in case
        // a third-party NSError contains a cyclic underlying error.
        for _ in 0..<8 {
            chain.append(current)
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        func has(_ code: SUError) -> Bool {
            chain.contains { $0.domain == SUSparkleErrorDomain && $0.code == Int(code.rawValue) }
        }
        if has(.noUpdateError) { return "当前已是最新版本" }
        if chain.contains(where: { $0.domain == NSURLErrorDomain && $0.code == NSURLErrorCancelled }) || has(.installationCanceledError) {
            return "已取消更新，可稍后重试"
        }
        if chain.contains(where: { $0.domain == NSURLErrorDomain && $0.code == NSURLErrorTimedOut }) {
            return "连接更新服务器超时，请稍后重试"
        }
        if chain.contains(where: { $0.domain == NSURLErrorDomain }) {
            return "无法连接更新服务器，请检查网络后重试"
        }
        // Sparkle 2.10 exposes an HTTP failure's status in the download error
        // description, rather than as a separate userInfo value.
        if chain.contains(where: { $0.domain == SUSparkleErrorDomain && $0.code == Int(SUError.downloadError.rawValue) && $0.localizedDescription.hasSuffix("(404)") }) {
            return checkingFeed ? "更新源暂不可用（尚未发布或已移除），请稍后重试" : "更新包暂不可用，请稍后重试"
        }
        if has(.signatureError) || has(.validationError) {
            return "更新校验失败，已停止安装，请稍后重试"
        }
        if has(.authenticationFailure) || has(.installationWriteNoPermissionError) {
            return "更新未获得安装权限，请完成管理员授权后重试"
        }
        if has(.downloadError) { return "更新下载失败，请检查网络后重试" }
        if has(.appcastError) || has(.appcastParseError) { return "无法获取更新信息，请稍后重试" }
        return "更新未能完成，请稍后重试"
    }
}
