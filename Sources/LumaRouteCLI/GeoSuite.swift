import Foundation
import LumaRouteCore

enum GeoSuite {
    static func run(binary: URL,bundled: URL,manifest: URL,home: URL) async throws {
        var passed = 0
        func check(_ value: Bool,_ message: String) throws {
            guard value else { throw LumaError.message("GEO 验证失败："+message) }
            passed += 1; print("PASS "+message)
        }
        let assets = try GeoAsset.parse(Data(contentsOf:manifest))
        var files: [String:Data] = [:]
        for asset in assets {
            let data = try Data(contentsOf:bundled.appendingPathComponent(asset.name))
            try check(data.count == asset.size && CoreUpdates.digest(data) == asset.sha256,"输入 \(asset.name) 文件大小与摘要有效")
            files[asset.name] = data
        }
        let policyURL = binary.deletingLastPathComponent().appendingPathComponent("GeoData/GeoSite-policy.json")
        files = try GeoSitePolicy.load(from:policyURL).protect(files)
        var settings = NetworkSettings(); settings.mixedPort = 19896; settings.controllerPort = 19897; settings.mode = .direct
        let source = """
        geodata-mode: true
        proxies: []
        rules: ['GEOSITE,cn,DIRECT', 'GEOIP,CN,DIRECT', 'MATCH,DIRECT']
        """
        let secret = UUID().uuidString+UUID().uuidString
        let runner = CoreRunner(binary:binary,home:home,secret:secret)
        let (_,file) = try await runner.prepare(source:source,settings:settings,rules:[])
        for (name,data) in files { try data.write(to:home.appendingPathComponent(name),options:.atomic) }
        try await runner.validate(file:file)
        let yaml = try String(contentsOf:file,encoding:.utf8)
        try await runner.start(yaml:yaml,settings:settings)
        let api = MihomoAPI(port:settings.controllerPort,secret:secret)
        let originals = try GeoDataUpdates.names.map { try Data(contentsOf:home.appendingPathComponent($0)) }
        do {
            var invalid = files; invalid["GeoSite.dat"] = Data("invalid protobuf".utf8)
            var rejected = false
            do { try await runner.updateGeoData(payloads:invalid) } catch { rejected = true }
            try check(rejected,"内核拒绝损坏的规则数据库")
            let after = try GeoDataUpdates.names.map { try Data(contentsOf:home.appendingPathComponent($0)) }
            try check(after == originals,"更新失败恢复全部旧 GEO 文件")
            _ = try await api.version()
            try check(try await request(port:settings.mixedPort),"失败更新后原内核继续代理真实请求")
            var invalidIP = files; invalidIP["GeoIP.dat"] = Data("invalid ip database".utf8)
            var rejectedIP = false
            do { try await runner.updateGeoData(payloads:invalidIP) } catch { rejectedIP = true }
            try check(rejectedIP,"内核拒绝已进入事务但无效的 IP 数据")
            try check(try GeoDataUpdates.names.map { try Data(contentsOf:home.appendingPathComponent($0)) } == originals,"内核校验失败后事务恢复全部原文件")
            try check(try await request(port:settings.mixedPort),"事务校验失败后原内核继续代理真实请求")
            try await runner.updateGeoData(payloads:files)
            try check(try GeoDataUpdates(home:home).canRollback,"成功更新保存可回退的快照")
            try check(try await request(port:settings.mixedPort),"更新重启后真实请求仍通过")
            try await runner.updateGeoData(rollback:true)
            try check(try await request(port:settings.mixedPort),"回退重启后真实请求仍通过")
            let recovered = try GeoDataUpdates.names.map { try Data(contentsOf:home.appendingPathComponent($0)) }
            try check(recovered == originals,"回退的三份数据与原版本逐字节一致")
            await runner.stop()
            let disk = try GeoDataUpdates(home:home)
            try disk.beginUpdate(invalid)
            _ = try GeoDataUpdates(home:home)
            let restored = try GeoDataUpdates.names.map { try Data(contentsOf:home.appendingPathComponent($0)) }
            try check(restored == originals,"未完成事务在重新打开时恢复所有原文件")
            print("geodata integration passed: \(passed) assertions")
        } catch { await runner.stop(); throw error }
    }
    private static func request(port: Int) async throws -> Bool {
        try await Task.detached {
            let task = Process(); let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath:"/usr/bin/curl")
            task.arguments = ["--disable","--silent","--fail","--max-time","5","--proxy","http://127.0.0.1:\(port)","--noproxy","","http://127.0.0.1:18772/data"]
            task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
            try task.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
            guard task.terminationStatus == 0 else { return false }
            let object = try JSONSerialization.jsonObject(with:data) as? [String:Any]
            return object?["route"] as? String == "direct"
        }.value
    }
}
