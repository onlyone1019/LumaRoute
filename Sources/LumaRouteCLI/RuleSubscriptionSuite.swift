import Foundation
import LumaRouteCore

enum RuleSubscriptionSuite {
    static func run(binary: URL, home: URL, official: Bool = false) async throws {
        var passed = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw LumaError.message("规则订阅验收失败："+name) }
            passed += 1; print("PASS "+name)
        }
        let local = try LocalStore(root:home.appendingPathComponent("data"),secrets:MemorySecrets())
        let runner = CoreRunner(binary:binary,home:home.appendingPathComponent("runtime"),secret:UUID().uuidString+UUID().uuidString)
        var settings = NetworkSettings(); settings.mixedPort = 19910; settings.controllerPort = 19911
        let profile = Profile(name:"规则订阅隔离验收",isRemote:false)
        let source = """
        proxies:
          - {name: 东京节点, type: http, server: 127.0.0.1, port: 18771}
          - {name: 大阪节点, type: http, server: 127.0.0.1, port: 18773}
        proxy-groups:
          - {name: 东京, type: select, proxies: [东京节点]}
          - {name: 大阪, type: select, proxies: [大阪节点]}
        rule-providers:
          airport: {type: inline, behavior: domain, payload: ['airport.fixture.test']}
        rules:
          - RULE-SET,airport,东京
          - DOMAIN,unrelated.test,东京
          - MATCH,东京
        """
        let original = try ConfigComposer.parse(source)
        var database = AppDatabase(); database.profiles = [profile]; database.activeProfileID = profile.id
        try local.commit(database,profiles:[profile.id:source])
        let legacy = try JSONDecoder().decode(AppDatabase.self,from:Data("{\"profiles\":[],\"settings\":\(String(data:JSONEncoder().encode(NetworkSettings()),encoding:.utf8)!),\"customRules\":[],\"savedChoices\":{}}".utf8))
        try check(legacy.ruleSubscriptions == nil,"旧数据库无需迁移即可读取")
        let entry = try RuleCatalogEntry.entry("proxy")
        let content = try await RuleSubscriptionDownload.fetch(entry,sourceURL:URL(string:"http://127.0.0.1:18770/ruleset/domain")!)
        var item = RuleSubscription(profileID:profile.id,catalogID:entry.id,target:"大阪")
        item.revision = try local.saveRuleSubscriptionContent(content)
        item.lastUpdated = Date(); item.lastAttempt = Date(); item.ruleCount = 1
        database.ruleSubscriptions = [item]; try local.save(database)
        let snapshots = try local.ruleSubscriptionSnapshots(database,profileID:profile.id)
        let (yaml,file) = try await runner.prepare(source:source,settings:settings,rules:[],ruleSubscriptions:snapshots)
        let parsed = try ConfigComposer.parse(yaml)
        let rules = parsed["rules"] as! [String]
        let airportRules = original["rules"] as! [String]
        try check(rules.filter{!$0.hasPrefix("RULE-SET,lumaroute-rule-")} == airportRules,"机场原规则内容和相对顺序完全保留")
        try check(rules[0] == airportRules[0] && rules[2].hasPrefix("RULE-SET,lumaroute-rule-") && rules.last == "MATCH,东京","补充规则插在机场兜底前")
        try check((parsed["proxy-groups"] as! NSArray).isEqual(to:original["proxy-groups"] as! [Any]),"机场策略组及引用不变")
        try check((parsed["rule-providers"] as? [String:Any])?["airport"] != nil,"机场自己的规则提供器保留")
        try await runner.validate(file:file)
        try await runner.start(yaml:yaml,settings:settings)
        do {
            try check(try await route(port:settings.mixedPort,host:"airport.fixture.test") == "tokyo","真实请求优先命中机场原规则")
            try check(try await route(port:settings.mixedPort,host:"other.fixture.test") == "osaka","未命中机场的请求使用补充规则目标组")
            try check(try await route(port:settings.mixedPort,host:"unrelated.test") == "tokyo","无关流量仍走原分流")
            var priority = item; priority.priority = .override
            let (overrideYAML,overrideFile) = try await runner.prepare(source:source,settings:settings,rules:[],ruleSubscriptions:[.init(subscription:priority,content:content)])
            try await runner.validate(file:overrideFile); try await runner.apply(yaml:overrideYAML,settings:settings)
            try check(try await route(port:settings.mixedPort,host:"airport.fixture.test") == "osaka","显式优先规则可以覆盖机场匹配")
            let (customYAML,customFile) = try await runner.prepare(source:source,settings:settings,rules:[CustomRule(type:"DOMAIN",payload:"airport.fixture.test",target:"东京")],ruleSubscriptions:[.init(subscription:priority,content:content)])
            try await runner.validate(file:customFile); try await runner.apply(yaml:customYAML,settings:settings)
            try check(try await route(port:settings.mixedPort,host:"airport.fixture.test") == "tokyo","手工自定义规则仍保持最高优先级")
            var disabled=item; disabled.enabled=false
            let (disabledYAML,disabledFile) = try await runner.prepare(source:source,settings:settings,rules:[],ruleSubscriptions:[.init(subscription:disabled,content:content)])
            try await runner.validate(file:disabledFile); try await runner.apply(yaml:disabledYAML,settings:settings)
            try check(try await route(port:settings.mixedPort,host:"other.fixture.test") == "tokyo","停用规则订阅立即恢复机场兜底")
            try check(try local.profileContent(profile.id) == source,"导入应用停用均不改写机场原始文件")
            var missing=item; missing.target="已删除的组"
            let (missingYAML,missingFile) = try await runner.prepare(source:source,settings:settings,rules:[],ruleSubscriptions:[.init(subscription:missing,content:content)])
            try await runner.validate(file:missingFile)
            try check((try ConfigComposer.parse(missingYAML))["rules"] as? [String] == airportRules,"目标组缺失只暂停该覆盖，机场规则仍可加载")
            let otherSnapshots = try local.ruleSubscriptionSnapshots(database,profileID:UUID())
            try check(otherSnapshots.isEmpty,"切换机场不会套用前一机场的策略组映射")
            for endpoint in ["html","503"] {
                var rejected=false
                do { _ = try await RuleSubscriptionDownload.fetch(entry,sourceURL:URL(string:"http://127.0.0.1:18770/ruleset/"+endpoint)!) } catch { rejected=true }
                try check(rejected && (try local.ruleSubscriptionContent(item)) == content,"\(endpoint)下载失败保留上次可用缓存")
            }
            let bad = "payload: ['IP-CIDR,invalid/1000']"
            var badItem=item; badItem.catalogID="applications"
            var rejected=false
            do {
                try await CoreRunner.validateRuleSubscription(.init(subscription:badItem,content:bad),binary:binary)
            } catch { rejected=true }
            try check(rejected,"格式合法但内容错误的规则集被真实内核拒绝")
            try check(try await route(port:settings.mixedPort,host:"airport.fixture.test") == "tokyo","失败候选校验不影响正在运行的原规则")
            let oldSnapshot = try local.backup(database)
            local.cleanRuleSubscriptionCache(AppDatabase())
            let (restored,restoredProfiles) = try local.readBackup(oldSnapshot)
            try local.commitBackup(restored,profiles:restoredProfiles,from:oldSnapshot)
            try check(try local.ruleSubscriptionContent(item) == content,"备份包含规则缓存，断网恢复不依赖重新下载")
            let wire = HelperRequest(action:"apply",ruleSubscriptions:snapshots)
            let decoded = try JSONDecoder().decode(HelperRequest.self,from:JSONEncoder().encode(wire))
            try check(decoded.ruleSubscriptions?.first?.content == content,"管理员协议传递规则内容而非任意本机路径")
            try check(!item.isDue(at:Date().addingTimeInterval(3599)) && item.isDue(at:Date().addingTimeInterval(86401)),"自动更新仅在周期到期时触发")
            var retry=item; retry.lastAttempt=Date().addingTimeInterval(86000)
            try check(!retry.isDue(at:Date().addingTimeInterval(86401)),"更新失败按尝试时间退避，不每两秒重试")
            var manual=item; manual.autoUpdate=false
            try check(!manual.isDue(at:Date().addingTimeInterval(999999)),"关闭自动更新后不调度")
            let collision="lumaroute-rule-"+item.id.uuidString.lowercased()
            let collisionSource=source.replacingOccurrences(of:"  airport:",with:"  \(collision): {type: inline, behavior: domain, payload: ['collision.test']}\n  airport:")
            let collisionConfig = try ConfigComposer.parse(ConfigComposer.compose(source:collisionSource,settings:settings,rules:[],secret:"synthetic",ruleSubscriptions:snapshots))
            try check((collisionConfig["rule-providers"] as? [String:Any])?.count == 3,"本地提供器名称碰撞不覆盖机场定义")
            if official {
                for catalog in RuleCatalogEntry.all {
                    let downloaded = try await RuleSubscriptionDownload.fetch(catalog)
                    let candidate = RuleSubscription(profileID:profile.id,catalogID:catalog.id,target:"DIRECT")
                    let (_,officialFile) = try await runner.prepare(source:source,settings:settings,rules:[],ruleSubscriptions:[.init(subscription:candidate,content:downloaded)])
                    try await runner.validate(file:officialFile)
                    try await CoreRunner.validateRuleSubscription(.init(subscription:candidate,content:downloaded),binary:binary)
                    try check(true,"官方 \(catalog.id) 下载且真实 Mihomo 校验通过")
                }
            }
            await runner.stop()
            print("rule subscription integration passed: \(passed) assertions")
        } catch { await runner.stop(); throw error }
    }
    private static func route(port: Int,host: String) async throws -> String {
        try await Task.detached {
            let process=Process(); let pipe=Pipe()
            process.executableURL=URL(fileURLWithPath:"/usr/bin/curl")
            process.arguments=["--disable","--silent","--fail","--proxy","http://127.0.0.1:\(port)","--noproxy","","--max-time","5","http://\(host):18772/data"]
            process.standardOutput=pipe; process.standardError=FileHandle.nullDevice
            try process.run(); let data=pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0,let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],let route=object["route"] as? String else { throw LumaError.message("回环路由请求失败") }
            return route
        }.value
    }
}
