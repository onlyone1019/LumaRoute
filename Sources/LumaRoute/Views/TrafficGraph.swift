import SwiftUI
import LumaRouteCore

/// Smooth two-series chart: a few dashed guides, no frame, a soft fill and a live marker.
struct TrafficGraph:View {
    var samples:[Traffic]
    private let top:CGFloat = 10
    private let bottom:CGFloat = 8
    private let gutter:CGFloat = 62
    private var maximum:Double { max(1024,Double(samples.map { max($0.down,$0.up) }.max() ?? 0)*1.2) }
    private var idle:Bool { samples.allSatisfy { $0.down == 0 && $0.up == 0 } }
    var body:some View {
        VStack(spacing:8) {
            GeometryReader { geo in
                let plot = CGSize(width:max(1,geo.size.width-gutter),height:geo.size.height)
                let down = points(upload:false,size:plot),up = points(upload:true,size:plot)
                ZStack(alignment:.topLeading) {
                    ForEach(0..<4) { index in
                        let y = top+(plot.height-top-bottom)*CGFloat(index)/3
                        Path { p in p.move(to:CGPoint(x:gutter,y:y)); p.addLine(to:CGPoint(x:geo.size.width,y:y)) }
                            .stroke(Color.primary.opacity(0.08),style:StrokeStyle(lineWidth:1,dash:[3,4]))
                        Text(index == 3 ? "0":axisLabel(maximum*Double(3-index)/3)).font(.system(size:10)).foregroundStyle(.tertiary)
                            .frame(width:gutter-10,alignment:.trailing).position(x:(gutter-10)/2,y:y)
                    }
                    area(down,baseline:plot.height-bottom).fill(LinearGradient(colors:[LumaPalette.accent.opacity(0.26),LumaPalette.accent.opacity(0)],startPoint:.top,endPoint:.bottom))
                    smooth(down).stroke(LumaPalette.accent,style:StrokeStyle(lineWidth:2,lineCap:.round,lineJoin:.round))
                    smooth(up).stroke(LumaPalette.upload,style:StrokeStyle(lineWidth:2,lineCap:.round,lineJoin:.round))
                    if !idle,let last = down.last {
                        Circle().fill(LumaPalette.accent.opacity(0.22)).frame(width:16,height:16).position(last)
                        Circle().fill(LumaPalette.accent).frame(width:8,height:8).position(last)
                    }
                    if idle { Text(samples.isEmpty ? "等待内核流量数据":"暂无流量 · 等待代理请求").font(.system(size:12)).foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity) }
                }
            }
            HStack { Text("最近 60 次采样"); Spacer(); Text("现在") }.font(.system(size:11)).foregroundStyle(.tertiary).padding(.leading,gutter)
        }.accessibilityElement(children:.ignore).accessibilityLabel("实时流量图").accessibilityValue(idle ? "暂无流量":"下载和上传速度随时间变化")
    }
    /// `size` is the plot area; x starts after the label gutter.
    private func points(upload:Bool,size:CGSize)->[CGPoint] {
        let plot = size.height-top-bottom
        return samples.enumerated().map { index,sample in
            let x = gutter+size.width*CGFloat(index)/CGFloat(max(1,samples.count-1))
            let value = Double(upload ? sample.up:sample.down)
            return CGPoint(x:x,y:top+plot*(1-CGFloat(value/maximum)))
        }
    }
    /// Catmull-Rom curve through the samples; control points stay between neighbours so it never overshoots.
    private func smooth(_ pts:[CGPoint])->Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to:first)
        for i in 0..<max(0,pts.count-1) {
            let p0 = pts[max(0,i-1)],p1 = pts[i],p2 = pts[i+1],p3 = pts[min(pts.count-1,i+2)]
            var c1 = CGPoint(x:p1.x+(p2.x-p0.x)/6,y:p1.y+(p2.y-p0.y)/6)
            var c2 = CGPoint(x:p2.x-(p3.x-p1.x)/6,y:p2.y-(p3.y-p1.y)/6)
            let low = min(p1.y,p2.y),high = max(p1.y,p2.y)
            c1.y = min(max(c1.y,low),high); c2.y = min(max(c2.y,low),high)
            path.addCurve(to:p2,control1:c1,control2:c2)
        }
        return path
    }
    private func area(_ pts:[CGPoint],baseline:CGFloat)->Path {
        var path = smooth(pts)
        guard let first = pts.first,let last = pts.last else { return path }
        path.addLine(to:CGPoint(x:last.x,y:baseline)); path.addLine(to:CGPoint(x:first.x,y:baseline)); path.closeSubpath()
        return path
    }
    private func axisLabel(_ value:Double)->String {
        let unit = value >= 1024*1024 ? "MB/s":value >= 1024 ? "KB/s":"B/s"
        let divisor:Double = value >= 1024*1024 ? 1024*1024:value >= 1024 ? 1024:1
        return (value/divisor).formatted(.number.precision(.fractionLength(0...1)))+" "+unit
    }
}
