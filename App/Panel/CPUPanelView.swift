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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelCard { CPUOverview(store: store, splitUserSystem: settings.panelSplitUserSystem) }
            PanelCard { CPUHistoryChart(store: store, history: services.history, defaultSpan: settings.panelChartSpan) }
            PanelCard { CPUCoresSection(store: store, sensors: services.collectors.sensors) }
            PanelCard { CPUDetailsSection(store: store) }
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
                        .contentTransition(.numericText())
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

    private func coreBars(_ cores: [Int], color: Color) -> some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(cores, id: \.self) { index in
                CoreBar(index: index, value: index < store.cpuCores.count ? store.cpuCores[index].value : nil, color: color)
            }
        }
        .frame(height: 18)
    }
}

/// 一个核的小柱。不可用时画成空槽，不画成 0。
private struct CoreBar: View {
    let index: Int
    let value: Double?
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1.5).fill(.quaternary)
                if let value {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color)
                        .frame(height: max(proxy.size.height * min(max(value, 0), 1), 1))
                }
            }
        }
        .help(String(localized: "核 \(index)：\(value.map { PercentFormat.string(fromRatio: $0) } ?? String(localized: "不可用"))"))
    }
}

// MARK: - 详情

private struct CPUDetailsSection: View {
    let store: MetricStore
    @State private var expanded = false

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
            }
            .padding(.top, 4)
        } label: {
            Text("详情").font(.caption.weight(.semibold))
        }
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
