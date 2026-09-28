// 调度的纯函数部分（M0 设计 §5.2、§8）：有效间隔、本次到期、下一次唤醒、网格与墙钟的换算。
//
// 时间模型：
// - 基础 tick 为 1 s。第 n 个 tick 定在 Unix 时间第 n 秒之后 50 ms（「对齐到整秒之后约 50 ms」，
//   SMC 类数据源每秒更新，将来沿用）。所以 n 就是 Unix 秒数，间隔为 k 的采集器在 n % k == 0 的 tick 上到期，
//   相同间隔的采集器天然落在同一次唤醒里。
// - 引擎只在「有采集器到期」的 tick 上唤醒：没有到期项的整秒不唤醒，没有需求时完全不唤醒。

import SysModel

enum Schedule {
    // MARK: - 有效间隔

    /// 一个需求在给定降频下的有效间隔（基础 tick 数）；在降频下被停掉时返回 nil。
    /// 结果不超过 `Demand.maxInterval`（乘上降频倍数后也一样），保证 tick 序号换算成纳秒时不会溢出。
    static func effectiveInterval(of demand: Demand, under throttle: ThrottleFactor) -> Int? {
        if throttle == .paused, demand.tier != .background {
            return nil
        }
        let base = Demand.clampInterval(demand.interval)
        let (product, overflow) = base.multipliedReportingOverflow(by: throttle.multiplier)
        return overflow ? Demand.maxInterval : Demand.clampInterval(product)
    }

    /// 每个采集器的有效间隔：所有需要它的需求里最短的那个（每个采集器每个 tick 最多跑一次）。
    /// 不在结果里的采集器当前没有需求。`available` 之外的采集器 ID 被忽略。
    static func effectiveIntervals(
        for demands: some Sequence<Demand>, throttle: ThrottleFactor, available: Set<CollectorID>
    ) -> [CollectorID: Int] {
        var result: [CollectorID: Int] = [:]
        for demand in demands {
            guard let interval = effectiveInterval(of: demand, under: throttle) else { continue }
            for id in demand.collectors where available.contains(id) {
                result[id] = min(result[id] ?? .max, interval)
            }
        }
        return result
    }

    // MARK: - 到期

    /// 间隔为 `interval` 的采集器在第 `tick` 个 tick 是否到期。
    static func isDue(tick: Int64, interval: Int) -> Bool {
        tick % Int64(max(interval, 1)) == 0
    }

    /// 第 `tick` 个 tick 上要跑的采集器，按 ID 排序（执行顺序稳定）。
    /// `pendingBaseline` 是刚获得需求、还没建立差分基线的采集器：它们在下一个 tick 就跑，不等整倍数。
    static func dueCollectors(
        at tick: Int64, intervals: [CollectorID: Int], pendingBaseline: Set<CollectorID>
    ) -> [CollectorID] {
        intervals
            .filter { id, interval in pendingBaseline.contains(id) || isDue(tick: tick, interval: interval) }
            .keys
            .sorted()
    }

    /// `tick` 之后第一个有采集器到期的 tick；没有任何需求时返回 nil（定时器应当停掉）。
    static func nextTick(
        after tick: Int64, intervals: [CollectorID: Int], pendingBaseline: Set<CollectorID>
    ) -> Int64? {
        guard !intervals.isEmpty else { return nil }
        if intervals.keys.contains(where: pendingBaseline.contains) {
            return tick + 1
        }
        return intervals.values.lazy.map { nextMultiple(of: Int64(max($0, 1)), after: tick) }.min()
    }

    /// 严格大于 `tick` 的最小的 `k` 的倍数（对负数同样成立）。
    static func nextMultiple(of k: Int64, after tick: Int64) -> Int64 {
        let (quotient, remainder) = tick.quotientAndRemainder(dividingBy: k)
        let floor = remainder < 0 ? quotient - 1 : quotient
        return (floor + 1) * k
    }
}

/// tick 网格与墙钟（Unix 纳秒）的换算。
struct TickGrid: Hashable, Sendable {
    /// 基础 tick，纳秒。M0 固定为 1 s，tick 序号即 Unix 秒数。
    static let baseNanos: Int64 = 1_000_000_000

    /// 每个 tick 相对整秒的偏移，纳秒（约 50 ms）。
    var offsetNanos: Int64 = 50_000_000

    /// 墙钟时刻 `unixNanos` 当时或之前的最后一个 tick。
    func tick(atOrBefore unixNanos: Int64) -> Int64 {
        let shifted = unixNanos - offsetNanos
        let (quotient, remainder) = shifted.quotientAndRemainder(dividingBy: Self.baseNanos)
        return remainder < 0 ? quotient - 1 : quotient
    }

    /// 第 `tick` 个 tick 的墙钟时刻，Unix 纳秒。超出 Int64 范围时饱和到 `.max` / `.min`，不会溢出崩溃
    /// （正常情况下间隔不超过 `Demand.maxInterval`，到不了这里）。
    func unixNanos(of tick: Int64) -> Int64 {
        let (scaled, overflow) = tick.multipliedReportingOverflow(by: Self.baseNanos)
        if overflow { return tick < 0 ? .min : .max }
        let (sum, sumOverflow) = scaled.addingReportingOverflow(offsetNanos)
        if sumOverflow { return offsetNanos < 0 ? .min : .max }
        return sum
    }

    /// 定时器排下一次唤醒时，从哪个 tick 之后开始找。
    ///
    /// 通常就是「现在」所在的 tick；但如果上一次执行的 tick 比现在还晚一点（墙钟与单调时钟之间的微小偏差、
    /// 定时器按单调时钟提前了几毫秒），从上一次执行的 tick 之后找，避免同一个 tick 跑两次。
    /// 墙钟被往回大幅调整（超过 2 个 tick）时以现在为准，否则会长时间不唤醒。
    static func searchStart(current: Int64, lastRun: Int64?) -> Int64 {
        guard let lastRun, lastRun > current, lastRun - current <= 2 else { return current }
        return lastRun
    }
}
