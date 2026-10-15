// 面板的 CPU tab（CPU 模块设计 §7.2，边界稿 §5.2，D29、D37）。
//
// 分区：概览 → 历史图 → 核心（按档分组，每簇一行）→ 详情（默认折叠）→ Top N。
// 只读 MetricStore 与芯片档案；需求由 PanelController 按 tab 可见性登记。

import SwiftUI
import SysCollectors
import SysModel

struct CPUPanelView: View {
    let store: MetricStore
    let services: CPUServices
    @Bindable var settings: AppSettings
    var expandDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelCard { CPUOverview(store: store, splitUserSystem: settings.panelSplitUserSystem) }
            PanelCard { CPUHistoryChart(store: store, history: services.history, defaultSpan: settings.panelChartSpan) }
            PanelCard { CPUCoresSection(store: store, sensors: services.collectors.sensors) }
            PanelCard { CPUDetailsSection(store: store, services: services, expandInitially: expandDetails) }
            if settings.panelTopNRows > 0 {
                PanelCard { TopNSection(model: services.topN, grouping: settings.panelGrouping) }
            }
        }
    }
}

// MARK: - 概览

private struct CPUOverview: View {
    let store: MetricStore
    let splitUserSystem: Bool

    var body: some View {
        let total = store.latest[.cpuUsageTotal]
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("总占用")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(total?.value.map { PercentFormat.string(fromRatio: $0) } ?? PercentFormat.placeholder)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if total?.quality == .estimated {
                        Text("估算")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("部分核的计数器复位，总占用由其余核估算")
                    }
                }
                if splitUserSystem {
                    UserSystemBar(user: store.latest[.cpuUsageUser]?.value, system: store.latest[.cpuUsageSystem]?.value)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                smallValue(String(localized: "频率"), fastestFrequency)
                smallValue(
                    String(localized: "最高温"), store.latest[.cpuTemperatureMax]?.value.map(Formatting.temperature) ?? "—")
                if let state = store.latest[.cpuThermalState]?.value, let badge = DisplayNames.thermalState(state) {
                    Text(badge.text)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badge.color.opacity(0.25), in: .capsule)
                        .help("系统热状态")
                }
            }
        }
    }

    /// 最快档（perflevel0）各簇实际频率的最大值；都空闲时显示「空闲」。
    private var fastestFrequency: String {
        guard let topology = CPUTopologyService.shared.current, topology.quality.isOK,
            let level = topology.perfLevels.first
        else { return "—" }
        let samples = level.clusters.compactMap { store.latest[.cpuFrequencyCluster($0)] }
        if let hz = samples.compactMap(\.value).max() { return Formatting.frequency(hz) }
        return samples.isEmpty ? "—" : String(localized: "空闲")
    }

    private func smallValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
    }
}

private struct UserSystemBar: View {
    let user: Double?
    let system: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    Rectangle().fill(Color.accentColor).frame(width: proxy.size.width * clamp(user))
                    Rectangle().fill(Color.orange).frame(width: proxy.size.width * clamp(system))
                    Spacer(minLength: 0)
                }
                .background(.quaternary)
                .clipShape(.rect(cornerRadius: 2))
            }
            .frame(width: 150, height: 5)
            HStack(spacing: 8) {
                legend(Color.accentColor, String(localized: "用户"), user)
                legend(.orange, String(localized: "系统"), system)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func clamp(_ v: Double?) -> CGFloat { CGFloat(min(max(v ?? 0, 0), 1)) }

    private func legend(_ color: Color, _ title: String, _ value: Double?) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(title) \(value.map { PercentFormat.string(fromRatio: $0) } ?? "—")").monospacedDigit()
        }
    }
}

// MARK: - 核心

struct CPUCoresSection: View {
    let store: MetricStore
    let sensors: SensorCollector?
    @Environment(\.panelLayoutChanged) private var layoutChanged

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let topology = CPUTopologyService.shared.current, topology.logicalCPUCount == store.cpuCores.count {
                switch topology.quality {
                case .ok:
                    ForEach(topology.perfLevels, id: \.index) { level in
                        levelGroup(level, topology)
                    }
                case .clustersOnly:
                    ForEach(topology.clusters, id: \.key) { cluster in
                        clusterRow(cluster, title: cluster.key.description, color: .accentColor, showsTemperature: true)
                    }
                case .coresOnly:
                    coreBars(Array(store.cpuCores.indices), color: .accentColor)
                }
                Text("温度为簇所在位置的温度，GPU 重载时也会升高；功耗不含 GPU。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("每核占用（\(store.cpuCores.count) 个逻辑核）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                coreBars(Array(store.cpuCores.indices), color: .accentColor)
            }
        }
        // 第一次采样之后才按拓扑分组显示，行数会变
        .onChange(of: store.cpuCores.count) { layoutChanged() }
    }

    /// 档内各簇是否共用同一组温度键（D37：共用时温度只显示在组标题里）。
    private func sharesTemperature(_ level: PerfLevel) -> Bool {
        guard level.clusters.count > 1, let profile = sensors?.profile?.profile else { return false }
        let sets = level.clusters.map { Set(profile.temperature.clusters[$0.description] ?? []) }
        return sets.allSatisfy { !$0.isEmpty && $0 == sets[0] }
    }

    private func levelGroup(_ level: PerfLevel, _ topology: CPUTopology) -> some View {
        let color = DisplayNames.perfLevelColor(level.name, index: level.index)
        let shared = sharesTemperature(level)
        let usage = store.latest[.cpuUsagePerfLevel(level.index)]?.value
        // 共用温度键时各簇温度相同，取第一个簇的值放在标题里。
        let sharedTemperature = shared ? level.clusters.compactMap { store.latest[.cpuTemperatureCluster($0)]?.value }.max() : nil
        var title = "\(DisplayNames.perfLevel(level.name)) ×\(level.cpuCount)"
        title += " · \(usage.map { PercentFormat.string(fromRatio: $0) } ?? "—")"
        if let sharedTemperature { title += " · \(Formatting.temperature(sharedTemperature))" }
        let clusters = topology.clusters.filter { $0.perfLevel == level.index }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.caption.weight(.semibold)).monospacedDigit()
            }
            ForEach(Array(clusters.enumerated()), id: \.element.key) { offset, cluster in
                clusterRow(
                    cluster, title: clusters.count > 1 ? String(localized: "簇 \(offset + 1)") : String(localized: "簇"),
                    color: color, showsTemperature: !shared)
            }
        }
    }

    private func clusterRow(_ cluster: CPUCluster, title: String, color: Color, showsTemperature: Bool) -> some View {
        let usage = store.latest[.cpuUsageCluster(cluster.key)]?.value
        let frequency = store.latest[.cpuFrequencyCluster(cluster.key)]
        let temperature = showsTemperature ? store.latest[.cpuTemperatureCluster(cluster.key)]?.value : nil
        let power = store.latest[.cpuPowerCluster(cluster.key)]?.value
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Text(title).frame(width: 40, alignment: .leading).foregroundStyle(.secondary)
                Text(usage.map { PercentFormat.string(fromRatio: $0) } ?? "—").frame(width: 42, alignment: .trailing)
                Text(frequencyText(frequency)).frame(width: 76, alignment: .trailing)
                Text(temperature.map(Formatting.temperature) ?? "").frame(width: 52, alignment: .trailing)
                Text(power.map(Formatting.watts) ?? "").frame(width: 62, alignment: .trailing)
            }
            .font(.caption)
            .monospacedDigit()
            coreBars(cluster.cpus, color: color)
        }
    }

    private func frequencyText(_ sample: Sample?) -> String {
        guard let sample else { return "—" }
        if let hz = sample.value { return Formatting.frequency(hz) }
        if case .unavailable(let reason) = sample.quality, reason.code == UnavailableReason.clusterIdle().code {
            return String(localized: "空闲")
        }
        return "—"
    }

    /// 一组核的小柱：一个 Canvas 画完（原先每核一个 GeometryReader，每秒重算十几个视图，开销实测后改掉）。
    /// 不可用时画成空槽，不画成 0。
    private func coreBars(_ cores: [Int], color: Color) -> some View {
        let all = store.cpuCores
        let values = cores.map { $0 < all.count ? all[$0].value : nil }
        return Canvas { context, size in
            let gap: CGFloat = 2
            let count = CGFloat(max(values.count, 1))
            let width = (size.width - gap * (count - 1)) / count
            for (i, value) in values.enumerated() {
                let x = CGFloat(i) * (width + gap)
                let slot = CGRect(x: x, y: 0, width: width, height: size.height)
                context.fill(Path(roundedRect: slot, cornerRadius: 1.5), with: .color(.secondary.opacity(0.25)))
                if let value {
                    let h = max(size.height * CGFloat(min(max(value, 0), 1)), 1)
                    let bar = CGRect(x: x, y: size.height - h, width: width, height: h)
                    context.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: .color(color))
                }
            }
        }
        .frame(height: 18)
        .help(
            zip(cores, values).map { cpu, value in "\(cpu)：\(value.map { PercentFormat.string(fromRatio: $0) } ?? "—")" }
                .joined(separator: "  "))
    }
}

// MARK: - 详情

private struct CPUDetailsSection: View {
    let store: MetricStore
    let services: CPUServices
    @State private var expanded: Bool
    @State private var sourcesExpanded: Bool
    @Environment(\.panelLayoutChanged) private var layoutChanged

    init(store: MetricStore, services: CPUServices, expandInitially: Bool) {
        self.store = store
        self.services = services
        _expanded = State(initialValue: expandInitially)
        _sourcesExpanded = State(initialValue: expandInitially)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                row(String(localized: "负载均值"), loadAverage, help: String(localized: "1、5、15 分钟；内核约每 5 秒更新一次"))
                row(String(localized: "开机时间"), Formatting.duration(Self.uptime))
                row(String(localized: "进程 / 线程"), "\(int(.cpuTaskCount)) / \(int(.cpuThreadCount))")
                row(
                    String(localized: "中断"),
                    "IPI \(rate(.cpuInterruptIPIRate)) · \(String(localized: "定时器")) \(rate(.cpuInterruptTimerRate)) · \(String(localized: "其余")) \(rate(.cpuInterruptOtherRate))",
                    help: String(localized: "全部核之和；「其余」是扣掉 IPI 和定时器后的余量，约等于设备中断"))
                DisclosureGroup(isExpanded: $sourcesExpanded) {
                    interruptSources
                } label: {
                    Text("中断来源").font(.caption)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("详情").font(.caption.weight(.semibold))
        }
        .onChange(of: expanded) { layoutChanged() }
        .onChange(of: sourcesExpanded) { layoutChanged() }
    }

    /// 按设备的中断次数（IOReport，展开时每 5 秒更新一次）。
    @ViewBuilder
    private var interruptSources: some View {
        let _ = store.engineStatus?.tickCount  // 随 tick 刷新
        let sources = services.collectors.interrupts?.latestSources ?? []
        VStack(alignment: .leading, spacing: 2) {
            if sources.isEmpty {
                Text("约 5 秒后显示").font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(sources.prefix(8), id: \.device) { source in
                HStack {
                    Text(source.device).font(.caption2.monospaced())
                    Spacer()
                    Text(Formatting.rate(source.perSecond)).font(.caption2).monospacedDigit()
                }
                .foregroundStyle(.secondary)
            }
        }
        .onChange(of: min(sources.count, 8)) { layoutChanged() }
        .onAppear { services.setInterruptSourcesVisible(true) }
        .onDisappear { services.setInterruptSourcesVisible(false) }
    }

    private var loadAverage: String {
        [MetricID.cpuLoadAverage1, .cpuLoadAverage5, .cpuLoadAverage15]
            .map { store.latest[$0]?.value.map { String(format: "%.2f", $0) } ?? "—" }
            .joined(separator: "  ")
    }

    private func int(_ id: MetricID) -> String {
        store.latest[id]?.value.map { String(Int($0)) } ?? "—"
    }

    private func rate(_ id: MetricID) -> String {
        store.latest[id]?.value.map(Formatting.rate) ?? "—"
    }

    private func row(_ title: String, _ value: String, help: String? = nil) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.caption)
        .help(help ?? "")
    }

    /// 开机至今（含睡眠），由 `kern.boottime` 算出。
    static var uptime: TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return 0 }
        return Date().timeIntervalSince1970 - (Double(boot.tv_sec) + Double(boot.tv_usec) / 1e6)
    }
}
