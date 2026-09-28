import AppKit

// Typecheck-level use of macOS 27 AppKit APIs relevant to a menu-bar monitor.
final class ExpandedDelegate: NSObject, NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {}
    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {}
}
@MainActor func typecheckOnly(_ item: NSStatusItem, _ d: ExpandedDelegate) {
    item.expandedInterfaceDelegate = d
    item.expandedInterfaceSession?.cancel()
    item.view = NSView()          // un-deprecated in the 27 SDK
    item.target = nil; item.action = nil
    let mi = NSMenuItem(title: "CPU", action: nil, keyEquivalent: "")
    mi.preferredImageVisibility = .visible
    let g = NSGlassEffectView(); g.effectIsInteractive = true
    let seg = NSSegmentedControl(); seg.role = .tabs
    _ = g.cornerConfiguration; _ = g.effectiveCornerRadii
    _ = NSViewCornerConfiguration.corners(radius: .containerConcentric)
}

@main struct Main {
    static func main() {
        func sel(_ c: AnyClass, _ s: String) -> String { "\(c).\(s): \((c as! NSObject.Type).instancesRespond(to: NSSelectorFromString(s)))" }
        print(sel(NSStatusItem.self, "expandedInterfaceDelegate"))
        print(sel(NSStatusItem.self, "setExpandedInterfaceDelegate:"))
        print(sel(NSStatusItem.self, "expandedInterfaceSession"))
        print("NSStatusItemExpandedInterfaceSession class:", NSClassFromString("NSStatusItemExpandedInterfaceSession") != nil)
        print(sel(NSStatusItem.self, "view"))
        print(sel(NSMenuItem.self, "preferredImageVisibility"))
        print(sel(NSGlassEffectView.self, "effectIsInteractive"))
        print(sel(NSSegmentedControl.self, "role"))
        print(sel(NSView.self, "cornerConfiguration"))
        print(sel(NSView.self, "effectiveCornerRadii"))
        print("NSViewCornerConfiguration class:", NSClassFromString("NSViewCornerConfiguration") != nil)
        let mi = NSMenuItem(title: "x", action: nil, keyEquivalent: "")
        print("NSMenuItem default preferredImageVisibility rawValue:", mi.preferredImageVisibility.rawValue)
        let g = NSGlassEffectView()
        print("NSGlassEffectView default effectIsInteractive:", g.effectIsInteractive)
    }
}
