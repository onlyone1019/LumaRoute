import AppKit

/// Keep the status-item footprint stable across digit counts and rate units.
enum MenuBarRateLayout {
    static let font = NSFont.menuBarFont(ofSize:9)
    static let textOrigin:CGFloat = 24 // 3-point inset + 18-point icon + 3-point minimum gap.
    static let trailingInset:CGFloat = 2
    private static let units = ["B/s","K/s","M/s","G/s","T/s","P/s","E/s"]
    static let width:CGFloat = {
        let samples = units.flatMap { unit in ["999"+unit,"9.9"+unit] }
        let textWidth = samples.map { ($0 as NSString).size(withAttributes:[.font:font]).width }.max() ?? 0
        return ceil(textOrigin+textWidth+trailingInset)
    }()
    static func format(_ bytes:Int64)->String {
        guard bytes > 0 else { return "0KB/s" }
        var value = Double(bytes)
        var unit = 0
        // Promote before rounding could create a fourth integer digit.
        while value >= 999.5 && unit < units.count-1 { value /= 1024; unit += 1 }
        return String(format:unit > 0 && value < 9.95 ? "%.1f":"%.0f",value)+units[unit]
    }
    static func image(up:String,down:String,icon:NSImage?,connected:Bool,showSpeed:Bool)->NSImage {
        let width:CGFloat = showSpeed ? self.width:25
        let attributes:[NSAttributedString.Key:Any] = [.font:font,.foregroundColor:NSColor.black]
        let image = NSImage(size:NSSize(width:width,height:22),flipped:false) { _ in
            icon?.draw(in:NSRect(x:3,y:2,width:18,height:18),from:.zero,operation:.sourceOver,fraction:connected ? 1:0.5)
            if showSpeed {
                for (value,y) in [(up,CGFloat(11)),(down,CGFloat(1))] {
                    let text = value as NSString
                    let textWidth = text.size(withAttributes:attributes).width
                    text.draw(at:NSPoint(x:width-trailingInset-textWidth,y:y),withAttributes:attributes)
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
