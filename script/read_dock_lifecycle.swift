// Optional, read-only test observer. Never requests Accessibility permission or
// performs AX actions; reports only tiles for the exact test bundle URL.
import AppKit
import ApplicationServices

func attribute(_ element:AXUIElement,_ name:String)->CFTypeRef? {
    var value:CFTypeRef?
    return AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success ? value:nil
}
let target = URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL
var result:[String:Any] = ["trusted":AXIsProcessTrusted()]
if AXIsProcessTrusted(), let dock = NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock").first {
    let root = AXUIElementCreateApplication(dock.processIdentifier)
    AXUIElementSetMessagingTimeout(root,1)
    var seen:[AXUIElement] = []
    var count = 0
    func visit(_ item:AXUIElement,_ depth:Int) {
        guard depth < 6, seen.count < 1500, !seen.contains(where:{CFEqual($0,item)}) else { return }
        seen.append(item)
        if let url = attribute(item,kAXURLAttribute as String) as? URL,
           url.standardizedFileURL == target { count += 1 }
        if let children = attribute(item,kAXChildrenAttribute as String) as? [AXUIElement] {
            for child in children { visit(child,depth + 1) }
        }
    }
    if attribute(root,kAXChildrenAttribute as String) != nil {
        visit(root,0)
        result["count"] = count
        result["dockPID"] = dock.processIdentifier
    }
}
print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)
