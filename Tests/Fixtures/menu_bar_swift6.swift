import AppKit

@main struct MenuBarSwift6Check {
    @MainActor static func require(_ condition: Bool,_ message: String) {
        if !condition {
            FileHandle.standardError.write(Data(("FAIL " + message + "\n").utf8))
            exit(1)
        }
    }

    @MainActor static func checkLayout() -> CGFloat {
        require(Thread.isMainThread,"AppKit layout runs on the main thread")
        require(MenuBarRateLayout.font == NSFont.menuBarFont(ofSize:9),"menu bar font is preserved")
        let cases: [(Int64,String)] = [
            (-1,"0KB/s"),(0,"0KB/s"),(1,"1B/s"),(999,"999B/s"),
            (1000,"1.0K/s"),(1024,"1.0K/s"),(1_048_576,"1.0M/s"),
            (1_073_741_824,"1.0G/s"),(Int64.max,"8.0E/s")
        ]
        for (bytes,expected) in cases {
            require(MenuBarRateLayout.format(bytes) == expected,"rate formatting for \(bytes)")
        }
        print("PASS Swift 6 main-actor font and rate formatting")

        let width = MenuBarRateLayout.width
        for unit in ["B/s","K/s","M/s","G/s","T/s","P/s","E/s"] {
            for text in ["999"+unit,"9.9"+unit] {
                let measured = (text as NSString).size(withAttributes:[.font:MenuBarRateLayout.font]).width
                require(MenuBarRateLayout.textOrigin + measured + MenuBarRateLayout.trailingInset <= width,
                        "fixed menu width fits " + text)
            }
        }
        for showSpeed in [false,true] {
            for connected in [false,true] {
                let image = MenuBarRateLayout.image(up:"999M/s",down:"9.9G/s",icon:nil,
                                                   connected:connected,showSpeed:showSpeed)
                require(image.size == NSSize(width:showSpeed ? width:25,height:22),"menu image geometry")
                require(image.isTemplate,"template image follows system appearance")
                require(!(image.tiffRepresentation?.isEmpty ?? true),"offscreen AppKit rendering succeeds")
                require(MenuBarRateLayout.width == width,"drawing keeps menu footprint stable")
            }
        }
        print("PASS fixed menu width, image geometry and offscreen rendering")
        return width
    }

    @MainActor static func main() async {
        let width = checkLayout()
        await withTaskGroup(of:Bool.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    await MainActor.run {
                        Thread.isMainThread && MenuBarRateLayout.font.pointSize == 9 &&
                        MenuBarRateLayout.width == width && MenuBarRateLayout.format(1024) == "1.0K/s"
                    }
                }
            }
            for await valid in group { require(valid,"concurrent callers use main-actor layout") }
        }
        print("PASS 32 concurrent callers safely read main-actor layout")
    }
}
