// cpu.misc 的中断差分（CPU 模块设计 §5.6）：拆成 IPI、定时器、其余三项；回退按复位处理。

import Testing
@testable import SysCollectors

@Suite struct InterruptRatesTests {
    @Test func ratesSplitIntoThreeParts() {
        let r = InterruptRates.compute(
            previous: InterruptCounts(irq: 100, ipi: 50, timer: 20),
            current: InterruptCounts(irq: 1100, ipi: 550, timer: 220), elapsedNanos: 2_000_000_000)
        #expect(r == .rates(ipi: 250, timer: 100, other: 150))
    }

    @Test func regressionIsAReset() {
        let r = InterruptRates.compute(
            previous: InterruptCounts(irq: 100, ipi: 50, timer: 20),
            current: InterruptCounts(irq: 90, ipi: 60, timer: 30), elapsedNanos: 1_000_000_000)
        #expect(r == .counterReset)
    }

    @Test func negativeRemainderIsAReset() {
        let r = InterruptRates.compute(
            previous: InterruptCounts(irq: 0, ipi: 0, timer: 0),
            current: InterruptCounts(irq: 10, ipi: 8, timer: 8), elapsedNanos: 1_000_000_000)
        #expect(r == .counterReset)
    }

    @Test func zeroElapsedGivesNothing() {
        let c = InterruptCounts(irq: 1, ipi: 0, timer: 0)
        #expect(InterruptRates.compute(previous: c, current: c, elapsedNanos: 0) == nil)
    }
}

@Suite struct InterruptSourcesTests {
    func delta(_ subgroup: String, _ name: String, _ value: Int64) -> IOReportChannelDelta {
        IOReportChannelDelta(
            key: IOReportChannelKey(group: InterruptDeviceCollector.group, subgroup: subgroup, name: name),
            stateResidencies: [], stateNames: [], integerValue: value)
    }

    @Test func deviceNameDropsTrailingIndex() {
        #expect(InterruptDeviceCollector.device("i2c5 0") == "i2c5")
        #expect(InterruptDeviceCollector.device("gfx-asc") == "gfx-asc")
        #expect(InterruptDeviceCollector.device("lan 10gb") == "lan 10gb")
    }

    @Test func mergesByDeviceAndIgnoresOtherChannels() {
        let first = "               First Level Interrupt Handler Count"
        let sources = InterruptDeviceCollector.sources(
            [
                delta("ans 0", first, 30), delta("ans 1", first, 20),
                delta("ans 0", "              Second Level Interrupt Handler Count", 999),
                delta("smc 0", first, 10), delta("lan0 0", first, -5),
            ], elapsedNanos: 10_000_000_000)
        #expect(sources == [InterruptSource(device: "ans", perSecond: 5), InterruptSource(device: "smc", perSecond: 1)])
    }
}
