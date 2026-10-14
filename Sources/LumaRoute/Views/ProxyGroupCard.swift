import SwiftUI
import LumaRouteCore

struct ProxyGroupCard: View {
    @EnvironmentObject var store: AppStore
    let group: ProxyNode
    let filter: ProxyNodeFilter
    @State private var expanded = false
    @State private var selection: String?
    @State private var sortByDelay = false
    @State private var editingStrategy = false
    var nodes: [ProxyNode] {
        let items = (group.all ?? []).compactMap { store.proxies[$0] }.filter { filter.includes($0,profile:store.activeProfile?.name) || (!filter.search.isEmpty && group.name.localizedCaseInsensitiveContains(filter.search)) }
        return sortByDelay ? items.sorted { ($0.delay ?? Int.max,$0.name) < ($1.delay ?? Int.max,$1.name) } : items
    }
    var kind: String {
        switch group.type { case "Selector": return "手动选择"; case "URLTest": return group.fixed?.isEmpty == false ? "自动选择 · 已固定" : "自动选择"; case "Fallback": return group.fixed?.isEmpty == false ? "故障转移 · 已固定" : "故障转移"; case "LoadBalance": return "负载均衡"; default: return group.type }
    }
    var canSelect: Bool { group.type != "LoadBalance" && store.coreReady && !store.busy }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:12) {
                Button { withAnimation(.easeInOut(duration:0.15)) { expanded.toggle() } } label: {
                    HStack(spacing:12) {
                        Image(systemName:expanded ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width:12)
                        VStack(alignment:.leading,spacing:5) {
                            HStack(spacing:9) {
                                Text(group.name).font(.system(size:14,weight:.semibold))
                                Text(kind).font(.system(size:10,weight:.medium)).foregroundStyle(.secondary).padding(.horizontal,7).padding(.vertical,3).background(Color.primary.opacity(0.045),in:Capsule())
                            }
                            Text(store.selectionChain(for:group)).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(expanded ? "收起" : "展开") \(group.name)")
                Text("\(group.all?.count ?? 0)").font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(LumaPalette.accent).frame(minWidth:28,minHeight:25).background(LumaPalette.accent.opacity(0.08),in:Capsule()).help("此组的候选项数量，包含节点和策略组")
                Button { store.testNodes(nodes.filter { !$0.isGroup }) } label: { Image(systemName:"speedometer").frame(width:24,height:24) }.buttonStyle(.borderless).help("测试 \(group.name) 的节点延迟").accessibilityLabel("测速 \(group.name)").disabled(!store.coreReady || store.testRunning)
                if group.name != "GLOBAL" { Button { editingStrategy = true } label: { Image(systemName:"slider.horizontal.3").frame(width:24,height:24) }.buttonStyle(.borderless).help("设置 \(group.name) 的自动选择或故障转移策略").accessibilityLabel("策略设置 \(group.name)").disabled(store.activeProfile == nil || store.busy) }
                if ["URLTest","Fallback"].contains(group.type), group.fixed?.isEmpty == false { Button("恢复自动") { store.resumeAuto(group:group.name) } }
            }.padding(.horizontal,14).padding(.vertical,10)
            if expanded {
                Divider()
                VStack(spacing:10) {
                    HStack {
                        Text("\(nodes.count) 个候选项").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Toggle("延迟优先",isOn:$sortByDelay).toggleStyle(.checkbox)
                        Button("使用选中节点") { if let selection { store.select(group:group.name,node:selection) } }.disabled(selection == nil || !nodes.contains { $0.name == selection } || !canSelect)
                    }
                    Table(nodes,selection:$selection) {
                        TableColumn("节点 / 策略组") { node in
                            HStack {
                                Image(systemName:node.name == group.now ? "checkmark.circle.fill" : node.isGroup ? "point.3.connected.trianglepath.dotted" : "circle").foregroundStyle(node.name == group.now ? .blue:.secondary)
                                Text(node.name)
                            }
                        }.width(min:220,ideal:350)
                        TableColumn("来源") { node in Text(node.isGroup ? "策略组" : node.providerName ?? store.activeProfile?.name ?? "配置") }.width(min:100,ideal:160)
                        TableColumn("延迟") { node in
                            Text(node.isGroup ? "—" : store.nodeErrors[node.name] != nil ? "失败" : node.delay.map { "\($0) ms" } ?? "未测试").foregroundStyle(store.nodeErrors[node.name] != nil ? .red:node.delay != nil ? .green:.secondary)
                        }.width(90)
                        TableColumn("状态") { node in Text(node.name == group.now ? "当前使用" : node.alive == false ? "不可用" : node.isGroup ? "跟随策略" : "可用") }.width(90)
                    }
                    .frame(height:min(390,CGFloat(max(1,nodes.count))*30+30))
                    .contextMenu(forSelectionType:String.self) { ids in
                        if let name = ids.first {
                            Button("使用此节点") { store.select(group:group.name,node:name) }.disabled(!canSelect)
                            if let node = store.proxies[name],!node.isGroup { Button("测试延迟") { store.testNodes([node]) } }
                        }
                    } primaryAction: { ids in if let name = ids.first,canSelect { store.select(group:group.name,node:name) } }
                }.padding(14)
            }
        }
        .controlSize(.regular)
        .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:10))
        .overlay(RoundedRectangle(cornerRadius:10).stroke(LumaPalette.border,lineWidth:1))
        .onChange(of:filter.search) { if !filter.search.isEmpty { expanded = true } }
        .sheet(isPresented:$editingStrategy) {
            if let profileID = store.database.activeProfileID {
                GroupStrategySheet(group:group,draft:store.strategy(for:group.name) ?? GroupStrategy(profileID:profileID,group:group.name)).environmentObject(store)
            }
        }
    }
}
