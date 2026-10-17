// 设置的「应用活动」页（应用活动设计 §3.3，D41、D67–D69）。
//
// 按 D41 的模块页结构分节：菜单栏（应用活动不占 widget，只说明入口）、采集（「现在」档的间隔）、历史（每应用数据与电源断言）。
// 「记录每应用数据」从 CPU 页移来（D41：一个设置只有一处可编辑；CPU 页只读引用），偏好键不变。

import SwiftUI
import SysCollectors
import SysModel

struct AppActivitySettingsView: View {
    @Bindable var settings: AppSettings
    let store: MetricStore
    let services: AppServices
    let openPage: (SettingsPage) -> Void

    var body: some View {
        Form {
            Section {
                Button("打开应用活动窗口") { services.openAppActivity(nil, nil) }
            } header: {
                Text("窗口")
            } footer: {
                Text("应用活动不占菜单栏 widget。也可以从面板顶栏、各模块 Top N 底部的「在应用活动中查看全部」，或合并模式总览的「最耗能的应用」卡片打开。")
                    .font(.callout)
            }

            Section("采集") {
                Picker("「现在」的刷新间隔", selection: $settings.appActivityInterval) {
                    ForEach(AppSettings.panelIntervals, id: \.self) { seconds in
                        Text("\(seconds) 秒  \(CostLabel.text(collector: AppSampler.collectorID, interval: seconds, store: store))")
                            .tag(seconds)
                    }
                }
                Text("只在窗口可见时扫描全部应用；关闭、最小化或被完全遮住时停止，开销为 0。窗口第一次打开时要解析全部应用的名字，多花约 5–10 毫秒。开销按单核计。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("记录每应用数据与电源断言", isOn: $settings.historyAppsEnabled)
            } header: {
                Text("历史")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("面板和窗口关闭时也在后台每 10 秒扫描一次，每分钟记下 CPU、功率、GPU、ANE、磁盘、唤醒、内存各项前 10 名的应用，其余合成一行，保留 30 天（约 55 MB）。谁在阻止睡眠按断言的开始和结束记录（只在 SysInfo 运行期间）。总览的「最耗能的应用」卡片也来自这里，关掉后不出现。")
                    HStack(spacing: 4) {
                        Text("清除已记录的每应用数据：")
                        Button("历史库与导出") { openPage(.history) }
                            .buttonStyle(.link)
                    }
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}
