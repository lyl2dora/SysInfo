// axdump <pid> [maxDepth] : dump AX tree of a process (requires Accessibility trust of the responsible process; checked without prompting)
import ApplicationServices
import AppKit
setvbuf(stdout, nil, _IOLBF, 0)
let pid = pid_t(CommandLine.arguments.count > 1 ? Int32(CommandLine.arguments[1])! : 462)
let maxDepth = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 4
print("AXIsProcessTrusted =", AXIsProcessTrusted())
func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
func str(_ e: AXUIElement, _ a: String) -> String? { attr(e, a) as? String }
func pt(_ e: AXUIElement) -> String {
    var p = CGPoint.zero, s = CGSize.zero
    if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return "(\(Int(p.x)),\(Int(p.y)) \(Int(s.width))x\(Int(s.height)))"
}
func dump(_ e: AXUIElement, _ d: Int) {
    var names: CFArray?
    AXUIElementCopyAttributeNames(e, &names)
    let an = (names as? [String]) ?? []
    let extra = an.filter { !["AXRole","AXSubrole","AXTitle","AXDescription","AXIdentifier","AXPosition","AXSize","AXChildren","AXParent","AXTopLevelUIElement","AXWindow","AXFrame","AXRoleDescription","AXEnabled","AXFocused","AXSelected","AXChildrenInNavigationOrder"].contains($0) }
    var ex = ""
    for a in extra.prefix(12) { if let v = attr(e, a) { let sv = "\(v)".replacingOccurrences(of: "\n", with: " "); if sv.count < 60 { ex += " \(a)=\(sv)" } } }
    print(String(repeating: "  ", count: d) + "\(str(e, kAXRoleAttribute) ?? "?")/\(str(e, kAXSubroleAttribute) ?? "-") title='\(str(e, kAXTitleAttribute) ?? "")' desc='\(str(e, kAXDescriptionAttribute) ?? "")' id='\(str(e, kAXIdentifierAttribute) ?? "")' \(pt(e))" + ex)
    if d >= maxDepth { return }
    if let ch = attr(e, kAXChildrenAttribute) as? [AXUIElement] { for c in ch { dump(c, d + 1) } }
}
let app = AXUIElementCreateApplication(pid)
if let extras = attr(app, "AXExtrasMenuBar") { print("== AXExtrasMenuBar of pid \(pid)"); dump(extras as! AXUIElement, 0) } else { print("== no AXExtrasMenuBar for pid \(pid)") }
if CommandLine.arguments.contains("--full") { print("== full app tree"); dump(app, 0) }
