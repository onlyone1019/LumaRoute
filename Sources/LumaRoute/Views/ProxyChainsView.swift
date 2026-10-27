import SwiftUI
import LumaRouteCore

struct ProxyChainsView: View {
    @EnvironmentObject var store: AppStore
    @State private var editing: ProxyChain?
    private var chains: [ProxyChain] { store.activeProfile?.proxyChains ?? [] }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Text(store.activeProfile.map { "当前配置："+$0.name } ?? "请先启用订阅").font(.headline)
                    Text("电脑 → 前置节点 → VPS 落地 → 目标网站").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { editing = ProxyChain() } label: { Label("新建链路",systemImage:"plus") }
                    .buttonStyle(.borderedProminent).disabled(store.activeProfile == nil || !store.coreReady || store.busy)
            }
            Panel {
                VStack(alignment:.leading,spacing:6) {
                    Text("选择机场节点作前置，用 VPS 的 IP 访问目标网站。保存后，在“规则”中将需要的域名或应用指向“链式 · 链路名称”。")
                    Text("机场和 VPS 在不同订阅时，先前往“订阅 → 组合订阅”。链路仅用于当前配置，原节点仍可单独使用。").foregroundStyle(.secondary)
                    if !store.coreReady { Text("内核就绪后可从当前配置选择节点。").foregroundStyle(.orange) }
                }.font(.system(size:13)).fixedSize(horizontal:false,vertical:true)
            }
            if chains.isEmpty {
                EmptyMessage(icon:"point.3.connected.trianglepath.dotted",title:"尚未配置链式代理",detail:"先导入机场订阅和 VPS 节点，再新建链路选择前置与落地。")
            } else {
                ScrollView {
                    LazyVStack(spacing:10) {
                        ForEach(chains) { chain in chainRow(chain) }
                    }
                }
            }
        }
        .sheet(item:$editing) { chain in
            if let profileID = store.database.activeProfileID { ProxyChainSheet(chain:chain,profileID:profileID) }
        }
        .onChange(of:store.database.activeProfileID) { _,_ in editing = nil }
    }
    private func chainRow(_ chain: ProxyChain) -> some View {
        Panel {
            VStack(alignment:.leading,spacing:12) {
                HStack(spacing:12) {
                    Toggle("启用 "+chain.name,isOn:Binding(get:{chain.enabled},set:{ enabled in
                        var next = chains
                        guard let index = next.firstIndex(where:{$0.id == chain.id}),let profileID = store.database.activeProfileID else { return }
                        next[index].enabled = enabled
                        store.perform { try await store.saveProxyChains(next,profileID:profileID) }
                    })).labelsHidden().toggleStyle(.switch)
                    Text(chain.name).font(.system(size:15,weight:.semibold))
                    StatusPill(text:chain.enabled ? "已启用":"已停用",color:chain.enabled ? LumaPalette.accent:.secondary)
                    Spacer()
                    if let node = store.proxies[chain.groupName],chain.enabled {
                        LatencyChip(delay:node.delay,failed:store.nodeErrors[node.name] != nil)
                        Button("测试链路") { store.testNodes([node]) }.disabled(!store.coreReady || store.testRunning)
                    }
                    Button("编辑") { editing = chain }.disabled(!store.coreReady)
                    Button(role:.destructive) {
                        guard let profileID = store.database.activeProfileID else { return }
                        let next = chains.filter { $0.id != chain.id }
                        store.perform { try await store.saveProxyChains(next,profileID:profileID) }
                    } label: { Image(systemName:"trash").frame(width:24,height:24) }.buttonStyle(.borderless).help("删除链路").accessibilityLabel("删除 "+chain.name)
                }
                Text(chain.upstream+" → "+chain.landing).font(.system(size:13)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                HStack {
                    Text("分流出口："+chain.groupName).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("配置分流") { store.page = .rules }.disabled(!chain.enabled)
                }
            }
        }.disabled(store.busy)
    }
}

struct ProxyChainSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var chain: ProxyChain
    let profileID: UUID
    @State private var search = ""
    @State private var failure: String?
    private var candidates: [ProxyNode] {
        let chains = store.activeProfile?.proxyChains ?? []
        let excluded = Set(chains.map(\.groupName)+["GLOBAL","DIRECT","REJECT","REJECT-DROP","PASS","PASS-RULE","COMPATIBLE"])
        return store.proxies.values.filter {
            !excluded.contains($0.name) && !$0.name.hasPrefix("链路落地 · ") && $0.hidden != true &&
            !["direct","reject","pass","pass-rule","passrule","compatible","dns"].contains($0.type.lowercased())
        }.sorted { ($0.isGroup ? 0:1,$0.name) < ($1.isGroup ? 0:1,$1.name) }
    }
    private func options(landing: Bool) -> [ProxyNode] {
        candidates.filter { node in
            (!landing || !node.isGroup) && (search.isEmpty || node.name.localizedCaseInsensitiveContains(search) || node.name == (landing ? chain.landing:chain.upstream))
        }
    }
    private var validSelection: Bool {
        candidates.contains { $0.name == chain.upstream } && candidates.contains { !$0.isGroup && $0.name == chain.landing } && chain.upstream != chain.landing
    }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("配置链式代理").font(.title2.bold())
            TextField("链路名称，例如 香港到美国 VPS",text:$chain.name).textFieldStyle(LumaTextFieldStyle()).accessibilityLabel("链路名称")
            SearchField(placeholder:"筛选节点或策略组",text:$search)
            Panel {
                VStack(alignment:.leading,spacing:16) {
                    LumaPicker("前置",selection:Binding(get:{chain.upstream},set:{ name in
                        chain.upstream = name; chain.upstreamProvider = candidates.first { $0.name == name }?.providerName
                    }),value:chain.upstream.isEmpty ? "选择机场节点或策略组":chain.upstream,showsLabel:true) {
                        Text("选择前置").tag("")
                        ForEach(options(landing:false)) { node in Text(node.name+(node.isGroup ? "（策略组）":"")).tag(node.name) }
                        if !chain.upstream.isEmpty,!candidates.contains(where:{$0.name == chain.upstream}) { Text("已失效："+chain.upstream).tag(chain.upstream) }
                    }
                    Text("可选单个机场节点，或跟随现有策略组切换香港、日本等线路。").font(.caption).foregroundStyle(.secondary)
                    RowDivider()
                    LumaPicker("落地",selection:Binding(get:{chain.landing},set:{ name in
                        chain.landing = name; chain.landingProvider = candidates.first { $0.name == name }?.providerName
                    }),value:chain.landing.isEmpty ? "选择 VPS 节点":chain.landing,showsLabel:true) {
                        Text("选择落地").tag("")
                        ForEach(options(landing:true)) { Text($0.name).tag($0.name) }
                        if !chain.landing.isEmpty,!candidates.contains(where:{$0.name == chain.landing}) { Text("已失效："+chain.landing).tag(chain.landing) }
                    }
                    Text("目标网站看到落地节点的出口 IP。建议先使用 Shadowsocks；其他协议需确认前置支持。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("电脑 → \(chain.upstream.isEmpty ? "前置节点":chain.upstream) → \(chain.landing.isEmpty ? "VPS 落地":chain.landing) → 目标网站")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Toggle("启用此链路",isOn:$chain.enabled).toggleStyle(.checkbox)
            if let failure { Text(failure).font(.callout).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true) }
            HStack {
                Text("保存后可在分流规则中选择此链路。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存并应用") {
                    chain.name = chain.name.trimmingCharacters(in:.whitespacesAndNewlines)
                    var next = store.activeProfile?.proxyChains ?? []
                    if let index = next.firstIndex(where:{$0.id == chain.id}) { next[index] = chain } else { next.append(chain) }
                    store.perform {
                        do { try await store.saveProxyChains(next,profileID:profileID); dismiss() }
                        catch { failure = Redactor.clean(error.localizedDescription) }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(chain.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || (chain.enabled && !validSelection) || store.database.activeProfileID != profileID)
            }
        }.padding(24).frame(width:680).disabled(store.busy)
    }
}
