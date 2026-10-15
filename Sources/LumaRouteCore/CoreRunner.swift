import Foundation
import Yams

public actor CoreRunner {
    public let binary: URL
    public let home: URL
    public let secret: String
    private var process: Process?
    private var outputPipe: Pipe?
    private var currentYAML: String?
    private var currentSettings: NetworkSettings?
    private var lastRevisionCleanup = Date.distantPast
    private let lease: CoreProcessLease
    private static var coreEnvironment: [String:String] {
        var environment = ProcessInfo.processInfo.environment
        // A proxy can carry IPv6 destinations over an IPv4 uplink. Let the
        // explicit YAML ipv6 setting govern TUN IPv6 rather than host probing.
        environment["SKIP_SYSTEM_IPV6_CHECK"] = "true"
        return environment
    }
    public var onLog: (@Sendable (String) -> Void)?
    public init(binary: URL, home: URL, secret: String) {
        self.binary = binary; self.home = home; self.secret = secret
        self.lease = CoreProcessLease(home:home,binary:binary)
    }
    public var running: Bool { process?.isRunning ?? false }
    public func setLogHandler(_ handler: @escaping @Sendable (String) -> Void) { onLog = handler }
    public func prepare(source: String?, settings: NetworkSettings, rules: [CustomRule], strategies: [GroupStrategy] = [], ruleSubscriptions: [RuleSubscriptionSnapshot] = []) throws -> (String, URL) {
        _ = try GeoDataUpdates(home:home)
        try seedBundledGeoData()
        if Date().timeIntervalSince(lastRevisionCleanup) >= 300 {
            pruneRevisions(); lastRevisionCleanup = Date()
        }
        let directory = home.appendingPathComponent("revisions/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
        let yaml = try ConfigComposer.compose(source:source, settings:settings, rules:rules, secret:secret, resourceRoot:directory,strategies:strategies,ruleSubscriptions:ruleSubscriptions)
        try seedProviderCaches(for:yaml)
        let file = directory.appendingPathComponent("config.yaml")
        try Data(yaml.utf8).write(to:file, options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:file.path)
        return (yaml,file)
    }
    /// Retain active references, the newest 20 revisions and all work from the
    /// last hour (validation/in-flight applies). Unknown directories are untouched.
    public func pruneRevisions(now: Date = Date()) {
        let root = home.appendingPathComponent("revisions").standardizedFileURL
        var protected: Set<String> = []
        var yamls = [currentYAML].compactMap { $0 }
        let active = home.appendingPathComponent("active.yaml")
        if FileManager.default.fileExists(atPath:active.path) {
            guard let yaml = try? String(contentsOf:active,encoding:.utf8) else { return }
            yamls.append(yaml)
        }
        func inspect(_ value: Any) {
            if let string = value as? String,string.hasPrefix(root.path+"/") {
                let name = String(string.dropFirst(root.path.count+1).split(separator:"/").first ?? "")
                protected.insert(name)
            } else if let dictionary = value as? [String:Any] { for child in dictionary.values { inspect(child) } }
            else if let array = value as? [Any] { for child in array { inspect(child) } }
        }
        for yaml in yamls {
            // If references cannot be established, do not risk active caches.
            guard let parsed = try? ConfigComposer.parse(yaml) else { return }
            inspect(parsed)
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey,.isSymbolicLinkKey,.contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:Array(keys)) else { return }
        let candidates: [(URL,Date)] = entries.compactMap { entry in
            guard UUID(uuidString:entry.lastPathComponent) != nil,
                  let values = try? entry.resourceValues(forKeys:keys),values.isDirectory == true,values.isSymbolicLink != true,
                  let date = values.contentModificationDate else { return nil }
            return (entry,date)
        }.sorted { $0.1 > $1.1 }
        for (entry,date) in candidates.dropFirst(20) where !protected.contains(entry.lastPathComponent) && now.timeIntervalSince(date) > 3600 {
            try? FileManager.default.removeItem(at:entry)
        }
    }
    private func seedProviderCaches(for yaml: String) throws {
        let previous = currentYAML ?? (try? String(contentsOf:home.appendingPathComponent("active.yaml"),encoding:.utf8))
        guard let previous,
              let old = (try? ConfigComposer.parse(previous))?["proxy-providers"] as? [String:[String:Any]],
              let next = (try ConfigComposer.parse(yaml))["proxy-providers"] as? [String:[String:Any]] else { return }
        let owned = home.resolvingSymlinksInPath().path+"/"
        for (name,provider) in next where provider["type"] as? String == "http" {
            guard let prior = old[name], prior["url"] as? String == provider["url"] as? String,
                  let from = prior["path"] as? String, let to = provider["path"] as? String else { continue }
            let source = URL(fileURLWithPath:from).resolvingSymlinksInPath()
            let destination = URL(fileURLWithPath:to)
            guard source.path.hasPrefix(owned),destination.path.hasPrefix(owned),FileManager.default.fileExists(atPath:source.path),!FileManager.default.fileExists(atPath:destination.path) else { continue }
            try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try FileManager.default.copyItem(at:source,to:destination)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
        }
    }
    private func verifyProviders(yaml: String,api: MihomoAPI) async throws {
        let parsed = try ConfigComposer.parse(yaml)
        let definitions = parsed["proxy-providers"] as? [String:Any] ?? [:]
        let managed = (parsed["rule-providers"] as? [String:[String:Any]] ?? [:]).filter { _,value in
            guard value["type"] as? String == "file",let path = value["path"] as? String else { return false }
            return path.hasPrefix(home.path+"/") && URL(fileURLWithPath:path).deletingLastPathComponent().lastPathComponent == "rulesets"
        }
        let rules = parsed["rules"] as? [String] ?? []
        for _ in 0..<50 {
            let providers = try await api.providers()
            let liveRules = try await api.rules()
            var ruleProvidersReady = true
            if !managed.isEmpty {
                let response = try JSONSerialization.jsonObject(with:await api.data(["providers","rules"])) as? [String:Any]
                let ruleProviders = response?["providers"] as? [String:[String:Any]] ?? [:]
                ruleProvidersReady = managed.keys.allSatisfy { (ruleProviders[$0]?["ruleCount"] as? Int ?? 0) > 0 }
            }
            if definitions.keys.allSatisfy({ !(providers[$0]?.proxies ?? []).isEmpty }),liveRules.count >= rules.count,ruleProvidersReady { return }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        throw LumaError.message("节点提供器或规则订阅没有完整加载，已保留原配置")
    }
    private func seedBundledGeoData() throws {
        let resources = binary.deletingLastPathComponent()
        let candidates = [resources.appendingPathComponent("GeoData"),resources.deletingLastPathComponent().appendingPathComponent("GeoData"),CoreRunner.bundledBinary().deletingLastPathComponent().appendingPathComponent("GeoData")]
        guard let bundled = candidates.first(where:{FileManager.default.fileExists(atPath:$0.appendingPathComponent("geoip.metadb").path)}) else { return }
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        for name in ["geoip.metadb","GeoIP.dat","GeoSite.dat"] {
            let destination = home.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath:destination.path) {
                try FileManager.default.copyItem(at:bundled.appendingPathComponent(name),to:destination)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
            }
        }
    }
    public func validate(file: URL) async throws {
        let binary = self.binary; let home = self.home
        guard FileManager.default.isExecutableFile(atPath:binary.path) else { throw LumaError.message("尚未找到随应用打包的 Mihomo 内核") }
        let validation = Task.detached {
            // The live core owns cache.db. A validator using the same -d waits
            // for its lock before timing out, even when the YAML is valid.
            let isolated = home.appendingPathComponent("validation-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:isolated,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            defer { try? FileManager.default.removeItem(at:isolated) }
            for name in ["geoip.metadb","GeoIP.dat","GeoSite.dat"] {
                let resource = home.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath:resource.path) {
                    try FileManager.default.createSymbolicLink(at:isolated.appendingPathComponent(name),withDestinationURL:resource)
                }
            }
            let task = Process()
            let log = home.appendingPathComponent("validation-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600])
            let output = try FileHandle(forWritingTo:log)
            defer { try? output.close(); try? FileManager.default.removeItem(at:log) }
            task.executableURL = binary; task.arguments = ["-t","-d",isolated.path,"-f",file.path]
            var environment = Self.coreEnvironment
            environment["SAFE_PATHS"] = home.path
            task.environment = environment
            task.standardOutput = output; task.standardError = output
            try task.run()
            let deadline = Date().addingTimeInterval(30)
            defer { if task.isRunning { task.terminate() } }
            while task.isRunning && Date() < deadline { try await Task.sleep(nanoseconds:50_000_000) }
            if task.isRunning {
                task.terminate()
                for _ in 0..<20 { if !task.isRunning { break }; try? await Task.sleep(nanoseconds:50_000_000) }
                if task.isRunning { kill(task.processIdentifier,SIGKILL) }
                throw LumaError.message("配置校验超时，原配置已保留")
            }
            let reader = try FileHandle(forReadingFrom:log); defer { try? reader.close() }
            let data = try reader.read(upToCount:512*1024) ?? Data()
            guard task.terminationStatus == 0 else {
                let lines = (String(data:data,encoding:.utf8) ?? "").split(whereSeparator:\.isNewline).map(String.init)
                let errors = lines.filter { $0.contains("level=error") || $0.contains("level=fatal") }
                let details = (errors.isEmpty ? lines.filter { !$0.contains("level=info") }:errors).prefix(3).map { line in
                    guard let range = line.range(of:"msg=") else { return line }
                    let value = String(line[range.upperBound...])
                    return (try? JSONDecoder().decode(String.self,from:Data(value.utf8))) ?? value
                }.joined(separator:"\n")
                throw LumaError.message("配置校验失败：\n"+Redactor.clean(String(details.prefix(600))))
            }
        }
        try await withTaskCancellationHandler {
            try await validation.value
        } onCancel: { validation.cancel() }
    }
    public func start(yaml: String, settings: NetworkSettings) async throws {
        guard !settings.tun || geteuid() == 0 else { throw LumaError.message("TUN 需要通过已授权的后台服务运行") }
        if running { return }
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try lease.acquire()
        do { try await lease.recoverOrphan() }
        catch { lease.release(); throw error }
        do { try assertPortAvailable(settings.controllerPort); try assertPortAvailable(settings.mixedPort) }
        catch { lease.release(); throw error }
        let file = home.appendingPathComponent("active.yaml")
        do {
            try Data(yaml.utf8).write(to:file,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        } catch { lease.release(); throw error }
        let task = Process(); let pipe = Pipe()
        task.executableURL = binary; task.arguments = ["-d",home.path,"-f",file.path]
        task.environment = Self.coreEnvironment
        task.standardOutput = pipe; task.standardError = pipe
        let callback = onLog
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if !bytes.isEmpty, let text = String(data:bytes,encoding:.utf8) { callback?(Redactor.clean(text)) }
        }
        do {
            try task.run()
            process = task; outputPipe = pipe
            try lease.record(task.processIdentifier)
        } catch { await stop(); throw error }
        let api = MihomoAPI(port:settings.controllerPort,secret:secret)
        do { for _ in 0..<60 {
            if !task.isRunning { throw LumaError.message("内核启动失败；请检查端口占用和日志") }
            if (try? await api.version()) != nil {
                do { try await verifyProviders(yaml:yaml,api:api) }
                catch { await stop(); throw error }
                currentYAML = yaml; currentSettings = settings; return
            }
            try await Task.sleep(nanoseconds:100_000_000)
        } } catch { await stop(); throw error }
        await stop()
        throw LumaError.message("内核控制接口未就绪")
    }
    public func apply(yaml: String, settings: NetworkSettings,force: Bool = true) async throws {
        if !running { try await start(yaml:yaml,settings:settings); return }
        if let previousSettings = currentSettings,
           previousSettings.controllerPort != settings.controllerPort || previousSettings.mixedPort != settings.mixedPort {
            let previous = currentYAML
            await stop()
            do { try await start(yaml:yaml,settings:settings) }
            catch {
                if let previous { try? await start(yaml:previous,settings:previousSettings) }
                throw error
            }
            return
        }
        let api = MihomoAPI(port:settings.controllerPort,secret:secret)
        let previous = currentYAML
        do {
            try await api.reload(yaml:yaml,force:force)
            _ = try await api.version()
            try await verifyProviders(yaml:yaml,api:api)
            let file = home.appendingPathComponent("active.yaml")
            try Data(yaml.utf8).write(to:file,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            currentYAML = yaml
            currentSettings = settings
        } catch {
            if let previous { try? await api.reload(yaml:previous,force:force) }
            throw error
        }
    }
    /// A running core may replace rules without restarting listeners or streams.
    /// Validate the complete candidate once, and reject non-rule changes before reload.
    public func updateRouting(source: String?,settings: NetworkSettings,rules: [CustomRule],strategies: [GroupStrategy] = [],ruleSubscriptions: [RuleSubscriptionSnapshot] = []) async throws {
        try Task.checkCancellation()
        guard running,let previous = currentYAML,let previousSettings = currentSettings,
              previousSettings.mixedPort == settings.mixedPort,previousSettings.controllerPort == settings.controllerPort else {
            throw LumaError.message("内核运行状态已变化，请重新打开分流编辑器")
        }
        let pid = process?.processIdentifier
        let api = MihomoAPI(port:settings.controllerPort,secret:secret)
        let live = try JSONSerialization.jsonObject(with:await api.data(["configs"])) as? [String:Any]
        guard live?["mode"] as? String == settings.mode.rawValue else { throw LumaError.message("代理模式已改变，请重新保存分流规则") }
        let (yaml,file) = try prepare(source:source,settings:settings,rules:rules,strategies:strategies,ruleSubscriptions:ruleSubscriptions)
        try RoutingUpdatePolicy.validate(previous:previous,candidate:yaml,home:home)
        try await validate(file:file)
        let selections = GroupSelection.capture(try await api.proxies())
        guard running,process?.processIdentifier == pid,currentYAML == previous else { throw LumaError.message("校验期间内核运行状态已改变，请重新保存规则") }
        // Mode can have been patched since the last YAML apply. Roll back to
        // the actual mode, rather than the stale mode in that YAML snapshot.
        var rollback = try ConfigComposer.parse(previous); rollback["mode"] = settings.mode.rawValue
        let rollbackYAML = try Yams.dump(object:rollback,allowUnicode:true,sortKeys:true)
        try Task.checkCancellation()
        do {
            try await apply(yaml:yaml,settings:settings,force:false)
            try await GroupSelection.restore(selections,api:api)
        } catch {
            try? await apply(yaml:rollbackYAML,settings:settings,force:false)
            try? await GroupSelection.restore(selections,api:api)
            throw error
        }
    }
    @discardableResult public func stop() async -> Bool {
        if let process, process.isRunning {
            process.terminate()
            for _ in 0..<40 {
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds:50_000_000)
            }
            if process.isRunning { kill(process.processIdentifier,SIGKILL) }
            for _ in 0..<40 {
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds:50_000_000)
            }
            guard !process.isRunning else { onLog?("内核退出尚未确认，保留进程归属记录"); return false }
        }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil; outputPipe = nil; currentYAML = nil; currentSettings = nil
        lease.clear()
        return true
    }
    public func updateGeoData(payloads: [String:Data]? = nil,rollback: Bool = false) async throws {
        guard let yaml = currentYAML,let settings = currentSettings,running else { throw LumaError.message("请先启动内核再维护规则数据库") }
        let files = try GeoDataUpdates(home:home)
        if rollback { try files.beginRollback() }
        else {
            let downloaded: [String:Data]
            if let payloads { downloaded = payloads } else { downloaded = try await GeoAsset.download() }
            try files.beginUpdate(downloaded)
        }
        let expected = try files.fingerprints()
        var stopped = false
        do {
            try await validate(file:home.appendingPathComponent("active.yaml"))
            guard try files.fingerprints() == expected else { throw LumaError.message("内核校验时改变了待更新的 GEO 文件，已保留原版本") }
            await stop(); stopped = true
            try await start(yaml:yaml,settings:settings)
            guard try files.fingerprints() == expected else { throw LumaError.message("内核启动时改变了 GEO 文件，已保留原版本") }
            try files.finish()
        } catch {
            let original = error
            if stopped { await stop() }
            try files.cancel()
            if stopped { try await start(yaml:yaml,settings:settings) }
            throw original
        }
    }
    private func assertPortAvailable(_ port: Int) throws {
        guard (1...65535).contains(port) else { throw LumaError.message("代理端口超出有效范围") }
        let fd = socket(AF_INET,SOCK_STREAM,0)
        guard fd >= 0 else { throw LumaError.message("无法检查内核端口") }
        defer { close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&reuse,socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to:&address) { pointer in
            pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw LumaError.message("端口 \(port) 已被占用，请在设置中修改端口") }
    }
    public static func bundledBinary() -> URL {
        if let override = ProcessInfo.processInfo.environment["LUMAROUTE_CORE"] { return URL(fileURLWithPath:override) }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/mihomo")
    }
    public static func recoverAbandonedProcess(binary: URL,home: URL) async throws {
        let lease = CoreProcessLease(home:home,binary:binary)
        guard FileManager.default.fileExists(atPath:home.path) else { return }
        try lease.acquire()
        defer { lease.release() }
        try await lease.recoverOrphan()
    }
}

