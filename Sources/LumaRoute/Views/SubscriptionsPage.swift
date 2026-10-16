import SwiftUI
import UniformTypeIdentifiers
import LumaRouteCore

struct SubscriptionsPage:View {
    @EnvironmentObject var store:AppStore
    @State private var importing = false
    @State private var search = ""
    @State private var source = "all"
    @State private var dropping = false
    @State private var creatingComposition = false
    var profiles:[Profile] {
        store.database.profiles.filter {
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) &&
            (source == "all" || (source == "composition" ? $0.composition != nil:($0.composition == nil && (source == "remote" ? $0.isRemote:!$0.isRemote))))
        }
    }
    var body:some View {
        VStack(spacing:16) {
            PageHeader(title:"订阅",subtitle:"\(store.database.profiles.count) 个配置 · \(store.activeProfile?.composition == nil ? "单订阅模式":"组合模式")") {
                Button("组合订阅") { creatingComposition = true }.disabled(store.busy)
                Button("更新全部") { store.perform { try await store.updateAll() } }.disabled(store.busy)
                Button { store.addingSubscription=true } label:{ Label("添加订阅",systemImage:"plus") }.buttonStyle(.borderedProminent)
            }
            HStack(spacing:12) {
                SearchField(placeholder:"搜索订阅",text:$search)
                Picker("配置来源",selection:$source) { Text("全部").tag("all"); Text("远程订阅").tag("remote"); Text("本地配置").tag("local"); Text("组合配置").tag("composition") }.labelsHidden().pickerStyle(.segmented).fixedSize()
                Button("导入文件") { importing=true }
            }
            if store.database.profiles.isEmpty { EmptyMessage(icon:"doc.badge.plus",title:"添加你的第一个订阅",detail:"粘贴订阅链接，或导入本地配置文件。") }
            else {
                ScrollView {
                    VStack(spacing:12) {
                        ForEach(profiles) { profile in ProfileRow(profile:profile) }
                        if profiles.isEmpty { EmptyMessage(icon:"magnifyingglass",title:"没有匹配的配置",detail:"试试其他名称或配置来源。") }
                    }
                }
            }
            footer
        }
        .overlay { if dropping { dropHint } }
        .onDrop(of:[UTType.fileURL.identifier],isTargeted:$dropping) { providers in
            guard let provider=providers.first else { return false }
            _ = provider.loadObject(ofClass:URL.self) { url,_ in
                guard let url else { return }; Task { @MainActor in store.perform { try await store.importFile(url) } }
            }; return true
        }
        .sheet(isPresented:$creatingComposition) { CompositionSheet(profiles:store.database.profiles,activeID:store.database.activeProfileID) }
        .sheet(isPresented:$store.addingSubscription) { ImportSubscriptionSheet() }
        .fileImporter(isPresented:$importing,allowedContentTypes:[.yaml,.plainText,.data]) { result in
            switch result { case .success(let url):store.perform { try await store.importFile(url) }; case .failure(let e):store.report(e) }
        }
    }
    private var footer:some View {
        HStack(spacing:12) {
            Image(systemName:"arrow.triangle.2.circlepath").font(.system(size:16)).foregroundStyle(.secondary)
            VStack(alignment:.leading,spacing:2) {
                Text(!store.database.profiles.contains(where:{$0.isRemote}) ? "本地配置无需自动更新":store.refreshTask?.isCancelled == false ? "自动更新已开启":"自动更新尚未启动").font(.system(size:13,weight:.medium))
                Text("订阅更新失败时保留上次可用配置 · 也可以把配置文件拖到此页导入").font(.system(size:12)).foregroundStyle(.secondary)
            }
            Spacer(); Button("管理备份") { store.settingsTab = "更新与备份"; store.page = .settings }
        }
    }
    /// Shown only while a file is dragged over the page, instead of a permanent dashed box.
    private var dropHint:some View {
        let shape = RoundedRectangle(cornerRadius:LumaPalette.cardRadius,style:.continuous)
        return shape.fill(LumaPalette.accent.opacity(0.08))
            .overlay(shape.stroke(LumaPalette.accent,style:StrokeStyle(lineWidth:2,dash:[7,5])))
            .overlay(VStack(spacing:8) { Image(systemName:"arrow.down.doc").font(.system(size:30,weight:.medium)); Text("松开以导入配置文件").font(.system(size:15,weight:.semibold)) }.foregroundStyle(LumaPalette.accent))
            .allowsHitTesting(false)
    }
}
