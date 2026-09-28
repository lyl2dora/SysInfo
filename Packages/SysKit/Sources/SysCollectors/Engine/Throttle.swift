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

/// 降频信号的当前取值，由 app 层的 ThrottleMonitor 收集（K20，M0 设计 §5.3）。
public struct ThrottleSignals: Hashable, Sendable {
    /// 低电量模式（`ProcessInfo.isLowPowerModeEnabled`）。
    public var lowPowerMode: Bool
    /// `thermalState` 达到 `.serious` 及以上。
    public var thermalPressure: Bool
    /// 当前由 UPS 或电池供电（已去抖）。
    public var onBatteryPower: Bool
    /// 锁屏。
    public var screenLocked: Bool
    /// 显示器睡眠。
    public var displayAsleep: Bool
    /// 诊断页的手动降频开关（K20，测试用）。
    public var manual: Bool

    public init(
        lowPowerMode: Bool = false, thermalPressure: Bool = false, onBatteryPower: Bool = false,
        screenLocked: Bool = false, displayAsleep: Bool = false, manual: Bool = false
    ) {
        self.lowPowerMode = lowPowerMode
        self.thermalPressure = thermalPressure
        self.onBatteryPower = onBatteryPower
        self.screenLocked = screenLocked
        self.displayAsleep = displayAsleep
        self.manual = manual
    }

    /// 当前为真的信号对应的原因。
    public var activeReasons: Set<ThrottleReason> {
        var reasons: Set<ThrottleReason> = []
        if lowPowerMode { reasons.insert(.lowPowerMode) }
        if thermalPressure { reasons.insert(.thermalPressure) }
        if onBatteryPower { reasons.insert(.onBatteryPower) }
        if screenLocked { reasons.insert(.screenLocked) }
        if displayAsleep { reasons.insert(.displayAsleep) }
        if manual { reasons.insert(.manual) }
        return reasons
    }
}

/// 把降频信号汇总成交给引擎的 `setThrottle(factor:reasons:)` 参数（K20、D19、D25）。
public enum ThrottlePolicy {
    /// 触发降频时，所有采样间隔乘以这个倍数（K20）。
    public static let slowdownMultiplier = 2

    /// 汇总规则：
    /// - 锁屏或显示器睡眠：`paused`（菜单栏和面板都看不见，只保留后台需求）；
    /// - 低电量、过热、UPS 或电池放电、手动开关：`slowed(2)`；
    /// - 否则 `normal`。
    ///
    /// `automatic` 为 false（用户在设置里关掉了自动降频）时忽略所有自动信号，只看诊断页的手动开关。
    /// 返回的原因只包含实际生效的信号。
    public static func evaluate(_ signals: ThrottleSignals, automatic: Bool)
        -> (factor: ThrottleFactor, reasons: Set<ThrottleReason>)
    {
        var effective = signals
        if !automatic {
            effective = ThrottleSignals(manual: signals.manual)
        }
        let reasons = effective.activeReasons
        if effective.screenLocked || effective.displayAsleep {
            return (.paused, reasons)
        }
        if !reasons.isEmpty {
            return (.slowed(slowdownMultiplier), reasons)
        }
        return (.normal, [])
    }
}
