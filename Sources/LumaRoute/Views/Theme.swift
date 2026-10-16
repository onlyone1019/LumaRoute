import SwiftUI

/// Flat, tonal design tokens. Surfaces are separated by fill, never by strokes or shadows.
enum LumaPalette {
    static let accent = Color.accentColor
    static let upload = Color(red:0.61,green:0.31,blue:0.98)
    /// A card on the window canvas, and a control or tile sitting on a card.
    static let card = Color.primary.opacity(0.045)
    static let tile = Color.primary.opacity(0.07)
    static let hairline = Color.primary.opacity(0.08)
    static let cardRadius: CGFloat = 14
    static func latency(_ milliseconds:Int)->Color { milliseconds < 150 ? .green:milliseconds < 400 ? .orange:.red }
}

struct StatusPill:View {
    var text:String
    var color:Color = LumaPalette.accent
    var body:some View {
        Text(text).font(.system(size:11,weight:.medium)).foregroundStyle(color)
            .padding(.horizontal,8).padding(.vertical,3).background(color.opacity(0.13),in:Capsule()).fixedSize()
    }
}

struct LatencyChip:View {
    var delay:Int?
    var failed = false
    var body:some View {
        let color = failed ? Color.red:delay.map(LumaPalette.latency) ?? Color.secondary
        Text(failed ? "失败":delay.map { "\($0) ms" } ?? "未测试").font(.system(size:11,weight:.medium)).monospacedDigit()
            .foregroundStyle(color).padding(.horizontal,8).padding(.vertical,3).background(color.opacity(0.13),in:Capsule()).fixedSize()
    }
}

/// Thin capsule progress bar; turns orange near the limit and red when exhausted.
struct UsageBar:View {
    var fraction:Double
    var body:some View {
        Capsule().fill(Color.primary.opacity(0.09)).frame(height:6)
            .overlay(alignment:.leading) {
                GeometryReader { geo in
                    Capsule().fill(fraction >= 1 ? Color.red:fraction >= 0.85 ? Color.orange:LumaPalette.accent)
                        .frame(width:max(6,geo.size.width*min(1,max(0,fraction))))
                }
            }
            .accessibilityElement(children:.ignore).accessibilityLabel("已用流量").accessibilityValue("\(Int(fraction*100))%")
    }
}

/// Wraps children onto new rows when the available width runs out.
struct FlowLayout:Layout {
    var spacing:CGFloat = 8
    func sizeThatFits(proposal:ProposedViewSize,subviews:Subviews,cache:inout ())->CGSize {
        let width = proposal.width ?? .infinity
        var x:CGFloat = 0,y:CGFloat = 0,rowHeight:CGFloat = 0,widest:CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0,x+size.width > width { x = 0; y += rowHeight+spacing; rowHeight = 0 }
            x += size.width+spacing; rowHeight = max(rowHeight,size.height); widest = max(widest,x-spacing)
        }
        return CGSize(width:widest,height:y+rowHeight)
    }
    func placeSubviews(in bounds:CGRect,proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) {
        var x = bounds.minX,y = bounds.minY,rowHeight:CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX,x+size.width > bounds.maxX { x = bounds.minX; y += rowHeight+spacing; rowHeight = 0 }
            view.place(at:CGPoint(x:x,y:y),proposal:ProposedViewSize(size))
            x += size.width+spacing; rowHeight = max(rowHeight,size.height)
        }
    }
}
