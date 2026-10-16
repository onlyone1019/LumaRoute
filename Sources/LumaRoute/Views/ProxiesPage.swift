import SwiftUI
import LumaRouteCore

struct ProxyNodeFilter {
    var search = ""
    var region = "全部地区"
    var source = "全部来源"
    func includes(_ node: ProxyNode, profile: String?) -> Bool {
        (search.isEmpty || node.name.localizedCaseInsensitiveContains(search)) &&
        (source == "全部来源" || (node.providerName ?? profile ?? "配置") == source) &&
        (region != "日本" || node.name.range(of:"日本|东京|大阪|japan|tokyo|osaka|🇯🇵",options:[.regularExpression,.caseInsensitive]) != nil)
    }
}

struct ProxiesPage: View {
    @EnvironmentObject var store: AppStore
    @State private var filter = ProxyNodeFilter()
    var visibleGroups: [ProxyNode] {
        store.groups.filter { group in
            (filter.search.isEmpty && filter.region == "全部地区" && filter.source == "全部来源") ||
            (!filter.search.isEmpty && group.name.localizedCaseInsensitiveContains(filter.search)) ||
            (group.all ?? []).contains { name in store.proxies[name].map { filter.includes($0,profile:store.activeProfile?.name) } ?? false }
        }
    }
    var testCandidates: [ProxyNode] {
        let names = Set(visibleGroups.flatMap { $0.all ?? [] })
        return names.compactMap { store.proxies[$0] }.filter { !$0.isGroup && filter.includes($0,profile:store.activeProfile?.name) }.sorted { $0.name < $1.name }
    }
    var body: some View {
        VStack(spacing:14) {
            PageHeader(title:"代理",subtitle:store.database.settings.mode == .global ? "全局模式 · 在 GLOBAL 中选择节点" : "\(store.groups.count) 个策略组 · 按订阅顺序排列") {
                SearchField(placeholder:"搜索策略组或节点",text:$filter.search).frame(width:210)
                Button("测试全部") { store.testNodes(testCandidates) }.buttonStyle(LumaPrimaryButtonStyle()).disabled(!store.coreReady || testCandidates.isEmpty)
            }
            HStack {
                Picker("代理模式",selection:Binding(get:{store.database.settings.mode},set:{store.setMode($0)})) {
                    ForEach(RouteMode.allCases) { Text($0.label).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).frame(width:200)
                Spacer()
                LumaPicker("地区",selection:$filter.region,value:filter.region) { Text("全部地区").tag("全部地区"); Text("日本").tag("日本") }.frame(width:150)
                LumaPicker("来源",selection:$filter.source,value:filter.source) {
                    Text("全部来源").tag("全部来源")
                    ForEach(Array(Set(store.proxies.values.filter { !$0.isGroup }.map { $0.providerName ?? store.activeProfile?.name ?? "配置" })).sorted(),id:\.self) { Text($0).tag($0) }
                }.frame(width:180)
            }.controlSize(.regular).padding(.vertical,4)
            if store.groups.isEmpty { EmptyMessage(title:"尚无策略组",detail:"导入并启用订阅后，策略组与节点会显示在这里。") }
            else {
                ScrollView {
                    LazyVStack(spacing:8) {
                        ForEach(visibleGroups) { group in ProxyGroupCard(group:group,filter:filter) }
                        if visibleGroups.isEmpty { EmptyMessage(icon:"magnifyingglass",title:"没有匹配的策略组",detail:"试试其他关键词、地区或来源。") }
                    }
                }
                HStack {
                    Text("展开分组查看候选节点；选择其他策略组时保留代理链关系").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if store.testTotal > 0 {
                        Text("\(store.testRunning ? "测试" : store.testProgress == store.testTotal ? "已完成" : "已停止") \(store.testProgress)/\(store.testTotal)").font(.caption).monospacedDigit()
                        if store.testRunning { Button("停止") { store.cancelTests() } }
                    }
                }
            }
        }
    }
}
