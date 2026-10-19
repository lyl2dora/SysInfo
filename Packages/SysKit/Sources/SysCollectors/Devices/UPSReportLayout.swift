// UPS 的 HID 报告布局与取值（电源设备设计 §4.3，D84 PD2）。纯值类型，单测可以直接喂描述。
//
// - 报告由内核解析：每个报告只对其中一个元素发 GET_REPORT（`kIOHIDDeviceGetValueWithUpdate`），同一报告的其余元素
//   读内核刚更新的值，不自己算位偏移；
// - 同一项在多个集合里各有一份时，按调用方给的集合优先级取一份；
// - 有无符号看 `logicalMinimum`（实测 CoreHID 把 8 位的输入额定电压 230 读成 −26），按位宽改正；
// - 单位按 `unit` 与 `unitExponent`（4 位有符号）换算成 SI；`unit` 为 0 时按 HID 电源设备规范的默认单位，并标出来。

import Foundation

/// HID 电源设备页（0x84）与电池系统页（0x85）里用到的 usage。
public enum UPSUsage {
    public static let powerDevice: UInt32 = 0x84
    public static let batterySystem: UInt32 = 0x85

    static func key(_ page: UInt32, _ usage: UInt32) -> UInt32 { page << 16 | usage }

    // 集合
    static let presentStatus = key(0x84, 0x02)
    static let battery = key(0x84, 0x12)
    static let powerConverter = key(0x84, 0x16)
    static let input = key(0x84, 0x1a)
    static let output = key(0x84, 0x1c)
    static let powerSummary = key(0x84, 0x24)

    // 数值
    static let voltage = key(0x84, 0x30)
    static let percentLoad = key(0x84, 0x35)
    static let configVoltage = key(0x84, 0x40)
    static let configActivePower = key(0x84, 0x44)
    static let lowVoltageTransfer = key(0x84, 0x53)
    static let highVoltageTransfer = key(0x84, 0x54)
    static let test = key(0x84, 0x58)
    static let remainingCapacityLimit = key(0x85, 0x29)
    static let capacityMode = key(0x85, 0x2c)
    static let remainingCapacity = key(0x85, 0x66)
    static let fullChargeCapacity = key(0x85, 0x67)
    static let runTimeToEmpty = key(0x85, 0x68)
    static let manufacturerDate = key(0x85, 0x85)

    // 状态位
    static let acPresent = key(0x85, 0xd0)
    static let charging = key(0x85, 0x44)
    static let discharging = key(0x85, 0x45)
    static let needReplacement = key(0x85, 0x4b)
    static let overload = key(0x84, 0x65)
    static let communicationLost = key(0x84, 0x73)
    static let shutdownImminent = key(0x84, 0x69)
    static let belowRemainingCapacityLimit = key(0x85, 0x42)
    static let remainingTimeLimitExpired = key(0x85, 0x43)
    static let voltageNotRegulated = key(0x85, 0xdb)
}

/// 一个 feature 元素的描述（从 IOHIDElement 读出，或单测里手写）。
public struct UPSElementInfo: Hashable, Sendable {
    public var usage: UInt32          // page << 16 | usage
    public var collection: UInt32     // 父集合的 page << 16 | usage；没有时为 0
    public var reportID: UInt32
    public var reportSize: UInt32     // 位
    public var reportCount: UInt32
    public var logicalMin: Int64
    public var unit: UInt32
    public var unitExponent: UInt32   // 原始 4 位编码

    public init(
        usage: UInt32, collection: UInt32, reportID: UInt32, reportSize: UInt32, reportCount: UInt32 = 1, logicalMin: Int64 = 0,
        unit: UInt32 = 0, unitExponent: UInt32 = 0
    ) {
        self.usage = usage
        self.collection = collection
        self.reportID = reportID
        self.reportSize = reportSize
        self.reportCount = reportCount
        self.logicalMin = logicalMin
        self.unit = unit
        self.unitExponent = unitExponent
    }
}

/// 一台 UPS 的 feature 元素表。
public struct UPSReportLayout: Hashable, Sendable {
    /// 设备枚举出来的全部 feature 元素（0x84 / 0x85 页）。
    public private(set) var elements: [UPSElementInfo]

    public init(elements: [UPSElementInfo]) {
        self.elements = elements
    }

    /// 某个 usage 的元素：先按 `collections` 的顺序找，找不到再取任意集合里的第一个。
    public func element(_ usage: UInt32, in collections: [UInt32] = []) -> UPSElementInfo? {
        let candidates = elements.filter { $0.usage == usage }
        for collection in collections {
            if let hit = candidates.first(where: { $0.collection == collection }) { return hit }
        }
        return candidates.first
    }

    /// 按逻辑范围改正有无符号：逻辑最小值 ≥ 0 的字段读成负数时按位宽当无符号；逻辑最小值 < 0 的字段按位宽做符号扩展。
    public static func normalize(_ value: Int64, element: UPSElementInfo) -> Int64 {
        let size = Int64(element.reportSize)
        guard size > 0, size < 63 else { return value }
        let modulus = Int64(1) << size
        if element.logicalMin >= 0 {
            return value < 0 ? value + modulus : value
        }
        if value >= modulus / 2 { return value - modulus }
        return value
    }

    /// 4 位编码的单位指数。
    public static func exponent(_ encoded: UInt32) -> Int {
        let nibble = Int(encoded & 0xF)
        return nibble >= 8 ? nibble - 16 : nibble
    }

    /// 物理量的种类（决定 SI 换算与缺单位时的默认值）。
    public enum Quantity: Sendable {
        case volt
        case watt
        case second
        /// 无单位（百分比、计数、编码）。
        case plain
    }

    /// 换算成 SI。`unit` 为 0 时按规范默认单位（伏、瓦、秒，指数 0），返回值的 `defaulted` 为真。
    public static func siValue(_ raw: Int64, element: UPSElementInfo, as quantity: Quantity) -> (value: Double, defaulted: Bool) {
        let e = exponent(element.unitExponent)
        switch (quantity, element.unit) {
        case (.plain, _):
            return (Double(raw), false)
        case (_, 0):
            return (Double(raw) * pow(10, Double(e)), true)
        case (.volt, 0xf0d121), (.watt, 0xd121):
            // SI 线性：cm² g s⁻³ A⁻¹ = 1e-7 V；cm² g s⁻³ = 1e-7 W。
            return (Double(raw) * pow(10, Double(e - 7)), false)
        case (.second, 0x1001):
            return (Double(raw) * pow(10, Double(e)), false)
        default:
            // 认不出的单位：按默认单位，标出来（自检会拿 IOPS 对照电压与电量）。
            return (Double(raw) * pow(10, Double(e)), true)
        }
    }
}
