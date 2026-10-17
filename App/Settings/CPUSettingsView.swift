// 设置的 CPU 页（CPU 模块设计 §7.3，D19、D29、D41、D43）。
//
// 按 D41 的模块页结构分节（D43 去掉了「阈值」）：
// - 菜单栏：四个 widget 的开关；打开后就地展开该 widget 的配置（呈现形式、颜色、开销、预览）。
//   排版与小标签是全局设置，在「菜单栏」页；
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
                ForEach(MenuWidget.widgets(of: .cpu)) { widget in
                    WidgetSettingsRow(settings: settings, store: store, widget: widget)
                }
            } header: {
                Text("菜单栏")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("自定义颜色不随浅色 / 深色菜单栏切换，在部分壁纸上可读性较差。")
                    HStack(spacing: 4) {
                        Text("排版和小标签对所有模块统一生效。")
                        Button("在「菜单栏」页设置") { openPage(.menuBar) }
                            .buttonStyle(.link)
                    }
                }
                .font(.callout)
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
                        Text(HistoryChart.title(span)).tag(span)
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
                LabeledContent("每应用数据") {
                    HStack(spacing: 6) {
                        Text(settings.historyAppsEnabled ? "记录中" : "未记录").foregroundStyle(.secondary)
                        Button("在「应用活动」页设置") { openPage(.appActivity) }
                            .buttonStyle(.link)
                    }
                }
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

    private func intervalPicker(_ title: String, _ selection: Binding<Int>, collector: CollectorID) -> some View {
        Picker(title, selection: selection) {
            ForEach(AppSettings.panelIntervals, id: \.self) { seconds in
                Text("\(seconds) 秒  \(CostLabel.text(collector: collector, interval: seconds, store: store))").tag(seconds)
            }
        }
    }
}

