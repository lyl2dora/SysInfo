// 「总览」小组件（D90 W1、D91，充实版见 docs/design/widgets-rich.md）：小 / 中 / 大 / 超大竖版，内容随尺寸递增。
// 扩展开沙盒、只链接 SysModel：只读组容器里主 app 写的快照，不自己采样。

import AppIntents
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
        if snapshot?.wantsRefresh(at: .now) ?? true { WidgetStorage.markWanted() }
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
        .description(String(localized: "CPU、GPU、内存、功率与温度；中号起带 24 小时曲线。数据来自本机运行的 SysInfo。"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLargePortrait])
    }
}

@main
struct SysInfoWidgets: WidgetBundle {
    var body: some Widget { OverviewWidget() }
}

// MARK: - 布局

struct OverviewView: View {
    let entry: OverviewEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            let stale = snapshot.isStale(at: entry.date)
            VStack(alignment: .leading, spacing: family == .systemLarge || family == .systemExtraLargePortrait ? 10 : 4) {
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

    @ViewBuilder
    private func content(_ s: WidgetSnapshot) -> some View {
        switch family {
        case .systemSmall:
            RingGrid(snapshot: s)
        case .systemMedium:
            CardGrid(snapshot: s, height: 54)
        case .systemLarge:
            VStack(alignment: .leading, spacing: 8) {
                CardGrid(snapshot: s, height: 90)
                LevelBars(levels: s.cpuLevels)
                DetailGrid(snapshot: s)
            }
        default:  // .systemExtraLargePortrait
            VStack(alignment: .leading, spacing: 12) {
                CardGrid(snapshot: s, height: 82)
                LevelBars(levels: s.cpuLevels)
                DetailGrid(snapshot: s)
                Divider()
                Grid(horizontalSpacing: 14, verticalSpacing: 12) {
                    GridRow {
                        AnnotatedChart(slot: .cpuUsage, snapshot: s)
                        AnnotatedChart(slot: .gpuUsage, snapshot: s)
                    }
                    GridRow {
                        AnnotatedChart(slot: .systemPower, snapshot: s)
                        AnnotatedChart(slot: .socHotspot, snapshot: s)
                    }
                }
            }
        }
    }
}

// MARK: - 文案

enum SlotText {
    static func label(_ slot: WidgetSlot) -> String {
        switch slot {
        case .cpuUsage: String(localized: "CPU")
        case .memoryUsage: String(localized: "内存")
        case .systemPower: String(localized: "功率")
        case .socHotspot: String(localized: "SoC 温度")
        case .networkIn: String(localized: "下载")
        case .networkOut: String(localized: "上传")
        case .diskTemperature: String(localized: "盘温")
        case .gpuUsage: String(localized: "GPU")
        case .gpuPower: String(localized: "GPU 功率")
        case .memoryUsed: String(localized: "已用")
        case .memoryTotal: String(localized: "总量")
        case .memoryPressure: String(localized: "压力")
        case .swapUsed: String(localized: "交换")
        case .fanSpeed: String(localized: "风扇")
        case .diskFree: String(localized: "磁盘")
        case .diskTotal: String(localized: "磁盘")
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

    static func value(_ s: WidgetSnapshot, _ slot: WidgetSlot) -> String { value(s.item(slot), slot) }

    /// 各卡片的副信息（规格 §2）。
    static func detail(_ slot: WidgetSlot, _ s: WidgetSnapshot) -> String {
        switch slot {
        case .cpuUsage:
            return s.cpuLevels.map { "\($0.label) \(PercentFormat.string(fromRatio: $0.value))" }.joined(separator: " · ")
        case .gpuUsage:
            return String(localized: "功率 \(value(s, .gpuPower))")
        case .memoryUsage:
            let used = s.value(.memoryUsed).map { String(format: "%.1f", $0 / 1_073_741_824) } ?? PercentFormat.placeholder
            return "\(used) / \(value(s, .memoryTotal)) · " + String(localized: "压力 \(value(s, .memoryPressure))")
        case .systemPower:
            var parts = [String(localized: "SoC \(value(s, .socHotspot))")]
            if s.item(.fanSpeed) != nil { parts.append(String(localized: "风扇 \(value(s, .fanSpeed))")) }
            return parts.joined(separator: " · ")
        default:
            return ""
        }
    }
}

extension PercentFormat {
    static func string(fromRatio value: Double?) -> String { value.map { string(fromRatio: $0) } ?? placeholder }
}

// MARK: - 小号：圆环

struct RingGrid: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                Ring(label: SlotText.label(.cpuUsage), ratio: snapshot.value(.cpuUsage))
                Ring(label: SlotText.label(.gpuUsage), ratio: snapshot.value(.gpuUsage))
            }
            GridRow {
                Ring(label: SlotText.label(.memoryUsage), ratio: snapshot.value(.memoryUsage))
                Ring(label: String(localized: "磁盘"), ratio: snapshot.diskUsedRatio)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct Ring: View {
    let label: String
    let ratio: Double?

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: ratio.map { min(max($0, 0), 1) } ?? 0)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable()
                Text(PercentFormat.string(fromRatio: ratio))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
            }
            .frame(width: 40, height: 40)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 中号起：卡片

struct CardGrid: View {
    let snapshot: WidgetSnapshot
    let height: CGFloat

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                MetricCard(slot: .cpuUsage, snapshot: snapshot, height: height)
                MetricCard(slot: .gpuUsage, snapshot: snapshot, height: height)
            }
            GridRow {
                MetricCard(slot: .memoryUsage, snapshot: snapshot, height: height)
                MetricCard(slot: .systemPower, snapshot: snapshot, height: height)
            }
        }
    }
}

/// 一张卡：标签、大数字、副信息，底下垫一条 24 h 曲线。
struct MetricCard: View {
    let slot: WidgetSlot
    let snapshot: WidgetSnapshot
    let height: CGFloat

    /// 中号的卡矮：数字小一号，曲线只占文字下面剩下的一条。
    private var compact: Bool { height < 70 }

    var body: some View {
        let detail = SlotText.detail(slot, snapshot)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(SlotText.label(slot)).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(SlotText.value(snapshot, slot))
                    .font((compact ? Font.headline : .title3).weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .widgetAccentable()
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 4 : 6)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(alignment: .bottom) {
            // 曲线只占文字下方的空间，不压住副信息
            Sparkline(slot: slot, item: snapshot.item(slot), generatedAt: snapshot.generatedAt)
                .frame(height: height - (compact ? 34 : 40))
        }
        .background(.fill.quaternary, in: .rect(cornerRadius: 10))
        .clipShape(.rect(cornerRadius: 10))
    }
}

/// 卡片底下的曲线：没有坐标轴，只看形状。
/// 曲线一律用 Path 自绘，不用 Swift Charts：Charts 每张图都要建刻度、做布局，
/// 四种尺寸合计 17 张图时扩展每次重绘约 120 ms / 组件（docs/perf/widgets.md）。
struct Sparkline: View {
    let slot: WidgetSlot
    let item: WidgetSnapshot.Item?
    let generatedAt: Date

    var body: some View {
        let points = item?.curve ?? []
        if points.count > 1 {
            let x = CurveScale.xDomain(item, generatedAt)
            let y = CurveScale.yDomain(slot, points)
            ZStack {
                CurveShape(points: points, x: x, y: y, filled: true)
                    .fill(.linearGradient(colors: [.accentColor.opacity(0.35), .accentColor.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                CurveShape(points: points, x: x, y: y, filled: false)
                    .stroke(.tint.opacity(0.7), lineWidth: 1)
            }
            .widgetAccentable()
        }
    }
}

/// 折线或其下方的面积。横轴范围外的点不画，纵轴超出范围的值压到边上；相邻点直接连线（与原来的 LineMark 一致）。
nonisolated struct CurveShape: Shape {
    let points: [WidgetSnapshot.CurvePoint]
    let x: ClosedRange<Date>
    let y: ClosedRange<Double>
    let filled: Bool

    func path(in rect: CGRect) -> Path {
        let x0 = x.lowerBound.timeIntervalSince1970
        let xSpan = max(x.upperBound.timeIntervalSince1970 - x0, 1)
        let ySpan = max(y.upperBound - y.lowerBound, .ulpOfOne)
        let pts = points.compactMap { p -> CGPoint? in
            let t = (p.date.timeIntervalSince1970 - x0) / xSpan
            guard t >= 0, t <= 1, p.value.isFinite else { return nil }
            let v = (min(max(p.value, y.lowerBound), y.upperBound) - y.lowerBound) / ySpan
            return CGPoint(x: rect.minX + t * rect.width, y: rect.maxY - v * rect.height)
        }
        var path = Path()
        guard let first = pts.first, let last = pts.last, pts.count > 1 else { return path }
        path.move(to: first)
        for p in pts.dropFirst() { path.addLine(to: p) }
        if filled {
            path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// 竖直参考线（超大竖版的曲线）：把横轴等分成 `divisions` 段。
nonisolated struct GridLines: Shape {
    let divisions: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for i in 0...divisions {
            let px = rect.minX + rect.width * CGFloat(i) / CGFloat(divisions)
            path.move(to: CGPoint(x: px, y: rect.minY))
            path.addLine(to: CGPoint(x: px, y: rect.maxY))
        }
        return path
    }
}

enum CurveScale {
    /// 横轴固定为最近 24 h（或 15 min）：app 没运行的空档如实留白。
    static func xDomain(_ item: WidgetSnapshot.Item?, _ generatedAt: Date) -> ClosedRange<Date> {
        generatedAt.addingTimeInterval(-(item?.curveSource ?? .history).span)...generatedAt
    }

    /// 占用类固定 0…100%；温度从最小值往下留余量；其余从 0 到最大值（留 10% 余量）。
    static func yDomain(_ slot: WidgetSlot, _ points: [WidgetSnapshot.CurvePoint]) -> ClosedRange<Double> {
        let values = points.map(\.value)
        let hi = values.max() ?? 1
        switch slot {
        case .cpuUsage, .memoryUsage, .gpuUsage: return 0...1
        case .socHotspot, .diskTemperature:
            let lo = values.min() ?? 0
            return max(lo - 5, 0)...max(hi + 5, lo + 10)
        default: return 0...max(hi * 1.1, 1)
        }
    }
}

// MARK: - 大号起：按档占用与明细

/// CPU 各档占用条，档名与颜色按运行时的档（D20、D29）。
struct LevelBars: View {
    let levels: [WidgetSnapshot.CPULevel]
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        if !levels.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    HStack(spacing: 8) {
                        Text(level.label).font(.caption2).foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .leading).lineLimit(1)
                        Bar(ratio: level.value, color: renderingMode == .fullColor ? Self.color(level.name, index) : nil)
                        Text(PercentFormat.string(fromRatio: level.value)).font(.caption2.monospacedDigit())
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// 与面板的档颜色一致（D29）。
    static func color(_ name: String, _ index: Int) -> Color {
        switch name {
        case "Super": .purple
        case "Performance": .blue
        case "Efficiency": .green
        default: [Color.orange, .teal, .pink][index % 3]
        }
    }
}

struct Bar: View {
    let ratio: Double?
    var color: Color? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint))
                    .frame(width: geo.size.width * (ratio.map { min(max($0, 0), 1) } ?? 0))
                    .widgetAccentable()
            }
        }
        .frame(height: 6)
    }
}

/// 明细：一行网速与交换；一行盘温（带盘名）；一行容量组可用与容量条。盘与容量组跟随菜单栏 widget 的设置。
struct DetailGrid: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                compact("arrow.down", .networkIn)
                compact("arrow.up", .networkOut)
                compact("arrow.left.arrow.right", .swapUsed)
            }
            HStack(spacing: 4) {
                Image(systemName: "thermometer.medium").font(.caption2).foregroundStyle(.secondary).frame(width: 14)
                Text(SlotText.label(.diskTemperature)).font(.caption2).foregroundStyle(.secondary)
                if let name = snapshot.diskName {
                    Text(name).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Text(SlotText.value(snapshot, .diskTemperature)).font(.caption.monospacedDigit()).lineLimit(1)
                    .fixedSize().widgetAccentable()
            }
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "internaldrive").font(.caption2).foregroundStyle(.secondary).frame(width: 14)
                    Text(snapshot.diskGroupName ?? SlotText.label(.diskFree)).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .layoutPriority(1)  // 名字按自身宽度排，太长时截断，容量条至少留 60
                Bar(ratio: snapshot.diskUsedRatio).frame(minWidth: 60)
                Text(String(localized: "可用 \(SlotText.value(snapshot, .diskFree))"))
                    .font(.caption2.monospacedDigit()).lineLimit(1).fixedSize()
            }
        }
    }

    /// 只有图标和数值，三项并排。
    private func compact(_ symbol: String, _ slot: WidgetSlot) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption2).foregroundStyle(.secondary).frame(width: 14)
            Text(SlotText.value(snapshot, slot)).font(.caption.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.8)
                .widgetAccentable()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(SlotText.label(slot)) \(SlotText.value(snapshot, slot))")
    }
}

// MARK: - 超大竖版：带标注的曲线

struct AnnotatedChart: View {
    let slot: WidgetSlot
    let snapshot: WidgetSnapshot

    private var item: WidgetSnapshot.Item? { snapshot.item(slot) }
    private var source: WidgetSnapshot.CurveSource { item?.curveSource ?? .history }

    private var title: String {
        let label = SlotText.label(slot)
        return switch source {
        case .history: String(localized: "\(label) · 24 小时")
        case .historyOff: String(localized: "\(label) · 15 分钟（历史记录已关闭）")
        case .recent: String(localized: "\(label) · 15 分钟")
        }
    }

    var body: some View {
        let points = item?.curve ?? []
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            if points.count > 1 {
                let x = CurveScale.xDomain(item, snapshot.generatedAt)
                let y = CurveScale.yDomain(slot, points)
                ZStack {
                    GridLines(divisions: 4)
                        .stroke(.quaternary, style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                    CurveShape(points: points, x: x, y: y, filled: true).fill(.tint.opacity(0.2))
                    CurveShape(points: points, x: x, y: y, filled: false).stroke(.tint, lineWidth: 1.2)
                }
                .frame(maxHeight: .infinity)
                .widgetAccentable()
                // 竖线每 6 h（或 5 min）一条，不另标时间；下面只放统计
                Text(stats(points))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                Text("暂无数据").font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 「低 12%  均 18%  高 64%」
    private func stats(_ points: [WidgetSnapshot.CurvePoint]) -> String {
        let values = points.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return "" }
        let avg = values.reduce(0, +) / Double(values.count)
        let f = { WidgetFormat.string(slot, $0) }
        return String(localized: "低 \(f(lo))  均 \(f(avg))  高 \(f(hi))")
    }
}

// MARK: - 底栏

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

nonisolated extension WidgetSnapshot.CurvePoint {
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
        let gb = 1_073_741_824.0
        return WidgetSnapshot(
            generatedAt: now, refreshInterval: 300,
            items: [
                .init(slot: .cpuUsage, value: 0.12, quality: .measured, curve: curve(0.15, 0.1)),
                .init(slot: .gpuUsage, value: 0.08, quality: .measured, curve: curve(0.1, 0.08)),
                .init(slot: .memoryUsage, value: 0.56, quality: .measured, curve: curve(0.55, 0.05)),
                .init(slot: .systemPower, value: 11.4, quality: .measured, curve: curve(12, 6)),
                .init(slot: .socHotspot, value: 55, quality: .measured, curve: curve(58, 8)),
                .init(slot: .gpuPower, value: 1.2, quality: .measured),
                .init(slot: .memoryUsed, value: 13.4 * gb, quality: .measured),
                .init(slot: .memoryTotal, value: 24 * gb, quality: .measured),
                .init(slot: .memoryPressure, value: 0.18, quality: .measured),
                .init(slot: .swapUsed, value: 0, quality: .measured),
                .init(slot: .networkIn, value: 48_000, quality: .measured),
                .init(slot: .networkOut, value: 12_000, quality: .measured),
                .init(slot: .diskTemperature, value: 41, quality: .measured),
                .init(slot: .diskFree, value: 412e9, quality: .measured),
                .init(slot: .diskTotal, value: 994e9, quality: .measured),
            ],
            cpuLevels: [
                .init(label: String(localized: "超级核"), name: "Super", value: 0.18, quality: .measured),
                .init(label: String(localized: "性能核"), name: "Performance", value: 0.06, quality: .measured),
            ],
            diskName: "APPLE SSD", diskGroupName: "Macintosh HD")
    }
}
