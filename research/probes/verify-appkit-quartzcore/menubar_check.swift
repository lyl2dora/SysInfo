import AppKit
import CoreGraphics
let opts: CGWindowListOption = [.optionAll]
let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []
print("total windows:", list.count)
var byLayer: [Int: Int] = [:]
for w in list {
  let layer = w[kCGWindowLayer as String] as? Int ?? -999
  byLayer[layer, default: 0] += 1
  if layer >= 20 && layer <= 30 {
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
    let name = w[kCGWindowName as String] as? String ?? ""
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("layer=\(layer) pid=\(pid) owner=\(owner) name=\(name) bounds=\(b["X"] ?? 0),\(b["Y"] ?? 0) \(b["Width"] ?? 0)x\(b["Height"] ?? 0) onscreen=\(w[kCGWindowIsOnscreen as String] ?? "nil")")
  }
}
print("kCGStatusWindowLevel =", CGWindowLevelForKey(.statusWindow))
print("kCGMainMenuWindowLevel =", CGWindowLevelForKey(.mainMenuWindow))
print("layers:", byLayer.sorted{ $0.key < $1.key }.map{ "\($0.key):\($0.value)" }.joined(separator: " "))
_ = NSApplication.shared
print("NSStatusBar.system.thickness =", NSStatusBar.system.thickness)
for s in NSScreen.screens {
  print("screen frame=\(s.frame) visible=\(s.visibleFrame) scale=\(s.backingScaleFactor) gap=\(s.frame.maxY - s.visibleFrame.maxY) safeTop=\(s.safeAreaInsets.top) auxTopLeft=\(String(describing: s.auxiliaryTopLeftArea))")
}
print("NSMenu.menuBarVisible:", NSMenu.menuBarVisible())
print("mainMenu menuBarHeight:", NSApp.mainMenu?.menuBarHeight ?? -1)
