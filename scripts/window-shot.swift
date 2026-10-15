import ApplicationServices
import CoreGraphics
import Foundation
// 截图自查（CLAUDE.md「UI 用截图自查」，D39）：截 SysInfo Dev 的窗口（面板或设置窗口）。
// 用法：swift scripts/window-shot.swift <输出 png> [滚动位置 0…1]
// 给了滚动位置时，先用辅助功能接口设置窗口里最后一个滚动区的竖直滚动条（SwiftUI Form 不响应合成滚轮事件）。
// 需要调用方（终端或 sshd-keygen-wrapper）有屏幕录制与辅助功能权限。
let args = CommandLine.arguments
let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as! [[String: Any]]
// 取 SysInfo Dev 最大的那个窗口：面板在 popUpMenu 层级，设置窗口在普通层级；菜单栏 item 的窗口很小，自然排除。
let mine = list.filter { ($0["kCGWindowOwnerName"] as? String) == "SysInfo Dev" }
func area(_ w: [String: Any]) -> Double {
    let b = w["kCGWindowBounds"] as? [String: Double] ?? [:]
    return (b["Width"] ?? 0) * (b["Height"] ?? 0)
}
guard let w = mine.max(by: { area($0) < area($1) }), area(w) > 100 * 100,
      let number = w["kCGWindowNumber"] as? Int, let pid = w["kCGWindowOwnerPID"] as? Int else {
    print("no window (owner windows: \(mine.count))"); exit(1)
}
func children(_ e: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v)
    return (v as? [AXUIElement]) ?? []
}
func role(_ e: AXUIElement) -> String {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &v)
    return (v as? String) ?? ""
}
var bars: [AXUIElement] = []
func walk(_ e: AXUIElement, _ depth: Int) {
    if depth > 30 { return }
    if role(e) == kAXScrollAreaRole as String {
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(e, kAXVerticalScrollBarAttribute as CFString, &v) == .success, let v { bars.append(v as! AXUIElement) }
    }
    for c in children(e) { walk(c, depth + 1) }
}
if args.count > 2, let pos = Double(args[2]) {
    walk(AXUIElementCreateApplication(pid_t(pid)), 0)
    // 最后一个滚动区是详情页（侧栏在前）
    if let bar = bars.last {
        let r = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: pos))
        print("scroll bars \(bars.count), set \(pos): \(r.rawValue)")
    } else { print("no scroll bar") }
    usleep(500000)
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
p.arguments = ["-x", "-o", "-l", "\(number)", args[1]]
try p.run(); p.waitUntilExit()
print("ok")
