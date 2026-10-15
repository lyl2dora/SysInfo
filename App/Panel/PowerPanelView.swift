// 面板的「功耗与散热」tab（功耗与散热模块设计 §7.2，D44–D46）。
//
// 分区：概览 → 历史图 → 功率分解 → 最近 30 分钟 → 散热 → 能耗。
// 每秒都在变的部分（概览、分解、散热）用 AppKit 自绘（见 PowerLiveViews.swift），SwiftUI 只放外框；
// 30 分钟卡片与能耗卡片很少变化，用 SwiftUI，按分钟重读。需求由 PanelController 按 tab 可见性登记。

import SwiftUI
import SysCollectors
import SysModel
import SysStore

struct PowerPanelView: View {
    let store: MetricStore
    let services: AppServices
    @Bindable var settings: AppSettings
    var openCPUTab: () -> Void = {}
    /// 风扇数：自检时才发现，面板可能更早建好（`--open-panel`），所以等一会儿再定高度。
    @State private var fanCount = 0
    @Environment(\.panelLayoutChanged) private var layoutChanged

    var body: some View {
        let hasFans = fanCount > 0
        let fanCount = fanCount
        VStack(alignment: .leading, spacing: 10) {
            PanelCard {
                LiveView(make: { PowerOverviewDrawView(store: store) }, update: { $0.hasFans = hasFans })
                    .frame(height: PowerOverviewDrawView.height)
            }
            PanelCard {
                HistoryChart(
                    store: store, history: services.history, defaultSpan: settings.powerChartSpan,
                    series: ChartSeries(
                        metric: .powerSystem, overlay: settings.powerChartOverlaySoC ? .powerSoC : nil,
                        collector: PowerRailCollector.collectorID, scale: .watts))
            }
            PanelCard {
                VStack(alignment: .leading, spacing: 4) {
                    LiveView(make: { PowerBreakdownDrawView(store: store) })
                        .frame(height: PowerBreakdownDrawView.height)
                    Button("按簇查看 CPU 功耗", action: openCPUTab)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            PanelCard { PMGRBatchCard(pmgr: services.power.pmgr, history: services.history) }
            PanelCard {
                LiveView(make: { ThermalDrawView(store: store) }, update: { $0.fanCount = fanCount })
                    .frame(height: ThermalDrawView.height(fans: fanCount))
            }
            PanelCard { EnergyCard(history: services.history, enabled: settings.historyEnergyEnabled) }
        }
        .task {
            // 只在风扇数变化时更新（不订阅每秒的数据），最多等 10 s 等启动自检完成。
            for _ in 0..<40 {
                let count = services.power.sensors?.fans.count ?? 0
                if count != self.fanCount {
                    self.fanCount = count
                    layoutChanged()
                }
                if count > 0 || store.engineStatus?.health.contains(where: { $0.id == PowerSensorCollector.collectorID && $0.selfTest != nil }) == true {
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

// MARK: - 最近 30 分钟（D45）

/// PMGR 批次：Apple 功耗模型口径的分部件平均功率，每 30 分钟更新一次。CPU 行并排给出同一窗口里专用轨的均值。
struct PMGRBatchCard: View {
    let pmgr: PMGRBatchCollector?
    let history: HistoryRecorder?

    @State private var batch: PMGRBatch?
    @State private var railWatts: Double?
    @State private var now = Date()
    @Environment(\.panelLayoutChanged) private var layoutChanged

    /// 显示顺序与合并：归一化名 → 显示名。不认识的通道（例如 AFR、MSR）放在最后，原样显示。
    static let rows: [(title: String, components: [String])] = [
        (String(localized: "CPU"), ["cpu"]),
        (String(localized: "GPU"), ["gpu"]),
        (String(localized: "神经网络引擎"), ["ane"]),
        (String(localized: "媒体引擎"), ["ave"]),
        (String(localized: "内存控制器"), ["amcc", "dcs"]),
        (String(localized: "DRAM"), ["dram"]),
        (String(localized: "片上互连"), ["fabric"]),
        (String(localized: "显示"), ["display", "displayExt"]),
        (String(localized: "图像处理"), ["isp"]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("最近 30 分钟").font(.caption.weight(.semibold))
                Spacer()
                if let batch {
                    Text(windowText(batch)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let batch {
                let known = Set(Self.rows.flatMap(\.components))
                ForEach(Self.rows, id: \.title) { row in
                    let joules = row.components.compactMap { batch.joules[$0] }
                    if !joules.isEmpty {
                        line(row.title, watts: joules.reduce(0, +) / batch.seconds, extra: row.components == ["cpu"] ? railText : nil)
                    }
                }
                ForEach(batch.joules.keys.filter { !known.contains($0) }.sorted(), id: \.self) { name in
                    line(name.uppercased(), watts: batch.watts(name) ?? 0, extra: nil)
                }
                Text("Apple 功耗模型口径，每 30 分钟更新一次；神经网络引擎、媒体引擎只有这一个来源。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("等待首个批次：开机后约每 30 分钟发布一次，app 运行期间才能收到。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        // 批次异步读到后行数会变：请面板重新量高度。
        .onChange(of: batch) { layoutChanged() }
        .onChange(of: railWatts) { layoutChanged() }
    }

    private var railText: String? {
        railWatts.map { String(localized: "专用轨实测 \(Formatting.watts($0))") }
    }

    private func line(_ title: String, watts: Double, extra: String?) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            if let extra {
                Text(extra).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(Formatting.watts(watts)).monospacedDigit()
        }
        .font(.caption)
    }

    private func windowText(_ batch: PMGRBatch) -> String {
        let f = Date.FormatStyle(date: .omitted, time: .shortened)
        let minutes = Int(now.timeIntervalSince(batch.end) / 60)
        let age = minutes < 1 ? String(localized: "刚刚更新") : String(localized: "\(minutes) 分钟前更新")
        return "\(batch.start.formatted(f))–\(batch.end.formatted(f)) · \(age)"
    }

    private func reload() async {
        now = Date()
        let latest = pmgr?.latestBatch
        if latest != batch {
            batch = latest
            railWatts = nil
            if let latest, let history {
                // 同一窗口里 CPU 专用轨的均值（历史库的分钟数据，按覆盖秒数加权）。
                let points = try? await history.series(
                    .cpuPowerTotal, from: latest.start, to: latest.end.addingTimeInterval(-60), granularity: .minute)
                let n = points?.reduce(0) { $0 + Double($1.n) } ?? 0
                if let points, n > latest.seconds * 0.5 {
                    railWatts = points.reduce(0) { $0 + $1.avg * Double($1.n) } / n
                }
            }
        }
    }
}

// MARK: - 能耗（D46）

struct EnergyCard: View {
    let history: HistoryRecorder?
    let enabled: Bool

    @State private var rows: [(title: String, summary: EnergySummary)] = []
    @Environment(\.panelLayoutChanged) private var layoutChanged

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("能耗").font(.caption.weight(.semibold))
            if !enabled {
                Text("未记录能耗，可以在设置的「功耗与散热」页开启。").font(.caption2).foregroundStyle(.secondary)
            } else if history == nil {
                Text("历史库不可用").font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(rows, id: \.title) { row in
                    HStack {
                        Text(row.title).foregroundStyle(.secondary)
                        Spacer()
                        Text(Formatting.energy(row.summary.total)).monospacedDigit()
                    }
                    .font(.caption)
                }
                if rows.contains(where: { $0.summary.filled > 0 }) {
                    Text("含 SysInfo 未运行时段的系统累计值，满载时可能偏低。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: enabled) {
            guard enabled else { return }
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func reload() async {
        guard let history else { return }
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let week = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        var out: [(String, EnergySummary)] = []
        for (title, from, to) in [
            (String(localized: "今天"), today, now), (String(localized: "昨天"), yesterday, today),
            (String(localized: "近 7 天"), week, now),
        ] {
            // 区间右端按分钟取整：查询按分钟边界，「昨天」不能带上今天的第一分钟。
            let end = to == now ? now : to.addingTimeInterval(-1)
            if let summary = try? await history.energySummary(from: from, to: end) { out.append((title, summary)) }
        }
        let shapeChanged = out.count != rows.count || out.contains { $0.1.filled > 0 } != rows.contains { $0.summary.filled > 0 }
        rows = out
        if shapeChanged { layoutChanged() }
    }
}
