// 功耗与散热模块的指标标识与值类型（功耗与散热模块设计 §3.1，D44–D46）。命名一旦发布就不改。

import Foundation

extension MetricID {
    /// 整机直流功率，W（SMC `PDTR`，1 Hz 实时）。
    public static let powerSystem: MetricID = "power.system"
    /// 墙插功率，W：`PowerTelemetryData` 每 60 s 的估算值（= 1.035 × 直流 + 1.6 W 的公式，D46），质量为 estimated。
    public static let powerWall: MetricID = "power.wall"
    /// SoC 功率（模型口径），W（SMC `PZC0`）。
    public static let powerSoC: MetricID = "power.soc"
    /// DRAM 功率，W（SMC `PZD1`，只含 DRAM 本身）。
    public static let powerDRAM: MetricID = "power.dram"
    /// GPU 功率，W（AGX「GPU Energy」差分）。
    public static let powerGPU: MetricID = "power.gpu"
    /// 低功耗模式，0 / 1（`ProcessInfo.isLowPowerModeEnabled`）。
    public static let powerLowPowerMode: MetricID = "power.lowPowerMode"
    /// SoC 最热点，°C（芯片档案指定的 SMC 聚合键，D44 PT7）。
    public static let thermalSoCHotspot: MetricID = "thermal.soc.hotspot"

    private static let fanPrefix = "fan."

    /// 第 `index` 个风扇的实际转速，rpm（`F<i>Ac`）。
    public static func fanSpeed(_ index: Int) -> MetricID { MetricID("\(fanPrefix)\(index).rpm") }
    /// 目标转速，rpm（`F<i>Tg`）。
    public static func fanTarget(_ index: Int) -> MetricID { MetricID("\(fanPrefix)\(index).target") }
    /// 最低转速，rpm（`F<i>Mn`）。
    public static func fanMinimum(_ index: Int) -> MetricID { MetricID("\(fanPrefix)\(index).min") }
    /// 最高转速，rpm（`F<i>Mx`）。
    public static func fanMaximum(_ index: Int) -> MetricID { MetricID("\(fanPrefix)\(index).max") }
    /// 模式：0 自动，非 0 强制（`F<i>md` 或 `F<i>Md`，大小写随芯片不同，D44）。
    public static func fanMode(_ index: Int) -> MetricID { MetricID("\(fanPrefix)\(index).mode") }

    /// 若是风扇实际转速 `fan.<i>.rpm`，返回 i。
    public var fanSpeedIndex: Int? {
        guard rawValue.hasPrefix(Self.fanPrefix), rawValue.hasSuffix(".rpm") else { return nil }
        let middle = rawValue.dropFirst(Self.fanPrefix.count).dropLast(".rpm".count)
        guard let index = Int(middle), index >= 0 else { return nil }
        return index
    }
}

/// `AppleSmartBattery.PowerTelemetryData` 的一次读数（未文档键，只读）。
///
/// 累加器跨 app 重启保留、从开机起算；但满载约 73 W 以上时会整分钟漏记（D46），所以只用来补 app 没运行的时段。
public struct PowerTelemetryReading: Hashable, Sendable, Codable {
    /// `AccumulatedSystemPowerIn`，毫焦。
    public var accumulatedSystemPowerIn: Int64
    /// `SystemPowerInAccumulatorCount`：约每秒加一，每 60 s 发布一次。
    public var accumulatorCount: Int64
    /// `AccumulatedWallEnergyEstimate`，微瓦时（× 3.6 / 1000 得焦耳）。
    public var accumulatedWallEnergy: Int64
    /// 读到它的墙钟时刻。
    public var wallClock: Date

    public init(accumulatedSystemPowerIn: Int64, accumulatorCount: Int64, accumulatedWallEnergy: Int64, wallClock: Date) {
        self.accumulatedSystemPowerIn = accumulatedSystemPowerIn
        self.accumulatorCount = accumulatorCount
        self.accumulatedWallEnergy = accumulatedWallEnergy
        self.wallClock = wallClock
    }
}

/// 遥测一次发布（计数器变化）与同期 PDTR 积分的对账结果（诊断页，D46）。
public struct TelemetrySegment: Hashable, Sendable, Codable {
    /// 本段结束（检测到计数变化）的墙钟时刻。
    public var end: Date
    /// 本段墙钟长度，秒。
    public var seconds: Double
    /// 计数器增量（正常约 60）。
    public var countDelta: Int64
    /// 遥测均值，W（ΔAccumulatedSystemPowerIn / Δcount）。
    public var telemetryWatts: Double
    /// 同期 PDTR 积分的均值，W；本段 PDTR 覆盖不足时为 nil。
    public var integratedWatts: Double?

    public init(end: Date, seconds: Double, countDelta: Int64, telemetryWatts: Double, integratedWatts: Double?) {
        self.end = end
        self.seconds = seconds
        self.countDelta = countDelta
        self.telemetryWatts = telemetryWatts
        self.integratedWatts = integratedWatts
    }

    /// 累加器在这一段漏记了（计数增量明显少于经过的秒数）。
    public var isDropped: Bool { seconds >= 50 && Double(countDelta) < seconds * 0.9 }

    /// PDTR 积分与遥测均值的相对偏差；漏记或缺 PDTR 时为 nil。
    public var deviation: Double? {
        guard !isDropped, let integratedWatts, telemetryWatts > 0.1 else { return nil }
        return integratedWatts / telemetryWatts - 1
    }
}

/// PMGR 一个 30 分钟批次（功耗与散热模块设计 §4.4，D45）：Apple 功耗模型口径的分部件能量。
public struct PMGRBatch: Hashable, Sendable, Codable {
    /// 检测到上一个批次与本批次的墙钟时刻（批次每 1800 s 发布一次，检测有固定的滞后，两端相同）。
    public var start: Date
    public var end: Date
    /// 归一化名（`cpu`、`gpu`、`ane`…，不认识的通道用原名）→ 焦耳。
    public var joules: [String: Double]
    /// 同一窗口里 AGX「GPU Energy」的焦耳数（交叉核对用）；读不到时为 nil。
    public var agxJoules: Double?

    public init(start: Date, end: Date, joules: [String: Double], agxJoules: Double?) {
        self.start = start
        self.end = end
        self.joules = joules
        self.agxJoules = agxJoules
    }

    public var seconds: Double { end.timeIntervalSince(start) }

    /// 某个部件的平均功率，W。
    public func watts(_ component: String) -> Double? {
        guard let j = joules[component], seconds > 0 else { return nil }
        return j / seconds
    }
}

/// 交叉核对的一项结论（D44 §7：失败时对应项显示不可用，不回退到估算）。
public enum CrossCheckVerdict: String, Hashable, Sendable, Codable {
    /// 还没有可比的数据。
    case pending
    /// 积分覆盖不足，这一次不下结论。
    case inconclusive
    case passed
    case failed
}

/// 一项交叉核对的最新结果。
public struct CrossCheckResult: Hashable, Sendable, Codable {
    public var name: String
    public var verdict: CrossCheckVerdict
    /// 比值（SMC 或 AGX ÷ PMGR）。
    public var ratio: Double?
    /// 允许范围。
    public var range: ClosedRange<Double>
    public var at: Date?
    /// 连续失败次数（达到 2 次时对应指标改为不可用）。
    public var consecutiveFailures: Int

    public init(
        name: String, verdict: CrossCheckVerdict, ratio: Double?, range: ClosedRange<Double>, at: Date?,
        consecutiveFailures: Int
    ) {
        self.name = name
        self.verdict = verdict
        self.ratio = ratio
        self.range = range
        self.at = at
        self.consecutiveFailures = consecutiveFailures
    }
}
