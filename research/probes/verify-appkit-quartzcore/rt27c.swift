import AppKit
func dump(_ l: CALayer, _ d: Int, _ out: inout [String]) {
  out.append(String(repeating: " ", count: d) + String(describing: type(of: l)) + (l.name.map { " '\($0)'" } ?? "") + (l.filters.map { " filters=\($0.count)" } ?? ""))
  l.sublayers?.forEach { dump($0, d + 1, &out) }
}
@MainActor func run() {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let w = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 120, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
  let ve = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 120, height: 120)); ve.material = .popover; ve.state = .active; ve.blendingMode = .behindWindow
  w.contentView = ve
  w.orderFrontRegardless()
  w.displayIfNeeded(); CATransaction.flush()
  RunLoop.main.run(until: Date().addingTimeInterval(0.3))
  var out: [String] = []; if let l = ve.layer { dump(l, 0, &out) }
  print("window frame (offscreen):", w.frame, "onscreen? ", w.isOnActiveSpace)
  print("NSVisualEffectView(.popover, behindWindow) layer tree:\n" + out.joined(separator: "\n"))
  w.orderOut(nil)
}
MainActor.assumeIsolated { run() }
