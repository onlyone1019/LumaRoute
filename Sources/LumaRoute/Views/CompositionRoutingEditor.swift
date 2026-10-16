import SwiftUI
import UniformTypeIdentifiers
import LumaRouteCore

struct DomainRoutesEditor: View {
    @EnvironmentObject var store: AppStore
    @Binding var routes: [SubscriptionDomainRoute]
    let composition: SubscriptionComposition
    let profiles: [Profile]
    var policyLoader: ((SubscriptionComposition) async throws -> [String])? = nil
    @State private var policies: [String] = []
    @State private var loadedPolicyKey: String?
    @State private var policyFailure: String?
    @State private var batch = false
    @State private var importing: UUID?
    @State private var filePicker = false
    @State private var host = ""
    @State private var resolvedIP = ""
    @State private var process = ""
    @State private var verdict: String?
    private var policyKey: String { composition.profileIDs.map(\.uuidString).joined()+String(describing:composition.baseProfileID)+profiles.map { $0.name+String(describing:$0.lastUpdated) }.joined() }
    private var policiesReady: Bool { loadedPolicyKey == policyKey }
    var body: some View {
        Panel(padding:12) {
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Text("分流规则").font(.headline)
                    Spacer()
                    Button("批量添加") { batch = true }.disabled(!policiesReady)
                    Button { routes.append(SubscriptionDomainRoute(profileID:profiles.first?.id)) } label:{ Label("添加规则",systemImage:"plus") }
                }
                Text("从上到下首个匹配生效。自定义规则优先于这里；之后继续使用规则订阅、基础规则和兜底出口。保存后对新连接生效。").font(.caption).foregroundStyle(.secondary)
                if let policyFailure { Text(policyFailure).font(.caption).foregroundStyle(.orange) }
                if !policiesReady && policyFailure == nil { Text("正在加载出口列表…").font(.caption).foregroundStyle(.secondary) }
                if routes.isEmpty { Text("尚未添加规则，沿用基础订阅的分流。").foregroundStyle(.secondary).padding(.vertical,8) }
                ForEach($routes) { $route in
                    VStack(alignment:.leading,spacing:4) {
                        HStack(spacing:6) {
                            Toggle("启用分流规则",isOn:$route.enabled).labelsHidden().toggleStyle(.checkbox)
                            LumaPicker("匹配方式",selection:$route.type,value:CompositionRouting.types.first { $0.value == route.type }?.label ?? route.type) {
                                ForEach(CompositionRouting.types,id:\.value) { Text($0.label).tag($0.value) }
                            }.frame(width:150)
                            TextField(CompositionRouting.types.first { $0.value == route.type }?.placeholder ?? "匹配内容",text:$route.domain).textFieldStyle(LumaTextFieldStyle()).frame(minHeight:LumaControl.height).accessibilityLabel("分流匹配内容")
                            if route.type == "PROCESS-PATH" {
                                Button { importing = route.id; filePicker = true } label:{ Image(systemName:"folder") }.help("选择应用的可执行文件路径").accessibilityLabel("选择应用")
                            }
                        }
                        HStack(spacing:8) {
                            Text("出口").font(.callout).foregroundStyle(.secondary).frame(width:44,alignment:.leading)
                            CompositionExitPicker(selection:Binding(get:{ selection(route) },set:{ setTarget(&route,$0) }),profiles:profiles,policies:policies,policiesReady:policiesReady)
                            RuleOrderButtons(canMoveUp:routes.first?.id != route.id,canMoveDown:routes.last?.id != route.id,moveUp:{ move(route.id,by:-1) },moveDown:{ move(route.id,by:1) })
                            Button { routes.removeAll { $0.id == route.id } } label:{ Image(systemName:"trash").frame(width:28,height:LumaControl.height) }.buttonStyle(.borderless).help("删除分流规则").accessibilityLabel("删除分流规则")
                        }
                        if route.enabled,let error = routeError(route) { Text(error).font(.caption).foregroundStyle(.red) }
                    }.padding(10).background(Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:8))
                }
                Text("后缀包含域名及其子域名；关键词匹配域名中的文字。IP 网段只匹配已有目标 IP，不额外解析域名。应用路径使用可执行文件，进程名称和路径不区分大小写。").font(.caption).foregroundStyle(.secondary)
                Divider()
                DisclosureGroup("分流验证 · 当前草稿") {
                    VStack(alignment:.leading,spacing:8) {
                        TextField("域名或目标 IP（如 api.example.com）",text:$host).textFieldStyle(LumaTextFieldStyle()).accessibilityLabel("验证域名或 IP")
                        HStack {
                            TextField("已解析 IP（可选）",text:$resolvedIP).textFieldStyle(LumaTextFieldStyle())
                            TextField("进程名称或完整路径（可选）",text:$process).textFieldStyle(LumaTextFieldStyle())
                            Button("验证规则") { verify() }.disabled(!policiesReady)
                        }
                        if let verdict { Text(verdict).font(.callout).textSelection(.enabled).fixedSize(horizontal:false,vertical:true) }
                        Text("本地预览包含当前组合的自定义规则和上方草稿，不发起网络请求。未匹配时交给后续规则；策略组最终节点以“连接”页的实际新连接为准。规则模式下才会按此分流。").font(.caption).foregroundStyle(.secondary)
                    }.padding(.top,8)
                }
            }.padding(10).frame(maxWidth:.infinity,alignment:.leading)
        }
        .task(id:policyKey) {
            let key = policyKey
            loadedPolicyKey = nil
            policyFailure = nil
            verdict = nil
            do {
                let loaded: [String]
                if let policyLoader { loaded = try await policyLoader(composition) }
                else { loaded = try await store.compositionPolicyTargets(composition) }
                guard !Task.isCancelled,key == policyKey else { return }
                policies = loaded
                loadedPolicyKey = key
            } catch {
                guard !Task.isCancelled,key == policyKey else { return }
                policyFailure = "出口列表加载失败："+Redactor.clean(error.localizedDescription)
            }
        }
        .sheet(isPresented:$batch) {
            CompositionBatchSheet(routes:$routes,profiles:profiles,policies:policies,policiesReady:policiesReady)
        }
        .fileImporter(isPresented:$filePicker,allowedContentTypes:[.applicationBundle]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let path = Bundle(url:url)?.executableURL?.path,let index = routes.firstIndex(where:{$0.id == importing}) else { throw LumaError.message("无法读取此应用的可执行文件") }
                routes[index].domain = path
            } catch { policyFailure = Redactor.clean(error.localizedDescription) }
            importing = nil
        }
        .onChange(of:routes) { _,_ in verdict = nil }
        .onChange(of:host) { _,_ in verdict = nil }
        .onChange(of:resolvedIP) { _,_ in verdict = nil }
        .onChange(of:process) { _,_ in verdict = nil }
        .onChange(of:composition.customRules) { _,_ in verdict = nil }
    }
    private func selection(_ route: SubscriptionDomainRoute) -> String { route.target.map { "policy:"+$0 } ?? route.profileID.map { "profile:"+$0.uuidString } ?? "" }
    private func setTarget(_ route: inout SubscriptionDomainRoute,_ value: String) {
        if value.hasPrefix("profile:") { route.profileID = UUID(uuidString:String(value.dropFirst(8))); route.target = nil }
        else { route.profileID = nil; route.target = value.hasPrefix("policy:") ? String(value.dropFirst(7)):nil }
    }
    private func routeError(_ route: SubscriptionDomainRoute) -> String? {
        do { _ = try route.normalizedDomain() } catch { return Redactor.clean(error.localizedDescription) }
        guard policiesReady else { return nil }
        if let target = route.target { if !["DIRECT","REJECT"].contains(target) && !policies.contains(target) { return "目标策略组已不存在，请重新选择" } }
        else if !profiles.contains(where:{$0.id == route.profileID}) { return "目标订阅已移出组合，请重新选择" }
        return nil
    }
    private func move(_ id: UUID,by offset: Int) {
        guard let index = routes.firstIndex(where:{$0.id == id}),routes.indices.contains(index+offset) else { return }
        routes.swapAt(index,index+offset)
    }
    private func verify() {
        guard policiesReady else { return }
        do {
            var candidate = composition; candidate.domainRoutes = routes
            if let invalid = routes.first(where:{$0.enabled && routeError($0) != nil}) { throw LumaError.message(routeError(invalid)!) }
            let rules = try candidate.customRules + candidate.routingRules(profiles:store.database.profiles)
            switch try CompositionRouting.preview(rules:rules,host:host,ip:resolvedIP,process:process) {
            case .matched(let index,let rule):
                let row = (routes.firstIndex { $0.id == rule.id }).map { $0+1 } ?? index+1
                let origin = index < candidate.customRules.count ? "自定义规则第 \(index+1) 条":"分流规则第 \(row) 条"
                verdict = "命中\(origin)：\(rule.type) · \(rule.payload) → \(rule.target)"
            case .needs(let message): verdict = message
            case .fallsThrough: verdict = "未命中自定义规则和上方分流规则。将继续匹配规则订阅、基础规则和兜底出口；请在“连接”页核对实际出口。"
            }
        } catch { verdict = Redactor.clean(error.localizedDescription) }
    }
}

private struct CompositionExitPicker: View {
    @Binding var selection: String
    let profiles: [Profile]
    let policies: [String]
    let policiesReady: Bool
    private var known: Bool { selection.isEmpty || selection == "policy:DIRECT" || selection == "policy:REJECT" || policies.contains(where:{"policy:"+$0 == selection}) || profiles.contains(where:{"profile:"+$0.id.uuidString == selection}) }
    private var selectedLabel: String {
        if selection.isEmpty { return "选择出口" }
        if selection == "policy:DIRECT" { return "直连" }
        if selection == "policy:REJECT" { return "拒绝连接" }
        if selection.hasPrefix("profile:"),let profile = profiles.first(where:{"profile:"+$0.id.uuidString == selection}) { return "订阅 · "+profile.name }
        if selection.hasPrefix("policy:") { return (known || !policiesReady ? "":"已失效：")+String(selection.dropFirst(7)) }
        return policiesReady ? "出口已失效":"所选订阅（加载中）"
    }
    var body: some View {
        LumaPicker("分流出口",selection:$selection,value:selectedLabel) {
            Text("选择出口").tag("")
            Section("订阅") { ForEach(profiles) { Text("订阅 · "+$0.name).tag("profile:"+$0.id.uuidString) } }
            Section("连接方式") { Text("直连").tag("policy:DIRECT"); Text("拒绝连接").tag("policy:REJECT") }
            Section("策略组") { ForEach(policies,id:\.self) { Text($0).tag("policy:"+$0) } }
            if !known {
                Text(!policiesReady ? (selection.hasPrefix("policy:") ? String(selection.dropFirst(7)):"所选订阅（加载中）"):"出口已失效").tag(selection)
            }
        }.disabled(!policiesReady)
    }
}

private struct CompositionBatchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var routes: [SubscriptionDomainRoute]
    let profiles: [Profile]
    let policies: [String]
    let policiesReady: Bool
    @State private var text = ""
    @State private var type = "DOMAIN-SUFFIX"
    @State private var exit = ""
    @State private var failure: String?
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("批量添加分流规则").font(.title2.bold())
            Text("每行一条匹配内容，使用下方统一匹配方式和出口。也可每行填写 TYPE,匹配内容，混合多种类型。").foregroundStyle(.secondary)
            Text("example.com\nDOMAIN-KEYWORD,video\nIP-CIDR,192.168.0.0/16").font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary)
            TextEditor(text:$text).font(.system(.body,design:.monospaced)).frame(minHeight:180).border(Color.secondary.opacity(0.3)).accessibilityLabel("批量规则内容")
            HStack {
                LumaPicker("默认匹配方式",selection:$type,value:CompositionRouting.types.first { $0.value == type }?.label ?? type) { ForEach(CompositionRouting.types,id:\.value) { Text($0.label).tag($0.value) } }.frame(width:180)
                CompositionExitPicker(selection:$exit,profiles:profiles,policies:policies,policiesReady:policiesReady)
            }
            if let failure { Text(failure).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true) }
            HStack {
                Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("添加到草稿") {
                    do {
                        guard !exit.isEmpty else { throw LumaError.message("请选择分流出口") }
                        let id = exit.hasPrefix("profile:") ? UUID(uuidString:String(exit.dropFirst(8))):nil
                        let target = exit.hasPrefix("policy:") ? String(exit.dropFirst(7)):nil
                        let additions = try CompositionRouting.batch(text,type:type,profileID:id,target:target,existing:routes)
                        routes.append(contentsOf:additions); dismiss()
                    } catch { failure = Redactor.clean(error.localizedDescription) }
                }.buttonStyle(LumaPrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(!policiesReady)
            }
        }.padding(24).frame(width:620).onAppear { exit = profiles.first.map { "profile:"+$0.id.uuidString } ?? "policy:DIRECT" }
    }
}
