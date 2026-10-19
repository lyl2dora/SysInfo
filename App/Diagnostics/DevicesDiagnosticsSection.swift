// 诊断页的电源设备部分（电源设备设计 §6.4，D84）：
// - IOPS：公开 / 私有配件通知是否挂上、快照代数、最近一次重建的时刻与原因、通知累计次数；
// - HID：manager 是否打开、设备与元素数、最近一次 HID 与 IOPS 的对照、连续不一致次数；
//   主 UPS 按默认单位换算的字段、找不到的关键项；
// - 每台设备的解析结果（不含 Accessory Identifier、Power Source ID、序列号：诊断页常被截图分享）。

import SwiftUI
import SysCollectors
import SysModel

struct DevicesDiagnosticsSection: View {
    let store: MetricStore
    let services: AppServices

    var body: some View {
        let _ = store.engineStatus?.tickCount  // 随 tick 刷新
        let status = PowerSourceMonitor.shared.status
        let hid = services.devices.ups?.diagnostics
        let model = services.devicesModel
        Section("电源设备数据源") {
            LabeledContent("IOPS 通知") {
                Text("公开 \(status.publicNotify ? "✓" : "✗") · 配件 \(status.accessoryNotify ? "✓" : "✗") · 累计 \(status.notifyCount) 次")
            }
            LabeledContent("快照") {
                Text("第 \(status.generation) 代 · \(status.lastReason) · \(status.lastRebuild.map(Formatting.time) ?? "—")")
            }
            LabeledContent("配件接口（私有）") {
                Text(status.accessoriesAvailable ? "可用" : "不可用")
            }
            if let hid {
                LabeledContent("HID") {
                    Text("\(hid.managerOpen ? String(localized: "已打开") : String(localized: "已关闭（无需求）")) · 设备 \(hid.deviceCount) · 元素 \(hid.elementCount)")
                }
                LabeledContent("HID 与 IOPS 对照") {
                    Text(hid.lastComparison.isEmpty ? "—" : hid.lastComparison + (hid.mismatchStreak > 0 ? " · 连续不一致 \(hid.mismatchStreak)" : ""))
                }
            }
            if let reading = model.upsReading {
                if !reading.defaultedUnits.isEmpty {
                    LabeledContent("按默认单位换算") { Text(reading.defaultedUnits.joined(separator: ", ")) }
                }
                if !reading.missingKeys.isEmpty {
                    LabeledContent("缺少的关键项") { Text(reading.missingKeys.joined(separator: ", ")) }
                }
            }
            ForEach(model.snapshot.devices) { device in
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(device.parts.map { "\($0.role.diagnosticName) \(DevicesText.percent($0.level))\($0.isCharging ? "⚡︎" : "")" }.joined(separator: " · "))
                        Text("\(device.powerSourceState.rawValue) · TTE \(device.timeToEmpty.map { String(format: "%.0f s", $0) } ?? "—") · TTF \(device.timeToFull.map { String(format: "%.0f s", $0) } ?? "—")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Text(DevicesText.name(device))
                    Text("\(device.key.rawValue) · \(device.transport ?? "—")\(device.accessoryCategory.map { " · \($0)" } ?? "")")
                }
            }
            Text("设备键不含序列号与系统分配的电源 ID；配件键是 Group Identifier 的本地加盐哈希。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

extension PowerDevicePartRole {
    /// 诊断页用的英文角色名（与 IOPS 的 Part Identifier 对应）。
    var diagnosticName: String {
        switch self {
        case .main: "Main"
        case .combined: "Combined"
        case .left: "Left"
        case .right: "Right"
        case .case: "Case"
        case .other(let name): name
        }
    }
}
