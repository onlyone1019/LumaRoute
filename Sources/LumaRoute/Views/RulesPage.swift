import SwiftUI
import LumaRouteCore

struct RulesPage:View {
    @EnvironmentObject var store:AppStore
    @State private var draft:[CustomRule]=[]
    @State private var search=""
    @State private var tab="custom"
    @State private var adding=false
    @State private var initialized=false
    var body:some View {
        VStack(spacing:18) {
            PageHeader(title:"规则") {
                if tab == "custom" { Button("添加规则") { draft.append(CustomRule()); tab="custom" }.buttonStyle(LumaPrimaryButtonStyle()) }
            }
            HStack { SearchField(placeholder:"搜索域名、IP、应用或策略",text:$search); Picker("",selection:$tab) { Text("自定义规则").tag("custom"); Text("组合分流").tag("domains"); Text("应用分流").tag("apps"); Text("规则订阅").tag("providers"); Text("生效规则").tag("live") }.pickerStyle(.segmented).frame(width:500) }
            if tab == "custom" {
                HStack { Text("启用").frame(width:45); Text("类型").frame(width:140); Text("匹配内容").frame(maxWidth:.infinity,alignment:.leading); Text("目标策略").frame(width:180); Spacer().frame(width:45) }.foregroundStyle(.secondary)
                List {
                    ForEach($draft) { $rule in
                        if search.isEmpty || rule.payload.localizedCaseInsensitiveContains(search) || rule.target.localizedCaseInsensitiveContains(search) || rule.type.localizedCaseInsensitiveContains(search) {
                        HStack {
                            Toggle("",isOn:$rule.enabled).labelsHidden().frame(width:45)
                            Picker("",selection:$rule.type) {
                                Text("域名").tag("DOMAIN"); Text("域名后缀").tag("DOMAIN-SUFFIX"); Text("域名关键词").tag("DOMAIN-KEYWORD"); Text("IP 网段").tag("IP-CIDR"); Text("IPv6 网段").tag("IP-CIDR6"); Text("进程名称").tag("PROCESS-NAME"); Text("进程路径").tag("PROCESS-PATH")
                            }.frame(width:140)
                            TextField("匹配内容",text:$rule.payload).textFieldStyle(.roundedBorder)
                            Picker("",selection:$rule.target) { Text("直连").tag("DIRECT"); Text("拒绝").tag("REJECT"); ForEach(store.groups) { Text($0.name).tag($0.name) } }.frame(width:180)
                            VStack(spacing:2) {
                                Button { moveRule(rule.id,direction:-1) } label:{ Image(systemName:"chevron.up") }.disabled(!search.isEmpty || draft.first?.id == rule.id)
                                Button { moveRule(rule.id,direction:1) } label:{ Image(systemName:"chevron.down") }.disabled(!search.isEmpty || draft.last?.id == rule.id)
                            }.buttonStyle(.borderless)
                            Button { draft.removeAll { $0.id==rule.id } } label:{ Image(systemName:"trash") }.buttonStyle(.borderless)
                        }.padding(.vertical,6)
                        .moveDisabled(!search.isEmpty)
                        }
                    }.onMove { if search.isEmpty { draft.move(fromOffsets:$0,toOffset:$1) } }
                }.listStyle(.inset)
                    .overlay {
                        if draft.isEmpty { EmptyMessage(icon:"list.bullet.rectangle",title:"暂无自定义规则",detail:"使用“添加规则”创建规则；订阅规则仍会正常生效。") }
                    }
                Panel {
                    VStack(alignment:.leading,spacing:12) {
                        Text("规则执行顺序").font(.headline)
                        Text(store.activeProfile?.composition != nil ? "自定义规则 → 组合分流 → 优先规则订阅 → 基础订阅规则 → 补充规则订阅 → 兜底出口":"自定义规则 → 优先规则订阅 → 机场原规则 → 补充规则订阅 → 机场兜底规则")
                        Text("首个匹配生效。规则订阅默认只在机场原规则未匹配时补充；自定义规则和规则订阅会在机场更新后保留。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(draft==store.currentCustomRules ? "修改已应用":"有未应用的修改").font(.caption).foregroundStyle(.secondary)
                    Spacer(); Button("撤销") { draft=store.currentCustomRules }
                    Button("应用更改") { let rules=draft; store.perform { try await store.applyRules(rules) } }.buttonStyle(LumaPrimaryButtonStyle()).disabled(store.busy || draft==store.currentCustomRules)
                }
            } else if tab == "domains" {
                DomainRoutingView()
            } else if tab == "apps" {
                ApplicationRoutingView(onShowComposition:{ tab = "domains" })
            } else if tab == "providers" {
                RuleSubscriptionsView(search:search)
            } else {
                Table(store.liveRules.filter { search.isEmpty || $0.payload.localizedCaseInsensitiveContains(search) || $0.proxy.localizedCaseInsensitiveContains(search) }) {
                    TableColumn("类型",value:\.type).width(150)
                    TableColumn("匹配内容",value:\.payload)
                    TableColumn("目标策略",value:\.proxy).width(180)
                }
            }
        }.onAppear { if !initialized { draft=store.currentCustomRules; initialized=true } }
         .onChange(of:store.database.activeProfileID) { _,_ in draft=store.currentCustomRules }
         .onChange(of:store.currentCustomRules) { _,rules in draft=rules }
    }
    func moveRule(_ id:UUID,direction:Int) {
        guard let index=draft.firstIndex(where:{$0.id == id}),draft.indices.contains(index+direction) else { return }
        draft.swapAt(index,index+direction)
    }
}

