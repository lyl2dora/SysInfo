// 电源设备模块的数据模型（电源设备设计 §2，D84）。指标命名一旦发布就不改。
//
// - 设备键只在内存与设置里用，不含设备唯一标识（D84 PD7）：UPS 用 Vendor ID : Product ID，配件用 Group Identifier 的加盐哈希；
// - 电量、负载用 0…1 的比例；时间用秒；电压 V；功率 W；
// - 只有主 UPS（快照里第一台 UPS）有 MetricID（进环形缓冲、widget 与历史）；其余设备只在快照里。

import Foundation

// MARK: - 设备

/// 设备种类。
public enum PowerDeviceKind: String, Hashable, Codable, Sendable {
    case ups
    case internalBattery
    case accessory
}

/// 设备键（电源设备设计 §2.1）。只在内存与设置里用。
public struct PowerDeviceKey: RawRepresentable, Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// UPS：`ups:<vendorID>:<productID>`，同型号多台时追加序号（只在本次运行有效）。
    public static func ups(vendorID: Int, productID: Int, index: Int = 0) -> Self {
        Self(rawValue: index == 0 ? "ups:\(vendorID):\(productID)" : "ups:\(vendorID):\(productID):\(index)")
    }

    public static let internalBattery = Self(rawValue: "battery")

    /// 配件：`accessory:<哈希>`，哈希由调用方用加盐 SHA-256 算好。
    public static func accessory(hash: String) -> Self { Self(rawValue: "accessory:\(hash)") }
}

/// 供电状态（IOPS `Power Source State`）。
public enum PowerSourceState: String, Hashable, Codable, Sendable {
    /// 外接电源（`AC Power`）。
    case external
    /// 由自身电池供电（`Battery Power`）。
    case battery
    case unknown

    public init(iopsValue: String?) {
        switch iopsValue {
        case "AC Power": self = .external
        case "Battery Power": self = .battery
        default: self = .unknown
        }
    }
}

/// 部件的角色（配件按 `Part Identifier` 拆开；UPS 与内置电池只有 `.main`）。
public enum PowerDevicePartRole: Hashable, Codable, Sendable {
    case main
    case combined
    case left
    case right
    case `case`
    case other(String)

    public init(partIdentifier: String?) {
        switch partIdentifier {
        case nil, "": self = .main
        case "Combined": self = .combined
        case "Left": self = .left
        case "Right": self = .right
        case "Case": self = .case
        case let value?: self = .other(value)
        }
    }

    /// 显示顺序：左、右、合成、充电盒、其他。
    public var order: Int {
        switch self {
        case .main: 0
        case .left: 1
        case .right: 2
        case .combined: 3
        case .case: 4
        case .other: 5
        }
    }
}

/// 设备的一个部件（UPS 与内置电池只有一个）。
public struct PowerDevicePart: Hashable, Codable, Sendable {
    public var role: PowerDevicePartRole
    /// 系统给的部件名（`Part Name`，如「AirPods Pro 🅛」）；没有时为空，由显示层按角色拼。
    public var name: String
    /// 电量，0…1；读不到时为 nil。
    public var level: Double?
    public var isCharging: Bool
    public var isCharged: Bool
    /// 设备自报的低电量阈值，0…1。
    public var lowWarnLevel: Double?

    public init(
        role: PowerDevicePartRole, name: String = "", level: Double?, isCharging: Bool = false, isCharged: Bool = false,
        lowWarnLevel: Double? = nil
    ) {
        self.role = role
        self.name = name
        self.level = level
        self.isCharging = isCharging
        self.isCharged = isCharged
        self.lowWarnLevel = lowWarnLevel
    }
}

/// 一台电源设备。
public struct PowerDevice: Hashable, Codable, Sendable, Identifiable {
    public var key: PowerDeviceKey
    public var kind: PowerDeviceKind
    /// IOPS 的 `Name`；配件为设备名（合成项的名字）。
    public var name: String
    /// 传输方式（`Transport Type`）：USB、Bluetooth LE、Internal…
    public var transport: String?
    /// 部件，按 `PowerDevicePartRole.order` 排序。
    public var parts: [PowerDevicePart]
    public var powerSourceState: PowerSourceState
    /// 剩余时间，秒（IOPS `Time to Empty`，单位分钟）；未知时为 nil。
    public var timeToEmpty: Double?
    /// 充满时间，秒；未知时为 nil。
    public var timeToFull: Double?
    public var vendorID: Int?
    public var productID: Int?
    /// 配件类别（`Accessory Category`，如 Headset、Audio Battery Case）。
    public var accessoryCategory: String?
    /// UPS 的输入电压，V（IOPS `Voltage`，单位 mV）；只在外接电源且 ≥ 80 V 时有值（由电池供电时 IOPS 报的是电池电压）。
    public var inputVoltage: Double?

    public var id: PowerDeviceKey { key }

    public init(
        key: PowerDeviceKey, kind: PowerDeviceKind, name: String, transport: String? = nil, parts: [PowerDevicePart],
        powerSourceState: PowerSourceState = .unknown, timeToEmpty: Double? = nil, timeToFull: Double? = nil,
        vendorID: Int? = nil, productID: Int? = nil, accessoryCategory: String? = nil, inputVoltage: Double? = nil
    ) {
        self.key = key
        self.kind = kind
        self.name = name
        self.transport = transport
        self.parts = parts
        self.powerSourceState = powerSourceState
        self.timeToEmpty = timeToEmpty
        self.timeToFull = timeToFull
        self.vendorID = vendorID
        self.productID = productID
        self.accessoryCategory = accessoryCategory
        self.inputVoltage = inputVoltage
    }

    /// 代表这台设备的电量：主部件；配件取合成项，没有合成项时取各部件中最低的（充电盒除外，除非只剩它）。
    public var level: Double? {
        if let main = parts.first(where: { $0.role == .main || $0.role == .combined })?.level { return main }
        let buds = parts.filter { $0.role != .case }.compactMap(\.level)
        if let lowest = buds.min() { return lowest }
        return parts.compactMap(\.level).min()
    }

    /// 由自身电池供电（UPS 停电、笔记本拔掉电源）。
    public var isOnBattery: Bool { powerSourceState == .battery }

    /// 任一部件在充电。
    public var isCharging: Bool { parts.contains(where: \.isCharging) }

    /// 低电量阈值：主部件自报的值。
    public var lowWarnLevel: Double? { parts.first?.lowWarnLevel }
}

/// 一次读到的全部电源设备。
public struct PowerDeviceSnapshot: Hashable, Codable, Sendable {
    public var time: Date
    /// 排序：UPS → 内置电池 → 配件（按名称）。
    public var devices: [PowerDevice]
    /// 私有配件接口可用（自检通过）。不可用时配件不显示，面板注明。
    public var accessoriesAvailable: Bool

    public init(time: Date, devices: [PowerDevice], accessoriesAvailable: Bool) {
        self.time = time
        self.devices = devices
        self.accessoriesAvailable = accessoriesAvailable
    }

    public static let empty = PowerDeviceSnapshot(time: .distantPast, devices: [], accessoriesAvailable: false)

    /// 主 UPS：第一台 UPS。
    public var primaryUPS: PowerDevice? { devices.first { $0.kind == .ups } }

    public var internalBattery: PowerDevice? { devices.first { $0.kind == .internalBattery } }

    public var accessories: [PowerDevice] { devices.filter { $0.kind == .accessory } }

    /// 本机有 UPS 或内置电池（D89：电源设备 widget 的出厂开关按它定；配件连断频繁，不算）。
    public var hasUPSOrBattery: Bool { primaryUPS != nil || internalBattery != nil }

    public func device(_ key: PowerDeviceKey) -> PowerDevice? { devices.first { $0.key == key } }
}

// MARK: - UPS 扩展遥测（HID）

/// UPS 自检结果（HID Power Device `Test`）。
public enum UPSSelfTestResult: Int, Hashable, Codable, Sendable {
    case passed = 1
    case warning = 2
    case error = 3
    case aborted = 4
    case inProgress = 5
    case notInitiated = 6
}

/// 不随采样变化的 UPS 信息：设备接入、打开面板时读一次。
public struct UPSStaticInfo: Hashable, Codable, Sendable {
    /// 额定有功功率，W（`ConfigActivePower`）。
    public var ratedActivePower: Double?
    /// 额定输入电压，V。
    public var ratedInputVoltage: Double?
    /// 切换到电池的低压 / 高压阈值，V。
    public var lowTransferVoltage: Double?
    public var highTransferVoltage: Double?
    /// 电池额定电压，V。
    public var batteryNominalVoltage: Double?
    /// 电池生产日期（HID 日期编码解出的年月日）。
    public var manufactureDate: DateComponents?
    public var selfTestResult: UPSSelfTestResult?
    /// 低电量关机阈值，0…1（`RemainingCapacityLimit`）。
    public var remainingCapacityLimit: Double?

    public init(
        ratedActivePower: Double? = nil, ratedInputVoltage: Double? = nil, lowTransferVoltage: Double? = nil,
        highTransferVoltage: Double? = nil, batteryNominalVoltage: Double? = nil, manufactureDate: DateComponents? = nil,
        selfTestResult: UPSSelfTestResult? = nil, remainingCapacityLimit: Double? = nil
    ) {
        self.ratedActivePower = ratedActivePower
        self.ratedInputVoltage = ratedInputVoltage
        self.lowTransferVoltage = lowTransferVoltage
        self.highTransferVoltage = highTransferVoltage
        self.batteryNominalVoltage = batteryNominalVoltage
        self.manufactureDate = manufactureDate
        self.selfTestResult = selfTestResult
        self.remainingCapacityLimit = remainingCapacityLimit
    }

    /// HID 日期编码：(年 − 1980) × 512 + 月 × 32 + 日。不合法时为 nil。
    public static func decodeHIDDate(_ raw: Int) -> DateComponents? {
        guard raw > 0 else { return nil }
        let year = 1980 + raw / 512
        let month = (raw % 512) / 32
        let day = raw % 32
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }
}

/// UPS 状态位（HID `PresentStatus`）。
public struct UPSStatusFlags: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let acPresent = Self(rawValue: 1 << 0)
    public static let charging = Self(rawValue: 1 << 1)
    public static let discharging = Self(rawValue: 1 << 2)
    public static let needReplacement = Self(rawValue: 1 << 3)
    public static let overload = Self(rawValue: 1 << 4)
    public static let communicationLost = Self(rawValue: 1 << 5)
    public static let shutdownImminent = Self(rawValue: 1 << 6)
    public static let belowRemainingCapacityLimit = Self(rawValue: 1 << 7)
    public static let remainingTimeLimitExpired = Self(rawValue: 1 << 8)
    public static let voltageNotRegulated = Self(rawValue: 1 << 9)

    /// 需要提醒用户的异常位。
    public static let alarms: Self = [
        .needReplacement, .overload, .communicationLost, .shutdownImminent, .belowRemainingCapacityLimit,
        .remainingTimeLimitExpired, .voltageNotRegulated,
    ]
}

/// 一次 HID 采样。
public struct UPSTelemetry: Hashable, Codable, Sendable {
    public var time: Date
    /// 负载，0…1（`PercentLoad`）。
    public var load: Double?
    /// 负载功率估算，W = 负载 × 额定有功功率（D84 PD4）。
    public var loadPower: Double?
    public var inputVoltage: Double?
    public var batteryVoltage: Double?
    /// 电量，0…1（自检对照用）。
    public var charge: Double?
    /// 剩余时间，秒（`RunTimeToEmpty`）。
    public var runtime: Double?
    public var flags: UPSStatusFlags

    public init(
        time: Date, load: Double? = nil, loadPower: Double? = nil, inputVoltage: Double? = nil, batteryVoltage: Double? = nil,
        charge: Double? = nil, runtime: Double? = nil, flags: UPSStatusFlags = []
    ) {
        self.time = time
        self.load = load
        self.loadPower = loadPower
        self.inputVoltage = inputVoltage
        self.batteryVoltage = batteryVoltage
        self.charge = charge
        self.runtime = runtime
        self.flags = flags
    }
}

// MARK: - 指标

extension MetricID {
    /// 主 UPS 电量，0…1（IOPS）。
    public static let upsCharge: MetricID = "devices.ups.charge"
    /// 主 UPS 剩余时间，s（IOPS `Time to Empty`）。
    public static let upsRuntime: MetricID = "devices.ups.runtime"
    /// 主 UPS 输入电压，V（HID；断电时为 0）。
    public static let upsInputVoltage: MetricID = "devices.ups.inputVoltage"
    /// 主 UPS 是否由电池供电，0 / 1。
    public static let upsOnBattery: MetricID = "devices.ups.onBattery"
    /// 主 UPS 负载，0…1（HID）。
    public static let upsLoad: MetricID = "devices.ups.load"
    /// 主 UPS 负载功率估算，W（HID，estimated）。
    public static let upsLoadPower: MetricID = "devices.ups.loadPower"
    /// 主 UPS 电池电压，V（HID）。
    public static let upsBatteryVoltage: MetricID = "devices.ups.batteryVoltage"
}

extension UnavailableReason {
    /// 没有这个设备（例如 HID 匹配不到 UPS）。
    public static func noDevice(_ detail: String? = nil) -> Self { Self(code: "noDevice", detail: detail) }
}

/// 设备在不在的去抖（D89）：出现立刻为真；消失要持续 `hideDelay` 才变假，
/// 免得 UPS 的 USB 重新枚举、IOPS 重建快照时 widget 闪一下、旁边的 item 跟着跳。
public struct PresenceLatch: Sendable, Equatable {
    public static let defaultHideDelay: TimeInterval = 10

    public private(set) var value: Bool
    /// 观察到消失的时刻；设备回来时清掉。
    public private(set) var absentSince: Date?
    public let hideDelay: TimeInterval

    public init(initial: Bool, hideDelay: TimeInterval = PresenceLatch.defaultHideDelay) {
        value = initial
        self.hideDelay = hideDelay
    }

    /// 喂一次观察结果，返回去抖后的值。
    @discardableResult
    public mutating func update(present: Bool, at now: Date) -> Bool {
        if present {
            value = true
            absentSince = nil
        } else if value {
            let since = absentSince ?? now
            absentSince = since
            if now.timeIntervalSince(since) >= hideDelay { value = false; absentSince = nil }
        }
        return value
    }

    /// 还在等的话，什么时候该再检查一次（到点再喂一次 `present: false`）。
    public var pendingDeadline: Date? { absentSince.map { $0.addingTimeInterval(hideDelay) } }
}
