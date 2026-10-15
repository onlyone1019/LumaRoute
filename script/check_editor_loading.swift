import AppKit
import SwiftUI
import LumaRouteCore

/// Native UI acceptance host: actual editor, synthetic profiles, no persistence or core.
@MainActor final class EditorLoadingDelegate: NSObject,NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let store=AppStore()
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:640),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title="LumaRoute 编辑器隔离测试"
        window.contentView=NSHostingView(rootView:EditorLoadingFixture().environmentObject(store))
        window.center();window.makeKeyAndOrderFront(nil)
        self.window=window
        NSApp.activate(ignoringOtherApps:true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
}

struct EditorLoadingFixture: View {
    @State private var routes: [SubscriptionDomainRoute] = {
        var a=SubscriptionDomainRoute();a.type="DOMAIN-KEYWORD";a.domain="chatgpt";a.target="[自建] US-Residential"
        var b=a;b.id=UUID();b.domain="openai"
        return [a,b]
    }()
    @State private var revision=0
    @State private var mode="存在"
    private let a=Profile(name:"自建",isRemote:false)
    private let b=Profile(name:"sakuran",isRemote:false)
    var body: some View {
        var member=a
        member.lastUpdated=Date(timeIntervalSince1970:Double(revision))
        let profiles=[member,b]
        var plan=SubscriptionComposition();plan.profileIDs=profiles.map(\.id);plan.baseProfileID=a.id
        let requested=mode
        return VStack(alignment:.leading,spacing:14) {
            Text("真实编辑器 · 隔离测试").font(.title2)
            Text("本窗口使用模拟订阅，无数据库、内核或网络修改。加载延迟 5 秒，用于检查首帧。").foregroundStyle(.secondary)
            HStack {
                Button("重新加载有效出口") { mode="存在";revision += 1 }
                Button("加载缺失出口") { mode="缺失";revision += 1 }
                Button("模拟加载失败") { mode="失败";revision += 1 }
            }
            Text("测试场景："+mode+" · "+String(revision)).accessibilityLabel("测试场景")
            DomainRoutesEditor(routes:$routes,composition:plan,profiles:profiles,policyLoader:{ _ in
                // Detached wait deliberately outlives cancellation: a superseded
                // missing result must not overwrite the latest valid request.
                await Task.detached { try? await Task.sleep(nanoseconds:5_000_000_000) }.value
                if requested == "失败" { throw LumaError.message("模拟缓存读取失败") }
                return requested == "存在" ? ["[自建] US-Residential"]:[]
            })
            Spacer()
        }.padding(20).frame(minWidth:880,minHeight:600)
    }
}

@main struct EditorLoadingQA {
    @MainActor static func main() {
        let app=NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate=EditorLoadingDelegate();app.delegate=delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
