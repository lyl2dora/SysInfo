// Minimal LSUIElement host: asks chronod about configurations and requests reloads, then exits.
import AppKit
import WidgetKit
import os
let log = Logger(subsystem: "local.probe.widget27", category: "host")
func out(_ s: String) { print(s); log.error("HOST \(s, privacy: .public)") }
let sema = DispatchSemaphore(value: 0)
Task.detached {
    do { let c = try await WidgetCenter.shared.currentConfigurations(); out("currentConfigurations count=\(c.count) kinds=\(c.map{$0.kind})") }
    catch { out("currentConfigurations error=\(error)") }
    WidgetCenter.shared.reloadAllTimelines(); out("reloadAllTimelines called")
    for i in 0..<5 { WidgetCenter.shared.reloadTimelines(ofKind: "ProbeWidget"); out("reloadTimelines(ProbeWidget) #\(i)"); try? await Task.sleep(for: .milliseconds(300)) }
    try? await Task.sleep(for: .seconds(2))
    sema.signal()
}
sema.wait()
out("host exit")
