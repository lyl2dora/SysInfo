// axpress <pid> <descSubstring> : find first AXButton whose AXDescription contains substring in pid's AX tree and AXPress it.
// Used only on MenuBarAgent's "show hidden menu bar items" chevron (UI-only, reversible).
import ApplicationServices
import Foundation
setvbuf(stdout, nil, _IOLBF, 0)
let pid = pid_t(Int32(CommandLine.arguments[1])!)
let needle = CommandLine.arguments[2]
func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
func find(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
    if (attr(e, kAXRoleAttribute) as? String) == "AXButton", let ds = attr(e, kAXDescriptionAttribute) as? String, ds.contains(needle) { return e }
    if d > 5 { return nil }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { if let f = find(c, d + 1) { return f } }
    return nil
}
guard let b = find(AXUIElementCreateApplication(pid), 0) else { print("axpress: not found"); exit(1) }
let r = AXUIElementPerformAction(b, kAXPressAction as CFString)
print("axpress: AXPress on '\(needle)' -> \(r.rawValue)")
