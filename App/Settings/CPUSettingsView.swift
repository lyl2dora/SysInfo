// 设置的 CPU 页（CPU 模块设计 §7.3，D19、D29、D32）。
//
// - 采集：模块间隔覆盖；面板内频率、温度与功耗、Top N 的间隔（1/2/5 s），旁边标注开销；
// - 菜单栏：样式、「CPU」标签、着色与阈值，带实时预览（用真实的 item view 渲染）；
// - 面板：图表默认跨度、用户/系统拆分、Top N 行数与分组。
// 开销标注（D19）：优先用诊断数据里本机实测的单次 CPU 耗时换算；还没有实测时用参考值并注明出处。

import AppKit
import SwiftUI
import SysCollectors
import SysModel

struct CPUSettingsView: View {
    @Bindable var settings: AppSettings
    let store: MetricStore

    var body: some View {
        Form {
            Section("采集") {
                Picker("菜单栏采集间隔", selection: $settings.cpuIntervalOverride) {
                    Text("跟随默认（\(DisplayNames.interval(settings.globalInterval))）")
                        .tag(SamplingInterval?.none)
                    ForEach(SamplingInterval.allCases) { interval in
                        Text(DisplayNames.interval(interval)).tag(Optional(interval))
                    }
                }
                intervalPicker(
                    String(localized: "面板：频率"), $settings.panelFreqInterval, collector: CPUFrequencyCollector.collectorID)
                intervalPicker(
                    String(localized: "面板：温度与功耗"), $settings.panelSensorInterval, collector: SensorCollector.collectorID)
                intervalPicker(
                    String(localized: "面板：Top N"), $settings.panelTopNInterval, collector: AppSampler.collectorID)
                Text("面板内的采样只在 CPU 页可见时进行，占用固定每秒一次。开销按本机实测的单次耗时换算，按单核计。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("高开销选项") {
                Toggle(isOn: $settings.historyHighPrecision) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("后台高精度历史")
                        Text(
                            "频率、温度与功耗在后台每 5 秒采一次（默认 60 秒 / 10 秒）。频率 \(CostLabel.text(collector: CPUFrequencyCollector.collectorID, interval: 5, store: store))；温度与功耗 \(CostLabel.text(collector: SensorCollector.collectorID, interval: 5, store: store))。"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.historyCPUEnabled)
            }

            Section("菜单栏") {
                Picker("占用的样式", selection: $settings.menuBarCPUStyle) {
                    ForEach(MenuBarCPUStyle.allCases) { style in
                        Text(Self.styleName(style)).tag(style)
                    }
                }
                Toggle("显示小标签（CPU、FREQ、TEMP、PWR）", isOn: $settings.menuBarCPULabel)
                Toggle("占用高时着色", isOn: $settings.menuBarCPUColoring)
                if settings.menuBarCPUColoring {
                    Stepper(value: $settings.menuBarCPUWarningPercent, in: 50...99) {
                        LabeledContent("橙色阈值", value: "\(settings.menuBarCPUWarningPercent)%")
                    }
                    Stepper(value: $settings.menuBarCPUCriticalPercent, in: settings.menuBarCPUWarningPercent...100) {
                        LabeledContent("红色阈值", value: "\(settings.menuBarCPUCriticalPercent)%")
                    }
                    Text("总占用平滑后持续 10 秒达到阈值才变色，回落时留 5 个百分点。温度和热状态不参与着色。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("预览") {
                    StatusItemPreview(store: store, configuration: previewConfiguration)
                }
            }

            Section("面板") {
                Picker("图表默认跨度", selection: $settings.panelChartSpan) {
                    ForEach(ChartSpan.allCases) { span in
                        Text(CPUHistoryChart.title(span)).tag(span)
                    }
                }
                Toggle("拆分用户 / 系统", isOn: $settings.panelSplitUserSystem)
                Picker("Top N 行数", selection: $settings.panelTopNRows) {
                    ForEach(AppSettings.topNRowChoices, id: \.self) { rows in
                        Text(rows == 0 ? String(localized: "不显示") : "\(rows)").tag(rows)
                    }
                }
                Picker("Top N 分组", selection: $settings.panelGrouping) {
                    Text("按应用").tag(TopNGrouping.byApp)
                    Text("按进程").tag(TopNGrouping.byProcess)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var previewConfiguration: CPUStatusItemConfiguration {
        let topology = CPUTopologyService.shared.current
        return CPUStatusItemConfiguration(
            style: settings.menuBarCPUStyle, showsLabel: settings.menuBarCPULabel, coloring: settings.menuBarCPUColoring,
            levelCount: max(topology?.perfLevels.count ?? 2, 1),
            coreCount: topology?.logicalCPUCount ?? SystemInfo.maxLogicalCPUCount ?? 8)
    }

    static func styleName(_ style: MenuBarCPUStyle) -> String {
        switch style {
        case .stacked: String(localized: "上下（标签在上）")
        case .inline: String(localized: "左右")
        case .sparkline: String(localized: "迷你折线")
        case .barsTotal: String(localized: "柱：总量")
        case .barsLevels: String(localized: "柱：按档")
        case .barsCores: String(localized: "柱：每核")
        }
    }

    private func intervalPicker(_ title: String, _ selection: Binding<Int>, collector: CollectorID) -> some View {
        Picker(title, selection: selection) {
            ForEach(AppSettings.panelIntervals, id: \.self) { seconds in
                Text("\(seconds) 秒  \(CostLabel.text(collector: collector, interval: seconds, store: store))").tag(seconds)
            }
        }
    }
}

/// 开销标注（D19）。
enum CostLabel {
    /// 参考值：单次采样的线程 CPU 时间，毫秒（偏离记录与 D34 的两台实测，取较大者）。
    static let referenceMilliseconds: [CollectorID: Double] = [
        CPUFrequencyCollector.collectorID: 9.5,  // D34：M5 约 9.5 ms，M4 约 8.5 ms
        AppSampler.collectorID: 14,  // 偏离记录 §5.7：M5 约 10.8 ms，M4 约 14 ms（含组装）
    ]

    static func text(collector: CollectorID, interval: Int, store: MetricStore) -> String {
        if let health = store.engineStatus?.health.first(where: { $0.id == collector }), let cost = health.averageCost,
            health.sampleCount >= 5
        {
            let percent = Double(cost.cpuNanos) / 1e9 / Double(interval) * 100
            return String(localized: "约 \(String(format: "%.2f", percent))% 单核（本机实测）")
        }
        if let ms = referenceMilliseconds[collector] {
            let percent = ms / 1000 / Double(interval) * 100
            return String(localized: "约 \(String(format: "%.2f", percent))% 单核（参考 M5 Pro / M4 Pro）")
        }
        return String(localized: "尚无实测")
    }
}

/// 设置页的菜单栏预览：用真实的 item view 渲染。
private struct StatusItemPreview: NSViewRepresentable {
    let store: MetricStore
    let configuration: CPUStatusItemConfiguration

    func makeNSView(context: Context) -> CPUStatusItemView {
        CPUStatusItemView(store: store, height: NSStatusBar.system.thickness, configuration: configuration)
    }

    func updateNSView(_ view: CPUStatusItemView, context: Context) {
        view.configuration = configuration
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CPUStatusItemView, context: Context) -> CGSize? {
        CGSize(width: CPUStatusItemView.fixedWidth(for: configuration), height: NSStatusBar.system.thickness)
    }
}
