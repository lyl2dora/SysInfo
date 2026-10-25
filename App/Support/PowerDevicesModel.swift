// 电源设备的 app 层状态（电源设备设计 §6，D84）：快照来自 `PowerSourceMonitor` 的变化通知（事件驱动），
// UPS 的 HID 读数在 `devices.ups` 采样后由 AppServices 转来。菜单栏 widget、面板、设置页预览共用一个实例。

import Foundation
import Observation
import SysCollectors
import SysModel

/// 电源设备 widget 绑定的设备（`devices.widget.battery.target`）。
enum DeviceTarget: String, CaseIterable, Identifiable, Hashable {
    /// UPS → 内置电池 → 电量最低的配件。
    case auto
    case ups
    case battery
    /// 配件里电量最低的一台。
    case accessoryLowest

    var id: String { rawValue }
}

@Observable
final class PowerDevicesModel {
    static let shared = PowerDevicesModel()

    private(set) var snapshot: PowerDeviceSnapshot = .empty
    /// 主 UPS 的 HID 读数（面板可见、历史记录时才有更新）。
    private(set) var upsReading: UPSTelemetryCollector.Reading?
    /// 本机有没有 UPS 或内置电池，去抖后（出现立刻为真，消失 10 s 后才为假）。
    /// 电源设备 widget 的开关用户没动过时按它定（D89）。启动时第一份快照直接定值，不等去抖。
    private(set) var hasUPSOrBattery = false
    /// 设备的有无变了（第一台出现或最后一台消失，或去抖后的 UPS / 电池有无变了），或 UPS 的有无变了：
    /// 面板切换器、widget 开关与绑定、电源设备 tab 的 UPS 需求要更新。
    @ObservationIgnored var onPresenceChange: (() -> Void)?
    @ObservationIgnored private var observation: PowerSourceMonitor.Observation?
    @ObservationIgnored private var presence: PresenceLatch?
    @ObservationIgnored private var hideTimer: Timer?

    /// 开始跟随监视器（启动时调用一次）。`monitor.latest` 在还没有快照时当场读一次 IOPS（约 18 µs），
    /// 所以第一次布局菜单栏之前就知道有没有 UPS / 电池，widget 与其他 widget 一起上屏。
    func start(monitor: PowerSourceMonitor = .shared) {
        guard observation == nil else { return }
        observation = monitor.observe { [weak self] snapshot in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(snapshot) }
            }
        }
        apply(monitor.latest)
    }

    private func apply(_ snapshot: PowerDeviceSnapshot) {
        let hadDevices = !self.snapshot.devices.isEmpty
        let hadUPS = self.snapshot.primaryUPS != nil
        let changed = snapshot.devices != self.snapshot.devices || snapshot.accessoriesAvailable != self.snapshot.accessoriesAvailable
        if changed { self.snapshot = snapshot }
        let presenceChanged = updatePresence()
        // 已有内置电池时插上 UPS，去抖后的「UPS 或电池」不变，但 UPS 的 HID 需求要登记。
        let upsChanged = changed && hadUPS != (snapshot.primaryUPS != nil)
        if (changed && hadDevices != !snapshot.devices.isEmpty) || presenceChanged || upsChanged { onPresenceChange?() }
    }

    /// 把当前快照喂给去抖；还在等消失确认时排一个到点的复查。返回去抖后的值是否变了。
    @discardableResult
    private func updatePresence() -> Bool {
        let present = snapshot.hasUPSOrBattery
        var latch = presence ?? PresenceLatch(initial: present)
        let value = latch.update(present: present, at: Date())
        presence = latch
        hideTimer?.invalidate()
        hideTimer = nil
        if let deadline = latch.pendingDeadline {
            hideTimer = Timer.scheduledTimer(withTimeInterval: max(deadline.timeIntervalSinceNow, 0) + 0.05, repeats: false) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.updatePresence() else { return }
                    self.onPresenceChange?()
                }
            }
        }
        guard value != hasUPSOrBattery else { return false }
        hasUPSOrBattery = value
        return true
    }

    func updateUPS(_ reading: UPSTelemetryCollector.Reading?) {
        if reading != upsReading { upsReading = reading }
    }

    var hasDevices: Bool { !snapshot.devices.isEmpty }

    /// widget 绑定解析到的设备；没有时为 nil（widget 显示「—」）。
    func device(for target: DeviceTarget) -> PowerDevice? {
        switch target {
        case .auto: snapshot.primaryUPS ?? snapshot.internalBattery ?? lowestAccessory
        case .ups: snapshot.primaryUPS
        case .battery: snapshot.internalBattery
        case .accessoryLowest: lowestAccessory
        }
    }

    private var lowestAccessory: PowerDevice? {
        snapshot.accessories.filter { $0.level != nil }.min { ($0.level ?? 1) < ($1.level ?? 1) }
    }
}

/// 电源设备的显示文字（面板、widget、总览、设置共用）。
enum DevicesText {
    static func kind(_ kind: PowerDeviceKind) -> String {
        switch kind {
        case .ups: String(localized: "UPS")
        case .internalBattery: String(localized: "内置电池")
        case .accessory: String(localized: "配件")
        }
    }

    /// 部件名：左右耳、充电盒按角色（系统的部件名是「设备名 + 🅛」这类，重复设备名）；其余用系统给的名字。
    static func part(_ part: PowerDevicePart, device: PowerDevice) -> String {
        switch part.role {
        case .left: return String(localized: "左耳")
        case .right: return String(localized: "右耳")
        case .case: return String(localized: "充电盒")
        case .combined: return String(localized: "合计")
        case .main: return part.name.isEmpty ? name(device) : part.name
        case .other(let name): return part.name.isEmpty ? name : part.name
        }
    }

    /// 设备名：空时按种类。UPS 的名字常带固件号（APC：「Back-UPS RS 1000G FW:899.L2 .I USB FW:L2」），
    /// 只取 「 FW:」之前的型号，固件号放进 `firmware`。
    static func name(_ device: PowerDevice) -> String {
        guard !device.name.isEmpty else { return kind(device.kind) }
        return splitFirmware(device.name).model
    }

    /// UPS 名字里的固件部分；没有时为 nil。
    static func firmware(_ device: PowerDevice) -> String? {
        splitFirmware(device.name).firmware
    }

    static func splitFirmware(_ name: String) -> (model: String, firmware: String?) {
        guard let range = name.range(of: " FW:") else { return (name, nil) }
        let model = name[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        let firmware = name[range.lowerBound...].trimmingCharacters(in: .whitespaces)
        return model.isEmpty ? (name, nil) : (model, firmware)
    }

    static func percent(_ level: Double?) -> String {
        level.map { PercentFormat.string(fromRatio: $0) } ?? "—"
    }

    /// 时长：「27 分钟」「1 小时 5 分钟」。
    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return String(localized: "\(minutes) 分钟") }
        return String(localized: "\(minutes / 60) 小时 \(minutes % 60) 分钟")
    }

    /// 菜单栏用的短时长：「27m」「1h05」。
    static func durationShort(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%dh%02d", min(minutes / 60, 99), minutes % 60)
    }

    static func powerState(_ state: PowerSourceState) -> String {
        switch state {
        case .external: String(localized: "外接电源")
        case .battery: String(localized: "电池供电")
        case .unknown: String(localized: "状态未知")
        }
    }

    static func selfTest(_ result: UPSSelfTestResult) -> String {
        switch result {
        case .passed: String(localized: "通过")
        case .warning: String(localized: "警告")
        case .error: String(localized: "失败")
        case .aborted: String(localized: "中止")
        case .inProgress: String(localized: "进行中")
        case .notInitiated: String(localized: "未做过")
        }
    }

    /// UPS 异常位的文字（只列出置位的异常）。
    static func alarms(_ flags: UPSStatusFlags) -> [String] {
        var out: [String] = []
        if flags.contains(.needReplacement) { out.append(String(localized: "需要更换电池")) }
        if flags.contains(.overload) { out.append(String(localized: "过载")) }
        if flags.contains(.communicationLost) { out.append(String(localized: "通信中断")) }
        if flags.contains(.shutdownImminent) { out.append(String(localized: "即将关机")) }
        if flags.contains(.belowRemainingCapacityLimit) { out.append(String(localized: "低于剩余容量限")) }
        if flags.contains(.remainingTimeLimitExpired) { out.append(String(localized: "剩余时间已到限")) }
        if flags.contains(.voltageNotRegulated) { out.append(String(localized: "电压未稳压")) }
        return out
    }

    static func date(_ components: DateComponents) -> String {
        guard let date = Calendar(identifier: .gregorian).date(from: components) else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func volts(_ value: Double) -> String {
        value < 100 ? String(format: "%.1f V", value) : String(format: "%.0f V", value)
    }
}
