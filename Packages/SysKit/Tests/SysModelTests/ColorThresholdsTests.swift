// 菜单栏即时着色（D42）：按显示出来的整数判定。
// 持续判定（D32，留给 P2 的提醒）：持续 10 s 才升级、滞回降级、不可用与长间隔清零。

import Testing
import SysModel

@Suite struct DisplayedLevelTests {
    @Test func followsTheDisplayedInteger() {
        let t = ColorThresholds.cpuDefault
        #expect(t.displayedLevel(forRatio: 0.8449) == .normal)  // 显示 84%
        #expect(t.displayedLevel(forRatio: 0.8451) == .warning)  // 显示 85%
        #expect(t.displayedLevel(forRatio: 0.9449) == .warning)  // 显示 94%
        #expect(t.displayedLevel(forRatio: 0.9451) == .critical)  // 显示 95%
        #expect(t.displayedLevel(forRatio: 1.0) == .critical)
    }

    @Test func noSustainNoHysteresis() {
        let t = ColorThresholds.cpuDefault
        // 无状态：同一个值无论前后是什么，结果都一样。
        #expect(t.displayedLevel(forRatio: 0.97) == .critical)
        #expect(t.displayedLevel(forRatio: 0.84) == .normal)
        #expect(t.displayedLevel(forRatio: 0.86) == .warning)
    }

    @Test func unavailableIsNormal() {
        let t = ColorThresholds.cpuDefault
        #expect(t.displayedLevel(forRatio: nil) == .normal)
        #expect(t.displayedLevel(forRatio: .nan) == .normal)
    }

    @Test func customThresholds() {
        let t = ColorThresholds(warning: 0.70, critical: 0.70)
        #expect(t.displayedLevel(forRatio: 0.6951) == .critical)  // 显示 70%，两级同值时取高
        #expect(t.displayedLevel(forRatio: 0.6949) == .normal)
    }
}

@Suite struct SustainedLevelTrackerTests {
    @Test func upgradesOnlyAfterSustain() {
        var t = SustainedLevelTracker(thresholds: .cpuDefault)
        for s in 0..<10 { #expect(t.update(0.9, at: Double(s)) == .normal) }
        #expect(t.update(0.9, at: 10) == .warning)
    }

    @Test func briefDipResetsTheTimer() {
        var t = SustainedLevelTracker(thresholds: .cpuDefault)
        for s in 0..<8 { t.update(0.9, at: Double(s)) }
        t.update(0.5, at: 8)
        for s in 9..<18 { t.update(0.9, at: Double(s)) }
        #expect(t.level == .normal)
        #expect(t.update(0.9, at: 19) == .warning)
    }

    @Test func criticalAndHysteresis() {
        var t = SustainedLevelTracker(thresholds: .cpuDefault)
        for s in 0...10 { t.update(0.97, at: Double(s)) }
        #expect(t.level == .critical)
        #expect(t.update(0.92, at: 11) == .critical)  // 0.92 ≥ 0.95 − 0.05
        #expect(t.update(0.89, at: 12) == .warning)  // 仍 ≥ 0.85 − 0.05
        #expect(t.update(0.79, at: 13) == .normal)
    }

    @Test func unavailableAndGapsReset() {
        var t = SustainedLevelTracker(thresholds: .cpuDefault)
        for s in 0...10 { t.update(0.9, at: Double(s)) }
        #expect(t.level == .warning)
        #expect(t.update(nil, at: 11) == .normal)
        for s in 12...22 { t.update(0.9, at: Double(s)) }
        #expect(t.level == .warning)
        #expect(t.update(0.9, at: 100) == .normal)
    }
}
