// 降频信号汇总（K20，M0 设计 §5.3）。

import Testing
@testable import SysCollectors

@Suite struct ThrottlePolicyTests {
    @Test func noSignalsMeansNormal() {
        let result = ThrottlePolicy.evaluate(ThrottleSignals(), automatic: true)
        #expect(result.factor == .normal)
        #expect(result.reasons.isEmpty)
    }

    @Test(arguments: [
        (ThrottleSignals(lowPowerMode: true), ThrottleReason.lowPowerMode),
        (ThrottleSignals(thermalPressure: true), .thermalPressure),
        (ThrottleSignals(onBatteryPower: true), .onBatteryPower),
        (ThrottleSignals(manual: true), .manual),
    ])
    func slowdownSignals(signals: ThrottleSignals, reason: ThrottleReason) {
        let result = ThrottlePolicy.evaluate(signals, automatic: true)
        #expect(result.factor == .slowed(2))
        #expect(result.reasons == [reason])
    }

    @Test func lockOrDisplaySleepPausesAndKeepsAllReasons() {
        let locked = ThrottlePolicy.evaluate(ThrottleSignals(onBatteryPower: true, screenLocked: true), automatic: true)
        #expect(locked.factor == .paused)
        #expect(locked.reasons == [.onBatteryPower, .screenLocked])

        let asleep = ThrottlePolicy.evaluate(ThrottleSignals(displayAsleep: true), automatic: true)
        #expect(asleep.factor == .paused)
        #expect(asleep.reasons == [.displayAsleep])
    }

    @Test func disablingAutomaticIgnoresEverythingButManual() {
        let all = ThrottleSignals(
            lowPowerMode: true, thermalPressure: true, onBatteryPower: true, screenLocked: true, displayAsleep: true)
        #expect(ThrottlePolicy.evaluate(all, automatic: false).factor == .normal)
        #expect(ThrottlePolicy.evaluate(all, automatic: false).reasons.isEmpty)

        var manual = all
        manual.manual = true
        let result = ThrottlePolicy.evaluate(manual, automatic: false)
        #expect(result.factor == .slowed(2))
        #expect(result.reasons == [.manual])
    }
}

@Suite struct SessionStateTests {
    @Test func screenLockedKeyIsReadDefensively() {
        #expect(SessionState.screenLocked(inSessionDictionary: [SessionState.screenIsLockedKey: 1]))
        #expect(SessionState.screenLocked(inSessionDictionary: [SessionState.screenIsLockedKey: true]))
        #expect(!SessionState.screenLocked(inSessionDictionary: [SessionState.screenIsLockedKey: 0]))
        // 未锁屏时这个键不存在
        #expect(!SessionState.screenLocked(inSessionDictionary: ["kCGSessionOnConsoleKey": 1]))
        #expect(!SessionState.screenLocked(inSessionDictionary: [SessionState.screenIsLockedKey: "yes"]))
    }
}
