import SwiftUI
import LumaRouteCore

/// A flat tonal card. `emphasized` tints it with the accent instead of drawing a border.
struct Panel<Content:View>:View {
    var padding:CGFloat = 18
    var emphasized = false
    @ViewBuilder var content:Content
    var body:some View {
        content.padding(padding).frame(maxWidth:.infinity,alignment:.leading)
            .background(emphasized ? LumaPalette.accent.opacity(0.10):LumaPalette.card,in:RoundedRectangle(cornerRadius:LumaPalette.cardRadius,style:.continuous))
    }
}
struct SearchField:View {
    var placeholder:String
    @Binding var text:String
    var body:some View {
        HStack(spacing:7) {
            Image(systemName:"magnifyingglass").font(.system(size:12,weight:.medium)).foregroundStyle(.secondary)
            TextField(placeholder,text:$text).textFieldStyle(.plain).font(.system(size:13)).accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button { text = "" } label:{ Image(systemName:"xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
        }.padding(.horizontal,12).frame(height:LumaControl.height).background(LumaPalette.tile,in:Capsule())
    }
}
struct PageHeader<Actions:View>:View {
    var title:String
    var subtitle:String? = nil
    @ViewBuilder var actions:Actions
    var body:some View {
        HStack(alignment:.center,spacing:16) {
            VStack(alignment:.leading,spacing:3) {
                Text(title).font(.system(size:26,weight:.bold))
                if let subtitle { Text(subtitle).font(.system(size:13)).foregroundStyle(.secondary) }
            }
            Spacer(minLength:12); HStack(spacing:8) { actions }.fixedSize(horizontal:true,vertical:false)
        }.frame(minHeight:44)
    }
}
struct StatusDot:View {
    var active:Bool
    var body:some View { Circle().fill(active ? Color.green:Color.secondary.opacity(0.5)).frame(width:8,height:8) }
}
struct EmptyMessage:View {
    var icon:String = "tray"
    var title:String
    var detail:String
    var actionTitle:String? = nil
    var action:(()->Void)? = nil
    var body:some View {
        VStack(spacing:14) {
            Image(systemName:icon).font(.system(size:26,weight:.medium)).foregroundStyle(.secondary)
                .frame(width:64,height:64).background(LumaPalette.tile,in:Circle())
            VStack(spacing:5) {
                Text(title).font(.system(size:16,weight:.semibold))
                Text(detail).font(.system(size:13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let actionTitle,let action { Button(actionTitle,action:action).buttonStyle(.borderedProminent).padding(.top,4) }
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
            VStack(alignment:.leading,spacing:2) {
                Text(title).font(.system(size:14))
                if let detail { Text(detail).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
            }
            Spacer(minLength:12); HStack(spacing:8) { controls }.fixedSize(horizontal:true,vertical:false)
        }.padding(.vertical,compact ? 7:9).frame(minHeight:compact ? 40:46)
    }
}
struct RowDivider:View {
    var body:some View { Rectangle().fill(LumaPalette.hairline).frame(height:1) }
}
/// A titled group of settings rows on one flat card. Insert `RowDivider()` between rows.
struct SettingsGroup<Content:View>:View {
    var title:String? = nil
    @ViewBuilder var content:Content
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            if let title { Text(title).font(.system(size:12,weight:.semibold)).foregroundStyle(.secondary).padding(.leading,6) }
            VStack(spacing:0) { content }.padding(.horizontal,16).padding(.vertical,2).frame(maxWidth:.infinity,alignment:.leading)
                .background(LumaPalette.card,in:RoundedRectangle(cornerRadius:LumaPalette.cardRadius,style:.continuous))
        }
    }
}
struct IconBadge:View {
    var icon:String
    var size:CGFloat = 42
    var tint:Color = LumaPalette.accent
    var body:some View {
        Image(systemName:icon).font(.system(size:size*0.4,weight:.semibold)).foregroundStyle(tint)
            .frame(width:size,height:size).background(tint.opacity(0.13),in:RoundedRectangle(cornerRadius:size*0.29,style:.continuous))
    }
}
