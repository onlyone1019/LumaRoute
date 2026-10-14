import Foundation
import Darwin
import LumaRouteCore

enum MaintenanceSuite {
    static func run(manifest: URL,archive: URL,binary: URL,home: URL) async throws {
        var passed = 0
        func check(_ result: Bool,_ name: String) throws {
            guard result else { throw LumaError.message("维护验证失败："+name) }
            passed += 1; print("PASS "+name)
        }
        let data = try Data(contentsOf:manifest)
        let release = try CoreRelease.parse(data)
        try check(release.assetName.contains(CoreRelease.architecture),"官方稳定版按本机架构选择文件")
        var bad = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        bad["prerelease"] = true
        var rejected = false
        do { _ = try CoreRelease.parse(JSONSerialization.data(withJSONObject:bad)) } catch { rejected = true }
        try check(rejected,"预发布版不能作为稳定更新")
        bad = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        var assets = bad["assets"] as! [[String:Any]]
        let index = assets.firstIndex(where:{$0["name"] as? String == release.assetName})!
        assets[index]["browser_download_url"] = "https://example.org/core.gz"; bad["assets"] = assets
        rejected = false
        do { _ = try CoreRelease.parse(JSONSerialization.data(withJSONObject:bad)) } catch { rejected = true }
        try check(rejected,"非官方下载来源被拒绝")
        let updates = try CoreUpdates(root:home.appendingPathComponent("cores"),bundled:binary)
        let corrupt = home.appendingPathComponent("corrupt.gz")
        var bytes = try Data(contentsOf:archive)
        if bytes.isEmpty { bytes.append(0) } else { bytes[bytes.startIndex] ^= 1 }
        try bytes.write(to:corrupt)
        rejected = false
        do { _ = try await updates.stageArchive(corrupt,release:release) } catch { rejected = true }
        try check(rejected && (try updates.selection().active == nil),"官方摘要不匹配的下载不改变当前版本")
        let candidate = try await updates.stageArchive(archive,release:release)
        let candidateBinary = try updates.binary(for:candidate)
        try check(FileManager.default.isExecutableFile(atPath:candidateBinary.path),"真实官方压缩包校验并解压为独立可执行文件")
        let runtime = home.appendingPathComponent("runtime")
        let secret = UUID().uuidString+UUID().uuidString
        var settings = NetworkSettings(); settings.mixedPort = 19894; settings.controllerPort = 19895; settings.mode = .direct
        let previous = CoreRunner(binary:binary,home:runtime,secret:secret)
        let next = CoreRunner(binary:candidateBinary,home:runtime,secret:secret)
        let (yaml,file) = try await previous.prepare(source:nil,settings:settings,rules:[])
        try await previous.validate(file:file); try await previous.start(yaml:yaml,settings:settings)
        let api = MihomoAPI(port:settings.controllerPort,secret:secret)
        do {
            try await next.validate(file:file)
            try updates.beginSwitch(to:candidate)
            try check(try updates.activationVersion() == release.version && updates.selection().active == nil,"管理员启动请求在提交前使用候选版本，原版本尚未提交")
            await previous.stop(); try await next.start(yaml:yaml,settings:settings)
            try check(try await api.version() == release.version,"候选内核启动并返回预期版本")
            try check(try await request(port:settings.mixedPort),"新内核代理实际 HTTP 请求成功")
            try updates.finishSwitch()
            try check(try updates.currentBinary() == candidateBinary && updates.selection().canRollback,"运行成功后提交当前版本及回退信息")
            await next.stop()
            try updates.beginSwitch(to:updates.selection().previous)
            try check(try updates.activationVersion() == nil && updates.selection().active == candidate,"管理员回退内置版本在提交前显式请求内置内核")
            try await previous.start(yaml:yaml,settings:settings)
            _ = try await api.version(); try updates.finishSwitch()
            try check(try await request(port:settings.mixedPort),"回退内核代理实际 HTTP 请求成功")
            try check(try updates.currentBinary().path == binary.path,"真实运行回退至内置内核")
            await previous.stop()
            let payload = try Data(contentsOf:candidateBinary)
            try Data(payload.dropLast(1)).write(to:candidateBinary)
            rejected = false
            do { _ = try updates.binary(for:candidate) } catch { rejected = true }
            try check(rejected,"已下载内核被篡改后拒绝执行")
            try payload.write(to:candidateBinary)
            let before = try updates.selection()
            try updates.beginSwitch(to:candidate)
            try check(try updates.activationVersion() == release.version,"未完成事务仍请求待激活版本")
            // Reopening after a crash before activation restores the prior selection.
            let reopened = try CoreUpdates(root:updates.root,bundled:binary)
            try await reopened.recoverPendingSwitch(runtime:runtime)
            try check(try reopened.selection() == before,"切换事务未完成时重开恢复原版本")
            try check(try reopened.activationVersion() == before.active?.release.version,"取消事务后管理员请求恢复已提交版本")
            print("maintenance integration passed: \(passed) assertions")
        } catch { await previous.stop(); await next.stop(); try? updates.cancelSwitch(); throw error }
    }
    private static func request(port: Int) async throws -> Bool {
        try await Task.detached {
            let task = Process(); let output = Pipe()
            task.executableURL = URL(fileURLWithPath:"/usr/bin/curl")
            task.arguments = ["--disable","--silent","--fail","--max-time","5","--proxy","http://127.0.0.1:\(port)","--noproxy","","http://127.0.0.1:18772/data"]
            task.standardOutput = output; task.standardError = FileHandle.nullDevice
            try task.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
            guard task.terminationStatus == 0 else { return false }
            let object = try JSONSerialization.jsonObject(with:data) as? [String:Any]
            return object?["route"] as? String == "direct"
        }.value
    }
}
