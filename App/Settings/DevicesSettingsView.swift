// 设置的「电源设备」页（电源设备设计 §6.3，D41、D84）。
//
// 按 D41 的模块页结构分节：菜单栏（电源设备电量）、设备（当前检测到的设备）、历史。
// 不提供采集间隔：数值来自系统电源通知，UPS 扩展信息只在面板可见时每 2 秒读一次（D84 PD3）。

import SwiftUI
import SysModel

struct DevicesSettingsView: View {
    @Bindable var settings: AppSettings
    let store: MetricStore
    let model: PowerDevicesModel
    let openPage: (SettingsPage) -> Void

    var body: some View {
        Form {
            Section {
                ForEach(MenuWidget.widgets(of: .devices)) { widget in
                    WidgetSettingsRow(settings: settings, store: store, widget: widget)
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
                if model.snapshot.devices.isEmpty {
                    Text("没有检测到 UPS、电池或配件。").foregroundStyle(.secondary)
                }
                ForEach(model.snapshot.devices) { device in
                    LabeledContent {
                        Text(DevicesText.percent(device.level)).monospacedDigit()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DevicesText.name(device))
                            Text([DevicesText.kind(device.kind), device.transport].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("设备")
            } footer: {
                Text("UPS 的基本信息与蓝牙配件的电量来自系统电源接口，变化时由系统通知；UPS 的负载、电池电压等扩展信息通过 USB HID 读取（只读，只匹配电源设备类），只在面板可见时每 2 秒读一次。iPhone、iPad、Apple Watch 的电量 Mac 读不到；内置电池只显示基础信息。")
                    .font(.callout)
            }

            Section {
                Toggle("记录电源设备历史", isOn: $settings.historyDevicesEnabled)
            } header: {
                Text("历史")
            } footer: {
                HStack(spacing: 4) {
                    Text("有 UPS 时在后台每 60 秒记录一次电量、负载与输入电压，并记下每次切换到电池供电的起止时刻。配件与内置电池不记录。")
                    Button("历史库与导出") { openPage(.history) }
                        .buttonStyle(.link)
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }

    static func targetName(_ target: DeviceTarget) -> String {
        switch target {
        case .auto: String(localized: "自动（UPS → 内置电池 → 电量最低的配件）")
        case .ups: String(localized: "UPS")
        case .battery: String(localized: "内置电池")
        case .accessoryLowest: String(localized: "电量最低的配件")
        }
    }
}
