// 设置的「内存」页（内存模块设计 §7.3，D41、D49）。
//
// 按 D41 的模块页结构分节：菜单栏（3 个 widget）、采集、面板、历史。

import SwiftUI
import SysCollectors
import SysModel

struct MemorySettingsView: View {
    @Bindable var settings: AppSettings
    let store: MetricStore
    let openPage: (SettingsPage) -> Void

    var body: some View {
        Form {
            Section {
                ForEach(MenuWidget.widgets(of: .memory)) { widget in
                    WidgetSettingsRow(settings: settings, store: store, widget: widget)
                }
            } header: {
                Text("菜单栏")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("内存按 1024 换算，与活动监视器一致。自定义颜色不随浅色 / 深色菜单栏切换。")
                    HStack(spacing: 4) {
                        Text("排版和小标签对所有模块统一生效。")
                        Button("在「菜单栏」页设置") { openPage(.menuBar) }
                            .buttonStyle(.link)
                    }
                }
                .font(.callout)
            }

            Section("采集") {
                Picker("常驻采集间隔", selection: $settings.memoryIntervalOverride) {
                    Text("跟随默认（\(DisplayNames.interval(settings.globalInterval))）")
                        .tag(SamplingInterval?.none)
                    ForEach(SamplingInterval.allCases) { interval in
                        Text(DisplayNames.interval(interval)).tag(Optional(interval))
                    }
                }
                Picker("面板：内存 Top N", selection: $settings.memoryTopNInterval) {
                    ForEach(AppSettings.panelIntervals, id: \.self) { seconds in
                        Text("\(seconds) 秒  \(CostLabel.text(collector: AppSampler.collectorID, interval: seconds, store: store))")
                            .tag(seconds)
                    }
                }
                Text("面板里的内存读数固定每秒一次（开销很小）。Top N 每次要扫描全部进程组，开销按单核计。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("面板") {
                Picker("Top N 行数", selection: $settings.memoryTopNRows) {
                    ForEach(AppSettings.topNRowChoices, id: \.self) { rows in
                        Text(rows == 0 ? String(localized: "不显示") : "\(rows)").tag(rows)
                    }
                }
                Picker("Top N 分组", selection: $settings.memoryGrouping) {
                    Text("按应用").tag(TopNGrouping.byApp)
                    Text("按进程").tag(TopNGrouping.byProcess)
                }
                Picker("图表默认跨度", selection: $settings.memoryChartSpan) {
                    ForEach(ChartSpan.allCases) { span in
                        Text(HistoryChart.title(span)).tag(span)
                    }
                }
                Toggle("图表叠加内存压力", isOn: $settings.memoryChartOverlayPressure)
            }

            Section {
                Toggle("记录内存历史", isOn: $settings.historyMemoryEnabled)
            } header: {
                Text("历史")
            } footer: {
                HStack(spacing: 4) {
                    Text("面板关闭时也在后台每 10 秒记录一次：已用与构成、Swap、压力、页入 / 页出与换入 / 换出。每应用的内存历史留给「应用活动」模块。")
                    Button("历史库与导出") { openPage(.history) }
                        .buttonStyle(.link)
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}
