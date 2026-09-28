import SwiftUI
import AppKit
import Observation

nonisolated(unsafe) var modelInits = 0
@Observable final class Model {
    var cpu: Double = 0
    init() { modelInits += 1 }
}

struct Probe: View {
    @State private var model = Model()
    let tag: Int
    var body: some View { Text("tag \(tag) cpu \(model.cpu)") }
}

@MainActor func run() {
    // 1) constructing the view struct repeatedly (what a parent re-render does)
    for i in 0..<5 { _ = Probe(tag: i) }
    print("after 5 Probe() struct inits, Model.init count =", modelInits)
    // 2) host it and force layout, then replace rootView several times (parent re-render)
    let host = NSHostingView(rootView: Probe(tag: 100))
    host.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
    host.layoutSubtreeIfNeeded()
    print("after hosting + layout, Model.init count =", modelInits)
    for i in 0..<5 {
        host.rootView = Probe(tag: 200 + i)
        host.layoutSubtreeIfNeeded()
    }
    print("after 5 rootView replacements, Model.init count =", modelInits)
}
@main struct Main { static func main() { MainActor.assumeIsolated { run() } } }
