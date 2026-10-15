import Foundation
import LumaRouteCore

/// Uses the production online download path and a local unprivileged core only.
enum GeoOnlineSuite {
    static func run(binary: URL,legacy: URL,home: URL) async throws {
        var passed = 0
        func check(_ condition: Bool,_ label: String) throws {
            guard condition else { throw LumaError.message("在线 GEO 验证失败："+label) }
            passed += 1; print("PASS "+label)
        }
        let resources = binary.deletingLastPathComponent().appendingPathComponent("GeoData")
        let policyURL = resources.appendingPathComponent("GeoSite-policy.json")
        let policy = try GeoSitePolicy.load(from:policyURL)
        let initial = try Data(contentsOf:resources.appendingPathComponent("GeoSite.dat"))
        try check(policy.applying(to:initial) == initial,"内置数据与已审核许可规则一致")
        let legacyData = try Data(contentsOf:legacy)
        let expectedRollback = try policy.applying(to:legacyData)
        try check(expectedRollback != legacyData,"旧版输入确实需要替换许可分类")
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        for name in GeoDataUpdates.names {
            try FileManager.default.copyItem(at:resources.appendingPathComponent(name),to:home.appendingPathComponent(name))
        }
        // A selected downloaded core is outside the app, as in privileged service use.
        let executable = home.appendingPathComponent("selected-core/mihomo")
        try FileManager.default.createDirectory(at:executable.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:binary,to:executable)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:executable.path)
        var settings = NetworkSettings(); settings.mixedPort = 19906; settings.controllerPort = 19907; settings.mode = .rule
        let source = """
        geodata-mode: true
        proxies: []
        rules: ['GEOSITE,biliintl,DIRECT', 'GEOSITE,sharepoint,DIRECT', 'GEOSITE,cn,DIRECT', 'GEOIP,CN,DIRECT', 'MATCH,DIRECT']
        """
        let runner = CoreRunner(binary:executable,home:home,secret:UUID().uuidString+UUID().uuidString,geoPolicy:policyURL)
        let (_,file) = try await runner.prepare(source:source,settings:settings,rules:[])
        try await runner.validate(file:file)
        let yaml = try String(contentsOf:file,encoding:.utf8)
        try await runner.start(yaml:yaml,settings:settings)
        func files() throws -> [String:Data] {
            try Dictionary(uniqueKeysWithValues:GeoDataUpdates.names.map { ($0,try Data(contentsOf:home.appendingPathComponent($0))) })
        }
        do {
            // No injected payload: exercises the exact GUI / helper online entry.
            try await runner.updateGeoData()
            let downloaded = try files()
            try check(policy.protect(downloaded) == downloaded,"真实在线下载后两类规则保持审核版本")
            try check(try GeoDataUpdates(home:home).canRollback,"在线成功更新保留旧版本快照")
            try check(try await request(settings.mixedPort),"在线更新后内核仍能代理回环 HTTP 请求")
            var invalid = downloaded; invalid["GeoSite.dat"] = Data([0x0a])
            var rejected = false
            do { try await runner.updateGeoData(payloads:invalid) } catch { rejected = true }
            try check(rejected,"损坏下载在事务写入前被拒绝")
            try check(try files() == downloaded,"拒绝失败更新后全部当前文件保持原样")
            try check(try await request(settings.mixedPort),"拒绝失败更新后当前内核继续运行")
            // Reproduce an old snapshot without ever restarting on unreviewed data.
            let disk = try GeoDataUpdates(home:home)
            var old = downloaded; old["GeoSite.dat"] = legacyData
            try disk.beginUpdate(old); try disk.finish()
            try disk.beginUpdate(downloaded); try disk.finish()
            let snapshotRoot = home.appendingPathComponent("geo-history")
            let snapshots = try FileManager.default.contentsOfDirectory(at:snapshotRoot,includingPropertiesForKeys:nil)
            let original = snapshots.first { (try? Data(contentsOf:$0.appendingPathComponent("GeoSite.dat"))) == legacyData }
            try await runner.updateGeoData(rollback:true)
            let restored = try files()
            try check(restored["GeoSite.dat"] == expectedRollback,"回退真实旧快照后重新应用已审核分类")
            try check(restored["GeoIP.dat"] == downloaded["GeoIP.dat"] && restored["geoip.metadb"] == downloaded["geoip.metadb"],"回退分类处理不改变 IP 文件")
            try check(original != nil && (try Data(contentsOf:original!.appendingPathComponent("GeoSite.dat"))) == legacyData,"旧快照备份原件逐字节保留")
            try check(try await request(settings.mixedPort),"旧快照回退后内核仍能代理回环 HTTP 请求")
            await runner.stop()
            let summary: [String:Any] = ["assertions":passed,"actual_online_download":true,"legacy_rollback_sanitized":true,"backup_unchanged":true,"selected_core_outside_app":true]
            try JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys]).write(to:home.appendingPathComponent("geo-online-results.json"))
            print("online geodata integration passed: \(passed) assertions")
        } catch { await runner.stop(); throw error }
    }
    private static func request(_ port: Int) async throws -> Bool {
        try await Task.detached {
            let task = Process(),pipe = Pipe()
            task.executableURL = URL(fileURLWithPath:"/usr/bin/curl")
            task.arguments = ["--disable","--silent","--fail","--max-time","5","--proxy","http://127.0.0.1:\(port)","--noproxy","","http://127.0.0.1:18772/data"]
            task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
            try task.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
            return task.terminationStatus == 0 && (try? JSONSerialization.jsonObject(with:data) as? [String:String])?["route"] == "direct"
        }.value
    }
}
