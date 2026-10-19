// 电源设备的硬件测试（电源设备设计 §8，D84）：读真实机器，默认跳过，`make test-hw` 运行。
// 有 UPS 时 HID 与 IOPS 对照；没有任何设备时（M4 对照机）两个采集器正常返回空，自检通过。

import Foundation
import SysModel
import Testing
@testable import SysCollectors

@Suite(.tags(.hardware), .hardwareOnly)
struct PowerDevicesHardwareTests {
    @Test func sourcesSelfTestIsUsable() {
        let collector = PowerSourceCollector(monitor: PowerSourceMonitor())
        #expect(collector.selfTest().isUsable)
    }

    @Test func upsTelemetryMatchesIOPSOrIsAbsent() throws {
        let monitor = PowerSourceMonitor()
        let ups = UPSTelemetryCollector(monitor: monitor)
        let result = ups.selfTest()
        #expect(result.isUsable, "\(result.checks)")
        let output = ups.sample(at: .now())
        guard let device = monitor.latest.primaryUPS else {
            // 没有 UPS：不输出样本，也不打开 HID 设备。
            #expect(output.samples.isEmpty)
            #expect(ups.readings.isEmpty)
            return
        }
        let reading = try #require(UPSTelemetryCollector.primary(ups.readings, ups: device))
        let telemetry = try #require(reading.telemetry)
        #expect(UPSTelemetryCollector.compare(telemetry, ups: device).passed)
        if let load = telemetry.load { #expect((0...1.5).contains(load)) }
        if let battery = telemetry.batteryVoltage { #expect((5...100).contains(battery)) }
        // 有额定功率时负载功率是估算值。
        if reading.staticInfo.ratedActivePower != nil, telemetry.load != nil {
            #expect(output.samples.first { $0.id == .upsLoadPower }?.quality == .estimated)
        }
    }

    @Test func snapshotNeverTreatsUPSAsBattery() {
        let snapshot = PowerSourceMonitor.read()
        for device in snapshot.devices where device.kind == .internalBattery {
            #expect(device.vendorID == nil || device.transport == "Internal" || device.transport == nil)
        }
        #expect(snapshot.devices.filter { $0.kind == .ups }.allSatisfy { $0.key.rawValue.hasPrefix("ups:") })
    }
}
