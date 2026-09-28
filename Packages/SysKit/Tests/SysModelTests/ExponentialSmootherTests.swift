// 菜单栏数字的 EMA 平滑（K24）。

import Foundation
import Testing
import SysModel

@Suite struct ExponentialSmootherTests {
    private static let second: UInt64 = 1_000_000_000

    @Test func firstValuePassesThrough() {
        var ema = ExponentialSmoother(timeConstant: 1.5)
        let r1 = ema.update(0.4, atNanos: Self.second)
        #expect(r1 == 0.4)
        #expect(ema.value == 0.4)
    }

    @Test func weightFollowsElapsedTime() {
        var ema = ExponentialSmoother(timeConstant: 1)
        ema.update(0, atNanos: 0)
        // Δt = τ：alpha = 1 − 1/e
        let smoothed = ema.update(1, atNanos: Self.second) ?? .nan
        #expect(abs(smoothed - (1 - exp(-1))) < 1e-12)

        // 同样的跳变，Δt = 2τ 时更接近新值
        var slower = ExponentialSmoother(timeConstant: 1)
        slower.update(0, atNanos: 0)
        let smoothed2 = slower.update(1, atNanos: 2 * Self.second) ?? .nan
        #expect(smoothed2 > smoothed)
    }

    @Test func steadyInputStaysSteady() {
        var ema = ExponentialSmoother(timeConstant: 1.5)
        for t in UInt64(0)..<20 {
            ema.update(0.25, atNanos: t * Self.second)
        }
        #expect(abs((ema.value ?? 0) - 0.25) < 1e-12)
    }

    @Test func unavailableInputClearsState() {
        var ema = ExponentialSmoother(timeConstant: 1.5)
        ema.update(0.9, atNanos: 0)
        let r2 = ema.update(nil, atNanos: Self.second)
        #expect(r2 == nil)
        #expect(ema.value == nil)
        // 恢复后不和不可用之前的旧值混合
        let r3 = ema.update(0.1, atNanos: 2 * Self.second)
        #expect(r3 == 0.1)
        let r4 = ema.update(.nan, atNanos: 3 * Self.second)
        #expect(r4 == nil)
    }

    @Test func longGapResets() {
        var ema = ExponentialSmoother(timeConstant: 1, resetAfter: 5)
        ema.update(0.9, atNanos: 0)
        let r5 = ema.update(0.1, atNanos: 6 * Self.second)
        #expect(r5 == 0.1)
    }

    @Test func nonAdvancingClockTakesNewValue() {
        var ema = ExponentialSmoother(timeConstant: 1)
        ema.update(0.9, atNanos: 5 * Self.second)
        let r6 = ema.update(0.1, atNanos: 5 * Self.second)
        #expect(r6 == 0.1)
    }
}
