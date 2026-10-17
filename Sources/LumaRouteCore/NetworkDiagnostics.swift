import Foundation
import SystemConfiguration
import Darwin

public struct DiagnosticCheck: Identifiable, Sendable {
    public enum State: String, Sendable { case passed, warning, failed }
    public var title: String
    public var state: State
    public var detail: String
    public var id: String { title }
    public init(_ title: String,_ state: State,_ detail: String) { self.title = title; self.state = state; self.detail = detail }
}

public enum NetworkDiagnostics {
    public static func target(_ text: String) throws -> URL {
        guard let url = URL(string:text.trimmingCharacters(in:.whitespacesAndNewlines)),["http","https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host,!host.isEmpty,url.user == nil,url.password == nil else { throw LumaError.message("请输入不含账号密码的 HTTP 或 HTTPS 测试地址") }
        return url
    }
    public static func systemProxy(settings: NetworkSettings,actual: [String:Any]?) -> DiagnosticCheck {
        guard let actual else { return DiagnosticCheck("系统代理",.warning,"无法读取当前网络的系统代理设置") }
        let enabled = ["HTTP","HTTPS","SOCKS"].filter { actual[$0+"Enable"] as? Int == 1 }
        let matches = ["HTTP","HTTPS","SOCKS"].allSatisfy {
            actual[$0+"Enable"] as? Int == 1 && actual[$0+"Proxy"] as? String == "127.0.0.1" && actual[$0+"Port"] as? Int == settings.mixedPort
        }
        if settings.systemProxy {
            return DiagnosticCheck("系统代理",matches ? .passed:.failed,matches ? "当前网络的 HTTP、HTTPS 和 SOCKS 代理均指向 LumaRoute；绕过地址和不遵循系统代理的应用仍可能直连。":"应用已开启系统代理，但当前网络的代理地址或端口不一致。请检查是否被其他代理软件覆盖。")
        }
        return DiagnosticCheck("系统代理",.warning,enabled.isEmpty ? "系统代理未开启。显式代理测试可以成功，但普通应用未必经过 LumaRoute。":"LumaRoute 未开启系统代理，当前网络存在其他代理设置。")
    }
    public static func dnsResult(_ object: [String:Any]) -> DiagnosticCheck {
        guard let status = object["Status"] as? Int else { return DiagnosticCheck("DNS 解析",.failed,"内核未返回有效的 DNS 结果") }
        let answers = object["Answer"] as? [[String:Any]] ?? []
        let addresses = answers.filter { [1,28].contains($0["type"] as? Int ?? 0) }.compactMap { $0["data"] as? String }
        guard status == 0,!addresses.isEmpty else { return DiagnosticCheck("DNS 解析",.failed,"DNS 未返回地址记录（状态 \(status)）。请检查域名和当前 DNS 设置。") }
        return DiagnosticCheck("DNS 解析",.passed,"内核 DNS 返回 \(addresses.count) 条地址记录；该结果不等同于出口连通。")
    }
    public static func run(api: MihomoAPI,settings: NetworkSettings,url: URL) async throws -> [DiagnosticCheck] {
        let task = Task.detached(priority:.utility) { () throws -> [DiagnosticCheck] in
            var checks: [DiagnosticCheck] = []
            var configuration: [String:Any]?
            do { let version = try await api.version(timeout:3); checks.append(DiagnosticCheck("代理内核",.passed,"控制接口可访问，版本 "+version)) }
            catch { checks.append(DiagnosticCheck("代理内核",.failed,"控制接口不可访问："+Redactor.clean(error.localizedDescription))) }
            try Task.checkCancellation()
            do {
                configuration = try JSONSerialization.jsonObject(with:await api.data(["configs"],timeout:3)) as? [String:Any]
                let matches = configuration?["mixed-port"] as? Int == settings.mixedPort
                checks.append(DiagnosticCheck("代理监听配置",matches ? .passed:.failed,matches ? "内核配置的本机代理端口与应用一致；下一步将实际访问测试地址。":"内核代理端口与应用不一致或无法读取。"))
            } catch { checks.append(DiagnosticCheck("代理监听配置",.failed,"无法读取内核运行配置")) }
            checks.append(systemProxy(settings:settings,actual:SCDynamicStoreCopyProxies(nil) as? [String:Any]))
            let tun = (configuration?["tun"] as? [String:Any])?["enable"] as? Bool == true
            checks.append(DiagnosticCheck("TUN 接管",settings.tun ? (tun ? .passed:.failed):.warning,settings.tun ? (tun ? "内核报告 TUN 已启用；实际目标的连通性仍需结合出口测试判断。":"应用请求开启 TUN，但内核未报告启用。") : "TUN 未开启；未使用系统代理的应用和流量不会自动被接管。"))
            try Task.checkCancellation()
            do {
                var v4 = in_addr(),v6 = in6_addr()
                let host = url.host!.trimmingCharacters(in:CharacterSet(charactersIn:"[]"))
                if inet_pton(AF_INET,host,&v4) == 1 || inet_pton(AF_INET6,host,&v6) == 1 {
                    checks.append(DiagnosticCheck("DNS 解析",.warning,"测试地址使用 IP，无需 DNS 解析；域名解析尚未验证。"))
                } else {
                    let data = try await api.data(["dns","query"],query:[URLQueryItem(name:"name",value:host),URLQueryItem(name:"type",value:"A")],timeout:6)
                    checks.append(dnsResult(try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]))
                }
            } catch { checks.append(DiagnosticCheck("DNS 解析",.failed,Redactor.clean(error.localizedDescription))) }
            try Task.checkCancellation()
            do {
                let result = try await probe(url:url,port:settings.mixedPort)
                checks.append(result)
            } catch { checks.append(DiagnosticCheck("实际出口访问",.failed,Redactor.clean(error.localizedDescription))) }
            try Task.checkCancellation()
            return checks
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel:{ task.cancel() }
    }
    private static func probe(url: URL,port: Int) async throws -> DiagnosticCheck {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/curl")
        process.arguments = ["--disable","--config","-","--silent","--noproxy","","--proxy","http://127.0.0.1:\(port)","--proto","=http,https","--connect-timeout","3","--max-time","8","--output","/dev/null","--write-out","%{http_code}"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let escaped = url.absoluteString.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        try input.fileHandleForWriting.write(contentsOf:Data(("url = \""+escaped+"\"\n").utf8)); try input.fileHandleForWriting.close()
        while process.isRunning { try Task.checkCancellation(); try await Task.sleep(nanoseconds:50_000_000) }
        let status = Int(String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)) ?? 0
        guard process.terminationStatus == 0 else { return DiagnosticCheck("实际出口访问",.failed,"通过本机代理访问失败（传输错误 \(process.terminationStatus)）。检查代理监听、节点连通性及 TLS；不会忽略证书错误。") }
        if status >= 500 || status < 100 { return DiagnosticCheck("实际出口访问",.failed,"通过本机代理返回 HTTP \(status)，代理或目标服务器访问异常。请检查当前节点和目标网站。") }
        return DiagnosticCheck("实际出口访问",(200...399).contains(status) ? .passed:.warning,"通过本机代理按当前规则访问，返回 HTTP \(status)。这验证当前规则选择的出口，不保证它一定是代理节点，也不代表其他网站均可访问。")
    }
}
