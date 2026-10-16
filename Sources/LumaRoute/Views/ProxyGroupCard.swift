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
    /// The real exit this group currently resolves to, following nested groups.
    private var leaf: ProxyNode? {
        var next = group.now
        var visited: Set<String> = [group.name]
        while let name = next,visited.insert(name).inserted,let node = store.proxies[name] {
            if !node.isGroup { return node }
            next = node.now
        }
        return nil
    }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            header
            if expanded { details }
        }
        .background(LumaPalette.card,in:RoundedRectangle(cornerRadius:LumaPalette.cardRadius,style:.continuous))
        .onChange(of:filter.search) { if !filter.search.isEmpty { expanded = true } }
        .sheet(isPresented:$editingStrategy) {
            if let profileID = store.database.activeProfileID {
                GroupStrategySheet(group:group,draft:store.strategy(for:group.name) ?? GroupStrategy(profileID:profileID,group:group.name)).environmentObject(store)
            }
        }
    }
    private var header: some View {
        HStack(spacing:12) {
            Button { withAnimation(.easeInOut(duration:0.18)) { expanded.toggle() } } label: {
                HStack(spacing:12) {
                    Image(systemName:"chevron.right").font(.system(size:11,weight:.bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90:0)).frame(width:14)
                    VStack(alignment:.leading,spacing:5) {
                        HStack(spacing:9) {
                            Text(group.name).font(.system(size:15,weight:.semibold))
                            Text(kind).font(.system(size:11,weight:.medium)).foregroundStyle(.secondary).padding(.horizontal,8).padding(.vertical,3).background(LumaPalette.tile,in:Capsule())
                        }
                        Text(store.selectionChain(for:group)).font(.system(size:12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength:0)
                }.padding(.leading,16).padding(.vertical,13).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(expanded ? "收起" : "展开") \(group.name)")
            if let delay = leaf?.delay { LatencyChip(delay:delay) }
            Text("\(group.all?.count ?? 0)").font(.system(size:12,weight:.medium)).monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth:30,minHeight:24).background(LumaPalette.tile,in:Capsule()).help("此组的候选项数量，包含节点和策略组")
            iconButton("speedometer",help:"测试 \(group.name) 的节点延迟",label:"测速 \(group.name)") { store.testNodes(nodes.filter { !$0.isGroup }) }
                .disabled(!store.coreReady || store.testRunning)
            if group.name != "GLOBAL" {
                iconButton("slider.horizontal.3",help:"设置 \(group.name) 的自动选择或故障转移策略",label:"策略设置 \(group.name)") { editingStrategy = true }
                    .disabled(store.activeProfile == nil || store.busy)
            }
            if ["URLTest","Fallback"].contains(group.type),group.fixed?.isEmpty == false { Button("恢复自动") { store.resumeAuto(group:group.name) } }
        }.padding(.trailing,16)
    }
    private func iconButton(_ symbol:String,help:String,label:String,action:@escaping ()->Void)->some View {
        Button(action:action) { Image(systemName:symbol).font(.system(size:14)).foregroundStyle(.secondary).frame(width:28,height:28).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(help).accessibilityLabel(label)
    }
    private var details: some View {
        let items = nodes
        return VStack(spacing:12) {
            HStack(spacing:12) {
                Text("\(items.count) 个候选项").font(.system(size:12)).foregroundStyle(.secondary)
                Spacer()
                Toggle("延迟优先",isOn:$sortByDelay).toggleStyle(.checkbox)
                Button("使用选中节点") { if let selection { store.select(group:group.name,node:selection) } }
                    .disabled(selection == nil || !items.contains { $0.name == selection } || !canSelect)
            }
            ScrollView {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:220),spacing:8)],spacing:8) {
                    ForEach(items) { nodeChip($0) }
                }.padding(2)
            }.frame(maxHeight:380)
        }.padding(.horizontal,16).padding(.bottom,16)
    }
    private func nodeChip(_ node: ProxyNode) -> some View {
        let current = node.name == group.now
        let picked = selection == node.name
        let shape = RoundedRectangle(cornerRadius:10,style:.continuous)
        return Button { selection = node.name } label: {
            HStack(spacing:8) {
                VStack(alignment:.leading,spacing:3) {
                    Text(node.name).font(.system(size:13,weight:.medium)).lineLimit(1).truncationMode(.middle)
                    Text(status(node,current:current)).font(.system(size:11)).lineLimit(1)
                        .foregroundStyle(current ? LumaPalette.accent:node.alive == false ? Color.red:Color.secondary)
                }
                Spacer(minLength:4)
                if node.isGroup { Image(systemName:"point.3.connected.trianglepath.dotted").foregroundStyle(.secondary) }
                else { LatencyChip(delay:node.delay,failed:store.nodeErrors[node.name] != nil) }
            }.padding(.horizontal,12).padding(.vertical,10).frame(maxWidth:.infinity,alignment:.leading)
                .background(current ? LumaPalette.accent.opacity(0.14):LumaPalette.tile,in:shape)
                .overlay(shape.stroke(LumaPalette.accent,lineWidth:picked ? 2:0))
                .contentShape(shape)
        }.buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count:2).onEnded { if canSelect { store.select(group:group.name,node:node.name) } })
        .contextMenu {
            Button("使用此节点") { store.select(group:group.name,node:node.name) }.disabled(!canSelect)
            if !node.isGroup { Button("测试延迟") { store.testNodes([node]) } }
        }
        .accessibilityAddTraits(picked ? [.isSelected]:[])
    }
    private func status(_ node: ProxyNode,current: Bool) -> String {
        if current { return "当前使用" }
        if node.alive == false { return "不可用" }
        if node.isGroup { return "策略组 · 跟随策略" }
        return node.providerName ?? store.activeProfile?.name ?? "配置"
    }
}
