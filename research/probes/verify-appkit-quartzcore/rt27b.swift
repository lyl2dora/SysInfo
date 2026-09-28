import AppKit
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
  let g = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 200, height: 120)); g.cornerRadius = 24
  let win = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 200, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
  win.contentView = g
  let holder = NSView(frame: g.bounds); g.contentView = holder
  let card = Card(frame: NSRect(x: 8, y: 8, width: 184, height: 104)); holder.addSubview(card)
  let card0 = Card(frame: NSRect(x: 0, y: 0, width: 50, height: 50)); holder.addSubview(card0)
  win.layoutIfNeeded(); win.displayIfNeeded()
  print("holder frame:", holder.frame, "card frame:", card.frame)
  print("card inset 8 in glass r=24, .containerConcentric(4):", r(card), "callbacks:", card.calls)
  print("card0 at corner (0,0) 50x50:", r(card0))
  card.cfg = .uniformCorners(radius: .containerConcentric(20)); card.invalidateCornerConfiguration(); win.layoutIfNeeded()
  print("card inset 8, min 20 after invalidate:", r(card), "callbacks:", card.calls)
  let tw = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 400, height: 300), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
  let tc = Card(frame: NSRect(x: 0, y: 0, width: 400, height: 300)); tc.cfg = .uniformCorners(radius: .containerConcentric)
  tw.contentView = tc; tw.layoutIfNeeded(); tw.displayIfNeeded()
  print("titled window contentView frame:", tc.frame, "radii:", r(tc))
  let tw2 = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 400, height: 300), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
  let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)); tw2.contentView = root
  let tc2 = Card(frame: NSRect(x: 0, y: 0, width: 400, height: 250)); tc2.cfg = .uniformCorners(radius: .containerConcentric); root.addSubview(tc2)
  tw2.layoutIfNeeded(); tw2.displayIfNeeded()
  print("fullSize window, subview bottom 400x250:", r(tc2))
}
MainActor.assumeIsolated { run() }
