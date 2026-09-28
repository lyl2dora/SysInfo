// Read-only: build (never order on screen) a borderless non-activating NSPanel hosting NSGlassEffectView /
// NSGlassEffectContainerView / NSVisualEffectView and dump view + layer class trees, to see what backs each surface on macOS 27.
import AppKit

func dumpLayer(_ l: CALayer, _ depth: Int = 0) {
    guard depth < 6 else { return }
    let extra = l.filters.map { " filters=\($0.count)" } ?? ""
    print(String(repeating: "  ", count: depth) + "L:" + NSStringFromClass(type(of: l)) + " name=\(l.name ?? "-") cr=\(l.cornerRadius) curve=\(l.cornerCurve.rawValue)" + extra)
    for s in l.sublayers ?? [] { dumpLayer(s, depth + 1) }
}
func dumpView(_ v: NSView, _ depth: Int = 0) {
    guard depth < 6 else { return }
    print(String(repeating: "  ", count: depth) + "V:" + NSStringFromClass(type(of: v)) + " frame=\(v.frame)")
    for s in v.subviews { dumpView(s, depth + 1) }
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.backgroundColor = .clear
    panel.isOpaque = false
    let root = NSView(frame: panel.contentLayoutRect)
    root.wantsLayer = true
    panel.contentView = root

    let container = NSGlassEffectContainerView(frame: NSRect(x: 0, y: 0, width: 280, height: 120))
    let inner = NSView(frame: container.bounds)
    let g1 = NSGlassEffectView(frame: NSRect(x: 10, y: 10, width: 120, height: 100)); g1.cornerRadius = 18; g1.effectIsInteractive = true
    let g2 = NSGlassEffectView(frame: NSRect(x: 140, y: 10, width: 120, height: 100)); g2.style = .clear; g2.tintColor = .systemBlue
    let label = NSTextField(labelWithString: "CPU 12%")
    g1.contentView = label
    inner.addSubview(g1); inner.addSubview(g2)
    container.contentView = inner
    container.spacing = 8
    root.addSubview(container)

    let ve = NSVisualEffectView(frame: NSRect(x: 0, y: 130, width: 280, height: 70))
    ve.material = .popover; ve.blendingMode = .behindWindow; ve.state = .active
    root.addSubview(ve)

    root.layoutSubtreeIfNeeded()
    panel.displayIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))

    print("== view tree"); dumpView(root)
    print("\n== layer tree (panel never ordered on screen)")
    if let l = root.layer { dumpLayer(l) } else { print("root has no layer") }
    print("\ng1.effectIsInteractive=\(g1.effectIsInteractive) g1.cornerRadius=\(g1.cornerRadius) g1.effectiveCornerRadii.TL=\(g1.effectiveCornerRadii?.topLeft ?? -1)")
    print("g2.style=\(g2.style.rawValue) tint=\(String(describing: g2.tintColor))")
    print("panel.isVisible=\(panel.isVisible)")
    panel.close()
}
