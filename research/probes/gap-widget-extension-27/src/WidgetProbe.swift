// Minimal WidgetKit extension used to test whether pkd/chronod accept an extension WITHOUT app-sandbox on macOS 27.
import WidgetKit
import SwiftUI
import os
import IOKit
import Darwin

let log = Logger(subsystem: "local.probe.widget27", category: "ext")

@_silgen_name("sandbox_check")
func sandbox_check(_ pid: pid_t, _ op: UnsafePointer<CChar>?, _ type: Int32) -> Int32

func probeText() -> String {
    let sb = sandbox_check(getpid(), nil, 0)          // 1 = sandboxed, 0 = not
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
    var conn: io_connect_t = 0
    let kr = svc != 0 ? IOServiceOpen(svc, mach_task_self_, 0, &conn) : -1
    if conn != 0 { IOServiceClose(conn) }
    if svc != 0 { IOObjectRelease(svc) }
    let s = "pid=\(getpid()) sandboxed=\(sb) smcOpen=\(kr) container=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "none")"
    log.error("PROBE \(s, privacy: .public)")
    return s
}

struct E: TimelineEntry { let date: Date; let text: String }
struct Prov: TimelineProvider {
    func placeholder(in context: Context) -> E { E(date: .now, text: "placeholder") }
    func getSnapshot(in context: Context, completion: @escaping @Sendable (E) -> Void) { completion(E(date: .now, text: probeText())) }
    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<E>) -> Void) {
        completion(Timeline(entries: [E(date: .now, text: probeText())], policy: .atEnd))
    }
}
struct ProbeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ProbeWidget", provider: Prov()) { e in Text(e.text).font(.caption2) }
            .configurationDisplayName("Probe27").supportedFamilies([.systemSmall, .systemExtraLargePortrait])
    }
}
@main struct ProbeBundle: WidgetBundle { var body: some Widget { ProbeWidget() } }
