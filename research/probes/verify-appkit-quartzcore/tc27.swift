import AppKit
import SwiftUI

final class Del: NSObject, @MainActor NSStatusItemExpandedInterfaceDelegate {
  func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {}
  func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {}
}

final class Card: NSView {
  override var cornerConfiguration: NSViewCornerConfiguration? { .uniformCorners(radius: .containerConcentric(4)) }
  override func viewDidChangeEffectiveCornerRadii() { _ = effectiveCornerRadii?.topLeft }
}

@MainActor func f(_ si: NSStatusItem, _ d: Del) {
  si.expandedInterfaceDelegate = d
  si.expandedInterfaceSession?.cancel()
  si.view = NSView()
  si.target = d
  si.action = #selector(NSObject.copy)
  let g = NSGlassEffectView(); g.effectIsInteractive = true
  let mi = NSMenuItem(); mi.preferredImageVisibility = .visible
  let sc = NSSegmentedControl(); sc.role = .tabs
  let b = NSButton(); b.addTarget(d, action: #selector(NSObject.copy), for: [.primaryActionTriggered, .valueChanged])
  _ = NotificationCenter.default.addObserver(of: NSApplication.shared, for: .didChangeScreenParameters) { _ in }
  _ = NSScreen.main?.touchCapabilities
}

struct V: View {
  @Environment(\.systemPrefersReducedResourceUsage) var reduced
  var body: some View { GeometryReader { p in Text(verbatim: "\(p.concentricCornerRadii?.topLeading ?? 0) \(reduced)") } }
}
