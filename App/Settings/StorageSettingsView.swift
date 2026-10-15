// 设置的「存储」页（存储模块设计 §6.3，D41、D54、D55）。
//
// 按 D41 的模块页结构分节：菜单栏（3 个 widget，展开后选绑定的盘或组）、采集、面板、历史。

import SwiftUI
import SysCollectors
import SysModel

struct StorageSettingsView: View {
    @Bindable var settings: AppSettings
    let store: MetricStore
    let model: StorageModel
    let openPage: (SettingsPage) -> Void

    var body: some View {
        Form {
            Section {
                ForEach(MenuWidget.widgets(of: .storage)) { widget in
                    WidgetSettingsRow(settings: settings, store: store, widget: widget)
                }
            } header: {
                Text("菜单栏")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("以物理盘为单位：RAID 的每块成员盘各自显示，不合计。容量与速率按 1000 换算，与访达一致。自定义颜色不随浅色 / 深色菜单栏切换。")
                    HStack(spacing: 4) {
                        Text("排版和小标签对所有模块统一生效（读写速率固定上下两行）。")
                        Button("在「菜单栏」页设置") { openPage(.menuBar) }
                            .buttonStyle(.link)
                    }
                }
                .font(.callout)
            }

            Section("采集") {
                Picker("常驻采集间隔", selection: $settings.storageIntervalOverride) {
                    Text("跟随默认（\(DisplayNames.interval(settings.globalInterval))）")
                        .tag(SamplingInterval?.none)
                    ForEach(SamplingInterval.allCases) { interval in
                        Text(DisplayNames.interval(interval)).tag(Optional(interval))
                    }
                }
                Picker("面板：SMART", selection: $settings.storageSMARTInterval) {
                    ForEach(AppSettings.panelIntervals, id: \.self) { seconds in
                        Text("\(seconds) 秒  \(CostLabel.text(collector: SMARTCollector.collectorID, interval: seconds, store: store))")
                            .tag(seconds)
                    }
                }
                Picker("面板：读写最多的应用", selection: $settings.storageTopNInterval) {
                    ForEach(AppSettings.panelIntervals, id: \.self) { seconds in
                        Text("\(seconds) 秒  \(CostLabel.text(collector: AppSampler.collectorID, interval: seconds, store: store))")
                            .tag(seconds)
                    }
                }
                Text("面板打开时读写每秒一次、容量每 10 秒一次。SMART 在面板打开时读全部盘；面板关闭时只读盘温 widget 绑定的盘，其余盘每分钟读一次给历史。实测读 SMART 不会影响盘的低功耗状态。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("面板") {
                Picker("读写最多的应用：行数", selection: $settings.storageTopNRows) {
                    ForEach(AppSettings.topNRowChoices, id: \.self) { rows in
                        Text(rows == 0 ? String(localized: "不显示") : "\(rows)").tag(rows)
                    }
                }
                Picker("读写最多的应用：分组", selection: $settings.storageGrouping) {
                    Text("按应用").tag(TopNGrouping.byApp)
                    Text("按进程").tag(TopNGrouping.byProcess)
                }
                Picker("详情页图表默认跨度", selection: $settings.storageChartSpan) {
                    ForEach(ChartSpan.allCases) { span in
                        Text(HistoryChart.title(span)).tag(span)
                    }
                }
                if !model.inventory.raidSets.isEmpty {
                    Text("RAID 组在面板里默认展开，点组标题可以折叠，折叠状态会记住。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("记录存储历史", isOn: $settings.historyStorageEnabled)
            } header: {
                Text("历史")
            } footer: {
                HStack(spacing: 4) {
                    Text("面板关闭时也在后台每分钟记录一次：每块盘的读写、温度、寿命、备用块、介质错误与累计读写量，以及各容量组的已用与可用。小时数据永久保留，可以看长期的写入与磨损趋势。每应用的磁盘读写历史留给「应用活动」模块。")
                    Button("历史库与导出") { openPage(.history) }
                        .buttonStyle(.link)
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}
