import Foundation
import LumaRouteCore
import Darwin

enum LifecycleSuite {
    static func hold(binary: URL,home: URL) async throws {
        var settings = NetworkSettings(); settings.mixedPort = 19892; settings.controllerPort = 19893; settings.mode = .direct
        let runner = CoreRunner(binary:binary,home:home,secret:UUID().uuidString+UUID().uuidString)
        let (yaml,file) = try await runner.prepare(source:nil,settings:settings,rules:[])
        try await runner.validate(file:file)
        try await runner.start(yaml:yaml,settings:settings)
        try Data("ready".utf8).write(to:home.appendingPathComponent("fixture-ready"))
        while true { try await Task.sleep(nanoseconds:1_000_000_000) }
    }
    static func run(binary: URL,home: URL) async throws {
        var passed = 0
        func check(_ value: Bool,_ name: String) throws {
            guard value else { throw LumaError.message("生命周期验证失败："+name) }
            passed += 1; print("PASS "+name)
        }
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        let ready = home.appendingPathComponent("fixture-ready")
        try? FileManager.default.removeItem(at:ready)
        let child = Process()
        child.executableURL = URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["lifecycle-hold",binary.path,home.path]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        let secret = UUID().uuidString+UUID().uuidString
        var settings = NetworkSettings(); settings.mixedPort = 19892; settings.controllerPort = 19893; settings.mode = .direct
        let runner = CoreRunner(binary:binary,home:home,secret:secret)
        var orphan: pid_t?
        do {
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath:ready.path) { break }
                guard child.isRunning else { throw LumaError.message("生命周期子进程启动失败") }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            try check(FileManager.default.fileExists(atPath:ready.path),"隔离子应用与内核已就绪")
            let leaseURL = home.appendingPathComponent("core-process.json")
            let lease = try JSONSerialization.jsonObject(with:Data(contentsOf:leaseURL)) as! [String:Any]
            orphan = (lease["pid"] as! NSNumber).int32Value
            let (yaml,_) = try await runner.prepare(source:nil,settings:settings,rules:[])
            var denied = false
            do { try await runner.start(yaml:yaml,settings:settings) } catch { denied = true }
            await runner.stop()
            try check(denied && FileManager.default.fileExists(atPath:leaseURL.path),"同一目录拒绝重复运行且不删除其他实例记录")
            let occupied = CoreRunner(binary:binary,home:home.appendingPathComponent("occupied"),secret:secret)
            let (occupiedYAML,_) = try await occupied.prepare(source:nil,settings:settings,rules:[])
            denied = false
            do { try await occupied.start(yaml:occupiedYAML,settings:settings) } catch { denied = true }
            await occupied.stop()
            try check(denied && kill(orphan!,0) == 0,"端口冲突拒绝启动且不终止已有内核")
            kill(child.processIdentifier,SIGKILL)
            for _ in 0..<50 {
                if !child.isRunning { break }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            try check(!child.isRunning && kill(orphan!,0) == 0,"应用强制退出留下真实孤立内核")
            try await runner.start(yaml:yaml,settings:settings)
            let api = MihomoAPI(port:settings.controllerPort,secret:secret)
            _ = try await api.version()
            let replacement = try JSONSerialization.jsonObject(with:Data(contentsOf:leaseURL)) as! [String:Any]
            try check((replacement["pid"] as! NSNumber).int32Value != orphan,"重启清理精确身份的孤立进程并建立新内核")
            await runner.stop()
            try check(!FileManager.default.fileExists(atPath:leaseURL.path),"正常退出清理进程记录")
            var stale = lease
            stale["pid"] = getpid(); stale["startedSeconds"] = 1
            try JSONSerialization.data(withJSONObject:stale).write(to:leaseURL)
            try await runner.start(yaml:yaml,settings:settings)
            _ = try await api.version()
            try check(kill(getpid(),0) == 0,"PID 已复用时不向无关进程发送信号")
            await runner.stop()
            print("lifecycle integration passed: \(passed) assertions")
        } catch {
            if child.isRunning { kill(child.processIdentifier,SIGKILL) }
            // Recover through the same identity checks; never kill by a broad name match.
            await runner.stop()
            let (yaml,_) = try await runner.prepare(source:nil,settings:settings,rules:[])
            try? await runner.start(yaml:yaml,settings:settings)
            await runner.stop()
            throw error
        }
    }
}
