import Foundation
import Security
import LumaRouteCore

enum RegressionSuite {
    static func run() throws {
        var passed=try SQLiteStoreSuite.run()+CompositionSuite.model()+RoutingToolsSuite.model()+CompositionDNSSuite.model()+CompositionRoutingSuite.model()+RoutingSaveSuite.model()
        func check(_ condition:Bool,_ name:String)throws {
            guard condition else { throw LumaError.message("验收失败："+name) }
            passed += 1
            print("PASS "+name)
        }
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("work/regression-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try LocalStore(root:root,secrets:MemorySecrets())
        let input="""
        mixed-port: 7890
        external-controller: 0.0.0.0:9090
        external-controller-unix: /tmp/foreign.sock
        proxies:
          - {name: node, type: direct}
        proxy-groups:
          - {name: 自定义组, type: select, proxies: [node]}
        dns:
          nameserver: [https://dns.example.org/dns-query]
        rules:
          - MATCH,自定义组
        """
        let yaml=try ConfigComposer.compose(source:input,settings:NetworkSettings(),rules:[CustomRule(payload:"github.com",target:"自定义组")],secret:"synthetic-secret")
        let parsed=try ConfigComposer.parse(yaml)
        try check(parsed["mixed-port"] as? Int == 19790,"运行端口归 LumaRoute 管理")
        try check(parsed["external-controller"] as? String == "127.0.0.1:19791","控制接口只监听本机")
        try check(parsed["external-controller-unix"] == nil,"移除订阅指定的控制 socket")
        try check((parsed["dns"] as? [String:Any])?["nameserver"] as? [String] == ["https://dns.example.org/dns-query"],"保留订阅 DNS")
        try check((parsed["rules"] as? [String])?.first == "DOMAIN-SUFFIX,github.com,自定义组","自定义规则优先于订阅规则")
        try check((parsed["proxy-groups"] as? [[String:Any]])?.first?["name"] as? String == "自定义组","保留订阅策略组")
        let directOnly = try ConfigComposer.parse(ConfigComposer.compose(source:"rules: ['MATCH,DIRECT']",settings:NetworkSettings(),rules:[],secret:"synthetic-secret"))
        try check((directOnly["proxy-groups"] as? [[String:Any]])?.first?["proxies"] as? [String] == ["DIRECT"],"无节点的直连配置不生成空自动组")
        let providerOnly = try ConfigComposer.parse(ConfigComposer.compose(source:"proxy-providers: {fixture: {type: http, url: 'http://127.0.0.1:18770/provider'}}",settings:NetworkSettings(),rules:[],secret:"synthetic-secret"))
        try check((providerOnly["proxy-groups"] as? [[String:Any]])?.last?["use"] as? [String] == ["fixture"],"仅有提供器的订阅生成可用自动组")
        try check(parsed["geo-auto-update"] as? Bool == false,"规则数据库更新归事务维护流程管理")
        let oldHelperRequest = try JSONDecoder().decode(HelperRequest.self,from:Data("{\"action\":\"status\"}".utf8))
        try check(oldHelperRequest.coreVersion == nil,"管理员请求的新增版本字段兼容旧消息")
        try check(NetworkServiceSetup.resolve(installed:false,accepted:false,healthOnly:false) == .install,"未安装服务引导首次授权")
        try check(NetworkServiceSetup.resolve(installed:true,accepted:false,healthOnly:false) == .update,"应用构建变化引导完成更新")
        try check(NetworkServiceSetup.resolve(installed:true,accepted:false,healthOnly:true) == .update,"构建身份检查优先于网络权限状态")
        try check(NetworkServiceSetup.resolve(installed:true,accepted:true,healthOnly:true) == .enableNetwork,"启动验证服务引导启用网络功能")
        try check(NetworkServiceSetup.resolve(installed:true,accepted:true,healthOnly:false) == .ready,"已经授权的当前构建不重复提示")
        do {
            _ = try LocalServiceAuthorization.script(app:URL(fileURLWithPath:"/tmp/LumaRoute.app"),ownerUID:0,networkReady:true)
            throw LumaError.message("允许 root 冒充普通应用用户")
        } catch { try check(error.localizedDescription == "应用或用户身份无效","授权命令拒绝无效用户身份") }
        let authorizationSource = try LocalServiceAuthorization.script(app:URL(fileURLWithPath:"/tmp/LumaRoute \"quoted\" ' $() \\ 中文.app"),ownerUID:501,networkReady:true)
        let authorizationFile = root.appendingPathComponent("authorization.applescript")
        try authorizationSource.write(to:authorizationFile,atomically:true,encoding:.utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath:"/usr/bin/osacompile")
        compiler.arguments = ["-o",root.appendingPathComponent("authorization.scpt").path,authorizationFile.path]
        compiler.standardOutput = FileHandle.nullDevice; compiler.standardError = FileHandle.nullDevice
        try compiler.run(); compiler.waitUntilExit()
        try check(compiler.terminationStatus == 0,"含空格、引号和中文路径的系统授权脚本可正确编译")
        try check(authorizationSource.contains("quoted form of appPath") && authorizationSource.contains("quoted form of installerPath") && !authorizationSource.contains("password "),"路径由 AppleScript 安全转义，应用不传递管理员密码")
        try check(oldHelperRequest.systemProxyEnabled == nil,"系统代理独立请求兼容旧消息")
        let proxyRequestData = try JSONEncoder().encode(HelperRequest(action:"system-proxy",systemProxyEnabled:false))
        let proxyRequest = try JSONSerialization.jsonObject(with:proxyRequestData) as! [String:Any]
        try check(Set(proxyRequest.keys) == ["action","systemProxyEnabled"] && proxyRequest["systemProxyEnabled"] as? Bool == false,"系统代理关闭请求只传开关，不携带配置或端口")
        var previousNetwork = NetworkSettings(); previousNetwork.tun = true
        var proxyNetwork = previousNetwork; proxyNetwork.systemProxy = true
        try check(proxyNetwork.isSystemProxyOnlyChange(from:previousNetwork) && previousNetwork.isSystemProxyOnlyChange(from:proxyNetwork),"保留 TUN 的系统代理开关允许独立处理")
        try check(!previousNetwork.isSystemProxyOnlyChange(from:previousNetwork),"重复的系统代理设置不触发操作")
        let beforeProxyConfig = try ConfigComposer.parse(ConfigComposer.compose(source:input,settings:previousNetwork,rules:[],secret:"synthetic"))
        let afterProxyConfig = try ConfigComposer.parse(ConfigComposer.compose(source:input,settings:proxyNetwork,rules:[],secret:"synthetic"))
        try check(NSDictionary(dictionary:beforeProxyConfig).isEqual(to:afterProxyConfig),"系统代理开关不改变内核配置")
        let otherChanges:[(String,(inout NetworkSettings)->Void)] = [
            ("TUN",{ $0.tun.toggle() }), ("混合端口",{ $0.mixedPort += 1 }),
            ("控制端口",{ $0.controllerPort += 1 }), ("DNS",{ $0.dnsHijack.toggle() }),
            ("绕过列表",{ $0.bypass.append("example.org") })
        ]
        for (name,change) in otherChanges {
            var next = proxyNetwork; change(&next)
            try check(!next.isSystemProxyOnlyChange(from:previousNetwork),"同时修改"+name+"不能走系统代理快捷路径")
        }
        let preferenceChanges:[(String,(inout NetworkSettings)->Void)] = [
            ("外观",{ $0.appearance = "dark" }), ("登录启动",{ $0.autoLaunch.toggle() }),
            ("启动后连接",{ $0.connectOnLaunch.toggle() }), ("测试并发",{ $0.testConcurrency += 1 }),
            ("默认订阅更新间隔",{ $0.updateIntervalHours += 1 })
        ]
        var preferences = previousNetwork
        for (name,change) in preferenceChanges {
            var next = previousNetwork; change(&next); change(&preferences)
            try check(next.isApplicationOnlyChange(from:previousNetwork),name+"可独立保存")
            let config = try ConfigComposer.parse(ConfigComposer.compose(source:input,settings:next,rules:[],secret:"synthetic"))
            try check(NSDictionary(dictionary:beforeProxyConfig).isEqual(to:config),name+"不改变内核 YAML")
        }
        try check(preferences.isApplicationOnlyChange(from:previousNetwork),"组合修改普通设置仍独立保存")
        try check(!previousNetwork.isApplicationOnlyChange(from:previousNetwork),"相同设置无需保存")
        for (name,change) in otherChanges + [
            ("系统代理",{ $0.systemProxy.toggle() }), ("模式",{ $0.mode = .global }),
            ("协议栈",{ $0.stack = "system" }), ("自动路由",{ $0.autoRoute.toggle() }),
            ("网卡检测",{ $0.autoDetectInterface.toggle() }), ("局域网",{ $0.excludeLAN.toggle() }),
            ("MTU",{ $0.mtu += 1 }), ("Fake IP",{ $0.fakeIP.toggle() }),
            ("IPv6",{ $0.ipv6.toggle() }), ("测试 URL",{ $0.testURL = "https://example.org" }),
            ("测试超时",{ $0.testTimeout += 1 })
        ] {
            var next = preferences; change(&next)
            try check(!next.isApplicationOnlyChange(from:previousNetwork),"普通设置同时修改"+name+"仍走原配置流程")
        }
        let strategySource = """
        proxies:
          - {name: 日本节点, type: http, server: 127.0.0.1, port: 18771}
          - {name: 美国节点, type: http, server: 127.0.0.1, port: 18773}
        proxy-groups:
          - {name: 国外流量, type: select, proxies: [日本节点, 美国节点, 直接连接]}
          - {name: 苹果服务, type: select, proxies: [国外流量, 直接连接]}
          - {name: 直接连接, type: select, proxies: [DIRECT]}
        rules: ['MATCH,国外流量']
        """
        let strategy = GroupStrategy(profileID:UUID(),group:"国外流量",mode:.lowestLatency,candidateFilter:GroupStrategy.japanFilter)
        let strategyYAML = try ConfigComposer.compose(source:strategySource,settings:NetworkSettings(),rules:[],secret:"synthetic",strategies:[strategy])
        let strategyGroups = try ConfigComposer.parse(strategyYAML)["proxy-groups"] as! [[String:Any]]
        try check(strategyGroups.compactMap { $0["name"] as? String } == ["国外流量","苹果服务","直接连接"],"自动覆盖保持分组顺序与组名")
        try check(strategyGroups[0]["proxies"] as? [String] == ["日本节点"],"日本自动候选排除其他地区和嵌套组")
        try check(strategyGroups[1]["proxies"] as? [String] == ["国外流量","直接连接"],"其他服务组的引用不变")
        let sourceRestored = try ConfigComposer.compose(source:strategySource,settings:NetworkSettings(),rules:[],secret:"synthetic")
        try check((try ConfigComposer.parse(sourceRestored)["proxy-groups"] as? [[String:Any]])?.first?["type"] as? String == "select","移除覆盖可恢复订阅原策略")
        var empty = strategy; empty.candidateFilter = "does-not-exist"
        var emptyRejected = false
        do { _ = try ConfigComposer.compose(source:strategySource,settings:NetworkSettings(),rules:[],secret:"synthetic",strategies:[empty]) } catch { emptyRejected = true }
        try check(emptyRejected,"空自动候选被拒绝")
        var oldObject = try JSONSerialization.jsonObject(with:JSONEncoder().encode(AppDatabase())) as! [String:Any]
        oldObject.removeValue(forKey:"groupStrategies")
        let oldDatabase = try JSONSerialization.data(withJSONObject:oldObject)
        try check(try JSONDecoder().decode(AppDatabase.self,from:oldDatabase).groupStrategies == nil,"新增策略字段兼容已有数据库")
        for content in ["","<html>not a subscription</html>","proxies: ["] {
            do { _=try ConfigComposer.parse(content); throw LumaError.message("接受了无效订阅") }
            catch { try check(!error.localizedDescription.contains("接受了无效订阅"),"拒绝空或非法订阅") }
        }
        var malformedMessage = ""
        do { _ = try ConfigComposer.parse("proxies: [\npassword: synthetic-private-value") }
        catch { malformedMessage = error.localizedDescription }
        try check(malformedMessage.contains("YAML") && !malformedMessage.contains("YamlError") && !malformedMessage.contains("synthetic-private-value"),"损坏YAML给出可读提示且不暴露解析器或配置内容")
        do { try CustomRule(payload:"safe.com,DIRECT").validate(); throw LumaError.message("规则注入未被拒绝") }
        catch { try check(!error.localizedDescription.contains("规则注入未被拒绝"),"拒绝规则分隔符注入") }
        let uri="ss://dGVzdA@example.org:443#synthetic"
        let encoded=Data(uri.utf8).base64EncodedString()
        let uriRoot=root.appendingPathComponent("uri")
        let uriYAML=try ConfigComposer.compose(source:encoded,settings:NetworkSettings(),rules:[],secret:"synthetic",resourceRoot:uriRoot)
        try check(try String(contentsOf:uriRoot.appendingPathComponent("providers/proxy-0.yaml")) == uri,"URI 内容由内核原生 provider 解析")
        try check(!uriYAML.contains("_lumaroute_raw_provider"),"内部订阅标记不传给内核")
        let usage=SubscriptionUsage(header:"upload=12; download=34; total=100; expire=1799999999")
        try check(usage.upload+usage.download == 46 && usage.total == 100 && usage.expire != nil,"解析服务商额度与到期时间")
        try check(usage.usedBytes == 46 && usage.usedFraction == 0.46,"订阅页正常流量及进度")
        let extremeUsage = SubscriptionUsage(header:"upload=9223372036854775807; download=1; total=100")
        try check(extremeUsage.usedBytes == Int64.max && extremeUsage.usedFraction == 1 && !Format.bytes(extremeUsage.usedBytes).isEmpty,"订阅异常大流量不溢出且进度封顶")
        var invalidUsage = usage; invalidUsage.upload = -1; invalidUsage.download = -1; invalidUsage.total = 0
        try check(invalidUsage.usedBytes == 0 && invalidUsage.usedFraction == nil,"旧数据负流量及零额度不产生非法进度")
        let clean=Redactor.clean("failure https://example.org/sub?token=synthetic-password secret=abcdef password=abcdef")
        try check(!clean.contains("synthetic-password") && !clean.contains("abcdef"),"日志与诊断隐藏凭据")
        let encodedCredentials = Redactor.clean("vmess://synthetic-payload ss://synthetic-password {\"Authorization\":\"Bearer synthetic-token\"} auth: synthetic-auth")
        try check(!encodedCredentials.contains("synthetic-"),"URI 与 JSON 认证凭据脱敏")
        try check(try SubscriptionFetcher.normalizedUserAgent("   ") == nil,"空白User-Agent恢复默认")
        try check(try SubscriptionFetcher.normalizedUserAgent("  Custom-Agent/1.0  ") == "Custom-Agent/1.0","自定义User-Agent去除首尾空格")
        for value in ["agent\r\nAuthorization: injected","agent\nheader",String(repeating:"x",count:513),"中文标识"] {
            var rejected = false
            do { _ = try SubscriptionFetcher.normalizedUserAgent(value) } catch SubscriptionError.invalidUserAgent { rejected = true }
            try check(rejected,"拒绝非法User-Agent输入，长度\(value.utf8.count)")
        }
        var remoteA = Profile(name:"订阅A",isRemote:true); remoteA.userAgent = "Provider-A/1.0"
        var remoteB = Profile(name:"订阅B",isRemote:true); remoteB.userAgent = "Provider-B/2.0"
        var agents = AppDatabase(); agents.profiles = [remoteA,remoteB]
        try store.save(agents)
        try check(try store.load().profiles.map(\.userAgent) == ["Provider-A/1.0","Provider-B/2.0"],"各订阅独立持久化User-Agent")
        let legacy = Profile(name:"旧订阅",isRemote:true)
        let legacyData = try JSONEncoder().encode(legacy)
        try check(try JSONDecoder().decode(Profile.self,from:legacyData).userAgent == nil,"旧订阅没有User-Agent字段时兼容读取")
        let safeFailure = SubscriptionError.configuration("node https://example.org/sub?token=synthetic-token password=synthetic-password "+String(repeating:"x",count:900)).localizedDescription
        try check(!safeFailure.contains("synthetic-token") && !safeFailure.contains("synthetic-password") && safeFailure.count < 850,"订阅校验错误脱敏并限制详情长度")
        let client=MihomoAPI(port:19791,secret:"synthetic")
        let path=client.url(["proxies","日本 / 东京?01"]).absoluteString
        try check(path.contains("%2F") && path.contains("%3F") && !path.contains("synthetic"),"节点名称按路径段编码，密钥不进 URL")
        var db=AppDatabase()
        let profile=Profile(name:"synthetic",isRemote:false)
        db.profiles=[profile]; db.activeProfileID=profile.id
        db.customRules=[CustomRule(payload:"example.org",target:"DIRECT")]
        try store.saveProfile(input,id:profile.id); try store.save(db)
        var updated = db; updated.profiles[0].name = "更新后"
        try store.commit(updated,profiles:[profile.id:input+"\n# updated\n"])
        try check(try store.load().profiles[0].name == "更新后" && store.profileContent(profile.id).hasSuffix("# updated\n"),"配置快照与元数据共同提交")
        try store.commit(db,profiles:[profile.id:input])
        let readOnly = try LocalStore(root:root,readOnly:true)
        var writeRejected = false
        do { try readOnly.commit(updated,profiles:[profile.id:input+"\n# should roll back\n"]) } catch { writeRejected = true }
        try check(writeRejected,"只读 SQLite 写入失败被报告")
        try check(try store.load().profiles[0].name == "synthetic" && store.profileContent(profile.id) == input,"元数据写入失败后恢复原配置")
        try check(!FileManager.default.fileExists(atPath:root.appendingPathComponent("pending-commit.json").path),"SQLite 事务无需额外配置恢复记录")
        let backup=try store.backup(db)
        db.customRules=[]; try store.save(db)
        let restored=try store.restoreBackup(backup)
        try check(restored.customRules.count == 1,"备份恢复自定义规则")
        try check(try store.profileContent(profile.id) == input,"备份恢复完整订阅内容")
        let permissions=try FileManager.default.attributesOfItem(atPath:store.databaseURL.path)
        try check((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600,"业务数据库权限为 0600")
        let ownership: [String:Any] = ["applied":["HTTPEnable":1,"HTTPPort":19790],"previousApplied":["HTTPEnable":1,"HTTPPort":19789]]
        try check(SystemNetwork.owns(["HTTPEnable":1,"HTTPPort":19790],record:ownership),"网络恢复识别已提交的自有设置")
        try check(SystemNetwork.owns(["HTTPEnable":1,"HTTPPort":19789],record:ownership),"网络事务中断可识别提交前的自有设置")
        try check(!SystemNetwork.owns(["HTTPEnable":1,"HTTPPort":7890],record:ownership),"其他软件覆盖后的网络值不归 LumaRoute 恢复")
        let executable = URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL
        let ownRequirement = try LocalServiceInstallation.requirement(for:executable)
        try check(LocalServiceInstallation.currentProcessMatches(ownRequirement),"临时签名进程通过自身精确身份校验")
        var ownCode:SecStaticCode?; var codeInfo:CFDictionary?
        guard SecStaticCodeCreateWithPath(executable as CFURL,[],&ownCode) == errSecSuccess,let ownCode,
              SecCodeCopySigningInformation(ownCode,[],&codeInfo) == errSecSuccess,
              let identifier = (codeInfo as? [String:Any])?[kSecCodeInfoIdentifier as String] as? String else { throw LumaError.message("无法读取测试进程身份") }
        let fake = root.appendingPathComponent("different-client")
        try FileManager.default.copyItem(at:executable.deletingLastPathComponent().appendingPathComponent("LumaRouteHelper"),to:fake)
        let resign = Process(); resign.executableURL = URL(fileURLWithPath:"/usr/bin/codesign")
        resign.arguments = ["--force","--sign","-","--identifier",identifier,fake.path]
        resign.standardOutput = FileHandle.nullDevice; resign.standardError = FileHandle.nullDevice
        try resign.run(); resign.waitUntilExit()
        guard resign.terminationStatus == 0 else { throw LumaError.message("无法构建伪造身份测试客户端") }
        try check(!LocalServiceInstallation.currentProcessMatches(try LocalServiceInstallation.requirement(for:fake)),"同标识但不同代码的临时签名客户端被拒绝")
        try check(!LocalServiceInstallation.currentProcessMatches("malformed requirement !!!"),"无效调用方要求不会放宽身份校验")
        try PrivilegedConfigurationPolicy.validate(input)
        try check(true,"普通代理配置可通过管理员配置边界")
        for (fragment,name) in [("tls: {certificate: /etc/private.pem}","外部证书文件"),("post-up: touch /tmp/command","外部命令"),("proxy-providers: {unsafe: {type: http, url: 'file:///etc/passwd'}}","文件协议provider")] {
            var rejected = false
            do { try PrivilegedConfigurationPolicy.validate(input+"\n"+fragment+"\n") } catch { rejected = true }
            try check(rejected,"管理员配置拒绝"+name)
        }
        print("native regression suite passed: \(passed) assertions")
    }
}

