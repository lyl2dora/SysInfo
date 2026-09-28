import AppKit
@MainActor final class Del: NSObject, NSStatusItemExpandedInterfaceDelegate {
  var panel: NSPanel?
  func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) { panel?.orderFront(nil) }
  func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) { panel?.orderOut(nil) }
}
