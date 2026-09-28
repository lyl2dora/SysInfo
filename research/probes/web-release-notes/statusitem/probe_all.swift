// Probe: does an NSStatusItem still get its own window on macOS 27, and what does CGWindowList show for the menu bar?
import AppKit

final class D: NSObject, NSApplicationDelegate, NSStatusItemExpandedInterfaceDelegate {
    var item: NSStatusItem!
    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) { print("didBegin") }
    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) { print("didEnd") }
    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "PROBE"
        item.expandedInterfaceDelegate = self
        print("statusBar thickness:", NSStatusBar.system.thickness)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let w = self.item.button?.window
            print("button.window:", w.map { "\(type(of: $0)) num=\($0.windowNumber) frame=\($0.frame) level=\($0.level.rawValue)" } ?? "nil")
            print("item.isVisible:", self.item.isVisible, "expandedInterfaceSession:", String(describing: self.item.expandedInterfaceSession))
            let myPid = ProcessInfo.processInfo.processIdentifier
            let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
            if let s = NSScreen.main { print("main screen frame:", s.frame, "visibleFrame:", s.visibleFrame, "menubar height (frame.maxY - visible.maxY):", s.frame.maxY - s.visibleFrame.maxY) }
            print("total windows (optionAll):", info.count)
            var mine = 0, statusLayer = 0
            var owners: [String: Int] = [:]
            for d in info {
                let layer = d[kCGWindowLayer as String] as? Int ?? 0
                let pid = d[kCGWindowOwnerPID as String] as? Int32 ?? 0
                let owner = d[kCGWindowOwnerName as String] as? String ?? "?"
                if pid == myPid { mine += 1; print("  my window: layer=\(layer) bounds=\(d[kCGWindowBounds as String] ?? "") name=\(d[kCGWindowName as String] ?? "")") }
                if layer == 25 { statusLayer += 1; owners[owner, default: 0] += 1 }   // kCGStatusWindowLevel = 25
                if layer == 24 { owners["[layer24] " + owner, default: 0] += 1 }       // main menu level
            }
            print("windows owned by probe pid:", mine)
            print("windows (all) at status layer(25):", statusLayer)
            print("owners at layers 24/25:", owners.sorted { $0.key < $1.key })
            NSStatusBar.system.removeStatusItem(self.item)
            NSApp.terminate(nil)
        }
    }
}
let app = NSApplication.shared
let d = D()
app.delegate = d
app.setActivationPolicy(.accessory)
app.run()
