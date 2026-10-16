import SwiftUI
import LumaRouteCore

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
            TextField("名称",text:$name).textFieldStyle(LumaTextFieldStyle())
            TextField("订阅链接",text:$address).textFieldStyle(LumaTextFieldStyle())
            Text("完整订阅链接仅保存在本机，不随普通备份导出").font(.caption).foregroundStyle(.secondary)
            SubscriptionUserAgentField(value:$userAgent)
            if let failure { SubscriptionFailureMessage(message:failure) }
            HStack { Spacer(); Button("取消") { dismiss() }; Button("导入") {
                importing=true
                store.perform {
                    defer { importing=false }
                    do { failure=nil; try await store.importRemote(name:name,url:address.trimmingCharacters(in:.whitespacesAndNewlines),userAgent:userAgent); dismiss() }
                    catch { failure=Redactor.clean(error.localizedDescription) }
                }
            }.buttonStyle(.borderedProminent).disabled(address.isEmpty || importing) }
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
                    store.perform {
                        do { try await store.saveSubscriptionOptions(profile,userAgent:userAgent); dismiss() }
                        catch { failure=Redactor.clean(error.localizedDescription) }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width:520).disabled(store.busy)
    }
}

struct SubscriptionUserAgentField:View {
    @Binding var value:String
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            Text("User-Agent").font(.callout.weight(.medium))
            TextField("留空使用默认标识",text:$value).textFieldStyle(LumaTextFieldStyle()).accessibilityLabel("User-Agent")
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

