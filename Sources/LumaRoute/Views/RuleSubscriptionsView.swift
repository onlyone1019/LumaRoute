import SwiftUI
import LumaRouteCore

struct RuleSubscriptionsView: View {
    @EnvironmentObject var store: AppStore
    var search: String
    @State private var editing: RuleSubscription?
    private var items: [RuleSubscription] { store.currentRuleSubscriptions }
    var body: some View {
        VStack(spacing:14) {
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Text(store.activeProfile.map { "绑定配置："+$0.name } ?? "请先启用一个配置").font(.headline)
                    Text("Loyalsoldier / clash-rules · 默认每 24 小时更新 · 下载失败保留旧规则").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("更新全部规则集") { store.perform { try await store.updateAllRuleSubscriptions() } }.disabled(store.busy || items.isEmpty)
                Button("添加规则订阅") {
                    guard let id = store.database.activeProfileID else { return }
                    let available = RuleCatalogEntry.all.first { entry in !items.contains(where:{$0.catalogID == entry.id}) } ?? RuleCatalogEntry.all[0]
                    editing = RuleSubscription(profileID:id,catalogID:available.id,target:available.defaultTarget.isEmpty ? store.groups.first?.name ?? "DIRECT":available.defaultTarget)
                }.buttonStyle(LumaPrimaryButtonStyle()).disabled(store.busy || store.database.activeProfileID == nil || items.count >= RuleCatalogEntry.all.count)
            }
            if items.isEmpty {
                EmptyMessage(icon:"square.stack.3d.up",title:"暂无规则订阅",detail:"添加广告拦截、国内直连等规则集，再选择它使用的策略组。机场原分流规则会保留。")
            } else {
                ScrollView {
                    LazyVStack(spacing:10) {
                        ForEach(items.filter { item in search.isEmpty || item.target.localizedCaseInsensitiveContains(search) || ((try? RuleCatalogEntry.entry(item.catalogID).title) ?? item.catalogID).localizedCaseInsensitiveContains(search) }) { item in
                            RuleSubscriptionRow(item:item,first:items.first?.id == item.id,last:items.last?.id == item.id,edit:{ editing=item })
                        }
                    }
                }
            }
            Panel {
                VStack(alignment:.leading,spacing:6) {
                    Text("机场规则优先，补充规则在兜底前生效").font(.headline)
                    Text("同一优先级按列表顺序匹配。广告等规则若需优先拦截，可在设置中选择“优先于机场规则”；这会覆盖命中它的机场分流。规则订阅仅对当前配置生效，单订阅和组合配置分别保存。").font(.caption).foregroundStyle(.secondary)
                    Link("查看规则来源与说明",destination:URL(string:"https://github.com/Loyalsoldier/clash-rules")!).font(.caption)
                }
            }
        }.sheet(item:$editing) { RuleSubscriptionSheet(item:$0) }
    }
}

private struct RuleSubscriptionRow: View {
    @EnvironmentObject var store: AppStore
    let item: RuleSubscription
    let first: Bool
    let last: Bool
    let edit: () -> Void
    var body: some View {
        Panel {
            HStack(alignment:.top,spacing:12) {
                Toggle("启用规则订阅",isOn:Binding(get:{item.enabled},set:{ value in
                    var next=item; next.enabled=value; store.perform { try await store.saveRuleSubscription(next) }
                })).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(store.busy)
                VStack(alignment:.leading,spacing:5) {
                    Text((try? RuleCatalogEntry.entry(item.catalogID).title) ?? item.catalogID).font(.headline)
                    Text("\(item.ruleCount.formatted()) 条 · \(item.target) · \(item.priority.label)").font(.callout)
                    Text((item.lastUpdated.map { "上次更新 "+$0.formatted(date:.abbreviated,time:.shortened) } ?? "尚未下载") + (item.autoUpdate ? " · 每 \(item.intervalHours) 小时更新":" · 自动更新已关闭")).font(.caption).foregroundStyle(.secondary)
                    if let problem=store.ruleSubscriptionProblem(item) { Text(problem).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                }.frame(maxWidth:.infinity,alignment:.leading)
                Button("更新规则集") { store.perform { try await store.updateRuleSubscription(item) } }
                Button("设置规则集",action:edit)
                Menu {
                    Button("上移") { store.perform { try await store.moveRuleSubscription(item,direction:-1) } }.disabled(first)
                    Button("下移") { store.perform { try await store.moveRuleSubscription(item,direction:1) } }.disabled(last)
                    Divider()
                    Button("删除规则订阅",role:.destructive) { store.perform { try await store.deleteRuleSubscription(item) } }
                } label: { Image(systemName:"ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("规则订阅更多操作")
            }.disabled(store.busy)
        }
    }
}

private struct RuleSubscriptionSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var item: RuleSubscription
    @State private var error: String?
    private var available: [RuleCatalogEntry] {
        RuleCatalogEntry.all.filter { entry in item.catalogID == entry.id || !store.currentRuleSubscriptions.contains(where:{$0.catalogID == entry.id}) }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text(item.revision == nil ? "添加规则订阅":"规则订阅设置").font(.title2.weight(.semibold))
            Form {
                Picker("规则集",selection:$item.catalogID) { ForEach(available) { Text($0.title).tag($0.id) } }.disabled(item.revision != nil)
                if let entry=try? RuleCatalogEntry.entry(item.catalogID) {
                    Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                    Text(entry.url.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Picker("目标策略",selection:$item.target) {
                    ForEach(store.ruleSubscriptionTargets,id:\.self) { Text($0 == "DIRECT" ? "直连 (DIRECT)":$0 == "REJECT" ? "拦截 (REJECT)":$0).tag($0) }
                    if !store.ruleSubscriptionTargets.contains(item.target) { Text("已失效："+item.target).tag(item.target) }
                }
                Picker("匹配优先级",selection:$item.priority) { ForEach(RuleSubscriptionPriority.allCases) { Text($0.label).tag($0) } }
                Text(item.priority == .supplement ? "机场已命中的流量保持原分流，只有未命中的流量才尝试此规则集。":"此规则集会先于机场规则匹配，可能改变机场对相关流量的分流。").font(.caption).foregroundStyle(item.priority == .override ? .orange:Color.secondary)
                Toggle("自动更新",isOn:$item.autoUpdate)
                Picker("更新间隔",selection:$item.intervalHours) { ForEach([1,6,12,24,48,168],id:\.self) { Text("\($0) 小时").tag($0) } }.disabled(!item.autoUpdate)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                Text("仅用于当前机场配置 · 原始配置文件不改写").font(.caption).foregroundStyle(.secondary)
                Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(item.revision == nil ? "下载并添加":"保存并应用") {
                    store.perform {
                        do { try await store.saveRuleSubscription(item); dismiss() }
                        catch { self.error = Redactor.clean(error.localizedDescription) }
                    }
                }.buttonStyle(LumaPrimaryButtonStyle()).disabled(store.busy || (item.enabled && !store.ruleSubscriptionTargets.contains(item.target))).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width:650).disabled(store.busy)
        .onChange(of:item.catalogID) { _,id in
            if let entry=try? RuleCatalogEntry.entry(id) { item.target = entry.defaultTarget.isEmpty ? store.groups.first?.name ?? "DIRECT":entry.defaultTarget }
        }
    }
}
