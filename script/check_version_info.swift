import Foundation
import LumaRouteCore

@main struct VersionCheck {
    static func require(_ value: Bool,_ message: String) {
        if !value { FileHandle.standardError.write(Data(("FAIL "+message+"\n").utf8)); exit(1) }
    }
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1])
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let version = CommandLine.arguments[2],build = CommandLine.arguments[3],core = CommandLine.arguments[4]
        let app = AppStore()
        require(app.applicationVersion?.label == "\(version) · Build \(build)","settings version uses the current bundle")
        require(SubscriptionFetcher.defaultUserAgent == "clash.meta/\(core.dropFirst()) LumaRoute/\(version)","default UA uses the current bundle")
        print("PASS settings and default UA follow bundle \(version) build \(build)")

        var log = LogEntry(level:"warning",source:"测试",message:"placeholder")
        log.message = "中文 https://example.org/sub?token=private password=credential"
        app.logs = [log]
        let file = root.appendingPathComponent("diagnostics.txt")
        try app.exportDiagnostics(to:file)
        let exported = try String(contentsOf:file,encoding:.utf8)
        let page = LogsPageState()
        page.prepareExport(app.logs,coreStatus:app.coreVersion)
        require(app.flushes == 1,"file export flushes pending logs")
        require(exported.hasPrefix("LumaRoute \(version) · Build \(build)\nMihomo v4.6.8\n"),"diagnostics header contains app build and runtime core")
        require(page.exportDocument?.text == exported,"log page and file export use identical metadata and formatting")
        require(!exported.contains("private") && !exported.contains("credential") && exported.contains("[已隐藏]"),"both exports remain sanitized")
        page.finishExport()
        require(page.exportDocument == nil && !page.exporting,"export completion releases its snapshot")
        print("PASS file and log-page exports share version/build, runtime core and redaction")

        require(app.subscriptionInfo().core == String(core.dropFirst()),"uninitialized updater uses bundled core metadata")
        let updates = root.appendingPathComponent("cores")
        app.coreUpdates = try CoreUpdates(root:updates,bundled:root.appendingPathComponent("unused-core"))
        require(app.subscriptionInfo().core == String(core.dropFirst()),"empty selection uses bundled core metadata")
        func select(_ selected: String) throws {
            let artifact: [String:Any] = ["id":UUID().uuidString,"binarySHA256":String(repeating:"0",count:64),
                "release":["version":selected,"assetName":"fixture.gz","downloadURL":"https://example.org/fixture.gz","sha256":String(repeating:"0",count:64),"size":1]]
            try JSONSerialization.data(withJSONObject:["active":artifact,"canRollback":false]).write(to:updates.appendingPathComponent("selection.json"),options:.atomic)
        }
        try select("v3.5.7")
        require(app.subscriptionInfo().core == "3.5.7","stopped core uses persisted selection")
        app.coreReady = true
        require(app.subscriptionInfo().core == "4.6.8","running core takes priority over selection and bundle")
        app.coreVersion = "v5.7.9"
        require(app.subscriptionInfo().core == "5.7.9","runtime changes are not cached")
        app.coreReady = false
        try select("v2.4.6")
        require(app.subscriptionInfo().core == "2.4.6","selection rollback is immediately reflected")
        print("PASS bundled/selected/running core priority and upgrade/rollback UA tracking")
        print("version integration suite passed: 3 scenarios")
    }
}
