import AppKit
import Observation

@Observable @MainActor final class Metrics { var cpu: Double = 0; var other: Int = 0 }

final class GaugeView: NSView {
    let m: Metrics
    var draws = 0, layouts = 0
    init(_ m: Metrics) { self.m = m; super.init(frame: NSRect(x: 0, y: 0, width: 60, height: 22)) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { draws += 1; _ = m.cpu }
    override func layout() { super.layout(); layouts += 1; _ = m.cpu }
}

@main struct Main {
    @MainActor static func main() {
        _ = NSApplication.shared
        let m = Metrics()
        let v = GaugeView(m)
        // offscreen window, never ordered front
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 60, height: 22), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = v
        v.needsLayout = true
        v.layoutSubtreeIfNeeded()
        v.display()
        print("after initial display: draws=\(v.draws) layouts=\(v.layouts) needsDisplay=\(v.needsDisplay) needsLayout=\(v.needsLayout)")
        m.other = 5
        print("after untracked change: needsDisplay=\(v.needsDisplay) needsLayout=\(v.needsLayout)")
        m.cpu = 42
        print("after tracked cpu change: needsDisplay=\(v.needsDisplay) needsLayout=\(v.needsLayout)")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        print("after runloop: needsDisplay=\(v.needsDisplay) needsLayout=\(v.needsLayout)")
        v.layoutSubtreeIfNeeded(); v.displayIfNeeded()
        print("after displayIfNeeded: draws=\(v.draws) layouts=\(v.layouts)")
    }
}
