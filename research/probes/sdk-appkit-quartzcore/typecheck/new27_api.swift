import AppKit

@MainActor
final class Expanded: NSObject, NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBeginExpandedInterfaceSession session: NSStatusItemExpandedInterfaceSession) {}
    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {}
}

final class Rounded: NSView {
    override var cornerConfiguration: NSViewCornerConfiguration? { .corners(radius: .containerConcentric(8)) }
    override func viewDidChangeEffectiveCornerRadii() { super.viewDidChangeEffectiveCornerRadii(); _ = effectiveCornerRadii?.topLeft }
}

@MainActor
func probe27(_ item: NSStatusItem, _ d: Expanded) {
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
    _ = NSColor.quinaryLabel
    Task { @MainActor in
        for await _ in NotificationCenter.default.messages(of: NSApplication.self, for: .didChangeScreenParameters) { break }
    }
    _ = NSViewCornerConfiguration.capsule(maximumRadius: 12)
    _ = NSViewCornerConfiguration.uniformCorners(radius: .fixed(10))
}
