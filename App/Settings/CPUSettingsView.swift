// 设置的 CPU 页（CPU 模块设计 §7.3，D19、D29、D32、D41）。
//
// 按 D41 的模块页结构分节：
// - 菜单栏：四个 widget 的开关；打开后就地展开该 widget 的配置（呈现形式、着色、开销、预览）。
//   排版与小标签是全局设置，在「菜单栏」页；
// - 阈值：始终显示（P2 的提醒复用）；
// - 采集：模块间隔覆盖；面板内频率、温度与功耗、Top N 的间隔（1/2/5 s），旁边标注开销；
// - 面板：图表默认跨度、用户/系统拆分、Top N 行数与分组；
// - 历史：是否记录 CPU 与每应用历史、后台高精度历史。
// 开销标注（D19）：优先用诊断数据里本机实测的单次 CPU 耗时换算；还没有实测时用参考值并注明出处。

import AppKit
import SwiftUI
import SysCollectors
import SysModel

struct CPUSettingsView: View {
    @Bindable var settings: AppSettings
    let store: MetricStore
    let openPage: (SettingsPage) -> Void

    var body: some View {
        Form {
            Section {
                ForEach(CPUMenuWidget.allCases) { widget in
                    widgetRow(widget)
                }
            } header: {
                Text("菜单栏")
            } footer: {
                HStack(spacing: 4) {
                    Text("排版和小标签对所有模块统一生效。")
                    Button("在「菜单栏」页设置") { openPage(.menuBar) }
                        .buttonStyle(.link)
                }
                .font(.callout)
            }

            Section {
                Stepper(value: $settings.menuBarCPUWarningPercent, in: 50...99) {
                    LabeledContent("橙色阈值", value: "\(settings.menuBarCPUWarningPercent)%")
                }
                Stepper(value: $settings.menuBarCPUCriticalPercent, in: settings.menuBarCPUWarningPercent...100) {
                    LabeledContent("红色阈值", value: "\(settings.menuBarCPUCriticalPercent)%")
                }
            } header: {
                Text("阈值")
            } footer: {
                Text("总占用平滑后持续 10 秒达到阈值才算越界，回落时留 5 个百分点。占用 widget 的着色使用这组阈值，以后的提醒也会使用。")
            }

            Section("采集") {
                Picker("常驻采集间隔", selection: $settings.cpuIntervalOverride) {
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
                Text("常驻采集间隔决定菜单栏 widget 的刷新。面板内的采样只在 CPU 页可见时进行，占用固定每秒一次。开销按本机实测的单次耗时换算，按单核计。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

            Section {
                Toggle("记录 CPU 历史", isOn: $settings.historyCPUEnabled)
                Toggle("记录每应用 CPU", isOn: $settings.historyAppsEnabled)
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
            } header: {
                Text("历史")
            } footer: {
                HStack(spacing: 4) {
                    Text("面板关闭时也在后台低频采样（占用、频率每 60 秒，温度与每应用每 10 秒）。")
                    Button("历史库与导出") { openPage(.history) }
                        .buttonStyle(.link)
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }

    /// 一个 widget：开关与说明；打开后展开它自己的配置与预览（D41）。
    @ViewBuilder
    private func widgetRow(_ widget: CPUMenuWidget) -> some View {
        let visible = settings.isVisible(widget)
        Toggle(isOn: Binding(get: { settings.isVisible(widget) }, set: { settings.setVisible(widget, $0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(CPUWidgetInfo.title(widget))
                if let note = CPUWidgetInfo.note(widget, settings: settings, store: store) {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if visible {
            Group {
                if widget == .usage {
                    Picker("呈现形式", selection: $settings.cpuUsagePresentation) {
                        ForEach(CPUUsagePresentation.allCases) { presentation in
                            Text(Self.presentationName(presentation)).tag(presentation)
                        }
                    }
                    Toggle("占用高时着色", isOn: $settings.menuBarCPUColoring)
                }
                LabeledContent("预览") {
                    StatusItemPreview(store: store, configuration: CPUStatusItemConfiguration(widget: widget, settings: settings))
                }
            }
            .padding(.leading, 16)
        }
    }

    static func presentationName(_ presentation: CPUUsagePresentation) -> String {
        switch presentation {
        case .number: String(localized: "数字")
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

/// CPU widget 的名称与说明，CPU 页与菜单栏总览共用。
enum CPUWidgetInfo {
    static func title(_ widget: CPUMenuWidget) -> String {
        switch widget {
        case .usage: String(localized: "CPU 占用")
        case .frequency: String(localized: "CPU 频率")
        case .temperature: String(localized: "CPU 温度")
        case .power: String(localized: "CPU 功耗")
        }
    }

    /// 开销说明（D19）：按常驻采集间隔换算。
    static func note(_ widget: CPUMenuWidget, settings: AppSettings, store: MetricStore) -> String? {
        let interval = settings.cpuInterval.rawValue
        switch widget {
        case .usage:
            return nil
        case .frequency:
            return String(localized: "最忙的簇的实际频率。高开销：\(CostLabel.text(collector: CPUFrequencyCollector.collectorID, interval: interval, store: store))")
        case .temperature:
            return String(localized: "CPU 最高温。\(CostLabel.text(collector: SensorCollector.collectorID, interval: interval, store: store))")
        case .power:
            return String(localized: "CPU 各簇功耗之和，不含 GPU；没有专用功耗轨的芯片显示「—」。\(CostLabel.text(collector: SensorCollector.collectorID, interval: interval, store: store))")
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
struct StatusItemPreview: NSViewRepresentable {
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
