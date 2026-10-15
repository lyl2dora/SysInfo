// 面板里每秒都在变的部分，用 AppKit 自绘（CPU 模块偏离记录 2026-10-15，开销实测后改）。
//
// SwiftUI 每次数据更新都要重算整棵视图树、重新布局、重排文字。面板打开时每秒一次，实测占主线程大头
// （M4 上面板档 4%，预算 2%）。这里的 view 和菜单栏 item 一样，在 `draw(_:)` 里直接读 MetricStore，
// 由观察系统在数据变化时只重绘自己；SwiftUI 那边只放外框和静态文字，不读 MetricStore。
//
// 坐标系翻转（isFlipped），文字用 NSAttributedString 画，颜色一律用语义色或按档名取的颜色。

import AppKit
import OSLog
import SwiftUI
import SysCollectors
import SysModel

/// 自绘 view 的公共部分。
class LiveDrawView: NSView {
    let store: MetricStore

    init(store: MetricStore) {
        self.store = store
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// 诊断用：设了环境变量 SYSINFO_DRAW_STATS 时，每 30 秒把各 view 的重绘次数写进日志（开销分析用）。
    static let drawStatsEnabled = ProcessInfo.processInfo.environment["SYSINFO_DRAW_STATS"] != nil
    nonisolated(unsafe) static var drawCounts: [String: Int] = [:]
    nonisolated(unsafe) static var drawStatsTimer: Timer?

    func countDraw() {
        guard Self.drawStatsEnabled else { return }
        Self.drawCounts[String(describing: type(of: self)), default: 0] += 1
        if Self.drawStatsTimer == nil {
            Self.drawStatsTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                let summary = LiveDrawView.drawCounts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
                Log.panel.notice("重绘次数（30 s）：\(summary, privacy: .public)")
                LiveDrawView.drawCounts = [:]
            }
        }
    }

    static func text(_ s: String, _ font: NSFont, _ color: NSColor = .labelColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    }

    /// 左对齐画在 (x, y)，返回宽度。
    @discardableResult
    static func draw(_ s: NSAttributedString, x: CGFloat, y: CGFloat) -> CGFloat {
        s.draw(at: NSPoint(x: x, y: y))
        return s.size().width
    }

    /// 右对齐：右边缘在 `right`。
    static func drawRight(_ s: NSAttributedString, right: CGFloat, y: CGFloat) {
        s.draw(at: NSPoint(x: right - s.size().width, y: y))
    }

    static let caption = NSFont.systemFont(ofSize: 11)
    static let captionDigits = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let captionBold = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let caption2 = NSFont.systemFont(ofSize: 10)
    static let caption2Digits = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
}

// MARK: - 概览

final class OverviewDrawView: LiveDrawView {
    var splitUserSystem = true {
        didSet { needsDisplay = true }
    }

    static let height: CGFloat = 86

    private static let big: NSFont = {
        let base = NSFont.monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 34) } ?? base
    }()
    private static let subheadline = NSFont.systemFont(ofSize: 13)
    private static let callout = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)

    override func draw(_ dirtyRect: NSRect) {
        countDraw()
        let latest = store.latest  // 观察：数据变化时重绘
        let total = latest[.cpuUsageTotal]
        Self.draw(Self.text(String(localized: "总占用"), Self.subheadline, .secondaryLabelColor), x: 0, y: 0)
        let value = total?.value.map { PercentFormat.string(fromRatio: $0) } ?? PercentFormat.placeholder
        let w = Self.draw(Self.text(value, Self.big), x: 0, y: 16)
        if total?.quality == .estimated {
            Self.draw(Self.text(String(localized: "估算"), Self.caption, .secondaryLabelColor), x: w + 6, y: 38)
        }
        if splitUserSystem {
            let user = latest[.cpuUsageUser]?.value
            let system = latest[.cpuUsageSystem]?.value
            let bar = NSRect(x: 0, y: 60, width: 150, height: 5)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
            let uw = bar.width * CGFloat(min(max(user ?? 0, 0), 1))
            let sw = bar.width * CGFloat(min(max(system ?? 0, 0), 1))
            NSColor.controlAccentColor.setFill()
            NSRect(x: 0, y: bar.minY, width: uw, height: bar.height).fill()
            NSColor.systemOrange.setFill()
            NSRect(x: uw, y: bar.minY, width: min(sw, bar.width - uw), height: bar.height).fill()
            var x: CGFloat = 0
            for (color, title, v) in [
                (NSColor.controlAccentColor, String(localized: "用户"), user),
                (NSColor.systemOrange, String(localized: "系统"), system),
            ] {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: 72, width: 6, height: 6)).fill()
                let label = "\(title) \(v.map { PercentFormat.string(fromRatio: $0) } ?? "—")"
                x += 9 + Self.draw(Self.text(label, Self.caption2Digits, .secondaryLabelColor), x: x + 9, y: 69) + 8
            }
        }
        // 右列：最快档频率、CPU 最高温、热状态徽标
        let right = bounds.width
        Self.drawRight(Self.text(String(localized: "频率"), Self.caption2, .secondaryLabelColor), right: right, y: 0)
        Self.drawRight(Self.text(fastestFrequency(latest), Self.callout), right: right, y: 12)
        Self.drawRight(Self.text(String(localized: "最高温"), Self.caption2, .secondaryLabelColor), right: right, y: 34)
        let temp = latest[.cpuTemperatureMax]?.value.map(Formatting.temperature) ?? "—"
        Self.drawRight(Self.text(temp, Self.callout), right: right, y: 46)
        if let state = latest[.cpuThermalState]?.value, let badge = DisplayNames.thermalState(state) {
            let label = Self.text(badge.text, Self.captionBold)
            let size = label.size()
            let rect = NSRect(x: right - size.width - 12, y: 68, width: size.width + 12, height: size.height + 4)
            NSColor(badge.color).withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            label.draw(at: NSPoint(x: rect.minX + 6, y: rect.minY + 2))
        }
        setAccessibilityLabel(String(localized: "总占用 \(value)，最高温 \(temp)"))
    }

    /// 最快档（perflevel0）各簇实际频率的最大值；都空闲时显示「空闲」。
    private func fastestFrequency(_ latest: [MetricID: Sample]) -> String {
        guard let topology = CPUTopologyService.shared.current, topology.quality.isOK,
            let level = topology.perfLevels.first
        else { return "—" }
        let samples = level.clusters.compactMap { latest[.cpuFrequencyCluster($0)] }
        if let hz = samples.compactMap(\.value).max() { return Formatting.frequency(hz) }
        return samples.isEmpty ? "—" : String(localized: "空闲")
    }
}

// MARK: - 核心

final class CoresDrawView: LiveDrawView {
    let sensors: SensorCollector?

    init(store: MetricStore, sensors: SensorCollector?) {
        self.sensors = sensors
        super.init(store: store)
    }

    static let headerHeight: CGFloat = 16
    static let rowHeight: CGFloat = 15
    static let barsHeight: CGFloat = 18
    static let clusterGap: CGFloat = 4
    static let levelGap: CGFloat = 8
    static let footnoteHeight: CGFloat = 16
    /// 列的右边缘：簇名左对齐在 0，占用、频率、温度、功耗右对齐。
    static let columns: [CGFloat] = [82, 158, 210, 272]

    /// 按拓扑算出的固定高度（拓扑在一次运行中不变；变了由面板重新量高）。
    static func height(for topology: CPUTopology?, cores: Int) -> CGFloat {
        let cluster = rowHeight + 3 + barsHeight + clusterGap
        guard let topology, topology.logicalCPUCount == cores, cores > 0 else { return 16 + barsHeight }
        switch topology.quality {
        case .ok:
            let levels = CGFloat(topology.perfLevels.count)
            return levels * headerHeight + CGFloat(topology.clusters.count) * cluster
                + max(levels - 1, 0) * levelGap + footnoteHeight
        case .clustersOnly:
            return CGFloat(topology.clusters.count) * cluster + footnoteHeight
        case .coresOnly:
            return barsHeight + 4
        }
    }

    /// 档内各簇是否共用同一组温度键（D37：共用时温度只显示在组标题里）。
    private func sharesTemperature(_ level: PerfLevel) -> Bool {
        guard level.clusters.count > 1, let profile = sensors?.profile?.profile else { return false }
        let sets = level.clusters.map { Set(profile.temperature.clusters[$0.description] ?? []) }
        return sets.allSatisfy { !$0.isEmpty && $0 == sets[0] }
    }

    override func draw(_ dirtyRect: NSRect) {
        countDraw()
        let latest = store.latest  // 观察：数据变化时重绘
        let cores = store.cpuCores
        guard let topology = CPUTopologyService.shared.current, topology.logicalCPUCount == cores.count, !cores.isEmpty
        else {
            Self.draw(
                Self.text(String(localized: "每核占用（\(cores.count) 个逻辑核）"), Self.caption, .secondaryLabelColor), x: 0, y: 0)
            drawBars(Array(cores.indices), cores: cores, color: .controlAccentColor, y: 16)
            return
        }
        var y: CGFloat = 0
        var summary: [String] = []
        switch topology.quality {
        case .ok:
            for (i, level) in topology.perfLevels.enumerated() {
                if i > 0 { y += Self.levelGap }
                let color = NSColor(DisplayNames.perfLevelColor(level.name, index: level.index))
                let shared = sharesTemperature(level)
                let usage = latest[.cpuUsagePerfLevel(level.index)]?.value
                var title = "\(DisplayNames.perfLevel(level.name)) ×\(level.cpuCount)"
                title += " · \(usage.map { PercentFormat.string(fromRatio: $0) } ?? "—")"
                if shared, let t = level.clusters.compactMap({ latest[.cpuTemperatureCluster($0)]?.value }).max() {
                    title += " · \(Formatting.temperature(t))"
                }
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 0, y: y + 4, width: 7, height: 7)).fill()
                Self.draw(Self.text(title, Self.captionBold), x: 12, y: y)
                summary.append(title)
                y += Self.headerHeight
                let clusters = topology.clusters.filter { $0.perfLevel == level.index }
                for (offset, cluster) in clusters.enumerated() {
                    let name = clusters.count > 1 ? String(localized: "簇 \(offset + 1)") : String(localized: "簇")
                    y = drawCluster(cluster, name: name, color: color, showsTemperature: !shared, latest, cores, y: y)
                }
            }
        case .clustersOnly:
            for cluster in topology.clusters {
                y = drawCluster(
                    cluster, name: cluster.key.description, color: .controlAccentColor, showsTemperature: true, latest,
                    cores, y: y)
            }
        case .coresOnly:
            drawBars(Array(cores.indices), cores: cores, color: .controlAccentColor, y: 0)
            return
        }
        Self.draw(
            Self.text(
                String(localized: "温度为簇所在位置的温度，GPU 重载时也会升高；功耗不含 GPU。"), Self.caption2, .tertiaryLabelColor),
            x: 0, y: y + 2)
        setAccessibilityLabel(summary.joined(separator: "；"))
    }

    private func drawCluster(
        _ cluster: CPUCluster, name: String, color: NSColor, showsTemperature: Bool, _ latest: [MetricID: Sample],
        _ cores: [Sample], y: CGFloat
    ) -> CGFloat {
        let usage = latest[.cpuUsageCluster(cluster.key)]?.value
        let frequency = latest[.cpuFrequencyCluster(cluster.key)]
        let temperature = showsTemperature ? latest[.cpuTemperatureCluster(cluster.key)]?.value : nil
        let power = latest[.cpuPowerCluster(cluster.key)]?.value
        Self.draw(Self.text(name, Self.caption, .secondaryLabelColor), x: 0, y: y)
        let cells = [
            usage.map { PercentFormat.string(fromRatio: $0) } ?? "—", Self.frequencyText(frequency),
            temperature.map(Formatting.temperature) ?? "", power.map(Formatting.watts) ?? "",
        ]
        for (cell, right) in zip(cells, Self.columns) where !cell.isEmpty {
            Self.drawRight(Self.text(cell, Self.captionDigits), right: right, y: y)
        }
        drawBars(cluster.cpus, cores: cores, color: color, y: y + Self.rowHeight + 3)
        return y + Self.rowHeight + 3 + Self.barsHeight + Self.clusterGap
    }

    static func frequencyText(_ sample: Sample?) -> String {
        guard let sample else { return "—" }
        if let hz = sample.value { return Formatting.frequency(hz) }
        if case .unavailable(let reason) = sample.quality, reason.code == UnavailableReason.clusterIdle().code {
            return String(localized: "空闲")
        }
        return "—"
    }

    /// 一组核的小柱：不可用时画成空槽，不画成 0。
    private func drawBars(_ indices: [Int], cores: [Sample], color: NSColor, y: CGFloat) {
        let gap: CGFloat = 2
        let width = bounds.width
        let count = CGFloat(max(indices.count, 1))
        let w = (width - gap * (count - 1)) / count
        for (i, cpu) in indices.enumerated() {
            let x = CGFloat(i) * (w + gap)
            NSColor.secondaryLabelColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: Self.barsHeight), xRadius: 1.5, yRadius: 1.5).fill()
            if cpu < cores.count, let v = cores[cpu].value {
                let h = max(Self.barsHeight * CGFloat(min(max(v, 0), 1)), 1)
                color.setFill()
                NSBezierPath(
                    roundedRect: NSRect(x: x, y: y + Self.barsHeight - h, width: w, height: h), xRadius: 1.5, yRadius: 1.5
                ).fill()
            }
        }
    }
}

// MARK: - 历史图的绘制区

final class ChartDrawView: LiveDrawView {
    /// 历史库读出的点（1 时、24 时、7 天）；为 nil 时画内存环形缓冲（2 分、15 分）。
    var stored: [CPUHistoryChart.StoredPoint]? {
        didSet { needsDisplay = true }
    }
    var spanSeconds: Double = 120 {
        didSet { needsDisplay = true }
    }

    private struct Point {
        var x: Double
        var y: Double
        var peak: Double?
        var segment: Int
    }

    private func points() -> [Point] {
        if let stored {
            let now = Date()
            var segment = 0
            var previous: CPUHistoryChart.StoredPoint?
            return stored.map { p in
                if let previous, p.date.timeIntervalSince(previous.date) > p.bucket * 1.5 { segment += 1 }
                previous = p
                let x = p.date.addingTimeInterval(p.bucket / 2).timeIntervalSince(now)
                return Point(x: min(x, 0), y: p.avg, peak: p.max, segment: segment)
            }
        }
        let raw = store.recentPoints(.cpuUsageTotal, seconds: spanSeconds)  // 观察：数据变化时重绘
        guard let newest = raw.last?.continuousNanos else { return [] }
        let maxGap = store.maxContinuousGapNanos(for: CPULoadCollector.collectorID)
        return TimeSeries.segmented(raw, maxGapNanos: maxGap).map { point, value, segment in
            Point(x: -Double(newest - point.continuousNanos) / 1e9, y: value, peak: nil, segment: segment)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        countDraw()
        let span = spanSeconds
        let size = bounds.size
        func x(_ v: Double) -> CGFloat { CGFloat((v + span) / span) * size.width }
        func y(_ v: Double) -> CGFloat { size.height * (1 - CGFloat(min(max(v, 0), 1))) }
        // 网格
        let grid = NSBezierPath()
        for level in [0.0, 0.5, 1.0] {
            grid.move(to: NSPoint(x: 0, y: y(level)))
            grid.line(to: NSPoint(x: size.width, y: y(level)))
        }
        for t in [-span, -span / 2, 0] {
            grid.move(to: NSPoint(x: x(t), y: 0))
            grid.line(to: NSPoint(x: x(t), y: size.height))
        }
        grid.lineWidth = 0.5
        grid.setLineDash([2, 2], count: 2, phase: 0)
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setStroke()
        grid.stroke()

        let all = points()
        let segments = Dictionary(grouping: all, by: \.segment).values.map { $0.sorted { $0.x < $1.x } }
        let accent = NSColor.controlAccentColor
        for segment in segments where !segment.isEmpty {
            let line = NSBezierPath()
            for (i, p) in segment.enumerated() {
                let pt = NSPoint(x: x(p.x), y: y(p.y))
                if i == 0 { line.move(to: pt) } else { line.line(to: pt) }
            }
            if stored == nil, let first = segment.first, let last = segment.last {
                let area = line.copy() as! NSBezierPath
                area.line(to: NSPoint(x: x(last.x), y: y(0)))
                area.line(to: NSPoint(x: x(first.x), y: y(0)))
                area.close()
                accent.withAlphaComponent(0.18).setFill()
                area.fill()
            }
            if segment.count > 1, segment.allSatisfy({ $0.peak != nil }) {
                let band = NSBezierPath()
                for (i, p) in segment.enumerated() {
                    let pt = NSPoint(x: x(p.x), y: y(p.peak ?? p.y))
                    if i == 0 { band.move(to: pt) } else { band.line(to: pt) }
                }
                for p in segment.reversed() { band.line(to: NSPoint(x: x(p.x), y: y(p.y))) }
                band.close()
                accent.withAlphaComponent(0.15).setFill()
                band.fill()
            }
            line.lineWidth = 1.5
            line.lineJoinStyle = .round
            accent.setStroke()
            line.stroke()
        }
        let latest = all.max { $0.x < $1.x }
        setAccessibilityLabel(
            String(localized: "CPU 占用图，最近值 \(latest.map { PercentFormat.string(fromRatio: $0.y) } ?? "—")"))
    }
}

// MARK: - SwiftUI 包装

/// 把自绘 view 放进 SwiftUI：SwiftUI 这边不读 MetricStore，数据更新时只有 AppKit view 自己重绘。
struct LiveView<View: LiveDrawView>: NSViewRepresentable {
    let make: () -> View
    var update: (View) -> Void = { _ in }

    func makeNSView(context: Context) -> View { make() }

    func updateNSView(_ view: View, context: Context) { update(view) }
}
