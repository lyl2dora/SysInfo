import SwiftUI
import Charts
import Observation

struct Sample: Identifiable, Hashable { let id: Int; let t: Double; let v: Double }
struct Module: Identifiable, Hashable, Sendable { let id: String }
enum Pane: Hashable { case cpu, gpu, mem }
struct ProbeError: Error {}

@MainActor @Observable final class Store {
    var samples: [Sample] = (0..<120).map { Sample(id: $0, t: Double($0), v: Double($0 % 17)) }
    var modules: [Module] = [.init(id: "cpu"), .init(id: "gpu"), .init(id: "ram")]
    var showAvg = true
}

@main struct ProbeApp: App {
    @State private var store = Store()          // @State macro (lazy init) in 27 SDK
    var body: some Scene {
        MenuBarExtra("Probe", systemImage: "cpu") {
            Popover(store: store)
        }
        .menuBarExtraStyle(.window)
        Settings { SettingsView(store: store) }
        Window("Detail", id: "detail") { Popover(store: store) }
            .windowResizability(.contentSize)
    }
}

struct Popover: View {
    let store: Store
    @Namespace private var ns
    @Environment(\.systemPrefersReducedResourceUsage) private var reduced   // new 27
    @Environment(\.appearsActive) private var active
    @State private var pane: Pane = .cpu
    @State private var err: ProbeError?
    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                Picker("Pane", selection: $pane) {
                    Text("CPU").tag(Pane.cpu); Text("GPU").tag(Pane.gpu); Text("Mem").tag(Pane.mem)
                }
                .pickerStyle(.tabs)                                   // new 27
                Chart {
                    LinePlot(store.samples, x: .value("t", \.t), y: .value("v", \.v))  // vectorized (15.0)
                    if store.showAvg {                                  // _ConditionalContent : ChartContent (27)
                        RuleMark(y: .value("avg", 8))
                    }
                }
                .frame(height: reduced ? 60 : 120)
                GeometryReader { g in
                    let r = g.concentricCornerRadii ?? .init()          // new 27
                    UnevenRoundedRectangle(cornerRadii: r).fill(.tint.opacity(0.2))
                }
                .frame(height: 20)
                HStack {
                    Button("Refresh") {}.buttonStyle(.glass)
                    Button("Open") {}.buttonStyle(.glassProminent)
                    Button("Tinted") {}.buttonStyle(.glass(.regular.tint(.orange).interactive()))
                }
                .glassEffectID("buttons", in: ns)
            }
            .padding()
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
        .alert(error: $err) { Button("OK") {} }                        // new 27 (any Error)
        .onChange(of: pane) { _, _ in }
    }
}

struct SettingsView: View {
    @Bindable var store: Store
    @State private var name = ""
    var body: some View {
        Form {
            TextField("Name", text: $name)
                .textFieldStyle(.bordered)                             // new 27
                .textInputBorderShape(.capsule)                        // new 27
            List {
                ForEach(store.modules) { m in Text(m.id) }
                    .reorderable()                                     // new 27
            }
            .reorderContainer(for: Module.self) { diff in              // new 27
                let moving = store.modules.filter { diff.sources.contains($0.id) }
                store.modules.removeAll { diff.sources.contains($0.id) }
                switch diff.destination.position {
                case .before(let id):
                    let i = store.modules.firstIndex { $0.id == id } ?? store.modules.endIndex
                    store.modules.insert(contentsOf: moving, at: i)
                case .end:
                    store.modules.append(contentsOf: moving)
                @unknown default: break
                }
            }
        }
        .toolbar {
            ToolbarItem { Button("A") {} }.contentMarginsRemoved()    // new 27
            ToolbarSpacer(.fixed)
            ToolbarItem { Button("B") {} }.visibilityPriority(.init(higherThan: .low))  // 26.1 / 27 init
        }
    }
}

#Preview("args", arguments: [1, 2, 3]) { n in Text("\(n)") }         // new 27
