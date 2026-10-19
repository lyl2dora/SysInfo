// 面板的「电源设备」tab（电源设备设计 §6.2，D84 PD5）。
//
// 每台设备一张卡片：UPS（IOPS 基本项 + HID 扩展遥测）、内置电池（基础项，未在真机验证）、配件（按 Group 合并）。
// 内容由 PowerDevicesModel 的快照（事件驱动）与 HID 读数（每 2 s）驱动，变化不频繁，用 SwiftUI 直接画。
// 需求由 PanelController 按 tab 可见性登记。

import SwiftUI
import SysCollectors
import SysModel

struct DevicesPanelView: View {
    let store: MetricStore
    let services: AppServices
    @Bindable var settings: AppSettings

    var body: some View {
        let model = services.devicesModel
        let snapshot = model.snapshot
        VStack(alignment: .leading, spacing: 10) {
            if snapshot.devices.isEmpty {
                PanelCard {
                    Text("没有检测到 UPS、电池或配件")
                        .font(.panelRow)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(snapshot.devices) { device in
                switch device.kind {
                case .ups:
                    UPSCard(
                        store: store, services: services, settings: settings, device: device,
                        reading: device.key == snapshot.primaryUPS?.key ? model.upsReading : nil,
                        isPrimary: device.key == snapshot.primaryUPS?.key)
                case .internalBattery:
                    PanelCard { BatteryCardContent(device: device) }
                case .accessory:
                    PanelCard { AccessoryCardContent(device: device) }
                }
            }
            if !snapshot.accessoriesAvailable, !snapshot.devices.isEmpty || snapshot.time != .distantPast {
                Text("读取配件电量的系统接口不可用，蓝牙配件不显示。")
                    .font(.panelNote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - UPS

private struct UPSCard: View {
    let store: MetricStore
    let services: AppServices
    let settings: AppSettings
    let device: PowerDevice
    let reading: UPSTelemetryCollector.Reading?
    /// 主 UPS 才有 HID 遥测与曲线（D84：只给主 UPS 指标）。
    let isPrimary: Bool

    @State private var showsMore = false
    @Environment(\.panelLayoutChanged) private var layoutChanged

    var body: some View {
        let telemetry = reading?.telemetry
        let info = reading?.staticInfo
        PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(DevicesText.name(device)).font(.panelTitle.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    StateCapsule(state: device.powerSourceState)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(DevicesText.percent(device.level))
                        .font(.system(size: PanelType.hero, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    VStack(alignment: .leading, spacing: 2) {
                        if let seconds = device.timeToEmpty {
                            Text("剩余约 \(DevicesText.duration(seconds))").font(.panelRow)
                        }
                        if device.isCharging {
                            Text("充电中").font(.panelNote).foregroundStyle(.secondary)
                        }
                    }
                }
                if isPrimary {
                    if let telemetry {
                        detailRows(telemetry, info: info)
                    } else {
                        Text(reading == nil ? "扩展信息读取中…" : "扩展信息不可用（HID 读取失败）")
                            .font(.panelRow).foregroundStyle(.secondary)
                        if let voltage = device.inputVoltage {
                            row(String(localized: "输入电压"), DevicesText.volts(voltage))
                        }
                    }
                } else if let voltage = device.inputVoltage {
                    row(String(localized: "输入电压"), DevicesText.volts(voltage))
                }
            }
        }
        if isPrimary, telemetry?.load != nil {
            PanelCard {
                VStack(alignment: .leading, spacing: 4) {
                    Text("负载").font(.panelRow.weight(.semibold)).foregroundStyle(.secondary)
                    HistoryChart(
                        store: store, history: services.history, defaultSpan: .twoMinutes,
                        series: ChartSeries(metric: .upsLoad, overlay: nil, collector: UPSTelemetryCollector.collectorID, scale: .unit))
                }
            }
        }
    }

    @ViewBuilder
    private func detailRows(_ telemetry: UPSTelemetry, info: UPSStaticInfo?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let load = telemetry.load {
                let watts = telemetry.loadPower.map { String(localized: " · 约 \(String(format: "%.0f", $0)) W") } ?? ""
                row(String(localized: "负载"), DevicesText.percent(load) + watts)
                if let rated = info?.ratedActivePower {
                    note(String(localized: "接在这台 UPS 上的所有设备，按额定 \(String(format: "%.0f", rated)) W 估算"))
                }
            }
            if let input = telemetry.inputVoltage {
                row(String(localized: "输入电压"), Self.inputText(input, info: info))
            }
            if let battery = telemetry.batteryVoltage {
                row(String(localized: "电池电压"), Self.batteryText(battery, info: info))
            }
            let alarms = DevicesText.alarms(telemetry.flags)
            if alarms.isEmpty {
                row(String(localized: "状态"), String(localized: "正常"))
            } else {
                HStack(alignment: .top) {
                    Text("状态").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(alarms.joined(separator: "、")).foregroundStyle(.red).multilineTextAlignment(.trailing)
                }
                .font(.panelRow)
            }
            if let info, info.selfTestResult != nil || info.manufactureDate != nil || info.remainingCapacityLimit != nil
                || DevicesText.firmware(device) != nil
            {
                DisclosureGroup(isExpanded: $showsMore) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let test = info.selfTestResult { row(String(localized: "自检结果"), DevicesText.selfTest(test)) }
                        if let date = info.manufactureDate { row(String(localized: "电池生产日期"), DevicesText.date(date)) }
                        if let limit = info.remainingCapacityLimit {
                            row(String(localized: "低电量关机阈值"), DevicesText.percent(limit))
                        }
                        if let firmware = DevicesText.firmware(device) { row(String(localized: "固件"), firmware) }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("更多").font(.panelRow).foregroundStyle(.secondary)
                }
                .onChange(of: showsMore) { layoutChanged() }
            }
        }
    }

    /// 「228 V（切换 176–294 V）」。
    static func inputText(_ volts: Double, info: UPSStaticInfo?) -> String {
        // 断电时 HID 读到 0 V（2026-10-19 放电实测）。
        if volts < 1 { return String(localized: "无市电") }
        guard let low = info?.lowTransferVoltage, let high = info?.highTransferVoltage else { return DevicesText.volts(volts) }
        return String(localized: "\(DevicesText.volts(volts))（切换 \(String(format: "%.0f", low))–\(String(format: "%.0f", high)) V）")
    }

    /// 「27.3 V / 额定 24.0 V」。
    static func batteryText(_ volts: Double, info: UPSStaticInfo?) -> String {
        guard let nominal = info?.batteryNominalVoltage else { return DevicesText.volts(volts) }
        return String(localized: "\(DevicesText.volts(volts)) / 额定 \(DevicesText.volts(nominal))")
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit()
        }
        .font(.panelRow)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.panelNote).foregroundStyle(.secondary)
    }
}

/// 供电状态胶囊：外接电源为次要色，电池供电为橙色。
private struct StateCapsule: View {
    let state: PowerSourceState

    var body: some View {
        Text(DevicesText.powerState(state))
            .font(.panelNote.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(state == .battery ? Color.white : Color.secondary)
            .background(state == .battery ? Color.orange : Color.secondary.opacity(0.15), in: .capsule)
    }
}

// MARK: - 内置电池

private struct BatteryCardContent: View {
    let device: PowerDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("内置电池").font(.panelTitle.weight(.semibold))
                Spacer(minLength: 4)
                StateCapsule(state: device.powerSourceState)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(DevicesText.percent(device.level))
                    .font(.system(size: PanelType.hero, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 2) {
                    if device.isCharging, let seconds = device.timeToFull {
                        Text("充满还要约 \(DevicesText.duration(seconds))").font(.panelRow)
                    } else if device.isCharging {
                        Text("充电中").font(.panelRow)
                    } else if let seconds = device.timeToEmpty {
                        Text("剩余约 \(DevicesText.duration(seconds))").font(.panelRow)
                    }
                }
            }
            Text("基础信息来自系统电源接口；未在带电池的 Mac 上实测验证。")
                .font(.panelNote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 配件

private struct AccessoryCardContent: View {
    let device: PowerDevice

    var body: some View {
        // 合成项只用来代表整台设备；有左右耳时不单独成行。
        let parts = device.parts.count > 1 ? device.parts.filter { $0.role != .combined } : device.parts
        VStack(alignment: .leading, spacing: 4) {
            Text(DevicesText.name(device)).font(.panelRow.weight(.semibold))
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                HStack(spacing: 6) {
                    Text(parts.count == 1 ? DevicesText.kind(.accessory) : DevicesText.part(part, device: device))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if part.isCharging {
                        Image(systemName: "bolt.fill").font(.panelNote).foregroundStyle(.secondary)
                            .accessibilityLabel(Text("充电中"))
                    }
                    LevelBar(level: part.level, low: part.lowWarnLevel)
                    Text(DevicesText.percent(part.level)).monospacedDigit().frame(minWidth: 36, alignment: .trailing)
                }
                .font(.panelRow)
            }
        }
    }
}

/// 小电量条：低于设备自报的阈值时红色。
private struct LevelBar: View {
    let level: Double?
    let low: Double?

    var body: some View {
        let value = min(max(level ?? 0, 0), 1)
        let isLow = level.map { $0 <= (low ?? 0.1) } ?? false
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.2))
            Capsule().fill(isLow ? Color.red : Color.accentColor).frame(width: 40 * value)
        }
        .frame(width: 40, height: 5)
        .opacity(level == nil ? 0.4 : 1)
    }
}
