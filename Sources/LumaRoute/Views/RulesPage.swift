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
        VStack(spacing:16) {
            PageHeader(title:"规则") {
                if tab == "custom" { Button("添加规则") { draft.append(CustomRule()); tab="custom" }.buttonStyle(.borderedProminent) }
            }
            HStack(spacing:12) {
                SearchField(placeholder:"搜索域名、IP、应用或策略",text:$search)
                Picker("规则分类",selection:$tab) { Text("自定义规则").tag("custom"); Text("组合分流").tag("domains"); Text("应用分流").tag("apps"); Text("规则订阅").tag("providers"); Text("生效规则").tag("live") }.labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            if tab == "custom" { custom }
            else if tab == "domains" { DomainRoutingView() }
            else if tab == "apps" { ApplicationRoutingView(onShowComposition:{ tab = "domains" }) }
            else if tab == "providers" { RuleSubscriptionsView(search:search) }
            else { live }
        }.onAppear { if !initialized { draft=store.currentCustomRules; initialized=true } }
         .onChange(of:store.database.activeProfileID) { _,_ in draft=store.currentCustomRules }
         .onChange(of:store.currentCustomRules) { _,rules in draft=rules }
    }
    private var custom:some View {
        VStack(spacing:14) {
            HStack(spacing:8) { Text("启用").frame(width:30); Text("类型").frame(width:140,alignment:.leading); Text("匹配内容").frame(maxWidth:.infinity,alignment:.leading); Text("目标策略").frame(width:200,alignment:.leading); Spacer().frame(width:90) }
                .font(.system(size:12)).foregroundStyle(.secondary).padding(.horizontal,14)
            List {
                ForEach($draft) { $rule in
                    if search.isEmpty || rule.payload.localizedCaseInsensitiveContains(search) || rule.target.localizedCaseInsensitiveContains(search) || rule.type.localizedCaseInsensitiveContains(search) {
                        HStack(spacing:8) {
                            Toggle("启用规则",isOn:$rule.enabled).labelsHidden().toggleStyle(.checkbox).frame(width:30)
                            LumaPicker("规则类型",selection:$rule.type,value:CompositionRouting.types.first { $0.value == rule.type }?.label ?? rule.type) {
                                Text("域名").tag("DOMAIN"); Text("域名后缀").tag("DOMAIN-SUFFIX"); Text("域名关键词").tag("DOMAIN-KEYWORD"); Text("IP 网段").tag("IP-CIDR"); Text("IPv6 网段").tag("IP-CIDR6"); Text("进程名称").tag("PROCESS-NAME"); Text("进程路径").tag("PROCESS-PATH")
                            }.frame(width:140)
                            TextField("匹配内容",text:$rule.payload).textFieldStyle(LumaTextFieldStyle()).accessibilityLabel("规则匹配内容")
                            LumaPicker("目标策略",selection:$rule.target,value:rule.target == "DIRECT" ? "直连":rule.target == "REJECT" ? "拒绝":rule.target) {
                                Text("直连").tag("DIRECT"); Text("拒绝").tag("REJECT"); ForEach(store.groups) { Text($0.name).tag($0.name) }
                                if !["DIRECT","REJECT"].contains(rule.target),!store.groups.contains(where:{$0.name == rule.target}) { Text("已失效："+rule.target).tag(rule.target) }
                            }.frame(width:200)
                            RuleOrderButtons(canMoveUp:search.isEmpty && draft.first?.id != rule.id,canMoveDown:search.isEmpty && draft.last?.id != rule.id,moveUp:{ moveRule(rule.id,direction:-1) },moveDown:{ moveRule(rule.id,direction:1) })
                            Button { draft.removeAll { $0.id==rule.id } } label:{ Image(systemName:"trash").frame(width:28,height:LumaControl.height) }.buttonStyle(.borderless).help("删除规则").accessibilityLabel("删除规则")
                        }.padding(.horizontal,14).padding(.vertical,8)
                        .background(LumaPalette.card,in:RoundedRectangle(cornerRadius:12,style:.continuous))
                        .listRowSeparator(.hidden).listRowBackground(Color.clear).listRowInsets(EdgeInsets(top:3,leading:0,bottom:3,trailing:0))
                        .moveDisabled(!search.isEmpty)
                    }
                }.onMove { if search.isEmpty { draft.move(fromOffsets:$0,toOffset:$1) } }
            }.listStyle(.plain).scrollContentBackground(.hidden).padding(.horizontal,-8)
                .overlay {
                    if draft.isEmpty { EmptyMessage(icon:"list.bullet.rectangle",title:"暂无自定义规则",detail:"使用“添加规则”创建规则；订阅规则仍会正常生效。") }
                }
            orderPanel
            HStack(spacing:8) {
                Text(draft==store.currentCustomRules ? "修改已应用":"有未应用的修改").font(.system(size:12)).foregroundStyle(.secondary)
                Spacer(); Button("撤销") { draft=store.currentCustomRules }
                Button("应用更改") { let rules=draft; store.perform { try await store.applyRules(rules) } }.buttonStyle(.borderedProminent).disabled(store.busy || draft==store.currentCustomRules)
            }
        }
    }
    private var orderPanel:some View {
        let steps = store.activeProfile?.composition != nil ? ["自定义规则","组合分流","优先规则订阅","基础订阅规则","补充规则订阅","兜底出口"]:["自定义规则","优先规则订阅","机场原规则","补充规则订阅","机场兜底规则"]
        return Panel {
            VStack(alignment:.leading,spacing:12) {
                Text("规则执行顺序").font(.system(size:14,weight:.semibold))
                FlowLayout(spacing:6) {
                    ForEach(Array(steps.enumerated()),id:\.offset) { index,step in
                        HStack(spacing:6) {
                            if index > 0 { Image(systemName:"chevron.right").font(.system(size:10,weight:.bold)).foregroundStyle(.tertiary) }
                            Text(step).font(.system(size:12,weight:.medium)).padding(.horizontal,10).padding(.vertical,5).background(LumaPalette.tile,in:Capsule())
                        }
                    }
                }
                Text("首个匹配生效。规则订阅默认只在机场原规则未匹配时补充；自定义规则和规则订阅会在机场更新后保留。").font(.system(size:12)).foregroundStyle(.secondary)
            }
        }
    }
    private var live:some View {
        Table(store.liveRules.filter { search.isEmpty || $0.payload.localizedCaseInsensitiveContains(search) || $0.proxy.localizedCaseInsensitiveContains(search) }) {
            TableColumn("类型",value:\.type).width(150)
            TableColumn("匹配内容",value:\.payload)
            TableColumn("目标策略",value:\.proxy).width(180)
        }.scrollContentBackground(.hidden).alternatingRowBackgrounds(.disabled)
            .background(LumaPalette.card,in:RoundedRectangle(cornerRadius:LumaPalette.cardRadius,style:.continuous))
            .clipShape(RoundedRectangle(cornerRadius:LumaPalette.cardRadius,style:.continuous))
    }
    func moveRule(_ id:UUID,direction:Int) {
        guard let index=draft.firstIndex(where:{$0.id == id}),draft.indices.contains(index+direction) else { return }
        draft.swapAt(index,index+direction)
    }
}
