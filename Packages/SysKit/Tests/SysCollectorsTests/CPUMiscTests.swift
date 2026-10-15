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
