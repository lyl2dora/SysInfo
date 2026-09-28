import AppKit
import ObjectiveC

final class Card: NSView {
  var cfg: NSViewCornerConfiguration? = .uniformCorners(radius: .containerConcentric(4))
  var calls = 0
  override var cornerConfiguration: NSViewCornerConfiguration? { cfg }
  override func viewDidChangeEffectiveCornerRadii() { calls += 1 }
}
func r(_ v: NSView) -> String {
  guard let c = v.effectiveCornerRadii else { return "nil" }
  return "TL=\(c.topLeft) TR=\(c.topRight) BL=\(c.bottomLeft) BR=\(c.bottomRight)"
}
@MainActor func run() {
  let app = NSApplication.shared
  app.setActivationPolicy(.prohibited)
  print("OS:", ProcessInfo.processInfo.operatingSystemVersionString)
  for c in ["NSStatusItemExpandedInterfaceSession","NSViewCornerConfiguration","NSViewCornerRadius","NSViewCornerRadii","NSRefreshController","NSGlassEffectView","NSGlassEffectContainerView","NSStatusItemAuxiliaryHostingView","NSTextSelectionManager"] {
    print("class \(c):", NSClassFromString(c) != nil ? "present" : "ABSENT")
  }
  let sel: [(AnyClass, String)] = [(NSStatusItem.self,"expandedInterfaceDelegate"),(NSStatusItem.self,"setExpandedInterfaceDelegate:"),(NSStatusItem.self,"expandedInterfaceSession"),(NSStatusItem.self,"view"),(NSGlassEffectView.self,"effectIsInteractive"),(NSMenuItem.self,"preferredImageVisibility"),(NSSegmentedControl.self,"role"),(NSControl.self,"addTarget:action:forControlEvents:"),(NSView.self,"effectiveCornerRadii"),(NSScreen.self,"touchCapabilities")]
  for (cls, s) in sel { print("\(cls).\(s):", class_getInstanceMethod(cls, NSSelectorFromString(s)) != nil ? "yes" : "NO") }
  let g = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
  print("glass defaults: style=\(g.style.rawValue) cornerRadius=\(g.cornerRadius) tint=\(String(describing: g.tintColor)) interactive=\(g.effectIsInteractive)")
  g.effectIsInteractive = true
  print("glass interactive after set:", g.effectIsInteractive)
  g.cornerRadius = 24
  let win = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
  win.contentView = g
  let card = Card(frame: NSRect(x: 8, y: 8, width: 184, height: 104))
  g.contentView = card
  card.layoutSubtreeIfNeeded(); g.layoutSubtreeIfNeeded(); win.displayIfNeeded()
  print("glass effectiveCornerRadii:", r(g))
  print("card (.containerConcentric(4), inset 8 in r=24):", r(card), "callbacks:", card.calls)
  let cap = Card(frame: NSRect(x: 0, y: 0, width: 100, height: 40)); cap.cfg = .capsule
  print("capsule 100x40:", r(cap))
  let fx = Card(frame: NSRect(x: 0, y: 0, width: 100, height: 40)); fx.cfg = .uniformCorners(radius: .fixed(10))
  print("fixed 10:", r(fx))
  let tw = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 400, height: 300), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
  let tc = Card(frame: NSRect(x: 0, y: 0, width: 400, height: 300)); tc.cfg = .uniformCorners(radius: .containerConcentric)
  tw.contentView = tc; tc.layoutSubtreeIfNeeded()
  print("titled window contentView (containerConcentric):", r(tc))
  print("plain NSView (no config):", r(NSView()))
  let mi = NSMenuItem(title: "x", action: nil, keyEquivalent: "")
  print("NSMenuItem.preferredImageVisibility default:", mi.preferredImageVisibility.rawValue)
  print("NSSegmentedControl.role default:", NSSegmentedControl().role.rawValue)
  print("NSStatusBar.system.thickness:", NSStatusBar.system.thickness)
  print("reduceTransparency:", NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
  print("touchCapabilities main:", NSScreen.main?.touchCapabilities.rawValue ?? 999)
  // NSVisualEffectView layer classes
  let ve = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)); ve.material = .popover; ve.state = .active
  let w2 = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
  w2.contentView = ve; ve.layoutSubtreeIfNeeded(); w2.displayIfNeeded()
  var names: [String] = []
  func walk(_ l: CALayer, _ d: Int) { names.append(String(repeating: " ", count: d) + String(describing: type(of: l)) + (l.name.map{" '\($0)'"} ?? "")); l.sublayers?.forEach { walk($0, d+1) } }
  if let l = ve.layer { walk(l, 0) }
  print("NSVisualEffectView(.popover) layers:\n" + names.joined(separator: "\n"))
  var gnames: [String] = []
  func walk2(_ l: CALayer, _ d: Int) { gnames.append(String(repeating: " ", count: d) + String(describing: type(of: l))); l.sublayers?.forEach { walk2($0, d+1) } }
  if let l = g.layer { walk2(l, 0) }
  print("NSGlassEffectView layers (first 15):\n" + gnames.prefix(15).joined(separator: "\n"))
  var sv: [String] = []
  func walkv(_ v: NSView, _ d: Int) { sv.append(String(repeating: " ", count: d) + String(describing: type(of: v))); v.subviews.forEach { walkv($0, d+1) } }
  walkv(g, 0)
  print("NSGlassEffectView subviews:\n" + sv.joined(separator: "\n"))
}
MainActor.assumeIsolated { run() }
