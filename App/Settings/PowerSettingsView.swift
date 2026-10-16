// 设置的「功耗与散热」页（功耗与散热模块设计 §7.3，D41、D44–D46）。
//
// 按 D41 的模块页结构分节：菜单栏（4 个 widget；没有风扇的机型不列风扇；GPU 功率移到 GPU 页，D57）、采集、面板、历史。

import SwiftUI
import SysCollectors
import SysModel

struct PowerSettingsView: View {
    @Bindable var settings: AppSettings
    let store: MetricStore
    let services: AppServices
    let openPage: (SettingsPage) -> Void

    var body: some View {
        Form {
            Section {
                ForEach(MenuWidget.widgets(of: .power).filter { $0 != .fan || services.power.hasFans }) { widget in
                    WidgetSettingsRow(settings: settings, store: store, widget: widget)
                }
            } header: {
                Text("菜单栏")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("功率值做约 2 秒的平滑。自定义颜色不随浅色 / 深色菜单栏切换。")
                    HStack(spacing: 4) {
                        Text("GPU 功率 widget 在 GPU 模块里。")
                        Button("在「GPU 与加速器」页设置") { openPage(.gpu) }
                            .buttonStyle(.link)
                    }
                    HStack(spacing: 4) {
                        Text("排版和小标签对所有模块统一生效。")
                        Button("在「菜单栏」页设置") { openPage(.menuBar) }
                            .buttonStyle(.link)
                    }
                }
                .font(.callout)
            }

            Section("采集") {
                Picker("常驻采集间隔", selection: $settings.powerIntervalOverride) {
                    Text("跟随默认（\(DisplayNames.interval(settings.globalInterval))）")
                        .tag(SamplingInterval?.none)
                    ForEach(SamplingInterval.allCases) { interval in
                        Text(DisplayNames.interval(interval)).tag(Optional(interval))
                    }
                }
                Picker("面板：SoC / GPU / DRAM、温度与风扇", selection: $settings.powerPanelInterval) {
                    ForEach(AppSettings.panelIntervals, id: \.self) { seconds in
                        Text(
                            "\(seconds) 秒  \(CostLabel.text(collector: GPUPowerCollector.collectorID, interval: seconds, store: store))"
                        ).tag(seconds)
                    }
                }
                Text("面板里的整机功率固定每秒一次；最近 30 分钟的分部件数据每 60 秒检查一次。开销按单核计，GPU 功率一项最高。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("面板") {
                Picker("图表默认跨度", selection: $settings.powerChartSpan) {
                    ForEach(ChartSpan.allCases) { span in
                        Text(HistoryChart.title(span)).tag(span)
                    }
                }
                Toggle("图表叠加 SoC 功率", isOn: $settings.powerChartOverlaySoC)
            }

            Section {
                Toggle("记录功耗与散热历史", isOn: $settings.historyPowerEnabled)
                Toggle(isOn: $settings.historyEnergyEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("记录能耗")
                        Text("后台每秒读一次整机功率并积分，\(CostLabel.text(collector: PowerRailCollector.collectorID, interval: 1, store: store))。SysInfo 没运行的时段用系统累计值补上，满载时可能偏低。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("历史")
            } footer: {
                HStack(spacing: 4) {
                    Text("面板关闭时也在后台记录：SoC / GPU / DRAM 功率、最热点、风扇每 10 秒，分部件数据每 60 秒。")
                    Button("历史库与导出") { openPage(.history) }
                        .buttonStyle(.link)
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}
