// 设置的「GPU 与加速器」页（GPU 模块设计 §8，D41、D57）。
//
// 按 D41 的模块页结构分节：菜单栏（GPU 活跃、GPU 功率、GPU 温度）、采集、面板、历史。
// GPU 功率 widget 从「功耗与散热」页移来（D57 G3），偏好键不变。

import SwiftUI
import SysCollectors
import SysModel

struct GPUSettingsView: View {
    @Bindable var settings: AppSettings
    let store: MetricStore
    let openPage: (SettingsPage) -> Void

    var body: some View {
        Form {
            Section {
                ForEach(MenuWidget.widgets(of: .gpu)) { widget in
                    WidgetSettingsRow(settings: settings, store: store, widget: widget)
                }
            } header: {
                Text("菜单栏")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("「GPU 活跃」是 GPU 上电运行的时间比例，不是算力占用；要看负载轻重，配合功率看。GPU 活跃与 GPU 功率读同一个数据源，同时打开不增加开销。自定义颜色不随浅色 / 深色菜单栏切换。")
                    HStack(spacing: 4) {
                        Text("排版和小标签对所有模块统一生效。")
                        Button("在「菜单栏」页设置") { openPage(.menuBar) }
                            .buttonStyle(.link)
                    }
                }
                .font(.callout)
            }

            Section("采集") {
                Picker("常驻采集间隔", selection: $settings.gpuIntervalOverride) {
                    Text("跟随默认（\(DisplayNames.interval(settings.globalInterval))）")
                        .tag(SamplingInterval?.none)
                    ForEach(SamplingInterval.allCases) { interval in
                        Text(DisplayNames.interval(interval)).tag(Optional(interval))
                    }
                }
                Picker("面板：温度、ANE 与媒体引擎", selection: $settings.gpuPanelInterval) {
                    ForEach(AppSettings.panelIntervals, id: \.self) { seconds in
                        Text("\(seconds) 秒  \(CostLabel.text(collector: GPUTemperatureCollector.collectorID, interval: seconds, store: store))")
                            .tag(seconds)
                    }
                }
                Picker("面板：GPU Top N 与 ANE 功率", selection: $settings.gpuTopNInterval) {
                    ForEach(AppSettings.panelIntervals, id: \.self) { seconds in
                        Text("\(seconds) 秒  \(CostLabel.text(collector: AppSampler.collectorID, interval: seconds, store: store))")
                            .tag(seconds)
                    }
                }
                Text("面板里的 GPU 活跃、频率与功率固定每秒一次。ANE 功率由按应用的能耗记账估算，与 Top N 共用同一次扫描，所以 Top N 行数设为「不显示」时也会扫描。开销按单核计。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("面板") {
                Picker("Top N 行数", selection: $settings.gpuTopNRows) {
                    ForEach(AppSettings.topNRowChoices, id: \.self) { rows in
                        Text(rows == 0 ? String(localized: "不显示") : "\(rows)").tag(rows)
                    }
                }
                Picker("Top N 分组", selection: $settings.gpuGrouping) {
                    Text("按应用").tag(TopNGrouping.byApp)
                    Text("按进程").tag(TopNGrouping.byProcess)
                }
                Picker("图表默认跨度", selection: $settings.gpuChartSpan) {
                    ForEach(ChartSpan.allCases) { span in
                        Text(HistoryChart.title(span)).tag(span)
                    }
                }
                Picker("图表显示", selection: $settings.gpuChartShowsPower) {
                    Text("GPU 活跃").tag(false)
                    Text("GPU 功率").tag(true)
                }
            }

            Section {
                Toggle("记录 GPU 与加速器历史", isOn: $settings.historyGPUEnabled)
            } header: {
                Text("历史")
            } footer: {
                HStack(spacing: 4) {
                    Text("面板关闭时也在后台每 10 秒记录一次：GPU 活跃、GPU 温度、ANE 上电比例。GPU 功率随「功耗与散热」历史记录。每应用的 GPU 历史留给「应用活动」模块。")
                    Button("历史库与导出") { openPage(.history) }
                        .buttonStyle(.link)
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}
