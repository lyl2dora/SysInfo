// 探针 host：不开沙盒的 LSUIElement app，定时往组容器写快照，可选地调用 reloadTimelines。
//
// 参数：
//   --interval S      每 S 秒写一次快照（默认 60；0 = 只写一次）
//   --reload-every S  每 S 秒调用一次 reloadAllTimelines（默认 0 = 不调用）
//   --reload-on-write 每次写快照后都调用 reloadAllTimelines
//   --points N        快照里曲线的点数
//   --pad-kb K        快照填充大小
//   --ballast-mb M    让扩展额外分配 M MB
//   --exit-after S    S 秒后退出（默认不退出）
//   --activate        开一个窗口并切到前台（B3）
import AppKit
import WidgetKit

final class HostDelegate: NSObject, NSApplicationDelegate {
    var timers: [Timer] = []
    var window: NSWindow?

    func arg(_ name: String) -> Double? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return Double(a[i + 1])
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let has = { CommandLine.arguments.contains($0) }
        let interval = arg("--interval") ?? 60
        let reloadEvery = arg("--reload-every") ?? 0
        let reloadOnWrite = has("--reload-on-write")
        Probe.event("host.launch", ["args": Array(CommandLine.arguments.dropFirst()), "group": Probe.group, "groupURL": Probe.groupURL?.path ?? "nil"])

        _ = ProbeSnapshot.bump(reason: "launch", points: arg("--points").map(Int.init), padKB: arg("--pad-kb").map(Int.init), ballastMB: arg("--ballast-mb").map(Int.init))
        if reloadOnWrite { reload("on-write") }

        Task {
            do {
                let c = try await WidgetCenter.shared.currentConfigurations()
                Probe.event("host.configs", ["count": c.count, "items": c.map { "\($0.kind)/\($0.family)" }])
            } catch {
                Probe.event("host.configs.error", ["error": "\(error)"])
            }
        }

        if interval > 0 {
            timers.append(Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                _ = ProbeSnapshot.bump(reason: "timer")
                if reloadOnWrite { self?.reload("on-write") }
            })
        }
        if reloadEvery > 0 {
            timers.append(Timer.scheduledTimer(withTimeInterval: reloadEvery, repeats: true) { [weak self] _ in self?.reload("every") })
        }
        // B3：开一个普通窗口并切到前台，看 chronod 的 containerApp 豁免是否生效
        if has("--activate") {
            NSApp.setActivationPolicy(.regular)
            let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 120), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Probe host (foreground)"
            w.makeKeyAndOrderFront(nil)
            window = w
            NSApp.activate()
            Probe.event("host.activate", ["active": NSApp.isActive])
        }
        if let s = arg("--exit-after") {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) {
                Probe.event("host.exit")
                NSApp.terminate(nil)
            }
        }
    }

    func reload(_ why: String) {
        WidgetCenter.shared.reloadAllTimelines()
        Probe.event("host.reloadAll", ["why": why])
    }
}

@main
struct HostMain {
    static func main() {
        let app = NSApplication.shared
        let d = HostDelegate()
        app.delegate = d
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
