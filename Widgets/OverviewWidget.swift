// 「总览」小组件（D90 W1、D91 WS1，规格 docs/design/widgets.md §6）：小 / 中 / 大 / 超大竖版，内容随尺寸递增。
// 扩展开沙盒、只链接 SysModel：只读组容器里主 app 写的快照，不自己采样。

import AppIntents
import Charts
import SwiftUI
import SysModel
import WidgetKit

struct OverviewEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct OverviewProvider: TimelineProvider {
    func placeholder(in context: Context) -> OverviewEntry { OverviewEntry(date: .now, snapshot: .sample(at: .now)) }

    /// 图库预览：还没有快照时给示例数据，免得列表里只有一句「打开 SysInfo」。
    func getSnapshot(in context: Context, completion: @escaping @Sendable (OverviewEntry) -> Void) {
        let e = entry()
        completion(context.isPreview && e.snapshot == nil ? OverviewEntry(date: .now, snapshot: .sample(at: .now)) : e)
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<OverviewEntry>) -> Void) {
        let e = entry()
        // 刷新由主 app 写完快照后主动发起；这里只排一个兜底（三个写入周期，至少 15 分钟），规格 §4.4。
        let interval = e.snapshot?.refreshInterval ?? 300
        completion(Timeline(entries: [e], policy: .after(.now.addingTimeInterval(max(interval * 3, 900)))))
    }

    private func entry() -> OverviewEntry {
        let snapshot = WidgetStorage.readSnapshot()
        if snapshot == nil || snapshot?.isStale(at: .now) == true { WidgetStorage.markWanted() }
        return OverviewEntry(date: .now, snapshot: snapshot)
    }
}

struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.widgetKind, provider: OverviewProvider()) { entry in
            OverviewView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(String(localized: "SysInfo 总览"))
        .description(String(localized: "CPU、内存、功率与温度；大尺寸带 24 小时曲线。数据来自本机运行的 SysInfo。"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLargePortrait])
    }
}

@main
struct SysInfoWidgets: WidgetBundle {
    var body: some Widget { OverviewWidget() }
}

// MARK: - 视图

struct OverviewView: View {
    let entry: OverviewEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            let stale = snapshot.isStale(at: entry.date)
            VStack(alignment: .leading, spacing: spacing) {
                content(snapshot)
                    .opacity(stale ? 0.45 : 1)
                Spacer(minLength: 0)
                Footer(snapshot: snapshot, stale: stale)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.title2).widgetAccentable()
                Text("打开 SysInfo 后显示数据").font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
        }
    }

    private var spacing: CGFloat { family == .systemSmall ? 4 : 8 }

    @ViewBuilder
    private func content(_ s: WidgetSnapshot) -> some View {
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 6) {
                MetricCell(slot: .cpuUsage, snapshot: s, large: true)
                MetricCell(slot: .memoryUsage, snapshot: s, large: true)
            }
        case .systemMedium:
            FourGrid(snapshot: s)
        case .systemLarge:
            VStack(alignment: .leading, spacing: 10) {
                FourGrid(snapshot: s)
                NetworkRow(snapshot: s)
                CurveRow(slots: [.cpuUsage, .systemPower], snapshot: s)
            }
        default:  // .systemExtraLargePortrait
            VStack(alignment: .leading, spacing: 12) {
                FourGrid(snapshot: s)
                HStack {
                    NetworkRow(snapshot: s)
                    Spacer()
                    MetricCell(slot: .bootDiskTemperature, snapshot: s, large: false)
                }
                CurveRow(slots: [.cpuUsage, .systemPower], snapshot: s)
                CurveRow(slots: [.memoryUsage, .socHotspot], snapshot: s)
            }
        }
    }
}

enum SlotText {
    static func label(_ slot: WidgetSlot) -> String {
        switch slot {
        case .cpuUsage: String(localized: "CPU")
        case .memoryUsage: String(localized: "内存")
        case .systemPower: String(localized: "功率")
        case .socHotspot: String(localized: "SoC 温度")
        case .networkIn: String(localized: "下载")
        case .networkOut: String(localized: "上传")
        case .bootDiskTemperature: String(localized: "启动盘")
        }
    }

    /// 数值；估算 / 推断类加「≈」（与面板一致，D24），不可用为「—」。
    static func value(_ item: WidgetSnapshot.Item?, _ slot: WidgetSlot) -> String {
        let text = WidgetFormat.string(slot, item?.value)
        guard let quality = item?.quality, item?.value != nil else { return text }
        switch quality {
        case .estimated, .inferred: return "≈" + text
        default: return text
        }
    }
}

struct MetricCell: View {
    let slot: WidgetSlot
    let snapshot: WidgetSnapshot
    let large: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(SlotText.label(slot)).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            Text(SlotText.value(snapshot.item(slot), slot))
                .font((large ? Font.title2 : Font.title3).weight(.semibold).monospacedDigit())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .widgetAccentable()
        }
    }
}

struct FourGrid: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                MetricCell(slot: .cpuUsage, snapshot: snapshot, large: true)
                MetricCell(slot: .memoryUsage, snapshot: snapshot, large: true)
            }
            GridRow {
                MetricCell(slot: .systemPower, snapshot: snapshot, large: true)
                MetricCell(slot: .socHotspot, snapshot: snapshot, large: true)
            }
        }
    }
}

struct NetworkRow: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(spacing: 14) {
            ForEach([WidgetSlot.networkIn, .networkOut], id: \.self) { slot in
                HStack(spacing: 3) {
                    Image(systemName: slot == .networkIn ? "arrow.down" : "arrow.up").font(.caption2.weight(.bold))
                    Text(SlotText.value(snapshot.item(slot), slot)).font(.callout.monospacedDigit()).widgetAccentable()
                }
                .accessibilityLabel("\(SlotText.label(slot)) \(SlotText.value(snapshot.item(slot), slot))")
            }
        }
    }
}

struct CurveRow: View {
    let slots: [WidgetSlot]
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(spacing: 12) {
            ForEach(slots, id: \.self) { slot in
                CurveChart(
                    slot: slot, item: snapshot.item(slot), historyEnabled: snapshot.historyEnabled,
                    generatedAt: snapshot.generatedAt)
            }
        }
    }
}

struct CurveChart: View {
    let slot: WidgetSlot
    let item: WidgetSnapshot.Item?
    let historyEnabled: Bool
    let generatedAt: Date

    private var xDomain: ClosedRange<Date> {
        generatedAt.addingTimeInterval(historyEnabled ? -86_400 : -900)...generatedAt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(historyEnabled ? "\(SlotText.label(slot)) · 24 小时" : "\(SlotText.label(slot)) · 15 分钟（历史记录已关闭）")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            let points = item?.curve ?? []
            if points.count > 1 {
                // 横轴用时间、范围固定为最近 24 h（或 15 min）：数值轴的自动范围会把 0 包进去，
                // 「Unix 分钟」那样的大数会全挤到最右边；固定范围也让 app 没运行的空档如实留白。
                Chart(points, id: \.minute) { p in
                    AreaMark(x: .value("时间", p.date), y: .value("数值", p.value))
                        .foregroundStyle(.tint.opacity(0.25))
                    LineMark(x: .value("时间", p.date), y: .value("数值", p.value))
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                }
                .chartXScale(domain: xDomain)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: yDomain(points))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .widgetAccentable()
            } else {
                Text("暂无数据").font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 占用类固定 0…100%；其余从 0 到最大值（留 10% 余量），温度从最小值往下留余量。
    private func yDomain(_ points: [WidgetSnapshot.CurvePoint]) -> ClosedRange<Double> {
        let values = points.map(\.value)
        let hi = values.max() ?? 1
        switch slot {
        case .cpuUsage, .memoryUsage: return 0...1
        case .socHotspot, .bootDiskTemperature:
            let lo = values.min() ?? 0
            return max(lo - 5, 0)...max(hi + 5, lo + 10)
        default: return 0...max(hi * 1.1, 1)
        }
    }
}

struct Footer: View {
    let snapshot: WidgetSnapshot
    let stale: Bool
    @Environment(\.widgetFamily) private var family

    var body: some View {
        HStack(spacing: 4) {
            if stale {
                // 小号放不下全文，只写「未运行」
                Text(family == .systemSmall ? "未运行 ·" : "SysInfo 未运行 ·").font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // 相对时间由系统自己走字，不需要刷新
            Text(snapshot.generatedAt, style: .relative).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(intent: RefreshWidgetIntent()) {
                Image(systemName: "arrow.clockwise").font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "刷新"))
        }
    }
}

extension WidgetSnapshot.CurvePoint {
    var date: Date { Date(timeIntervalSince1970: TimeInterval(minute) * 60) }
}

extension WidgetSnapshot {
    /// 图库预览与占位用的示例数据（不是实测，只在没有快照时出现）。
    static func sample(at now: Date) -> WidgetSnapshot {
        let end = Int64(now.timeIntervalSince1970 / 60) / 5 * 5
        func curve(_ base: Double, _ swing: Double) -> [CurvePoint] {
            (0..<288).map { i in
                CurvePoint(minute: end - Int64(287 - i) * 5, value: base + swing * sin(Double(i) / 23) * cos(Double(i) / 61))
            }
        }
        return WidgetSnapshot(
            generatedAt: now, refreshInterval: 300, historyEnabled: true,
            items: [
                .init(slot: .cpuUsage, value: 0.12, quality: .measured, curve: curve(0.15, 0.1)),
                .init(slot: .memoryUsage, value: 0.56, quality: .measured, curve: curve(0.55, 0.05)),
                .init(slot: .systemPower, value: 11.4, quality: .measured, curve: curve(12, 6)),
                .init(slot: .socHotspot, value: 55, quality: .measured, curve: curve(58, 8)),
                .init(slot: .networkIn, value: 48_000, quality: .measured),
                .init(slot: .networkOut, value: 12_000, quality: .measured),
                .init(slot: .bootDiskTemperature, value: 41, quality: .measured),
            ])
    }
}
