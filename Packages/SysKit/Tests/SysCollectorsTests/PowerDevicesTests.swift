// 电源设备（D84）：IOPS 解析、HID 取值与换算、对照与样本。不访问硬件。

import Foundation
import Testing
@testable import SysCollectors
import SysModel

@Suite struct PowerDevicesTests {
    private func parse(_ items: [[String: Any]]) -> [PowerDevice] {
        PowerSourceMonitor.parse(items, accessoryKey: { "h-\($0)" })
    }

    private let ups: [String: Any] = [
        "Type": "UPS", "Name": "Back-UPS Test ", "Transport Type": "USB", "Current Capacity": 87, "Max Capacity": 100,
        "Is Charging": true, "Is Present": true, "Power Source State": "AC Power", "Time to Empty": 27, "Vendor ID": 1309,
        "Product ID": 2, "Voltage": 228_000,
    ]

    private func airpods(group: String = "group-a") -> [[String: Any]] {
        let left: [String: Any] = [
            "Part Identifier": "Left", "Part Name": "AirPods L", "Current Capacity": 90, "Max Capacity": 100, "Is Charging": true,
            "Is Present": true, "Low Warn Level": 20,
        ]
        let right: [String: Any] = [
            "Part Identifier": "Right", "Part Name": "AirPods R", "Current Capacity": 80, "Max Capacity": 100, "Is Present": true,
        ]
        return [
            [
                "Type": "Accessory Source", "Name": "AirPods Pro", "Group Identifier": group, "Part Identifier": "Combined",
                "Combined Parts": [left, right], "Current Capacity": 80, "Max Capacity": 100, "Is Present": true,
                "Transport Type": "Bluetooth LE", "Accessory Category": "Headset", "Power Source State": "AC Power",
            ],
            [
                "Type": "Accessory Source", "Name": "AirPods Pro Case", "Group Identifier": group, "Part Identifier": "Case",
                "Current Capacity": 69, "Max Capacity": 100, "Is Present": true, "Power Source State": "Battery Power",
            ],
        ]
    }

    // MARK: - IOPS 解析

    @Test func parsesUPSWithIOPSUnits() throws {
        let devices = parse([ups])
        let device = try #require(devices.first)
        #expect(device.kind == .ups)
        #expect(device.key.rawValue == "ups:1309:2")
        #expect(device.name == "Back-UPS Test")
        #expect(device.level == 0.87)
        #expect(device.timeToEmpty == 1620)
        #expect(device.inputVoltage == 228)
        #expect(device.powerSourceState == .external)
        // 由电池供电、或刚恢复市电时 IOPS 的 Voltage 是电池电压：不当作输入电压。
        var onBattery = ups
        onBattery["Power Source State"] = "Battery Power"
        onBattery["Voltage"] = 24_000
        #expect(parse([onBattery]).first?.inputVoltage == nil)
        var justBack = ups
        justBack["Voltage"] = 26_000
        #expect(parse([justBack]).first?.inputVoltage == nil)
        #expect(device.isCharging)
    }

    @Test func mergesAccessoryPartsByGroup() throws {
        let devices = parse(airpods())
        #expect(devices.count == 1)
        let device = try #require(devices.first)
        #expect(device.kind == .accessory)
        #expect(device.key.rawValue == "accessory:h-group-a")
        #expect(device.name == "AirPods Pro")
        #expect(device.parts.map(\.role) == [.left, .right, .combined, .case])
        #expect(device.parts[0].lowWarnLevel == 0.2)
        // 合成项优先代表整台设备的电量。
        #expect(device.level == 0.8)
        #expect(device.accessoryCategory == "Headset")
    }

    @Test func accessoryLevelFallsBackToLowestBudWithoutCombined() throws {
        let items: [[String: Any]] = [
            ["Type": "Accessory Source", "Name": "Buds", "Group Identifier": "g", "Part Identifier": "Left", "Current Capacity": 40, "Max Capacity": 100],
            ["Type": "Accessory Source", "Name": "Buds", "Group Identifier": "g", "Part Identifier": "Right", "Current Capacity": 60, "Max Capacity": 100],
            ["Type": "Accessory Source", "Name": "Buds Case", "Group Identifier": "g", "Part Identifier": "Case", "Current Capacity": 10, "Max Capacity": 100],
        ]
        let device = try #require(parse(items).first)
        #expect(device.level == 0.4)
    }

    @Test func caseWithEmptyNameStillJoinsItsGroup() throws {
        var items = airpods()
        items[1]["Name"] = ""
        let devices = parse(items)
        #expect(devices.count == 1)
        #expect(devices[0].parts.contains { $0.role == .case })
    }

    @Test func ignoresUnknownTypesAndAbsentSources() {
        var absent = ups
        absent["Is Present"] = false
        let devices = parse([absent, ["Type": "Something New", "Name": "x", "Current Capacity": 50]])
        #expect(devices.isEmpty)
    }

    @Test func numbersUPSWithSameModel() {
        let devices = parse([ups, ups])
        #expect(devices.map(\.key.rawValue) == ["ups:1309:2", "ups:1309:2:1"])
    }

    @Test func ordersUPSBatteryThenAccessories() {
        let battery: [String: Any] = [
            "Type": "InternalBattery", "Name": "InternalBattery-0", "Current Capacity": 55, "Max Capacity": 100,
            "Power Source State": "Battery Power", "Time to Full Charge": 0, "Time to Empty": 300,
        ]
        let devices = parse(airpods() + [battery, ups])
        #expect(devices.map(\.kind) == [.ups, .internalBattery, .accessory])
        #expect(devices[1].key == .internalBattery)
        #expect(devices[1].timeToEmpty == 18_000)
        #expect(devices[1].timeToFull == nil)
        #expect(devices[1].inputVoltage == nil)
    }

    @Test func iopsMinutesRules() {
        #expect(PowerSourceMonitor.minutes(-1) == nil)
        #expect(PowerSourceMonitor.minutes(0) == nil)
        #expect(PowerSourceMonitor.minutes(65535) == nil)
        #expect(PowerSourceMonitor.minutes(2) == 120)
    }

    // MARK: - HID 取值与换算

    private func element(size: UInt32, logicalMin: Int64, unit: UInt32 = 0, exponent: UInt32 = 0) -> UPSElementInfo {
        UPSElementInfo(usage: 0, collection: 0, reportID: 1, reportSize: size, logicalMin: logicalMin, unit: unit, unitExponent: exponent)
    }

    @Test func voltageLookupDoesNotBorrowAnotherCollection() {
        // 只有 Input 下有 Voltage 的 UPS：电池电压不能借用市电电压
        let input = UPSElementInfo(usage: UPSUsage.voltage, collection: UPSUsage.input, reportID: 1, reportSize: 8)
        let layout = UPSReportLayout(elements: [input])
        #expect(layout.element(UPSUsage.voltage, in: [UPSUsage.battery, UPSUsage.powerSummary], exact: true) == nil)
        #expect(layout.element(UPSUsage.voltage, in: [UPSUsage.input], exact: true) == input)
        // 含义不随集合变的 usage 仍可回退
        #expect(layout.element(UPSUsage.voltage, in: [UPSUsage.battery]) == input)
    }

    @Test func normalizesSignedness() {
        // 8 位、逻辑最小 0 的 230 被读成 −26 时改回无符号（CoreHID 实测）。
        #expect(UPSReportLayout.normalize(-26, element: element(size: 8, logicalMin: 0)) == 230)
        #expect(UPSReportLayout.normalize(230, element: element(size: 8, logicalMin: 0)) == 230)
        // 逻辑最小 < 0 的字段按位宽做符号扩展。
        #expect(UPSReportLayout.normalize(255, element: element(size: 8, logicalMin: -128)) == -1)
        #expect(UPSReportLayout.normalize(-1, element: element(size: 8, logicalMin: -128)) == -1)
    }

    @Test func convertsHIDUnits() {
        let battery = UPSReportLayout.siValue(2728, element: element(size: 16, logicalMin: 0, unit: 0xf0d121, exponent: 5), as: .volt)
        #expect(abs(battery.value - 27.28) < 1e-9)
        #expect(!battery.defaulted)
        let input = UPSReportLayout.siValue(229, element: element(size: 8, logicalMin: 0, unit: 0xf0d121, exponent: 7), as: .volt)
        #expect(abs(input.value - 229) < 1e-9)
        let power = UPSReportLayout.siValue(600, element: element(size: 16, logicalMin: 0, unit: 0xd121, exponent: 7), as: .watt)
        #expect(abs(power.value - 600) < 1e-9)
        let time = UPSReportLayout.siValue(1630, element: element(size: 16, logicalMin: 0, unit: 0x1001), as: .second)
        #expect(time.value == 1630)
        // 缺单位：按默认单位，并标出来。
        let missing = UPSReportLayout.siValue(230, element: element(size: 8, logicalMin: 0), as: .volt)
        #expect(missing.value == 230)
        #expect(missing.defaulted)
        // 负指数（4 位有符号编码 0xE = −2）。
        #expect(UPSReportLayout.exponent(0xE) == -2)
    }

    @Test func findsElementByCollectionPriority() {
        let summary = UPSElementInfo(usage: UPSUsage.voltage, collection: UPSUsage.powerSummary, reportID: 9, reportSize: 16)
        let battery = UPSElementInfo(usage: UPSUsage.voltage, collection: UPSUsage.battery, reportID: 38, reportSize: 16)
        let input = UPSElementInfo(usage: UPSUsage.voltage, collection: UPSUsage.input, reportID: 49, reportSize: 8)
        let layout = UPSReportLayout(elements: [summary, battery, input])
        #expect(layout.element(UPSUsage.voltage, in: [UPSUsage.input]) == input)
        #expect(layout.element(UPSUsage.voltage, in: [UPSUsage.battery, UPSUsage.powerSummary]) == battery)
        #expect(layout.element(UPSUsage.voltage, in: [UPSUsage.output]) == summary)
        #expect(layout.element(UPSUsage.percentLoad) == nil)
    }

    @Test func decodesHIDDate() {
        let date = UPSStaticInfo.decodeHIDDate(21811)
        #expect(date?.year == 2022)
        #expect(date?.month == 9)
        #expect(date?.day == 19)
        #expect(UPSStaticInfo.decodeHIDDate(0) == nil)
        #expect(UPSStaticInfo.decodeHIDDate(42 * 512 + 13 * 32 + 1) == nil)
    }

    // MARK: - 对照与样本

    @Test func comparesHIDWithIOPS() throws {
        let device = try #require(parse([ups]).first)
        let good = UPSTelemetry(time: Date(), inputVoltage: 229, charge: 0.88)
        #expect(UPSTelemetryCollector.compare(good, ups: device).passed)
        let badCharge = UPSTelemetry(time: Date(), inputVoltage: 228, charge: 0.5, flags: .acPresent)
        #expect(!UPSTelemetryCollector.compare(badCharge, ups: device).passed)
        let badVoltage = UPSTelemetry(time: Date(), inputVoltage: -26, charge: 0.87, flags: .acPresent)
        #expect(!UPSTelemetryCollector.compare(badVoltage, ups: device).passed)
        // 放电时两边的电量估算一秒一跳（实测同一时刻差 6 个百分点）：容差内；断电时 HID 输入 0 V 不与 IOPS 比。
        let lagging = UPSTelemetry(time: Date(), inputVoltage: 0, charge: 0.81, flags: .discharging)
        #expect(UPSTelemetryCollector.compare(lagging, ups: device).passed)
        #expect(UPSTelemetryCollector.compare(good, ups: nil).passed)
    }

    @Test func picksPrimaryReadingByModel() {
        func reading(_ vid: Int, _ location: Int) -> UPSTelemetryCollector.Reading {
            .init(
                vendorID: vid, productID: 2, locationID: location, product: "", telemetry: nil, staticInfo: UPSStaticInfo(),
                defaultedUnits: [], missingKeys: [])
        }
        let readings = [reading(99, 1), reading(1309, 2)]
        let device = parse([ups]).first
        #expect(UPSTelemetryCollector.primary(readings, ups: device)?.vendorID == 1309)
        #expect(UPSTelemetryCollector.primary(readings, ups: nil)?.vendorID == 99)
        #expect(UPSTelemetryCollector.primary([], ups: device) == nil)
    }

    @Test func sourceSamplesOnlyForPrimaryUPS() {
        let time = SampleTime(monotonicNanos: 1, wallClock: Date())
        let none = PowerSourceCollector.samples(PowerDeviceSnapshot(time: Date(), devices: parse(airpods()), accessoriesAvailable: true), at: time)
        #expect(none.isEmpty)
        let samples = PowerSourceCollector.samples(PowerDeviceSnapshot(time: Date(), devices: parse([ups]), accessoriesAvailable: true), at: time)
        #expect(samples.first { $0.id == .upsCharge }?.value == 0.87)
        #expect(samples.first { $0.id == .upsRuntime }?.value == 1620)
        #expect(samples.first { $0.id == .upsOnBattery }?.value == 0)
    }

    @Test func loadPowerIsEstimated() {
        let time = SampleTime(monotonicNanos: 1, wallClock: Date())
        let samples = UPSTelemetryCollector.samples(
            UPSTelemetry(time: Date(), load: 0.23, loadPower: 138, inputVoltage: 228, batteryVoltage: 27.3), at: time)
        #expect(samples.first { $0.id == .upsInputVoltage }?.value == 228)
        #expect(samples.first { $0.id == .upsLoadPower }?.quality == .estimated)
        #expect(samples.first { $0.id == .upsLoad }?.quality == .measured)
        let missing = UPSTelemetryCollector.samples(UPSTelemetry(time: Date(), load: 0.23), at: time)
        #expect(missing.first { $0.id == .upsLoadPower }?.quality.isUnavailable == true)
    }
}
