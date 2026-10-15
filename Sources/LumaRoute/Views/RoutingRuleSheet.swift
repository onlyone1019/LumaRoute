import SwiftUI
import UniformTypeIdentifiers
import LumaRouteCore

struct RoutingRuleSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var rule: CustomRule
    @State private var profileID: UUID?
    @State private var importing = false
    @State private var failure: String?
    private var isApplication: Bool { rule.type.hasPrefix("PROCESS-") }
    init(rule: CustomRule,profileID: UUID?) { _rule = State(initialValue:rule); _profileID = State(initialValue:profileID) }
    private var replaces: Bool { store.currentCustomRules.contains { $0.id != rule.id && $0.type == rule.type && $0.payload == rule.payload } }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(isApplication ? "应用分流":"从连接创建分流").font(.title2.bold())
            Text("生效配置："+(store.activeProfile?.name ?? "未选择")).foregroundStyle(.secondary)
            Picker("匹配方式",selection:$rule.type) {
                if isApplication { Text("完整进程路径").tag("PROCESS-PATH"); Text("进程名称").tag("PROCESS-NAME") }
                else { Text("完整域名").tag("DOMAIN"); Text("域名及子域名").tag("DOMAIN-SUFFIX"); Text("IPv4 地址 / 网段").tag("IP-CIDR"); Text("IPv6 地址 / 网段").tag("IP-CIDR6") }
            }
            HStack {
                TextField(isApplication ? "可执行文件路径或进程名称":"域名或 IP 网段",text:$rule.payload).textFieldStyle(.roundedBorder).accessibilityLabel("分流匹配内容")
                if isApplication { Button("选择应用…") { importing = true } }
            }
            if isApplication { Text("选择应用会填入主进程路径。浏览器等应用可能使用辅助进程，请从实际连接创建对应规则，或填写辅助进程名称。").font(.caption).foregroundStyle(.secondary) }
            Picker("目标出口",selection:$rule.target) {
                ForEach(store.routingTargets,id:\.name) { Text($0.label).tag($0.name) }
                if !store.routingTargets.contains(where:{$0.name == rule.target}) { Text("原目标已不存在："+rule.target).tag(rule.target) }
            }
            Toggle("启用规则",isOn:$rule.enabled).toggleStyle(.checkbox)
            Text("保存后置于自定义规则首位，优先于域名分流和订阅规则。仅在规则模式下生效，新连接使用新规则。").font(.caption).foregroundStyle(.secondary)
            if replaces { Text("已存在相同匹配条件，保存将替换它。").foregroundStyle(.orange) }
            if let failure { Text(failure).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true) }
            HStack {
                Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(replaces ? "保存并替换":"保存并应用") {
                    store.perform {
                        do {
                            var proposed = rule
                            proposed.payload = proposed.payload.trimmingCharacters(in:.whitespacesAndNewlines)
                            if ["DOMAIN","DOMAIN-SUFFIX"].contains(proposed.type) {
                                var route = SubscriptionDomainRoute(); route.type = proposed.type; route.domain = proposed.payload
                                proposed.payload = try route.normalizedDomain()
                            }
                            try await store.saveRoutingRule(proposed,profileID:profileID); dismiss()
                        } catch { failure = Redactor.clean(error.localizedDescription) }
                    }
                }.buttonStyle(LumaPrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(store.activeProfile == nil || rule.payload.isEmpty)
            }
        }.padding(24).frame(width:620).disabled(store.busy)
         .fileImporter(isPresented:$importing,allowedContentTypes:[.applicationBundle]) { result in
             do {
                 let url = try result.get()
                 guard let executable = Bundle(url:url)?.executableURL else { throw LumaError.message("无法读取该应用的主进程，请手动填写进程名称或路径") }
                 rule.type = "PROCESS-PATH"; rule.payload = executable.path; failure = nil
             } catch { failure = Redactor.clean(error.localizedDescription) }
         }
    }
}

struct ApplicationRoutingView: View {
    var onShowComposition: (() -> Void)? = nil
    private var compositionRuleCount: Int { store.activeProfile?.composition?.domainRoutes.filter { $0.type.hasPrefix("PROCESS-") }.count ?? 0 }
    @EnvironmentObject var store: AppStore
    @State private var editing: CustomRule?
    private var rules: [CustomRule] { store.currentCustomRules.filter { $0.type.hasPrefix("PROCESS-") } }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text("应用分流").font(.headline); Spacer()
                Button("添加应用") { editing = CustomRule(type:"PROCESS-PATH") }.disabled(store.busy || store.activeProfile == nil)
            }
            Text("按实际联网进程匹配。流量必须先进入 LumaRoute；TUN 可接管不遵循系统代理的应用。应用规则与其他自定义规则按统一顺序匹配。").font(.caption).foregroundStyle(.secondary)
            if !store.helperActive {
                HStack {
                    Text("本机进程识别需要已授权的后台服务；普通用户态内核可能无法匹配应用。").font(.caption).foregroundStyle(.orange)
                    Button("前往网络设置") { store.settingsTab = "网络"; store.page = .settings }
                }
            }
            if store.database.settings.mode != .rule {
                HStack { Text("当前不是规则模式，应用分流暂不生效。").foregroundStyle(.orange); Button("切换规则模式") { store.setMode(.rule) }.disabled(store.busy) }
            }
            if compositionRuleCount > 0 {
                HStack {
                    Text("当前组合另有 \(compositionRuleCount) 条应用规则，在组合分流中管理。").font(.caption).foregroundStyle(.secondary)
                    if let onShowComposition { Button("管理组合规则",action:onShowComposition) }
                }
            }
            if rules.isEmpty { EmptyMessage(icon:"app.badge.checkmark",title:compositionRuleCount > 0 ? "暂无自定义应用规则":"暂无应用分流",detail:"选择一个应用，或从连接列表为实际进程创建规则。") }
            else {
                List(rules) { rule in
                    HStack {
                        Toggle("启用应用规则",isOn:Binding(get:{rule.enabled},set:{ enabled in
                            var updated = store.currentCustomRules
                            if let index = updated.firstIndex(where:{$0.id == rule.id}) { updated[index].enabled = enabled }
                            store.perform { try await store.applyRules(updated) }
                        })).labelsHidden().toggleStyle(.checkbox)
                        VStack(alignment:.leading,spacing:4) { Text(rule.payload).lineLimit(2); Text((rule.type == "PROCESS-PATH" ? "完整路径":"进程名称")+" → "+(store.routingTargets.first(where:{$0.name == rule.target})?.label ?? rule.target)).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("编辑") { editing = rule }
                        Button("删除") { let updated = store.currentCustomRules.filter { $0.id != rule.id }; store.perform { try await store.applyRules(updated) } }
                    }.padding(.vertical,5).disabled(store.busy)
                }.listStyle(.inset)
            }
        }.sheet(item:$editing) { RoutingRuleSheet(rule:$0,profileID:store.database.activeProfileID) }
    }
}
