import AppKit

// Resize the imagegen master without redrawing the artwork; keep alpha intact.
let root = URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let folder = root.appendingPathComponent("Resources/MenuBar")
let source = folder.appendingPathComponent("LumaRoute-cat-source.png")
let data = try Data(contentsOf:source)
guard let bitmap = NSBitmapImageRep(data:data), let image = NSImage(data:data) else { fatalError("Invalid cat master") }
var left=bitmap.pixelsWide,top=bitmap.pixelsHigh,right=0,bottom=0
for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
    if (bitmap.colorAt(x:x,y:y)?.alphaComponent ?? 0) > 0.02 {
        left=min(left,x);right=max(right,x);top=min(top,y);bottom=max(bottom,y)
    }
}}
precondition(right > left && bottom > top,"Cat master must contain visible alpha")
let crop=NSRect(x:left,y:bitmap.pixelsHigh-bottom-1,width:right-left+1,height:bottom-top+1)
for scale in [1,2] {
    let pixels=18*scale
    let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let side=CGFloat(16*scale),ratio=min(side/crop.width,side/crop.height)
    let size=NSSize(width:crop.width*ratio,height:crop.height*ratio)
    image.draw(in:NSRect(x:(CGFloat(pixels)-size.width)/2,y:(CGFloat(pixels)-size.height)/2,width:size.width,height:size.height),from:crop,operation:.copy,fraction:1)
    NSGraphicsContext.restoreGraphicsState()
    rep.size=NSSize(width:18,height:18)
    let name="LumaRoute-menu-cat"+(scale == 1 ? "":"@2x")+".png"
    try rep.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(name))
    print("Generated \(name): \(pixels)x\(pixels), alpha preserved")
}
