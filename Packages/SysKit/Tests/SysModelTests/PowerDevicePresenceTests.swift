// 电源设备 widget 出厂开关所依据的「有没有 UPS / 电池」与去抖（D89）。

import Foundation
import Testing
import SysModel

@Suite struct PowerDevicePresenceTests {
    private func device(_ kind: PowerDeviceKind, _ key: String) -> PowerDevice {
        PowerDevice(key: PowerDeviceKey(rawValue: key), kind: kind, name: key, parts: [PowerDevicePart(role: .main, level: 0.5)])
    }

    private func snapshot(_ devices: [PowerDevice]) -> PowerDeviceSnapshot {
        PowerDeviceSnapshot(time: .now, devices: devices, accessoriesAvailable: true)
    }

    @Test func upsOrBatteryCountsAccessoriesDoNot() {
        #expect(!snapshot([]).hasUPSOrBattery)
        #expect(!snapshot([device(.accessory, "acc")]).hasUPSOrBattery)
        #expect(snapshot([device(.ups, "ups:1:2")]).hasUPSOrBattery)
        #expect(snapshot([device(.internalBattery, "battery"), device(.accessory, "acc")]).hasUPSOrBattery)
    }

    @Test func appearsImmediately() {
        var latch = PresenceLatch(initial: false)
        let v1 = latch.update(present: true, at: Date(timeIntervalSince1970: 0))
        #expect(v1)
        #expect(latch.pendingDeadline == nil)
    }

    @Test func disappearsOnlyAfterHideDelay() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var latch = PresenceLatch(initial: true, hideDelay: 10)
        let v2 = latch.update(present: false, at: t0)
        #expect(v2)
        #expect(latch.pendingDeadline == t0.addingTimeInterval(10))
        let v3 = latch.update(present: false, at: t0.addingTimeInterval(9.9))
        #expect(v3)
        let v4 = latch.update(present: false, at: t0.addingTimeInterval(10))
        #expect(!v4)
        #expect(latch.pendingDeadline == nil)
    }

    @Test func comingBackCancelsPendingHide() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var latch = PresenceLatch(initial: true, hideDelay: 10)
        latch.update(present: false, at: t0)
        let v5 = latch.update(present: true, at: t0.addingTimeInterval(3))
        #expect(v5)
        #expect(latch.pendingDeadline == nil)
        // 再次消失从头计时
        latch.update(present: false, at: t0.addingTimeInterval(5))
        let v6 = latch.update(present: false, at: t0.addingTimeInterval(14))
        #expect(v6)
        let v7 = latch.update(present: false, at: t0.addingTimeInterval(15))
        #expect(!v7)
    }

    @Test func absentWhileAlreadyHiddenStaysHidden() {
        var latch = PresenceLatch(initial: false)
        let v8 = latch.update(present: false, at: .now)
        #expect(!v8)
        #expect(latch.pendingDeadline == nil)
    }
}
