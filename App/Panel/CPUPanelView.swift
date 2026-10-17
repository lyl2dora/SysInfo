// 面板的 CPU tab（CPU 模块设计 §7.2，边界稿 §5.2，D29、D37）。
//
// 分区：概览 → 历史图 → 核心（按档分组，每簇一行）→ 详情（默认折叠）→ Top N。
// 只读 MetricStore 与芯片档案；需求由 PanelController 按 tab 可见性登记。

import SwiftUI
import SysCollectors
import SysModel

struct CPUPanelView: View {
    let store: MetricStore
    let services: AppServices
    @Bindable var settings: AppSettings
    var expandDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelCard {
                let split = settings.panelSplitUserSystem
                LiveView(make: { OverviewDrawView(store: store) }, update: { $0.splitUserSystem = split })
                    .frame(height: split ? OverviewDrawView.height : OverviewDrawView.height - 22)
            }
            PanelCard { HistoryChart(store: store, history: services.history, defaultSpan: settings.panelChartSpan) }
            PanelCard { CPUCoresSection(store: store, sensors: services.collectors.sensors) }
            PanelCard { CPUDetailsSection(store: store, services: services, expandInitially: expandDetails) }
            if settings.panelTopNRows > 0 {
                PanelCard { TopNSection(model: services.topN, grouping: settings.panelGrouping, slots: settings.panelTopNRows) }
            }
        }
    }
}

// MARK: - 核心

/// 核心区：高度按拓扑固定，内容由 CoresDrawView 自绘。
/// 拓扑在第一次采样后才确定（核数对上），这里只在核数变化时重新算高度并请面板量高。
struct CPUCoresSection: View {
    let store: MetricStore
    let sensors: SensorCollector?
    @State private var coreCount = 0
    @Environment(\.panelLayoutChanged) private var layoutChanged

    var body: some View {
        LiveView(make: { CoresDrawView(store: store, sensors: sensors) })
            .frame(height: CoresDrawView.height(for: CPUTopologyService.shared.current, cores: coreCount))
            .task {
                // 只在核数变化时更新（不订阅每秒的数据），最多等 10 s 拿到第一次采样
                for _ in 0..<40 {
                    let count = store.cpuCores.count  // task 不在 body 里，不会让 SwiftUI 订阅每秒的数据
                    if count != coreCount {
                        coreCount = count
                        layoutChanged()
                    }
                    if count > 0 { break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
    }
}

// MARK: - 详情

private struct CPUDetailsSection: View {
    let store: MetricStore
    let services: AppServices
    @State private var expanded: Bool
    @State private var sourcesExpanded: Bool
    @Environment(\.panelLayoutChanged) private var layoutChanged

    init(store: MetricStore, services: AppServices, expandInitially: Bool) {
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
                    toggleLabel($sourcesExpanded) { Text("中断来源").font(.panelRow) }
                }
            }
            .padding(.top, 4)
        } label: {
            toggleLabel($expanded) { Text("详情").font(.panelRow.weight(.semibold)) }
        }
        .onChange(of: expanded) { layoutChanged() }
        .onChange(of: sourcesExpanded) { layoutChanged() }
    }

    /// macOS 的 DisclosureGroup 只有三角能点；标签整行也能展开 / 收起（D71 全量验收发现）。
    private func toggleLabel(_ isOn: Binding<Bool>, @ViewBuilder _ label: () -> some View) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            label().frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 按设备的中断次数（IOReport，展开时每 5 秒更新一次）。
    @ViewBuilder
    private var interruptSources: some View {
        let _ = store.engineStatus?.tickCount  // 随 tick 刷新
        let sources = services.collectors.interrupts?.latestSources ?? []
        VStack(alignment: .leading, spacing: 2) {
            if sources.isEmpty {
                Text("约 5 秒后显示").font(.panelNote).foregroundStyle(.tertiary)
            }
            ForEach(sources.prefix(8), id: \.device) { source in
                HStack {
                    Text(source.device).font(.panelNote.monospaced())
                    Spacer()
                    Text(Formatting.rate(source.perSecond)).font(.panelNote).monospacedDigit()
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
        .font(.panelRow)
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
