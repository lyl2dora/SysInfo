// 占用着色的阈值与持续判定（D32，CPU 模块设计 §7.1）。放在共享模型里，P2 的提醒直接复用。
//
// - 输入是平滑后的值（菜单栏用 τ = 1.5 s 的 EMA）；
// - 升级：持续 `sustainSeconds` 秒不低于某级阈值才升到这一级；
// - 降级：低于当前级阈值减去滞回量时立即降到与当前值相符的级别（同样按滞回判断）；
// - 不可用或长时间没有新值（睡眠）时回到正常，计时清零。

/// 着色级别。
public enum UsageLevel: Int, Sendable, Hashable, Codable, Comparable, CaseIterable {
    case normal
    case warning
    case critical

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 着色阈值（比例 0…1）。
public struct ColorThresholds: Sendable, Hashable, Codable {
    public var warning: Double
    public var critical: Double
    /// 升级前需要持续的秒数。
    public var sustainSeconds: Double
    /// 降级的滞回量（比例，0.05 即 5 个百分点）。
    public var hysteresis: Double

    public init(warning: Double = 0.85, critical: Double = 0.95, sustainSeconds: Double = 10, hysteresis: Double = 0.05) {
        self.warning = warning
        self.critical = critical
        self.sustainSeconds = sustainSeconds
        self.hysteresis = hysteresis
    }

    /// D32 的出厂值：持续 10 s ≥85% 为橙，≥95% 为红，回落留 5 个百分点。
    public static let cpuDefault = ColorThresholds()

    func threshold(_ level: UsageLevel) -> Double? {
        switch level {
        case .normal: nil
        case .warning: warning
        case .critical: critical
        }
    }
}

/// 持续判定的状态机（纯值类型，便于单测）。
public struct SustainedLevelTracker: Sendable, Hashable {
    public var thresholds: ColorThresholds
    public private(set) var level: UsageLevel = .normal
    /// 各级别「连续不低于阈值」的起点，秒。
    private var aboveSince: [UsageLevel: Double] = [:]
    private var lastTime: Double?

    /// 两次输入相隔超过这么久（睡眠、暂停）就清零计时。
    public static let maxGapSeconds: Double = 30

    public init(thresholds: ColorThresholds) {
        self.thresholds = thresholds
    }

    /// 输入一个值（nil 为不可用），返回当前级别。`seconds` 是单调的时刻（含睡眠的连续时钟）。
    @discardableResult
    public mutating func update(_ value: Double?, at seconds: Double) -> UsageLevel {
        defer { lastTime = seconds }
        if let lastTime, seconds - lastTime > Self.maxGapSeconds || seconds < lastTime {
            aboveSince = [:]
            level = .normal
        }
        guard let value, value.isFinite else {
            aboveSince = [:]
            level = .normal
            return level
        }
        for candidate in [UsageLevel.warning, .critical] {
            guard let threshold = thresholds.threshold(candidate) else { continue }
            if value >= threshold {
                if aboveSince[candidate] == nil { aboveSince[candidate] = seconds }
            } else {
                aboveSince[candidate] = nil
            }
        }
        // 降级：低于当前级阈值减滞回量
        while let threshold = thresholds.threshold(level), value < threshold - thresholds.hysteresis {
            level = UsageLevel(rawValue: level.rawValue - 1) ?? .normal
        }
        // 升级：持续达标
        for candidate in [UsageLevel.critical, .warning] where candidate > level {
            if let since = aboveSince[candidate], seconds - since >= thresholds.sustainSeconds {
                level = candidate
                break
            }
        }
        return level
    }
}
