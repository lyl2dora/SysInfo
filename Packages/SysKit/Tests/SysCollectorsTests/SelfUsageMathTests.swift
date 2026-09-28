// rusage 时间单位换算与本进程 CPU 比例（M0 设计 §5.1、§8）。

import Testing
@testable import SysCollectors

@Suite struct MachTimebaseTests {
    let appleSilicon = MachTimebase(numer: 125, denom: 3)

    @Test func appleSiliconTicksToNanoseconds() {
        // 24 MHz 计时器：1 tick = 125/3 ns
        #expect(appleSilicon.nanoseconds(fromTicks: 0) == 0)
        #expect(appleSilicon.nanoseconds(fromTicks: 3) == 125)
        #expect(appleSilicon.nanoseconds(fromTicks: 24) == 1000)
        #expect(appleSilicon.nanoseconds(fromTicks: 24_000_000) == 1_000_000_000)
        // 不能整除时向下取整
        #expect(appleSilicon.nanoseconds(fromTicks: 1) == 41)
    }

    @Test func identityTimebase() {
        let identity = MachTimebase(numer: 1, denom: 1)
        #expect(identity.nanoseconds(fromTicks: 123_456_789) == 123_456_789)
    }

    @Test func largeValuesStayExact() {
        // 30 天的 tick：先乘后除会超出 64 位，用 128 位中间值仍然精确
        let ticks: UInt64 = 24_000_000 * 86_400 * 30
        #expect(appleSilicon.nanoseconds(fromTicks: ticks) == 1_000_000_000 * 86_400 * 30)
        let huge: UInt64 = 300_000_000_000_000_000  // × 125 超出 UInt64
        #expect(appleSilicon.nanoseconds(fromTicks: huge) == 12_500_000_000_000_000_000)
    }

    @Test func resultBeyondUInt64Saturates() {
        #expect(appleSilicon.nanoseconds(fromTicks: .max) == .max)
    }

    @Test func currentTimebaseIsReadAtRuntime() throws {
        let current = try #require(MachTimebase.current)
        #expect(current.numer > 0 && current.denom > 0)
    }
}

@Suite struct SelfUsageMathTests {
    typealias Baseline = SelfUsageCollector.Baseline

    @Test func ratioIsCPUTimeOverElapsedTime() {
        let previous = Baseline(cpuNanos: 1_000_000, monotonicNanos: 10_000_000_000)
        let current = Baseline(cpuNanos: 251_000_000, monotonicNanos: 11_000_000_000)
        #expect(SelfUsageCollector.cpuRatio(from: previous, to: current) == 0.25)
    }

    @Test func ratioCanExceedOneCore() {
        let previous = Baseline(cpuNanos: 0, monotonicNanos: 0)
        let current = Baseline(cpuNanos: 3_000_000_000, monotonicNanos: 2_000_000_000)
        #expect(SelfUsageCollector.cpuRatio(from: previous, to: current) == 1.5)
    }

    @Test func noRatioWithoutBaselineOrProgress() {
        let current = Baseline(cpuNanos: 5, monotonicNanos: 100)
        #expect(SelfUsageCollector.cpuRatio(from: nil, to: current) == nil)
        // 单调时间没前进
        #expect(SelfUsageCollector.cpuRatio(from: Baseline(cpuNanos: 1, monotonicNanos: 100), to: current) == nil)
        // CPU 时间回退：按复位处理，不钳为 0
        #expect(SelfUsageCollector.cpuRatio(from: Baseline(cpuNanos: 9, monotonicNanos: 50), to: current) == nil)
    }

    @Test func unitsClassifiedAsMachTicksWhenConversionMatches() {
        let timebase = MachTimebase(numer: 125, denom: 3)
        // 240 ms 的 CPU 时间 = 5_760_000 tick
        let source = SelfUsageCollector.classifyCPUUnits(
            rawTicks: 5_760_000, referenceNanos: 240_000_000, timebase: timebase)
        #expect(source == .rusageMachTicks(timebase))
    }

    @Test func unitsClassifiedAsNanosecondsWhenRawMatches() {
        // 内核若改成真正的纳秒：原始值直接与 getrusage 吻合
        let source = SelfUsageCollector.classifyCPUUnits(
            rawTicks: 240_000_000, referenceNanos: 240_100_000, timebase: MachTimebase(numer: 125, denom: 3))
        #expect(source == .rusageNanoseconds)
    }

    @Test func smallCPUTimePicksTheCloserHypothesis() {
        // CPU 时间很短时两种假设都在 2 ms 容差内，取更接近的一种
        let timebase = MachTimebase(numer: 125, denom: 3)
        let source = SelfUsageCollector.classifyCPUUnits(
            rawTicks: 24_000, referenceNanos: 1_000_000, timebase: timebase)  // 24000 tick = 1 ms
        #expect(source == .rusageMachTicks(timebase))
    }

    @Test func unitsUnrecognizedFallsBack() {
        let source = SelfUsageCollector.classifyCPUUnits(
            rawTicks: 1, referenceNanos: 500_000_000, timebase: MachTimebase(numer: 125, denom: 3))
        #expect(source == nil)
    }
}
