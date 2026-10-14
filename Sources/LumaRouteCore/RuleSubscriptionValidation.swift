import Foundation

extension CoreRunner {
    /// -t validates the configuration but may not initialize rule providers.
    /// An isolated unprivileged core confirms actual provider parsing/loading.
    public static func validateRuleSubscription(_ snapshot: RuleSubscriptionSnapshot, binary: URL) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumaRoute-rule-check-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:directory) }
        var settings = NetworkSettings()
        settings.mixedPort = try availableRuleCheckPort()
        repeat { settings.controllerPort = try availableRuleCheckPort() } while settings.controllerPort == settings.mixedPort
        let secret = UUID().uuidString+UUID().uuidString
        var candidate = snapshot; candidate.subscription.enabled = true; candidate.subscription.target = "DIRECT"
        let yaml = try ConfigComposer.compose(source:nil,settings:settings,rules:[],secret:secret,resourceRoot:directory,ruleSubscriptions:[candidate])
        let file = directory.appendingPathComponent("candidate.yaml")
        try Data(yaml.utf8).write(to:file,options:.atomic)
        let probe = CoreRunner(binary:binary,home:directory,secret:secret)
        do {
            try await probe.validate(file:file)
            try await probe.start(yaml:yaml,settings:settings)
            await probe.stop()
        } catch { await probe.stop(); throw error }
    }
    private static func availableRuleCheckPort() throws -> Int {
        let fd = socket(AF_INET,SOCK_STREAM,0)
        guard fd >= 0 else { throw LumaError.message("无法分配规则校验端口") }
        defer { close(fd) }
        var address=sockaddr_in(); address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family=sa_family_t(AF_INET); address.sin_addr.s_addr=inet_addr("127.0.0.1")
        let result=withUnsafePointer(to:&address) { pointer in pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length=socklen_t(MemoryLayout<sockaddr_in>.size)
        let queried=withUnsafeMutablePointer(to:&address) { pointer in pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(fd,$0,&length) } }
        guard result == 0,queried == 0 else { throw LumaError.message("无法分配规则校验端口") }
        return Int(UInt16(bigEndian:address.sin_port))
    }
}
