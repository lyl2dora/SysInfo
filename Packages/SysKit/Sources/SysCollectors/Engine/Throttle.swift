// 降频（K20、D19、D25，M0 设计 §5.2、§5.3）。
//
// 信号的汇总（低电量、过热、UPS 放电、锁屏、显示器睡眠）放在 app 层的 ThrottleMonitor，
// 引擎只接收汇总后的结果：`setThrottle(factor:reasons:)`。

/// 降频程度。
public enum ThrottleFactor: Hashable, Codable, Sendable {
    /// 不降频。
    case normal
    /// 所有需求的间隔乘以这个倍数（小于 2 时按不降频处理）。
    case slowed(Int)
    /// 锁屏或显示器睡眠：只保留 `.background` 需求，其余全停。
    case paused

    /// 间隔倍数；`paused` 时后台需求不再额外放慢，返回 1。
    public var multiplier: Int {
        switch self {
        case .normal, .paused: 1
        case .slowed(let factor): max(factor, 1)
        }
    }
}

/// 降频原因，供诊断页显示和日志记录。
public enum ThrottleReason: String, Hashable, Codable, Sendable, CaseIterable, Comparable {
    /// 低电量模式（`ProcessInfo.isLowPowerModeEnabled`）。
    case lowPowerMode
    /// `thermalState` 达到 `.serious` 及以上。
    case thermalPressure
    /// UPS 或电池放电。
    case onBatteryPower
    /// 锁屏。
    case screenLocked
    /// 显示器睡眠。
    case displayAsleep
    /// 诊断页的手动开关（K20）。
    case manual

    public static func < (lhs: ThrottleReason, rhs: ThrottleReason) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
