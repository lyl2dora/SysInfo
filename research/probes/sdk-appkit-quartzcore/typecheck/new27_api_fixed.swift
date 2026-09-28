import AppKit

final class Expanded: NSObject, @MainActor NSStatusItemExpandedInterfaceDelegate {
    @MainActor func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {}
    @MainActor func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {}
}

final class Rounded: NSView {
    override var cornerConfiguration: NSViewCornerConfiguration? { .corners(radius: .containerConcentric(8)) }
    override func viewDidChangeEffectiveCornerRadii() { super.viewDidChangeEffectiveCornerRadii(); _ = effectiveCornerRadii?.topLeft }
}

@MainActor
func probe27(_ item: NSStatusItem, _ d: Expanded) -> Any {
    item.expandedInterfaceDelegate = d
    item.expandedInterfaceSession?.cancel()
    let g = NSGlassEffectView()
    g.effectIsInteractive = true
    let mi = NSMenuItem(title: "CPU", action: nil, keyEquivalent: "")
    mi.preferredImageVisibility = .visible
    let seg = NSSegmentedControl()
    seg.role = .valueSelection
    let b = NSButton()
    b.addTarget(nil, action: #selector(NSText.copy(_:)), for: .primaryActionTriggered)
    let tf = NSTextField()
    tf.borderShape = .capsule
    _ = NSColor.quinaryLabelColor
    let token = NotificationCenter.default.addObserver(of: NSApplication.self, for: .didChangeScreenParameters) { _ in }
    _ = NSViewCornerConfiguration.capsule(maximumRadius: 12)
    _ = NSViewCornerConfiguration.uniformCorners(radius: .fixed(10))
    return token
}
