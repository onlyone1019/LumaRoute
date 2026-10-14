import SwiftUI
import UniformTypeIdentifiers
import LumaRouteCore

struct SubscriptionsPage:View {
    @EnvironmentObject var store:AppStore
    @State private var importing = false
    @State private var search = ""
    @State private var source = "all"
    @State private var dropping = false
    var profiles:[Profile] {
        store.database.profiles.filter {
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) &&
            (source == "all" || (source == "remote" ? $0.isRemote:!$0.isRemote))
        }
    }
    var body:some View {
        VStack(spacing:18) {
            PageHeader(title:"订阅",subtitle:"\(store.database.profiles.count) 个配置") {
                Button("更新全部") { store.perform { try await store.updateAll() } }.disabled(store.busy)
                Button { store.addingSubscription=true } label:{ Label("添加订阅",systemImage:"plus") }.buttonStyle(LumaPrimaryButtonStyle())
            }
            HStack(spacing:12) {
                SearchField(placeholder:"搜索订阅",text:$search)
                Picker("配置来源",selection:$source) { Text("全部").tag("all"); Text("远程订阅").tag("remote"); Text("本地配置").tag("local") }.labelsHidden().pickerStyle(.segmented).frame(width:280)
                Button("导入文件") { importing=true }
            }
            if store.database.profiles.isEmpty { EmptyMessage(icon:"doc.badge.plus",title:"添加你的第一个订阅",detail:"粘贴订阅链接，或导入本地配置文件。") }
            else {
                ScrollView {
                    VStack(spacing:14) {
                        ForEach(profiles) { profile in
                            ProfileRow(profile:profile)
                        }
                        if profiles.isEmpty { EmptyMessage(icon:"magnifyingglass",title:"没有匹配的配置",detail:"试试其他名称或配置来源。") }
                    }
                }
            }
            HStack(spacing:14) {
                Image(systemName:"doc.badge.plus").font(.system(size:19))
                Divider().frame(height:24)
                Image(systemName:"link").font(.system(size:17))
                Text("拖入配置文件，或使用“添加订阅”粘贴链接")
            }.font(.callout).foregroundStyle(dropping ? LumaPalette.accent:Color.secondary).frame(maxWidth:.infinity,minHeight:78)
                .background(dropping ? LumaPalette.accent.opacity(0.06):Color.clear,in:RoundedRectangle(cornerRadius:8))
                .overlay(RoundedRectangle(cornerRadius:8).stroke(dropping ? LumaPalette.accent:Color.secondary.opacity(0.25),style:StrokeStyle(lineWidth:1,dash:[5])))
                .onDrop(of:[UTType.fileURL.identifier],isTargeted:$dropping) { providers in
                    guard let provider=providers.first else { return false }
                    _ = provider.loadObject(ofClass:URL.self) { url,_ in
                        guard let url else { return }; Task { @MainActor in store.perform { try await store.importFile(url) } }
                    }; return true
                }
            HStack(spacing:12) {
                Image(systemName:"arrow.triangle.2.circlepath").font(.system(size:20))
                VStack(alignment:.leading,spacing:3) {
                    Text(!store.database.profiles.contains(where:{$0.isRemote}) ? "本地配置无需自动更新":store.refreshTask?.isCancelled == false ? "自动更新已开启":"自动更新尚未启动").font(.callout.weight(.medium))
                    Text("订阅更新失败时保留上次可用配置").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(); Button("管理备份") { store.settingsTab = "更新与备份"; store.page = .settings }
            }.padding(.top,6)
        }
        .sheet(isPresented:$store.addingSubscription) { ImportSubscriptionSheet() }
        .fileImporter(isPresented:$importing,allowedContentTypes:[.yaml,.plainText,.data]) { result in
            switch result { case .success(let url):store.perform { try await store.importFile(url) }; case .failure(let e):store.report(e) }
        }
    }
}
struct ProfileRow:View {
    @EnvironmentObject var store:AppStore
    @State private var showingOptions = false
    var profile:Profile
    var body:some View {
        Panel(emphasized:store.database.activeProfileID == profile.id) {
            HStack(alignment:.top,spacing:16) {
                IconBadge(icon:profile.isRemote ? "doc.text":"doc")
                VStack(alignment:.leading,spacing:8) {
                    HStack { Text(profile.name).font(.system(size:15,weight:.semibold)).lineLimit(1); if store.database.activeProfileID == profile.id { Text("使用中").font(.caption).padding(.horizontal,8).padding(.vertical,3).background(LumaPalette.accent.opacity(0.1),in:Capsule()).foregroundStyle(LumaPalette.accent).fixedSize() } }
                    Text(profile.displaySource).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text((profile.lastUpdated.map { "上次更新 "+$0.formatted(date:.abbreviated,time:.shortened) } ?? "尚未更新")+(profile.isRemote ? " · 每 \(profile.updateHours.formatted()) 小时更新":"")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if profile.userAgent != nil { Label("自定义 User-Agent",systemImage:"slider.horizontal.3").font(.caption).foregroundStyle(.secondary) }
                    if let error=profile.lastError { Label("更新失败，已保留旧配置："+error,systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(2) }
                }.frame(maxWidth:.infinity,alignment:.leading)
                VStack(alignment:.leading,spacing:8) {
                    if let usage=profile.usage {
                        Text("已用 "+Format.bytes(usage.usedBytes)+(usage.total.map { " / "+Format.bytes($0) } ?? ""))
                        if let fraction=usage.usedFraction { ProgressView(value:fraction).frame(width:180) }
                        Text(usage.expire.map { "到期 "+$0.formatted(date:.abbreviated,time:.omitted) } ?? "到期信息未提供").font(.caption).foregroundStyle(.secondary)
                    } else { Text("流量信息未提供").foregroundStyle(.secondary) }
                }.font(.callout).frame(width:180,alignment:.leading)
                HStack(spacing:8) {
                    if profile.isRemote { Button("更新") { store.perform { try await store.update(profile) } } }
                    if store.database.activeProfileID != profile.id { Button("启用") { store.perform { try await store.activate(profile) } }.buttonStyle(LumaPrimaryButtonStyle()) }
                    Menu {
                        if profile.isRemote { Button("订阅设置…") { showingOptions = true }; Divider() }
                        Button("删除",role:.destructive) { store.perform { try await store.deleteProfile(profile) } }
                    } label:{ Image(systemName:"ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width:28,height:28).accessibilityLabel("更多")
                }.fixedSize(horizontal:true,vertical:false).disabled(store.busy).controlSize(.regular)
            }
        }
        .sheet(isPresented:$showingOptions) { SubscriptionOptionsSheet(profile:profile) }
    }
}
struct ImportSubscriptionSheet:View {
    @EnvironmentObject var store:AppStore
    @Environment(\.dismiss) var dismiss
    @State var name=""
    @State var address=""
    @State var userAgent=""
    @State var importing=false
    @State var failure:String?
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("添加订阅").font(.title2.bold())
            TextField("名称",text:$name).textFieldStyle(.roundedBorder)
            TextField("订阅链接",text:$address).textFieldStyle(.roundedBorder)
            Text("订阅链接安全保存在本机钥匙串中").font(.caption).foregroundStyle(.secondary)
            SubscriptionUserAgentField(value:$userAgent)
            if let failure { SubscriptionFailureMessage(message:failure) }
            HStack { Spacer(); Button("取消") { dismiss() }; Button("导入") {
                importing=true
                store.perform {
                    defer { importing=false }
                    do { failure=nil; try await store.importRemote(name:name,url:address.trimmingCharacters(in:.whitespacesAndNewlines),userAgent:userAgent); dismiss() }
                    catch { failure=Redactor.clean(error.localizedDescription) }
                }
            }.buttonStyle(LumaPrimaryButtonStyle()).disabled(address.isEmpty || importing) }
            if importing { ProgressView("正在下载并校验订阅…") }
        }.padding(26).frame(width:520).disabled(store.busy)
    }
}

struct SubscriptionOptionsSheet:View {
    @EnvironmentObject var store:AppStore
    @Environment(\.dismiss) var dismiss
    let profile:Profile
    @State private var userAgent:String
    @State private var failure:String?
    init(profile:Profile) { self.profile=profile; _userAgent=State(initialValue:profile.userAgent ?? "") }
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("订阅设置").font(.title2.bold())
            Text(profile.name).font(.headline)
            SubscriptionUserAgentField(value:$userAgent)
            Text("仅影响此订阅。保存后，手动更新和自动更新都会使用新标识。").font(.caption).foregroundStyle(.secondary)
            if let failure { SubscriptionFailureMessage(message:failure) }
            HStack {
                Button("恢复默认") { userAgent=""; failure=nil }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do { try store.saveSubscriptionOptions(profile,userAgent:userAgent); dismiss() }
                    catch { failure=Redactor.clean(error.localizedDescription) }
                }.buttonStyle(LumaPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width:520).disabled(store.busy)
    }
}

struct SubscriptionUserAgentField:View {
    @Binding var value:String
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            Text("User-Agent").font(.callout.weight(.medium))
            TextField("留空使用默认标识",text:$value).textFieldStyle(.roundedBorder).accessibilityLabel("User-Agent")
            Text("默认："+SubscriptionFetcher.defaultUserAgent).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

struct SubscriptionFailureMessage:View {
    let message:String
    var body:some View {
        Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            .frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true)
    }
}

