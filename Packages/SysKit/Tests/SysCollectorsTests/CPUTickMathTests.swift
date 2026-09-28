// 每核 tick 差分（M0 设计 §5.1、§8）：陈旧判定、计数器回退按复位处理、核数变化。

import Testing
@testable import SysCollectors

@Suite struct CPUTickMathTests {
    func ticks(_ user: UInt32, _ system: UInt32, _ idle: UInt32, _ nice: UInt32 = 0) -> CoreTicks {
        CoreTicks(user: user, system: system, idle: idle, nice: nice)
    }

    @Test func identicalReadingIsStale() {
        let reading = [ticks(10, 5, 100), ticks(20, 5, 90)]
        #expect(CPUTickMath.delta(previous: reading, current: reading) == .stale)
    }

    @Test func perCoreAndTotalUsage() {
        let before = [ticks(100, 50, 1000, 0), ticks(200, 0, 800, 0)]
        // 核 0：忙 30 + 10 + 10(nice) = 50，总 100 → 0.5；核 1：忙 10，总 40 → 0.25
        let after = [ticks(130, 60, 1050, 10), ticks(210, 0, 830, 0)]
        guard case .usage(let usage) = CPUTickMath.delta(previous: before, current: after) else {
            Issue.record("应当得到占用")
            return
        }
        #expect(usage.perCore == [.ratio(0.5), .ratio(0.25)])
        #expect(usage.droppedCores == 0)
        // 总占用按 tick 加权：(50 + 10) / (100 + 40)，不是两核比例的简单平均 0.375
        #expect(usage.total == 60.0 / 140.0)
    }

    @Test func counterRegressionIsTreatedAsResetNotClamped() {
        let before = [ticks(100, 50, 1000), ticks(200, 0, 800)]
        // 核 0 的 idle 回退：按复位处理，丢弃这一段；核 1 正常
        let after = [ticks(110, 55, 900), ticks(220, 0, 880)]
        guard case .usage(let usage) = CPUTickMath.delta(previous: before, current: after) else {
            Issue.record("应当得到占用")
            return
        }
        #expect(usage.perCore == [.counterReset, .ratio(0.2)])
        #expect(usage.droppedCores == 1)
        // 总占用只由剩下的核算出（调用方据此标为 estimated），不把回退的核钳为 0 混进来
        #expect(usage.total == 0.2)
    }

    @Test func allCoresDroppedGivesNoTotal() {
        let before = [ticks(100, 50, 1000)]
        let after = [ticks(90, 50, 1000)]
        guard case .usage(let usage) = CPUTickMath.delta(previous: before, current: after) else {
            Issue.record("应当得到占用")
            return
        }
        #expect(usage.total == nil)
        #expect(usage.perCore == [.counterReset])
    }

    @Test func coreWithoutElapsedTicksIsDropped() {
        let before = [ticks(100, 50, 1000), ticks(200, 0, 800)]
        let after = [ticks(100, 50, 1000), ticks(230, 0, 870)]  // 核 0 没动，但整体不是陈旧
        guard case .usage(let usage) = CPUTickMath.delta(previous: before, current: after) else {
            Issue.record("应当得到占用")
            return
        }
        #expect(usage.perCore == [.noElapsedTicks, .ratio(0.3)])
        #expect(usage.droppedCores == 1)
        #expect(usage.total == 0.3)
    }

    @Test func coreCountChangeRebasesInsteadOfDiffing() {
        let before = [ticks(1, 1, 1)]
        let after = [ticks(2, 2, 2), ticks(3, 3, 3)]
        #expect(CPUTickMath.delta(previous: before, current: after) == .coreCountChanged(previous: 1, current: 2))
    }

    @Test func busyAndTotalDoNotOverflowNearUInt32Max() {
        let big = ticks(.max, .max, .max, .max)
        #expect(big.busy == 3 * UInt64(UInt32.max))
        #expect(big.total == 4 * UInt64(UInt32.max))
    }
}
