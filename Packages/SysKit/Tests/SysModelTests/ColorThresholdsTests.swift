// 占用着色的持续判定（D32）：持续 10 s 才升级、滞回降级、不可用与长间隔清零。

import Testing
import SysModel

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
