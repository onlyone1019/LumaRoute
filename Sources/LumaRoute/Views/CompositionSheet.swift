import SwiftUI
import LumaRouteCore

struct CompositionSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var profile: Profile
    @State private var draft: SubscriptionComposition
    @State private var activate: Bool
    @State private var failure: String?
    private var members: [Profile] { store.subscriptionProfiles.filter { draft.profileIDs.contains($0.id) } }
    init(profile: Profile? = nil,profiles: [Profile],activeID: UUID?) {
        let original = profile ?? Profile(name:"组合配置",isRemote:false)
        _profile = State(initialValue:original)
        var composition = original.composition ?? SubscriptionComposition()
        if original.composition == nil {
            composition.profileIDs = Array(profiles.filter { $0.composition == nil }.prefix(2).map(\.id))
            composition.baseProfileID = composition.profileIDs.contains(activeID ?? UUID()) ? activeID:composition.profileIDs.first
        }
        _draft = State(initialValue:composition)
        _activate = State(initialValue:profile == nil || activeID == original.id)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(profile.composition == nil ? "新建组合配置":"编辑组合配置").font(.title2.bold())
            TextField("组合名称",text:$profile.name).textFieldStyle(LumaTextFieldStyle()).accessibilityLabel("组合名称")
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    Panel(padding:12) {
                        VStack(alignment:.leading,spacing:10) {
                            Text("参与聚合的订阅").font(.headline)
                            ForEach(store.subscriptionProfiles) { item in
                                Toggle(item.name,isOn:Binding(get:{draft.profileIDs.contains(item.id)},set:{ selected in
                                    if selected { draft.profileIDs.append(item.id) } else { draft.profileIDs.removeAll { $0 == item.id } }
                                    if !draft.profileIDs.contains(draft.baseProfileID ?? UUID()) { draft.baseProfileID = draft.profileIDs.first }
                                    if let fallback = draft.fallbackProfileID,!draft.profileIDs.contains(fallback) { draft.fallbackProfileID = nil }
                                })).toggleStyle(.checkbox)
                            }
                            if store.subscriptionProfiles.count < 2 { Text("请先添加至少两个订阅或本地配置。").foregroundStyle(.secondary) }
                        }.padding(10).frame(maxWidth:.infinity,alignment:.leading)
                    }
                    Panel(padding:12) {
                        VStack(alignment:.leading,spacing:10) {
                            Text("默认分流").font(.headline)
                            LumaPicker("基础配置",selection:Binding(get:{draft.baseProfileID?.uuidString ?? ""},set:{draft.baseProfileID = UUID(uuidString:$0)}),value:members.first { $0.id == draft.baseProfileID }?.name ?? "选择基础订阅",showsLabel:true) {
                                Text("选择基础订阅").tag("")
                                ForEach(members) { Text($0.name).tag($0.id.uuidString) }
                            }
                            Text("沿用基础订阅的 DNS 和原有分流规则；下方分流规则优先生效。").font(.caption).foregroundStyle(.secondary)
                            LumaPicker("兜底出口",selection:Binding(get:{draft.fallbackProfileID?.uuidString ?? ""},set:{draft.fallbackProfileID = UUID(uuidString:$0)}),value:members.first { $0.id == draft.fallbackProfileID }?.name ?? "聚合节点（全部订阅）",showsLabel:true) {
                                Text("聚合节点（全部订阅）").tag("")
                                ForEach(members) { Text($0.name).tag($0.id.uuidString) }
                            }
                            Text("兜底用于基础规则未匹配的流量。聚合节点可手动选择，或使用“聚合自动”测速选优。").font(.caption).foregroundStyle(.secondary)
                        }.padding(10)
                    }
                    DomainRoutesEditor(routes:$draft.domainRoutes,composition:draft,profiles:members)
                }.padding(.trailing,4)
            }
            if let failure { Text(failure).font(.callout).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true) }
            HStack {
                Toggle("保存后启用",isOn:$activate).toggleStyle(.checkbox).disabled(profile.id == store.database.activeProfileID)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(activate ? "保存并启用":"保存组合") {
                    var proposed = profile; proposed.composition = draft
                    store.perform {
                        do { try await store.saveComposition(proposed,activate:activate); dismiss() }
                        catch { failure = Redactor.clean(error.localizedDescription) }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(members.count < 2)
            }
        }.padding(24).frame(width:790,height:650).disabled(store.busy)
    }
}

struct DomainRoutingView: View {
    @EnvironmentObject var store: AppStore
    @State private var draft: [SubscriptionDomainRoute] = []
    @State private var failure: String?
    @State private var initialized = false
    private var composition: SubscriptionComposition? { store.activeProfile?.composition }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            if let composition,let active = store.activeProfile {
                Text("当前组合："+active.name).font(.headline)
                if store.database.settings.mode != .rule {
                    HStack {
                        Text("分流规则仅在规则模式下生效。").foregroundStyle(.orange)
                        Button("切换规则模式") { store.setMode(.rule) }.disabled(store.busy)
                    }
                }
                ScrollView { DomainRoutesEditor(routes:$draft,composition:composition,profiles:store.subscriptionProfiles.filter { composition.profileIDs.contains($0.id) }) }
                if let failure { Text(failure).foregroundStyle(.red) }
                HStack {
                    Text(draft == composition.domainRoutes ? "分流规则已保存":"有未应用的修改").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("撤销") { draft = composition.domainRoutes; failure = nil }
                    Button("应用分流规则") {
                        var proposed = active; proposed.composition?.domainRoutes = draft
                        store.perform {
                            do { try await store.saveComposition(proposed,activate:true); failure = nil }
                            catch { failure = Redactor.clean(error.localizedDescription) }
                        }
                    }.buttonStyle(.borderedProminent).disabled(store.busy || draft == composition.domainRoutes)
                }
            } else {
                EmptyMessage(icon:"arrow.triangle.branch",title:"组合配置的分流规则",detail:"创建组合配置后，可将不同域名分别交给不同订阅。单订阅仍可使用自定义规则选择策略组。",actionTitle:"前往订阅",action:{ store.page = .subscriptions })
            }
        }.onAppear { if !initialized { draft = composition?.domainRoutes ?? []; initialized = true } }
         .onChange(of:store.database.activeProfileID) { _,_ in draft = composition?.domainRoutes ?? []; failure = nil }
         .onChange(of:composition?.domainRoutes) { previous,current in
             if draft == (previous ?? []) { draft = current ?? [] }
         }
    }
}
