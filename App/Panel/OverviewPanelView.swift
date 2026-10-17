// 合并模式的「总览」（D65 MG5，合并模式设计 §7.6）：每个模块一张定高小卡片（两行数值 + 最近 60 s 迷你曲线），
// 点击卡片换到该模块主页（替换，不算一层，D64）。
//
// - 数据只用各模块的常驻采集器（PanelController.updateOverviewDemands 登记）：不扫 Top N、不读全部盘 SMART、
//   不读 CoreWLAN。盘温取盘温 widget 绑定的盘最近一次读数（没开盘温 widget 时可能是历史每分钟那次读的）；
// - 「今日流量」读历史库（主接口），每 60 s 一次；
// - 卡片顺序与切换器一致（D65 MG3）；
// - 底部「最耗能的应用」卡片（D70）：复用后台历史已有的 10 s coalition 扫描，显示最近 60 s 按功率（CPU + GPU + ANE）
//   的前 3，不另外采样；关掉「记录每应用数据」时不出现。点击打开应用活动窗口，按功率排序。

import AppKit
import SwiftUI
import SysCollectors
import SysModel
import SysStore

struct OverviewPanelView: View {
    let store: MetricStore
    let services: AppServices
    let settings: AppSettings
    let tabs: [PanelTab]
    let select: (PanelTab) -> Void

    @State private var todayTraffic: Double?
    @State private var topEnergy: [(key: String, name: String, watts: Double)] = []
    @Environment(\.openAppActivity) private var openAppActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(tabs.filter { $0 != .overview }) { tab in
                Button {
                    select(tab)
                } label: {
                    PanelCard {
                        HStack(spacing: 6) {
                            LiveView(make: { OverviewCardDrawView(store: store, services: services, settings: settings, tab: tab) }) {
                                $0.todayTraffic = todayTraffic
                            }
                            .frame(height: OverviewCardDrawView.height)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(tab.title))
                .help("查看\(tab.title)")
            }
            if services.history != nil, settings.historyAppsEnabled {
                Button {
                    openAppActivity(.power)
                } label: {
                    PanelCard { energyCard }.contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("打开应用活动窗口，按功率排序")
            }
        }
        .task {
            while !Task.isCancelled {
                await loadTodayTraffic()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .task(id: settings.historyAppsEnabled) {
            while !Task.isCancelled, settings.historyAppsEnabled, let history = services.history {
                topEnergy = await history.recentTopEnergy(limit: Self.energyRows)
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    static let energyRows = 3

    /// 定高：标题 + 3 个行位（D64）。
    private var energyCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("最耗能的应用").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("最近 1 分钟").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(0..<Self.energyRows, id: \.self) { index in
                HStack(spacing: 6) {
                    if index < topEnergy.count {
                        let app = topEnergy[index]
                        AppIcon(path: services.appActivity?.appPath(forKey: app.key))
                        Text(app.name).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Formatting.watts(app.watts)).monospacedDigit()
                    } else {
                        Color.clear.frame(width: 16, height: 16)
                        Text(index == 0 && topEnergy.isEmpty ? String(localized: "等待数据…") : " ").foregroundStyle(.tertiary)
                        Spacer()
                    }
                }
                .font(.caption)
            }
        }
    }

    /// 主接口今日的入 + 出字节（历史库，按本地时区切日，同网络面板的流量统计）。
    private func loadTodayTraffic() async {
        guard let history = services.history, settings.historyNetworkEnabled else { return }
        let now = Date()
        let day = Calendar.current.startOfDay(for: now)
        var total = 0.0
        for direction in MetricID.NetworkDirection.allCases {
            guard let value = try? await history.total(.networkPrimary(direction), from: day, to: now) else { return }
            total += value
        }
        todayTraffic = total
    }
}

/// 一张总览卡片：左上模块名，第一行主数值，第二行次要数值；右侧最近 60 s 迷你曲线。
final class OverviewCardDrawView: LiveDrawView {
    static let height: CGFloat = 40
    static let sparklineSeconds: Double = 60
    static let sparklineWidth: CGFloat = 96

    private let services: AppServices
    private let settings: AppSettings
    let tab: PanelTab
    var todayTraffic: Double? {
        didSet { if todayTraffic != oldValue { needsDisplay = true } }
    }

    private static let title = NSFont.systemFont(ofSize: 11, weight: .semibold)
    /// 数值列的起点：所有卡片对齐，取最长模块名的宽度。
    private static let valueX: CGFloat = ceil(
        PanelTab.allCases.map { text($0.title, title).size().width }.max() ?? 64) + 10
    private static let primary = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)

    init(store: MetricStore, services: AppServices, settings: AppSettings, tab: PanelTab) {
        self.services = services
        self.settings = settings
        self.tab = tab
        super.init(store: store)
    }

    override func draw(_ dirtyRect: NSRect) {
        countDraw()
        let latest = store.latest
        let (first, second, series) = lines(latest)
        Self.draw(Self.text(tab.title, Self.title, .secondaryLabelColor), x: 0, y: 2)
        Self.draw(Self.text(first, Self.primary), x: Self.valueX, y: 0)
        Self.draw(Self.text(second, Self.caption2Digits, .secondaryLabelColor), x: Self.valueX, y: 22)
        let rect = NSRect(x: bounds.width - Self.sparklineWidth, y: 4, width: Self.sparklineWidth, height: bounds.height - 8)
        drawSparklines(series, in: rect)
        setAccessibilityLabel("\(tab.title) \(first) \(second)")
    }

    /// 各模块的两行文字与曲线（第一条强调色，第二条橙色）。
    private func lines(_ latest: [MetricID: Sample]) -> (String, String, [(MetricID, ScaleKind)]) {
        switch tab {
        case .overview:
            return ("", "", [])
        case .cpu:
            let total = latest[.cpuUsageTotal]?.value.map { PercentFormat.string(fromRatio: $0) } ?? "—"
            return (total, levelUsage(), [(.cpuUsageTotal, .ratio)])
        case .power:
            let system = store.smoothed[.powerSystem].map(Formatting.watts) ?? "—"
            var parts = [String(localized: "最热点 \(latest[.thermalSoCHotspot]?.value.map(Formatting.temperature) ?? "—")")]
            if services.power.hasFans {
                let rpm = latest.compactMap { id, sample in id.fanSpeedIndex != nil ? sample.value : nil }.max()
                parts.append(String(localized: "风扇 \(rpm.map { String(format: "%.0f", $0) } ?? "—") rpm"))
            }
            return (system, parts.joined(separator: " · "), [(.powerSystem, .watts)])
        case .memory:
            let usage = latest[.memoryUsage]?.value.map { PercentFormat.string(fromRatio: $0) } ?? "—"
            let pressure = latest[.memoryPressure]?.value.map { PercentFormat.string(fromRatio: $0) } ?? "—"
            let swap = latest[.memorySwapUsed]?.value.map { Formatting.memory($0) } ?? "—"
            return (usage, String(localized: "压力 \(pressure) · 交换 \(swap)"), [(.memoryUsage, .ratio)])
        case .storage:
            let model = services.storageModel
            guard let disk = model.resolveDisk(settings.diskTemperatureTarget)
            else { return ("—", String(localized: "没有物理盘"), []) }
            let temp = latest[.storageDisk(disk, .temp)]?.value.map(Formatting.temperature) ?? "—"
            let read = latest[.storageDisk(disk, .read)]?.value.map(Formatting.diskRate) ?? "—"
            let write = latest[.storageDisk(disk, .write)]?.value.map(Formatting.diskRate) ?? "—"
            var second = String(localized: "读 \(read)  写 \(write)")
            if let group = model.resolveGroup(settings.diskFreeTarget),
                let free = latest[.storageGroup(group, .available)]?.value
            {
                second += " · " + String(localized: "可用 \(Formatting.diskBytesShort(free))")
            }
            return (temp, second, [(.storageDisk(disk, .read), .bytes), (.storageDisk(disk, .write), .bytes)])
        case .gpu:
            let active = latest[.gpuActive]?.value.map { PercentFormat.string(fromRatio: $0) } ?? "—"
            let power = store.smoothed[.powerGPU].map(Formatting.watts) ?? "—"
            let temp = latest[.gpuTemperature]?.value.map(Formatting.temperature) ?? "—"
            return (active, String(localized: "功率 \(power) · 温度 \(temp)"), [(.gpuActive, .ratio)])
        case .network:
            let bits = settings.networkThroughputBits
            let down = latest[.networkPrimaryIn]?.value.map { NetworkText.rate($0, bits: bits) } ?? "—"
            let up = latest[.networkPrimaryOut]?.value.map { NetworkText.rate($0, bits: bits) } ?? "—"
            var parts: [String] = []
            if let primary = services.networkModel.state.primary { parts.append(primary) }
            if let todayTraffic { parts.append(String(localized: "今日 \(Formatting.diskBytes(todayTraffic))")) }
            return ("↓ \(down)  ↑ \(up)", parts.joined(separator: " · "), [(.networkPrimaryIn, .bytes), (.networkPrimaryOut, .bytes)])
        }
    }

    /// 按档占用：「Super 42% · Performance 8%」，档名运行时取（D20）。拓扑不成立时给逻辑核数。
    private func levelUsage() -> String {
        let cores = store.cpuCores
        guard let topology = CPUTopologyService.shared.current, topology.logicalCPUCount == cores.count,
            !topology.perfLevels.isEmpty
        else { return String(localized: "\(cores.count) 个逻辑核") }
        return topology.perfLevels.map { level -> String in
            let cpus = topology.clusters.filter { level.clusters.contains($0.key) }.flatMap(\.cpus)
            let values = cpus.compactMap { $0 < cores.count ? cores[$0].value : nil }
            let mean = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
            return "\(DisplayNames.perfLevel(level.name)) \(mean.map { PercentFormat.string(fromRatio: $0) } ?? "—")"
        }.joined(separator: " · ")
    }

    enum ScaleKind {
        /// 0…1，纵轴固定到 1。
        case ratio
        /// 瓦，纵轴按最大值（至少 1 W）。
        case watts
        /// 字节 / 秒，纵轴按最大值（至少 10 KB/s）。
        case bytes
    }

    private func drawSparklines(_ series: [(MetricID, ScaleKind)], in rect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        NSRect(x: rect.minX, y: rect.maxY - 0.5, width: rect.width, height: 0.5).fill()
        guard let kind = series.first?.1 else { return }
        let all = series.map { store.recentPoints($0.0, seconds: Self.sparklineSeconds) }
        let newest = all.compactMap { $0.last?.continuousNanos }.max() ?? 0
        guard newest > 0 else { return }
        let peak = all.flatMap { $0.compactMap(\.value) }.max() ?? 0
        let top: Double =
            switch kind {
            case .ratio: 1
            case .watts: max(peak, 1)
            case .bytes: max(peak, 10_000)
            }
        for (points, color) in zip(all, [NSColor.controlAccentColor, .systemOrange]) {
            let path = NSBezierPath()
            path.lineWidth = 1
            var started = false
            for point in points {
                guard let value = point.value else {
                    started = false
                    continue
                }
                let age = Double(newest &- point.continuousNanos) / 1e9
                let x = rect.maxX - CGFloat(age / Self.sparklineSeconds) * rect.width
                let y = rect.maxY - CGFloat(min(max(value / top, 0), 1)) * rect.height
                if started { path.line(to: NSPoint(x: x, y: y)) } else { path.move(to: NSPoint(x: x, y: y)) }
                started = true
            }
            color.setStroke()
            path.stroke()
        }
    }
}
