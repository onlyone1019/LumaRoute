import AppKit
import Sparkle
import LumaRouteCore

// This fixture runs real Sparkle and the production AppDelegate/AppUpdater.
// Only network/service ownership is replaced, so the user's proxy is untouched.
@MainActor final class FixtureRunner {
    func stop() async -> Bool { true }
}
@MainActor final class FixtureHelper {
    func send(_ request:HelperRequest) async throws -> HelperResponse {
        if Fixture.mode == "stop-failure" { throw LumaError.message("fixture network restore failed") }
        return HelperResponse(success:true,message:"fixture stopped")
    }
}
@MainActor final class AppStore {
    var error:String?
    var busy = false
    var checkingAppUpdate = false
    var appUpdateMessage:String?
    var appUpdateTargetBuild:Int?
    var shuttingDown = false
    var refreshing = false
    var recovering = false
    var serviceInstalling = false
    var updatingProfiles:Set<UUID> = []
    var updatingRuleSubscriptions:Set<UUID> = []
    var helperActive:Bool { get { Fixture.mode == "stop-failure" } set {} }
    var serviceRunning = false
    var coreReady = true
    let runner:FixtureRunner! = FixtureRunner()
    let helper = FixtureHelper()
    let store:LocalStore
    var database:AppDatabase
    var applicationVersion:AppVersion? { AppVersion(bundle:.main) }
    init() throws {
        store = try LocalStore(root:Fixture.root.appendingPathComponent("data"))
        database = try store.load()
        if database.profiles.isEmpty {
            let profile = Profile(name:"update-preservation-fixture",isRemote:false)
            database.profiles = [profile]; database.activeProfileID = profile.id
            database.settings.systemProxy = true; database.settings.tun = true
            database.settings.connectOnLaunch = false; database.settings.appearance = "dark"
            database.customRules = [CustomRule(type:"DOMAIN",payload:"example.com")]
            database.savedChoices = ["fixture-group":"fixture-node"]
            try store.save(database)
            try store.saveProfile("proxies: []\nproxy-groups: []\nrules: ['MATCH,DIRECT']\n",id:profile.id)
            try store.secrets.write("fixture-controller-secret",key:"controller-secret")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let state = try encoder.encode(database)
        let profileContent = try store.profileContent(database.activeProfileID!)
        guard profileContent.contains("MATCH,DIRECT"),try store.secrets.read("controller-secret") == "fixture-controller-secret" else { throw LumaError.message("fixture profile or secret changed") }
        let baseline = Fixture.root.appendingPathComponent("before-state.json")
        if !FileManager.default.fileExists(atPath:baseline.path) { try state.write(to:baseline) }
        else { try state.write(to:Fixture.root.appendingPathComponent("after-state.json")) }
    }
    func setMainWindowVisible(_ visible:Bool) {}
    func prepareForSleep() {}
    func resumeAfterNetworkChange() async {}
    func shutdown() async { shuttingDown = true; Fixture.event("shutdown") }
    func report(_ error:Error,source:String) {
        self.error = error.localizedDescription
        Fixture.finish("termination-rejected",detail:error.localizedDescription)
    }
    // The production prepareAppUpdateRestart() method is appended by the runner.
}
@MainActor final class StatusMenuController {
    init(store:AppStore,openMainWindow:@escaping ()->Void) {}
}

@MainActor enum Fixture {
    static weak var activeStore:AppStore?
    static var root:URL { URL(fileURLWithPath:Bundle.main.object(forInfoDictionaryKey:"LumaRouteTestRoot") as! String) }
    static var mode:String { Bundle.main.object(forInfoDictionaryKey:"LumaRouteTestMode") as! String }
    static var events:[String] = (try? JSONDecoder().decode([String].self,from:Data(contentsOf:root.appendingPathComponent("events.json")))) ?? []
    static func event(_ event:String) { events.append(event); try? JSONEncoder().encode(events).write(to:root.appendingPathComponent("events.json"),options:.atomic) }
    static func finish(_ status:String,detail:String = "") {
        let report:[String:Any] = ["status":status,"detail":detail,"events":events,"build":AppVersion(bundle:.main)!.build,
                                  "updateMessage":activeStore?.appUpdateMessage ?? "", "checking":activeStore?.checkingAppUpdate ?? false]
        let output = root.appendingPathComponent("result.json")
        if !FileManager.default.fileExists(atPath:output.path) {
            try! JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.atomic)
        }
        // Never terminate during Sparkle's callback stack.
        if status != "termination-rejected" { DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { exit(0) } }
    }
}

// The signed feed uses production GitHub URLs so the production source and
// architecture validation run unchanged. Only this fixture redirects transport.
extension AppUpdater {
    @objc(updater:willDownloadUpdate:withRequest:) func updater(_ updater:SPUUpdater,willDownloadUpdate item:SUAppcastItem,with request:NSMutableURLRequest) {
        request.url = URL(string:Bundle.main.object(forInfoDictionaryKey:"LumaRouteTestArchiveURL") as! String)!
    }
}

@MainActor final class TestDriver:NSObject,SPUUserDriver {
    func show(_ request:SPUUpdatePermissionRequest,reply:@escaping(SUUpdatePermissionResponse)->Void) { reply(SUUpdatePermissionResponse(automaticUpdateChecks:false,sendSystemProfile:false)) }
    func showUserInitiatedUpdateCheck(cancellation:@escaping()->Void) {
        Fixture.event("check")
        if Fixture.mode == "cancel-check" {
            cancellation()
            DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { Fixture.finish("check-cancelled") }
        }
    }
    func showUpdateFound(with appcastItem:SUAppcastItem,state:SPUUserUpdateState,reply:@escaping(SPUUserUpdateChoice)->Void) {
        Fixture.event("found")
        if Fixture.mode == "dismiss" { reply(.dismiss); Fixture.finish("dismissed") }
        else { reply(.install) }
    }
    func showUpdateReleaseNotes(with downloadData:SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error:Error) {}
    func showUpdateNotFoundWithError(_ error:Error,acknowledgement:@escaping()->Void) { acknowledgement(); Fixture.finish("no-update") }
    func showUpdaterError(_ error:Error,acknowledgement:@escaping()->Void) {
        acknowledgement()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { Fixture.finish("error",detail:error.localizedDescription) }
    }
    func showDownloadInitiated(cancellation:@escaping()->Void) {
        Fixture.event("download")
        if Fixture.mode == "cancel-download" { cancellation(); Fixture.finish("download-cancelled") }
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength:UInt64) {}
    func showDownloadDidReceiveData(ofLength length:UInt64) {}
    func showDownloadDidStartExtractingUpdate() { Fixture.event("extract") }
    func showExtractionReceivedProgress(_ progress:Double) {}
    func showReady(toInstallAndRelaunch reply:@escaping(SPUUserUpdateChoice)->Void) { Fixture.event("ready"); reply(.install) }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated:Bool,retryTerminatingApplication:@escaping()->Void) { Fixture.event("install") }
    func showUpdateInstalledAndRelaunched(_ relaunched:Bool,acknowledgement:@escaping()->Void) { acknowledgement() }
    func dismissUpdateInstallation() {}
}

@MainActor final class TestApp:NSObject,NSApplicationDelegate {
    let production = AppDelegate()
    let store = try! AppStore()
    var updater:AppUpdater?
    var window:NSWindow?
    func applicationDidFinishLaunching(_ notification:Notification) {
        Fixture.activeStore = store
        production.applicationDidFinishLaunching(notification)
        production.configure(store:store,openMainWindow:{})
        window = NSWindow(contentRect:NSRect(x:100,y:100,width:500,height:200),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window!.title = "LumaRoute isolated update acceptance"
        production.registerMainWindow(window!)
        window!.makeKeyAndOrderFront(nil)
        if store.applicationVersion!.build == 1002 {
            let state = try! AppUpdateHandoff.take(in:store.store.root,currentBuild:1002)
            Fixture.event("relaunched")
            Fixture.finish(state?.systemProxy == true && state?.tun == true ? "updated-and-restored":"missing-restart-state")
        } else {
            updater = AppUpdater(store:store,userDriver:Fixture.mode == "native-ui" ? nil:TestDriver())
            DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { self.updater!.checkForUpdates() }
        }
    }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply { production.applicationShouldTerminate(sender) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
}
@main enum Main {
    @MainActor static func checkChineseMessages() {
        func sparkle(_ code:SUError,_ underlying:Error? = nil) -> NSError {
            NSError(domain:SUSparkleErrorDomain,code:Int(code.rawValue),userInfo:underlying.map { [NSUnderlyingErrorKey:$0] } ?? [:])
        }
        let timeout = NSError(domain:NSURLErrorDomain,code:NSURLErrorTimedOut)
        let offline = NSError(domain:NSURLErrorDomain,code:NSURLErrorNotConnectedToInternet)
        let missing = NSError(domain:SUSparkleErrorDomain,code:Int(SUError.downloadError.rawValue),userInfo:[NSLocalizedDescriptionKey:"Not Found (404)"])
        let cases: [(Error,String)] = [
            (LumaError.message("请等待当前操作完成后再检查更新"),"请等待当前操作完成后再检查更新"),
            (sparkle(.appcastError,timeout),"连接更新服务器超时，请稍后重试"),
            (sparkle(.appcastError,offline),"无法连接更新服务器，请检查网络后重试"),
            (sparkle(.appcastError,missing),"更新源暂不可用（尚未发布或已移除），请稍后重试"),
            (sparkle(.signatureError),"更新校验失败，已停止安装，请稍后重试"),
            (sparkle(.authenticationFailure),"更新未获得安装权限，请完成管理员授权后重试"),
            (NSError(domain:"unknown",code:1),"更新未能完成，请稍后重试")
        ]
        for (error,expected) in cases { precondition(AppUpdater.message(for:error) == expected) }
        precondition(AppUpdater.message(for:missing,checkingFeed:false) == "更新包暂不可用，请稍后重试")
    }
    @MainActor static func main() {
        checkChineseMessages()
        let app = NSApplication.shared
        let delegate = TestApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
