import CoreGraphics
import Foundation
let targets = ["Stats", "Control Center", "控制中心", "MenuBarAgent", "SystemUIServer", "Window Server"]
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
  let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
  guard targets.contains(where: { owner.contains($0) }) else { continue }
  let layer = w[kCGWindowLayer as String] as? Int ?? -999
  let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
  let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
  print("owner=\(owner) pid=\(pid) layer=\(layer) bounds=\(b["X"] ?? 0),\(b["Y"] ?? 0) \(b["Width"] ?? 0)x\(b["Height"] ?? 0) onscreen=\(w[kCGWindowIsOnscreen as String] ?? "nil") name=\(w[kCGWindowName as String] ?? "")")
}
let l25 = list.filter { ($0[kCGWindowLayer as String] as? Int) == 25 }.count
print("windows at kCGStatusWindowLevel(25):", l25)
