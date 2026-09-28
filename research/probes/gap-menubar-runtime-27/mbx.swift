// Minimal MenuBarExtra label-update isolation probe. Variant via env MBX_V, runs MBX_SECS seconds.
// 0 static SF symbol | 1 Text | 2 Image+Text | 3 Image(nsImage) replaced per tick | 4 fixed-width Text
// 5 Text + @Environment(systemPrefersReducedResourceUsage) | 6 Text + onAppear | 7 Text + colorScheme | 8 Text + onChange(reduced)
// 9 App observes model + isInserted binding | 10 .menuBarExtraStyle(.window) | 11 = 9 + 10
// 12 label mutates a (non-published) model property in body (as mbprobe did) | 13 = 11 + 12
// 15 App observes per-tick model, no isInserted | 16 isInserted bound to a separate static model | 17 isInserted bound to @State
// 18 isInserted(static model) flipped false at 3s with per-tick Text label | 19 same with static label
// 14 Image(nsImage:) allocating a NEW NSImage in body each evaluation
import SwiftUI
import AppKit

let V = Int(ProcessInfo.processInfo.environment["MBX_V"] ?? "0") ?? 0
let SECS = Double(ProcessInfo.processInfo.environment["MBX_SECS"] ?? "10") ?? 10
let T0 = Date()
func log(_ s: String) { print(String(format: "[%7.3f] ", Date().timeIntervalSince(T0)) + s) }
var evals = 0
var ticks = 0
final class Model: ObservableObject {
    static let shared = Model()
    @Published var n = 0
    @Published var inserted = true
    @Published var img = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)!
    var counter = 0
}
func freshImage(_ w: Int) -> NSImage {
    let s = NSImage(size: NSSize(width: 40, height: 16), flipped: false) { _ in NSColor.black.setFill(); NSRect(x: 0, y: 0, width: CGFloat(w % 40), height: 16).fill(); return true }
    s.isTemplate = true; return s
}
struct L1: View { @ObservedObject var m = Model.shared; var body: some View { evals += 1; return Text("\(m.n)%") } }
struct L2: View { @ObservedObject var m = Model.shared; var body: some View { evals += 1; return HStack(spacing: 2) { Image(systemName: "cpu"); Text("\(m.n)%").monospacedDigit() } } }
struct L3: View { @ObservedObject var m = Model.shared; var body: some View { evals += 1; return Image(nsImage: m.img) } }
struct L4: View { @ObservedObject var m = Model.shared; var body: some View { evals += 1; return Text(String(format: "%2d%%", m.n)).monospacedDigit().frame(width: 40) } }
struct L5: View { @ObservedObject var m = Model.shared; @Environment(\.systemPrefersReducedResourceUsage) var reduced; var body: some View { evals += 1; return Text("\(m.n)% \(reduced ? "R" : "")") } }
struct L6: View { @ObservedObject var m = Model.shared; var body: some View { evals += 1; return Text("\(m.n)%").onAppear { log("L6 onAppear") } } }
struct L7: View { @ObservedObject var m = Model.shared; @Environment(\.colorScheme) var cs; var body: some View { evals += 1; return Text("\(m.n)%") } }
struct L8: View { @ObservedObject var m = Model.shared; @Environment(\.systemPrefersReducedResourceUsage) var reduced; var body: some View { evals += 1; return Text("\(m.n)%").onChange(of: reduced) { _, n in log("reduced -> \(n)") } } }
struct L12: View { @ObservedObject var m = Model.shared; var body: some View { evals += 1; m.counter += 1; return Text("\(m.n)%") } }
struct L14: View { @ObservedObject var m = Model.shared; var body: some View { evals += 1; return Image(nsImage: freshImage(m.n)) } }

func commonInit() {
    setvbuf(stdout, nil, _IOLBF, 0)
    NSApplication.shared.setActivationPolicy(.accessory)
    log("variant \(V) start")
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        ticks += 1; Model.shared.n = (ticks * 37) % 100
        if V == 3 { Model.shared.img = freshImage(ticks) }
        log("tick \(ticks) evals=\(evals)")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + SECS) {
        var ru = rusage(); getrusage(RUSAGE_SELF, &ru)
        log(String(format: "SUMMARY variant=%d ticks=%d labelEvals=%d cpu=%.3f", V, ticks, evals, Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec)/1e6 + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec)/1e6))
        exit(0)
    }
}
struct Label0: View {
    var body: some View {
        switch V {
        case 0: Image(systemName: "cpu")
        case 1: L1()
        case 2: L2()
        case 3: L3()
        case 4: L4()
        case 5: L5()
        case 6: L6()
        case 7: L7()
        case 8: L8()
        case 12: L12()
        case 14: L14()
        default: L1()
        }
    }
}
struct MBX: App {
    init() { commonInit() }
    var body: some Scene { MenuBarExtra { Text("content") } label: { Label0() } }
}
struct App9: App {
    @ObservedObject var model = Model.shared
    init() { commonInit() }
    var body: some Scene { MenuBarExtra(isInserted: $model.inserted) { Text("content") } label: { L1() } }
}
struct App10: App {
    init() { commonInit() }
    var body: some Scene { MenuBarExtra { Text("content") } label: { L1() }.menuBarExtraStyle(.window) }
}
struct App11: App {
    @ObservedObject var model = Model.shared
    init() { commonInit() }
    var body: some Scene { MenuBarExtra(isInserted: $model.inserted) { Text("content") } label: { L1() }.menuBarExtraStyle(.window) }
}
struct App13: App {
    @ObservedObject var model = Model.shared
    init() { commonInit() }
    var body: some Scene { MenuBarExtra(isInserted: $model.inserted) { Text("content") } label: { L12() }.menuBarExtraStyle(.window) }
}
final class InsertModel: ObservableObject { static let shared = InsertModel(); @Published var inserted = true }
struct App15: App {
    @ObservedObject var model = Model.shared
    init() { commonInit() }
    var body: some Scene { MenuBarExtra { Text("content") } label: { L1() } }
}
struct App16: App {
    @ObservedObject var ins = InsertModel.shared
    init() { commonInit() }
    var body: some Scene { MenuBarExtra(isInserted: $ins.inserted) { Text("content") } label: { L1() } }
}
struct App17: App {
    @State var inserted = true
    init() { commonInit() }
    var body: some Scene { MenuBarExtra(isInserted: $inserted) { Text("content") } label: { L1() } }
}
struct App18: App {
    // isInserted bound to a static model that is NOT touched per tick; flipped to false at t=3s (removal)
    @ObservedObject var ins = InsertModel.shared
    init() { commonInit(); DispatchQueue.main.asyncAfter(deadline: .now() + 3) { log("setting inserted=false"); InsertModel.shared.inserted = false; DispatchQueue.main.async { log("after inserted=false runloop turn") } } }
    var body: some Scene { MenuBarExtra(isInserted: $ins.inserted) { Text("content") } label: { L1() } }
}
struct App19: App {
    // same as 18 but static label (no per-tick label change)
    @ObservedObject var ins = InsertModel.shared
    init() { commonInit(); DispatchQueue.main.asyncAfter(deadline: .now() + 3) { log("setting inserted=false"); InsertModel.shared.inserted = false; DispatchQueue.main.async { log("after inserted=false runloop turn") } } }
    var body: some Scene { MenuBarExtra("CPU", systemImage: "cpu", isInserted: $ins.inserted) { Text("content") } }
}
@main enum Entry {
    static func main() {
        switch V { case 9: App9.main(); case 10: App10.main(); case 11: App11.main(); case 13: App13.main(); case 15: App15.main(); case 16: App16.main(); case 17: App17.main(); case 18: App18.main(); case 19: App19.main(); default: MBX.main() }
    }
}
