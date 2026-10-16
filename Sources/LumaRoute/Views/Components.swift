import SwiftUI
import LumaRouteCore

enum LumaPalette {
    static let accent = Color(red:0.02,green:0.47,blue:1)
    static let upload = Color(red:0.61,green:0.31,blue:0.98)
    static let border = Color.primary.opacity(0.09)
}
struct LumaPrimaryButtonStyle:ButtonStyle {
    func makeBody(configuration:Configuration)->some View {
        LumaButtonLabel(configuration:configuration,prominent:true)
    }
}

struct Panel<Content:View>:View {
    var padding:CGFloat = 16
    var emphasized = false
    @ViewBuilder var content:Content
    var body:some View {
        content.padding(padding).frame(maxWidth:.infinity,alignment:.leading)
            .background(emphasized ? LumaPalette.accent.opacity(0.055):Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:10))
            .overlay(RoundedRectangle(cornerRadius:10).stroke(emphasized ? LumaPalette.accent.opacity(0.65):LumaPalette.border,lineWidth:1))
    }
}
struct SearchField:View {
    var placeholder:String
    @Binding var text:String
    var body:some View {
        HStack(spacing:7) {
            Image(systemName:"magnifyingglass").font(.system(size:12)).foregroundStyle(.secondary)
            TextField(placeholder,text:$text).textFieldStyle(.plain).accessibilityLabel(placeholder)
        }.padding(.horizontal,10).frame(height:LumaControl.height)
            .background(Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:6))
            .overlay(RoundedRectangle(cornerRadius:6).stroke(LumaPalette.border,lineWidth:1))
    }
}
struct PageHeader<Actions:View>:View {
    var title:String
    var subtitle:String? = nil
    @ViewBuilder var actions:Actions
    var body:some View {
        HStack(alignment:.center,spacing:16) {
            VStack(alignment:.leading,spacing:4) { Text(title).font(.system(size:23,weight:.semibold)); if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) } }
            Spacer(); HStack(spacing:8) { actions }.fixedSize(horizontal:true,vertical:false)
        }.frame(minHeight:36).padding(.bottom,2)
    }
}
struct StatusDot:View {
    var active:Bool
    var body:some View { Circle().fill(active ? .green:Color.secondary.opacity(0.5)).frame(width:9,height:9) }
}
struct EmptyMessage:View {
    var icon:String = "tray"
    var title:String
    var detail:String
    var body:some View {
        VStack(spacing:12) {
            Image(systemName:icon).font(.system(size:32)).foregroundStyle(.secondary)
            Text(title).font(.headline); Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth:.infinity,maxHeight:.infinity).padding(32)
    }
}
struct NativeRow<Controls:View>:View {
    var title:String
    var detail:String? = nil
    var compact = false
    @ViewBuilder var controls:Controls
    var body:some View {
        HStack(spacing:16) {
            VStack(alignment:.leading,spacing:compact ? 2:3) { Text(title); if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) } }
            Spacer(minLength:12); HStack(spacing:8) { controls }.fixedSize(horizontal:true,vertical:false)
        }.frame(minHeight:LumaControl.height).padding(.vertical,compact ? 2:3)
    }
}
struct RootView:View {
    @EnvironmentObject var store:AppStore
    var body:some View {
        HStack(spacing:0) {
            SidebarView().frame(width:180)
            Divider()
            ZStack(alignment:.topTrailing) {
                VStack(spacing:14) {
                if store.serviceSetup != .ready {
                    Panel {
                        HStack(spacing:12) {
                            Image(systemName:"checkmark.shield").foregroundStyle(LumaPalette.accent)
                            VStack(alignment:.leading,spacing:3) {
                                Text(store.serviceSetup == .update ? "完成应用更新":"启用网络功能").font(.headline)
                                Text(store.serviceInstalling ? "等待授权完成，随后自动连接":"授权后自动准备系统代理和 TUN，无需单独安装").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(store.serviceSetupButton) { store.installService(networkReady:true) }
                                .buttonStyle(LumaPrimaryButtonStyle()).disabled(store.busy || store.serviceInstalling)
                        }
                    }
                }
                PageHostView().frame(maxWidth:.infinity,maxHeight:.infinity)
                }.padding(20)
                if store.busy { ProgressView().controlSize(.small).padding(12) }
                if let notice = store.notice {
                    VStack { Spacer(); HStack(spacing:12) {
                        Image(systemName:"info.circle").foregroundStyle(LumaPalette.accent)
                        Text(notice).font(.callout)
                        Button { store.notice = nil } label:{ Image(systemName:"xmark") }.buttonStyle(.borderless).accessibilityLabel("关闭提示")
                    }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10)).padding(16) }
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity).background(.background)
        }.tint(LumaPalette.accent).buttonStyle(LumaButtonStyle()).controlSize(.regular)
    }
}
struct SidebarView:View {
    @EnvironmentObject var store:AppStore
    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            ForEach(AppPage.allCases) { page in
                Button { if store.page != page { store.page = page } } label: {
                    HStack(spacing:12) {
                        Image(systemName:page.icon).font(.system(size:18,weight:.regular)).frame(width:22)
                        Text(page.rawValue).font(.system(size:14,weight:store.page == page ? .medium:.regular))
                        Spacer(minLength:0)
                    }.foregroundStyle(store.page == page ? LumaPalette.accent:Color.primary)
                        .padding(.horizontal,12).frame(height:38)
                        .background(store.page == page ? LumaPalette.accent.opacity(0.13):Color.clear,in:RoundedRectangle(cornerRadius:7))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(store.page == page ? [.isSelected]:[])
            }
            Spacer()
            HStack(alignment:.top,spacing:10) {
                StatusDot(active:store.connected).padding(.top,4)
                VStack(alignment:.leading,spacing:5) {
                    Text(store.connected ? "已连接":"未接管网络").font(.system(size:13,weight:.medium))
                    Text(store.database.settings.tun ? "TUN 已开启":store.database.settings.systemProxy ? "系统代理已开启":store.coreReady ? "内核运行中":"内核未就绪").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal,12).padding(.bottom,10)
        }.padding(.horizontal,10).padding(.top,24).background(.regularMaterial)
    }
}
struct IconBadge:View {
    var icon:String
    var tint:Color = .primary
    var body:some View {
        Image(systemName:icon).font(.system(size:18,weight:.medium)).foregroundStyle(tint)
            .frame(width:42,height:42).background(Color.primary.opacity(0.04),in:Circle())
    }
}

