// 到期计算（M0 设计 §5.2、§8）：多个需求、整数倍间隔、降频因子、暂停。

import SysModel
import Testing
@testable import SysCollectors

@Suite struct ScheduleTests {
    let cpu: CollectorID = "cpu.load"
    let selfUsage: CollectorID = "app.self"
    var available: Set<CollectorID> { [cpu, selfUsage] }

    // MARK: 有效间隔

    @Test func shortestIntervalWinsAcrossDemands() {
        let demands = [
            Demand(collectors: [cpu], interval: 5, source: .menubarCPU),
            Demand(collectors: [cpu, selfUsage], interval: 2, source: .panel),
        ]
        let intervals = Schedule.effectiveIntervals(for: demands, throttle: .normal, available: available)
        #expect(intervals == [cpu: 2, selfUsage: 2])
    }

    @Test func unknownCollectorsAreIgnored() {
        let demands = [Demand(collectors: ["gpu.load", cpu], interval: 1, source: .panel)]
        #expect(Schedule.effectiveIntervals(for: demands, throttle: .normal, available: available) == [cpu: 1])
    }

    @Test func intervalBelowOneIsClampedToOne() {
        #expect(Demand(collectors: [cpu], interval: 0, source: .panel).interval == 1)
        #expect(Demand(collectors: [cpu], interval: -3, source: .panel).interval == 1)
    }

    @Test func throttleFactorMultipliesAllIntervals() {
        let demands = [
            Demand(collectors: [cpu], interval: 1, source: .menubarCPU),
            Demand(collectors: [selfUsage], interval: 5, source: .diagnostics),
        ]
        #expect(
            Schedule.effectiveIntervals(for: demands, throttle: .slowed(2), available: available)
                == [cpu: 2, selfUsage: 10])
        // 倍数小于 2 等于不降频
        #expect(
            Schedule.effectiveIntervals(for: demands, throttle: .slowed(1), available: available)
                == [cpu: 1, selfUsage: 5])
        #expect(
            Schedule.effectiveIntervals(for: demands, throttle: .slowed(0), available: available)
                == [cpu: 1, selfUsage: 5])
    }

    @Test func pausedKeepsOnlyBackgroundDemands() {
        let foreground = Demand(collectors: [cpu], interval: 1, source: .menubarCPU)
        let background = Demand(collectors: [selfUsage], interval: 60, source: "history", tier: .background)
        #expect(Schedule.effectiveIntervals(for: [foreground], throttle: .paused, available: available).isEmpty)
        #expect(
            Schedule.effectiveIntervals(for: [foreground, background], throttle: .paused, available: available)
                == [selfUsage: 60])
    }

    @Test func hugeIntervalTimesFactorSaturates() {
        let demand = Demand(collectors: [cpu], interval: .max, source: .panel)
        #expect(Schedule.effectiveInterval(of: demand, under: .slowed(2)) == .max)
    }

    // MARK: 到期

    @Test func collectorsAreDueOnMultiplesOfTheirInterval() {
        let intervals: [CollectorID: Int] = [cpu: 1, selfUsage: 5]
        #expect(Schedule.dueCollectors(at: 1_790_000_000, intervals: intervals, pendingBaseline: []) == [selfUsage, cpu])
        #expect(Schedule.dueCollectors(at: 1_790_000_001, intervals: intervals, pendingBaseline: []) == [cpu])
        #expect(Schedule.dueCollectors(at: 1_790_000_005, intervals: intervals, pendingBaseline: []) == [selfUsage, cpu])
    }

    @Test func pendingBaselineRunsOnTheNextTickRegardlessOfInterval() {
        let intervals: [CollectorID: Int] = [cpu: 5]
        #expect(Schedule.dueCollectors(at: 7, intervals: intervals, pendingBaseline: [cpu]) == [cpu])
        #expect(Schedule.dueCollectors(at: 7, intervals: intervals, pendingBaseline: []).isEmpty)
        // 没有需求的采集器即使在 pendingBaseline 里也不跑
        #expect(Schedule.dueCollectors(at: 7, intervals: intervals, pendingBaseline: [selfUsage]).isEmpty)
    }

    // MARK: 下一次唤醒

    @Test func nextTickIsTheEarliestDueTick() {
        #expect(Schedule.nextTick(after: 10, intervals: [cpu: 1], pendingBaseline: []) == 11)
        #expect(Schedule.nextTick(after: 10, intervals: [cpu: 5], pendingBaseline: []) == 15)
        #expect(Schedule.nextTick(after: 14, intervals: [cpu: 5, selfUsage: 3], pendingBaseline: []) == 15)
        #expect(Schedule.nextTick(after: 15, intervals: [cpu: 5, selfUsage: 3], pendingBaseline: []) == 18)
        // 间隔都是 5 时，中间的 4 个整秒不唤醒
        #expect(Schedule.nextTick(after: 20, intervals: [cpu: 5, selfUsage: 5], pendingBaseline: []) == 25)
    }

    @Test func nextTickIsImmediateWhenABaselineIsPending() {
        #expect(Schedule.nextTick(after: 10, intervals: [cpu: 5], pendingBaseline: [cpu]) == 11)
        #expect(Schedule.nextTick(after: 10, intervals: [cpu: 5], pendingBaseline: [selfUsage]) == 15)
    }

    @Test func noDemandMeansNoWakeup() {
        #expect(Schedule.nextTick(after: 10, intervals: [:], pendingBaseline: []) == nil)
        #expect(Schedule.nextTick(after: 10, intervals: [:], pendingBaseline: [cpu]) == nil)
    }

    @Test func pausedDemandsProduceNoWakeup() {
        let demands = [Demand(collectors: [cpu], interval: 1, source: .menubarCPU)]
        let intervals = Schedule.effectiveIntervals(for: demands, throttle: .paused, available: available)
        #expect(Schedule.nextTick(after: 10, intervals: intervals, pendingBaseline: []) == nil)
    }

    @Test func nextMultipleHandlesNegativeTicks() {
        #expect(Schedule.nextMultiple(of: 5, after: -1) == 0)
        #expect(Schedule.nextMultiple(of: 5, after: -5) == 0)
        #expect(Schedule.nextMultiple(of: 5, after: -6) == -5)
        #expect(Schedule.nextMultiple(of: 5, after: 0) == 5)
    }

    // MARK: 网格

    @Test func gridAlignsTicksToWholeSecondsPlusOffset() {
        let grid = TickGrid(offsetNanos: 50_000_000)
        #expect(grid.unixNanos(of: 100) == 100_050_000_000)
        #expect(grid.tick(atOrBefore: 100_050_000_000) == 100)
        #expect(grid.tick(atOrBefore: 100_049_999_999) == 99)
        #expect(grid.tick(atOrBefore: 100_999_000_000) == 100)
        #expect(grid.tick(atOrBefore: 0) == -1)
    }

    @Test func searchStartAvoidsRunningTheSameTickTwice() {
        // 定时器按单调时钟触发，墙钟读数可能还差几毫秒没到这个 tick
        #expect(TickGrid.searchStart(current: 99, lastRun: 100) == 100)
        #expect(TickGrid.searchStart(current: 100, lastRun: 100) == 100)
        #expect(TickGrid.searchStart(current: 105, lastRun: 100) == 105)
        #expect(TickGrid.searchStart(current: 50, lastRun: nil) == 50)
        // 墙钟被往回大幅调整：以现在为准，不等上一次执行的 tick
        #expect(TickGrid.searchStart(current: 10, lastRun: 3600) == 10)
    }
}
