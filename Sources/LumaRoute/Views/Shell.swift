import SwiftUI
import LumaRouteCore

/// Native split view: the system draws the translucent sidebar; pages are hosted in the detail column.
struct RootView:View {
    @EnvironmentObject var store:AppStore
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    var body:some View {
        NavigationSplitView(columnVisibility:$columnVisibility) {
            SidebarView().navigationSplitViewColumnWidth(min:190,ideal:200,max:230)
        } detail: {
            ZStack(alignment:.topTrailing) {
                VStack(spacing:14) {
                    if store.serviceSetup != .ready { ServiceBanner() }
                    PageHostView().frame(maxWidth:.infinity,maxHeight:.infinity)
                }.padding(.horizontal,28).padding(.top,12).padding(.bottom,22)
                if store.busy { ProgressView().controlSize(.small).padding(12) }
                NoticeToast()
            }.frame(maxWidth:.infinity,maxHeight:.infinity).background(.background)
        }
    }
}
/// Content of the standalone Settings window (⌘,).
struct SettingsWindowContent:View {
    var body:some View {
        SettingsPage().controlSize(.large).padding(.horizontal,28).padding(.vertical,24).frame(width:780,height:760)
    }
}
struct SidebarView:View {
    @EnvironmentObject var store:AppStore
    var body:some View {
        VStack(spacing:6) {
            ForEach(AppPage.allCases) { page in
                SidebarRow(page:page,selected:store.page == page) { if store.page != page { store.page = page } }
            }
            Spacer(minLength:0)
        }.padding(.horizontal,12).padding(.top,8)
            .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
            .safeAreaInset(edge:.bottom,spacing:0) { SidebarStatus() }
    }
}
/// One large, roomy sidebar entry: tinted rounded fill when selected, soft gray on hover.
struct SidebarRow:View {
    let page:AppPage
    let selected:Bool
    let action:()->Void
    @State private var hovering = false
    var body:some View {
        let shape = RoundedRectangle(cornerRadius:11,style:.continuous)
        Button(action:action) {
            HStack(spacing:14) {
                Image(systemName:page.icon).font(.system(size:18,weight:.medium))
                    .foregroundStyle(selected ? LumaPalette.accent:Color.primary.opacity(0.85)).frame(width:26)
                Text(page.rawValue).font(.system(size:15,weight:selected ? .semibold:.regular)).tracking(1.5)
                Spacer(minLength:0)
            }.padding(.horizontal,14).frame(height:42).contentShape(shape)
        }.buttonStyle(.plain)
            .background(selected ? LumaPalette.accent.opacity(0.14):hovering ? LumaPalette.tile:Color.clear,in:shape)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? [.isSelected]:[])
    }
}
struct SidebarStatus:View {
    @EnvironmentObject var store:AppStore
    var body:some View {
        HStack(alignment:.top,spacing:10) {
            StatusDot(active:store.connected).padding(.top,5)
            VStack(alignment:.leading,spacing:3) {
                Text(store.connected ? "已连接":"未接管网络").font(.system(size:13,weight:.medium))
                Text(store.database.settings.tun ? "TUN 已开启":store.database.settings.systemProxy ? "系统代理已开启":store.coreReady ? "内核运行中":"内核未就绪").font(.system(size:12)).foregroundStyle(.secondary)
            }
            Spacer(minLength:0)
        }.padding(.horizontal,14).padding(.vertical,12)
            .background(LumaPalette.tile,in:RoundedRectangle(cornerRadius:12,style:.continuous)).padding(10)
    }
}
struct ServiceBanner:View {
    @EnvironmentObject var store:AppStore
    var body:some View {
        Panel(emphasized:true) {
            HStack(spacing:14) {
                IconBadge(icon:"checkmark.shield.fill")
                VStack(alignment:.leading,spacing:3) {
                    Text(store.serviceSetup == .update ? "完成应用更新":"启用网络功能").font(.system(size:15,weight:.semibold))
                    Text(store.serviceInstalling ? "等待授权完成，随后自动连接":"授权后自动准备系统代理和 TUN，无需单独安装").font(.system(size:12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(store.serviceSetupButton) { store.installService(networkReady:true) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(store.busy || store.serviceInstalling)
            }
        }
    }
}
struct NoticeToast:View {
    @EnvironmentObject var store:AppStore
    var body:some View {
        if let notice = store.notice {
            VStack { Spacer(); HStack(spacing:10) {
                Image(systemName:"info.circle.fill").foregroundStyle(LumaPalette.accent)
                Text(notice).font(.system(size:13))
                Button { store.notice = nil } label:{ Image(systemName:"xmark").font(.system(size:11,weight:.semibold)) }.buttonStyle(.borderless).accessibilityLabel("关闭提示")
            }.padding(.horizontal,16).padding(.vertical,11).background(.regularMaterial,in:Capsule())
                .shadow(color:.black.opacity(0.12),radius:12,y:4).padding(20) }
        }
    }
}
