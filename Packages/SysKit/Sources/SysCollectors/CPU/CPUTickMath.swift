// 每核 CPU tick 的差分（M0 设计 §5.1、§8）。纯函数，便于单测。

/// 一个逻辑核的累计 tick（来自 `PROCESSOR_CPU_LOAD_INFO`，单位是调度 tick）。
struct CoreTicks: Hashable, Sendable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32

    /// 忙碌 tick：user + system + nice。
    var busy: UInt64 { UInt64(user) + UInt64(system) + UInt64(nice) }
    /// 全部 tick：忙碌 + idle。
    var total: UInt64 { busy + UInt64(idle) }

    /// 四个计数器是否都不小于 `earlier` 的对应值。
    func isMonotonic(since earlier: CoreTicks) -> Bool {
        user >= earlier.user && system >= earlier.system && idle >= earlier.idle && nice >= earlier.nice
    }
}

/// 单个核在一段区间内的占用。
enum CoreUsage: Equatable, Sendable {
    /// 忙碌比例，0…1。
    case ratio(Double)
    /// 有计数器回退（负差），按复位处理，丢弃这一段，不钳为 0。
    case counterReset
    /// 这一段内计数器完全没有前进，算不出比例。
    case noElapsedTicks
}

/// 一段区间的 CPU 占用。
struct CPUUsage: Equatable, Sendable {
    /// 总占用：有效核的忙碌 tick 之和除以总 tick 之和；没有任何有效核时为 nil。
    var total: Double?
    var perCore: [CoreUsage]
    /// 被丢弃的核数（回退或没有前进）。大于 0 时总占用只是估算。
    var droppedCores: Int
}

/// 两次读数差分的结果。
enum CPUTickDelta: Equatable, Sendable {
    /// 与上次逐字节相同：视为陈旧（全局节流下的缓存结果，调研报告 §0-7），跳过本次。
    case stale
    /// 核数变了，无法逐核对齐：把本次读数当作新基线。
    case coreCountChanged(previous: Int, current: Int)
    case usage(CPUUsage)
}

enum CPUTickMath {
    static func delta(previous: [CoreTicks], current: [CoreTicks]) -> CPUTickDelta {
        if previous == current {
            return .stale
        }
        guard previous.count == current.count else {
            return .coreCountChanged(previous: previous.count, current: current.count)
        }

        var perCore: [CoreUsage] = []
        perCore.reserveCapacity(current.count)
        var busySum: UInt64 = 0
        var totalSum: UInt64 = 0
        var dropped = 0

        for (before, after) in zip(previous, current) {
            // 32 位计数器的回绕（单核约 497 天）也会表现为回退，同样按复位处理，只丢这一段。
            guard after.isMonotonic(since: before) else {
                perCore.append(.counterReset)
                dropped += 1
                continue
            }
            let busy = after.busy - before.busy
            let total = after.total - before.total
            guard total > 0 else {
                perCore.append(.noElapsedTicks)
                dropped += 1
                continue
            }
            perCore.append(.ratio(Double(busy) / Double(total)))
            busySum += busy
            totalSum += total
        }

        let total: Double? = totalSum > 0 ? Double(busySum) / Double(totalSum) : nil
        return .usage(CPUUsage(total: total, perCore: perCore, droppedCores: dropped))
    }
}
