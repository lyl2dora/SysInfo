// 探针扩展（沙盒）：读组容器里的快照，记录每次 timeline 请求；小、超大两种组件 + 一个 Control。
import WidgetKit
import SwiftUI
import Charts
import AppIntents

struct ProbeEntry: TimelineEntry {
    let date: Date
    let snap: ProbeSnapshot?
    let bytes: Int
    let readMs: Double
    let fpMB: Double
    let pid: Int32
    let timelineCount: Int
}

/// 扩展进程内的 timeline 请求计数（进程被回收后归零，可以看出进程复用情况）。
nonisolated(unsafe) var timelineCount = 0
nonisolated(unsafe) var ballast: [UnsafeMutableRawPointer] = []

func makeEntry(_ why: String, _ family: WidgetFamily, preview: Bool) -> ProbeEntry {
    let (s, bytes, ms) = ProbeSnapshot.load()
    if let mb = s?.ballastMB, mb > ballast.count {
        for _ in ballast.count..<mb {
            let p = malloc(1 << 20)!
            memset(p, 1, 1 << 20)
            ballast.append(p)
        }
    }
    timelineCount += 1
    let fp = Double(Probe.footprint()) / 1_048_576
    Probe.event("ext.\(why)", ["family": "\(family)", "preview": preview, "seq": s?.seq ?? -1, "ageS": s.map { Date().timeIntervalSince($0.writtenAt) } ?? -1, "bytes": bytes, "readMs": ms, "n": timelineCount, "ballastMB": ballast.count])
    return ProbeEntry(date: .now, snap: s, bytes: bytes, readMs: ms, fpMB: fp, pid: getpid(), timelineCount: timelineCount)
}

struct ProbeProvider: TimelineProvider {
    func placeholder(in context: Context) -> ProbeEntry {
        ProbeEntry(date: .now, snap: nil, bytes: 0, readMs: 0, fpMB: 0, pid: getpid(), timelineCount: 0)
    }
    func getSnapshot(in context: Context, completion: @escaping (ProbeEntry) -> Void) {
        completion(makeEntry("snapshot", context.family, preview: context.isPreview))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ProbeEntry>) -> Void) {
        let e = makeEntry("timeline", context.family, preview: context.isPreview)
        // 每 5 分钟请求一次刷新，看系统实际给多少（probe B）。
        completion(Timeline(entries: [e], policy: .after(.now.addingTimeInterval(300))))
    }
}

struct ModeLabel: View {
    @Environment(\.widgetRenderingMode) var mode
    @Environment(\.showsWidgetContainerBackground) var bg
    var body: some View { Text("mode \(String(describing: mode)) bg \(bg ? 1 : 0)").font(.system(size: 9)) }
}

struct SmallView: View {
    let e: ProbeEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("seq \(e.snap?.seq ?? -1)").font(.headline.monospacedDigit()).widgetAccentable()
            if let w = e.snap?.writtenAt {
                // 相对时间由系统自己走字，不需要重载
                Text(w, style: .relative).font(.caption.monospacedDigit())
            }
            Text("render \(e.date.formatted(date: .omitted, time: .standard))").font(.system(size: 9))
            Text("n \(e.timelineCount) pid \(e.pid)").font(.system(size: 9))
            Text(String(format: "fp %.1f MB", e.fpMB)).font(.system(size: 9))
            ModeLabel()
            HStack {
                Button(intent: ProbeRefreshIntent()) { Image(systemName: "arrow.clockwise") }
                Button(intent: ProbeRefreshDefaultIntent()) { Image(systemName: "arrow.2.circlepath") }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct LargeView: View {
    let e: ProbeEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SmallView(e: e)
            Text("snapshot \(e.bytes / 1024) KB, read \(String(format: "%.2f", e.readMs)) ms, points \(e.snap?.points.count ?? 0)").font(.caption)
            if let pts = e.snap?.points, !pts.isEmpty {
                Chart(Array(pts.enumerated()), id: \.offset) { p in
                    AreaMark(x: .value("i", p.offset), y: .value("v", p.element))
                        .foregroundStyle(.blue.opacity(0.4))
                    LineMark(x: .value("i", p.offset), y: .value("v", p.element))
                }
                .chartXAxis(.hidden)
                .widgetAccentable()
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct ProbeSmallWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ProbeSmall", provider: ProbeProvider()) { SmallView(e: $0) }
            .configurationDisplayName("Probe Small")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ProbeLargeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ProbeLarge", provider: ProbeProvider()) { LargeView(e: $0) }
            .configurationDisplayName("Probe Large")
            .supportedFamilies([.systemLarge, .systemExtraLarge, .systemExtraLargePortrait])
    }
}

struct ProbeControlValue: ControlValueProvider {
    var previewValue: Int { 0 }
    func currentValue() async throws -> Int {
        let s = ProbeSnapshot.load().0
        Probe.event("ext.control.value", ["seq": s?.seq ?? -1])
        return s?.seq ?? -1
    }
}

struct ProbeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ProbeControl", provider: ProbeControlValue()) { seq in
            ControlWidgetButton(action: ProbeRefreshIntent()) {
                Label("seq \(seq)", systemImage: "gauge.medium")
            }
        }
        .displayName("Probe Control")
    }
}

@main
struct ProbeBundle: WidgetBundle {
    var body: some Widget {
        ProbeSmallWidget()
        ProbeLargeWidget()
        ProbeControl()
    }
}
