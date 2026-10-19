// UPS 扩展遥测采集器 `devices.ups`（电源设备设计 §4.3，D84 PD2、PD3）：blocking 通道（USB 往返，墙钟几毫秒）。
//
// - 公开 IOHIDManager，匹配限定 `PrimaryUsagePage = 0x84`（D22），只读：只发 GET_REPORT，不写设备；
// - 报告由内核解析：每个报告只对其中一个元素用 `kIOHIDDeviceGetValueWithUpdate`，其余元素读内核刚更新的值；
// - 每次采样读常用项（电量、剩余时间、负载、输入 / 电池电压、状态位）；额定值、阈值、生产日期、自检结果在设备接入
//   与 `refreshStatic()`（面板打开时）读一次；
// - 只在有需求时打开 HID manager，180 s 没有采样就关闭。要长于历史的 60 s 间隔，否则后台每次采样都赶上刚关闭，
//   每分钟重开一次（重新枚举设备与约 260 个元素、重读静态项）。开着闲置时不占 CPU（实测 20 s 不到 0.2 ms）；
// - 自检：HID 的电量、输入电压与 IOPS 的同一台 UPS 对照（IOPS 就是系统从同一台设备读的）。没有 UPS 时通过（无设备不是失败）。
//   运行中连续 3 次对照不一致 → 输出不可用，引擎随后复检。

import Foundation
import IOKit.hid
import os
import Synchronization
import SysModel

public final class UPSTelemetryCollector: Collector {
    public static let collectorID: CollectorID = "devices.ups"
    public static let dataPath = "IOHIDManager（usage page 0x84，GET_REPORT feature）"
    /// 自检与运行中对照的容差。
    /// 电量容差放宽到 10 个百分点：放电时 IOPS 与 HID 的估算一秒一跳，同一时刻实测差到 6 个百分点（2026-10-19）。
    /// 对照只为抓解码错误这类大偏差。
    static let chargeTolerance = 0.10
    static let voltageTolerance = 2.0
    static let mismatchLimit = 3
    /// 这么久没有采样就关掉 HID manager（长于历史的 60 s 间隔，后台采样之间不关）。
    static let idleClose: DispatchTimeInterval = .seconds(180)

    public var id: CollectorID { Self.collectorID }
    public var lane: CollectorLane { .blocking }

    /// 一台 UPS 的最新读数。
    public struct Reading: Hashable, Sendable {
        /// 与 IOPS 设备对应用的 Vendor / Product ID 与 location ID（只在内存里用）。
        public var vendorID: Int
        public var productID: Int
        public var locationID: Int
        public var product: String
        public var telemetry: UPSTelemetry?
        public var staticInfo: UPSStaticInfo
        /// 按默认单位换算的字段（诊断页标出来）。
        public var defaultedUnits: [String]
        /// 报告里找不到的关键项。
        public var missingKeys: [String]
    }

    /// 诊断信息。
    public struct Diagnostics: Hashable, Sendable {
        public var managerOpen: Bool
        public var deviceCount: Int
        public var elementCount: Int
        /// 最近一次对照：HID 与 IOPS 的电量、输入电压。
        public var lastComparison: String
        public var mismatchStreak: Int
    }

    private struct State {
        var readings: [Reading] = []
        /// 主 UPS 的读数下标。
        var primaryIndex: Int?
        var mismatchStreak = 0
        var lastComparison = ""
        var staticRefreshRequested = true
        var managerOpen = false
        var deviceCount = 0
        var elementCount = 0
        var lastSample: ContinuousClock.Instant?
    }

    /// 一台已打开的设备：元素表与 IOHIDElement 句柄。
    private struct Entry {
        var registryID: UInt64
        var device: IOHIDDevice
        var layout: UPSReportLayout
        var handles: [UPSElementInfo: IOHIDElement]
        var reading: Reading
    }

    private let state = Mutex(State())
    private let monitor: PowerSourceMonitor
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "sysinfo-cli", category: "devices")
    /// HID 对象只在持有 `hidLock` 时访问（采样在引擎的 blocking 队列，空闲关闭在计时器队列）。
    private let hidLock = NSLock()
    private nonisolated(unsafe) var manager: IOHIDManager?
    private nonisolated(unsafe) var entries: [Entry] = []
    private let hidQueue = DispatchQueue(label: "zone.lyl.sysinfo.devices.hid", qos: .utility)
    private nonisolated(unsafe) var idleTimer: DispatchSourceTimer?

    public init(monitor: PowerSourceMonitor = .shared) {
        self.monitor = monitor
    }

    deinit {
        hidLock.withLock { closeManagerLocked() }
    }

    /// 全部 UPS 的最新读数（按 location ID 排序）。
    public var readings: [Reading] { state.withLock { $0.readings } }

    /// 主 UPS（与 IOPS 主 UPS 对应的那台）的读数。
    public var primaryReading: Reading? {
        state.withLock { s in s.primaryIndex.flatMap { s.readings.indices.contains($0) ? s.readings[$0] : nil } }
    }

    public var diagnostics: Diagnostics {
        state.withLock {
            Diagnostics(
                managerOpen: $0.managerOpen, deviceCount: $0.deviceCount, elementCount: $0.elementCount,
                lastComparison: $0.lastComparison, mismatchStreak: $0.mismatchStreak)
        }
    }

    /// 下一次采样时重读静态项（面板打开时调用）。
    public func refreshStatic() {
        state.withLock { $0.staticRefreshRequested = true }
    }

    // MARK: - Collector

    public func selfTest() -> SelfTestResult {
        let readings = hidLock.withLock { () -> [Reading] in
            openManagerIfNeededLocked()
            syncDevicesLocked()
            return readAllLocked(includeStatic: true)
        }
        let ups = monitor.refresh().primaryUPS
        var checks = [
            SelfTestCheck(
                name: "devices.ups.hid", passed: true,
                detail: readings.isEmpty ? "no UPS on usage page 0x84" : "\(readings.count) UPS")
        ]
        if let primary = Self.primary(readings, ups: ups), let telemetry = primary.telemetry {
            let comparison = Self.compare(telemetry, ups: ups)
            checks.append(SelfTestCheck(name: "devices.ups.compare", passed: comparison.passed, detail: comparison.detail))
            checks.append(
                SelfTestCheck(
                    name: "devices.ups.keys", passed: primary.missingKeys.isEmpty,
                    detail: primary.missingKeys.isEmpty ? "all key elements found" : "missing \(primary.missingKeys.joined(separator: ","))",
                    severity: .advisory))
            state.withLock {
                $0.lastComparison = comparison.detail
                $0.mismatchStreak = comparison.passed ? 0 : Self.mismatchLimit
            }
        } else if !readings.isEmpty {
            checks.append(SelfTestCheck(name: "devices.ups.compare", passed: false, detail: "HID read failed"))
            state.withLock { $0.mismatchStreak = Self.mismatchLimit }
        }
        publish(readings, ups: ups)
        scheduleIdleClose()
        return SelfTestResult(checks: checks, dataPath: Self.dataPath)
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        let includeStatic = state.withLock { s -> Bool in
            s.lastSample = .now
            defer { s.staticRefreshRequested = false }
            return s.staticRefreshRequested
        }
        let readings = hidLock.withLock { () -> [Reading] in
            openManagerIfNeededLocked()
            syncDevicesLocked()
            return readAllLocked(includeStatic: includeStatic)
        }
        scheduleIdleClose()
        let ups = monitor.latest.primaryUPS
        publish(readings, ups: ups)
        guard let primary = Self.primary(readings, ups: ups) else {
            // 没有 UPS：不输出样本（设备不存在，不是不可用）。
            return CollectorOutput(samples: [], status: .ok, dataPath: Self.dataPath)
        }
        guard let telemetry = primary.telemetry else {
            return CollectorOutput(
                samples: Self.unavailableSamples(.readFailed("GET_REPORT failed"), at: time), status: .unavailable,
                dataPath: Self.dataPath)
        }
        let comparison = Self.compare(telemetry, ups: ups)
        let streak = state.withLock { s -> Int in
            s.lastComparison = comparison.detail
            s.mismatchStreak = comparison.passed ? 0 : s.mismatchStreak + 1
            return s.mismatchStreak
        }
        guard streak < Self.mismatchLimit else {
            return CollectorOutput(
                samples: Self.unavailableSamples(.selfTestFailed(comparison.detail), at: time), status: .unavailable,
                dataPath: Self.dataPath)
        }
        return CollectorOutput(samples: Self.samples(telemetry, at: time), status: .ok, dataPath: Self.dataPath)
    }

    public func resetBaseline() {}

    // MARK: - 样本

    static func samples(_ telemetry: UPSTelemetry, at time: SampleTime) -> [Sample] {
        [
            telemetry.load.map { Sample(id: .upsLoad, value: $0, time: time) }
                ?? .unavailable(.upsLoad, reason: .readFailed("no PercentLoad"), at: time),
            telemetry.loadPower.map { Sample(id: .upsLoadPower, value: $0, quality: .estimated, time: time) }
                ?? .unavailable(.upsLoadPower, reason: .readFailed("no rated power"), at: time),
            telemetry.batteryVoltage.map { Sample(id: .upsBatteryVoltage, value: $0, time: time) }
                ?? .unavailable(.upsBatteryVoltage, reason: .readFailed("no battery voltage"), at: time),
            telemetry.inputVoltage.map { Sample(id: .upsInputVoltage, value: $0, time: time) }
                ?? .unavailable(.upsInputVoltage, reason: .readFailed("no input voltage"), at: time),
        ]
    }

    static func unavailableSamples(_ reason: UnavailableReason, at time: SampleTime) -> [Sample] {
        [.upsLoad, .upsLoadPower, .upsBatteryVoltage, .upsInputVoltage].map { .unavailable($0, reason: reason, at: time) }
    }

    /// 与 IOPS 的主 UPS 对应的读数：Vendor / Product 相同的第一台；IOPS 没有 UPS 时取第一台。
    static func primary(_ readings: [Reading], ups: PowerDevice?) -> Reading? {
        guard let ups, let vid = ups.vendorID, let pid = ups.productID else { return readings.first }
        return readings.first { $0.vendorID == vid && $0.productID == pid } ?? readings.first
    }

    /// HID 与 IOPS 对照：电量差 ≤ 10 个百分点；输入电压只在两边都是外接电源时比（差 ≤ 2 V）。
    static func compare(_ telemetry: UPSTelemetry, ups: PowerDevice?) -> (passed: Bool, detail: String) {
        guard let ups else { return (true, "no IOPS UPS to compare") }
        var parts: [String] = []
        var passed = true
        if let hid = telemetry.charge, let iops = ups.level {
            let ok = abs(hid - iops) <= chargeTolerance
            passed = passed && ok
            parts.append(String(format: "charge hid=%.0f%% iops=%.0f%%%@", hid * 100, iops * 100, ok ? "" : " ✗"))
        }
        if let hid = telemetry.inputVoltage, let iops = ups.inputVoltage, telemetry.flags.contains(.acPresent) {
            let ok = abs(hid - iops) <= voltageTolerance
            passed = passed && ok
            parts.append(String(format: "input hid=%.1fV iops=%.1fV%@", hid, iops, ok ? "" : " ✗"))
        }
        return (passed, parts.isEmpty ? "nothing to compare" : parts.joined(separator: ", "))
    }

    private func publish(_ readings: [Reading], ups: PowerDevice?) {
        let primary = Self.primary(readings, ups: ups)
        state.withLock { s in
            s.readings = readings
            s.primaryIndex = primary.flatMap { p in readings.firstIndex { $0.locationID == p.locationID && $0.vendorID == p.vendorID } }
        }
    }

    // MARK: - HID manager

    private func openManagerIfNeededLocked() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDPrimaryUsagePageKey: Int(UPSUsage.powerDevice)] as CFDictionary)
        IOHIDManagerSetDispatchQueue(manager, hidQueue)
        IOHIDManagerActivate(manager)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            logger.notice("IOHIDManagerOpen 返回 0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public)")
        }
        self.manager = manager
        state.withLock { $0.managerOpen = true }
    }

    private func closeManagerLocked() {
        guard let manager else { return }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerCancel(manager)
        self.manager = nil
        entries = []
        state.withLock {
            $0.managerOpen = false
            $0.staticRefreshRequested = true
        }
    }

    /// 60 s 没有采样就关掉 manager（下次采样再开）。
    private func scheduleIdleClose() {
        hidQueue.async { [weak self] in
            guard let self else { return }
            self.idleTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.hidQueue)
            timer.schedule(deadline: .now() + Self.idleClose)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let idle = self.state.withLock { s in
                    s.lastSample.map { ContinuousClock.now - $0 >= .seconds(179) } ?? true
                }
                guard idle else { return }
                self.hidLock.withLock { self.closeManagerLocked() }
            }
            self.idleTimer = timer
            timer.resume()
        }
    }

    /// 让设备表跟上 manager 当前匹配到的设备（接入、移除）。
    private func syncDevicesLocked() {
        guard let manager else { return }
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        var current: [UInt64: IOHIDDevice] = [:]
        for device in devices {
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
            current[id] = device
        }
        let known = Set(entries.map(\.registryID))
        guard Set(current.keys) != known else { return }
        entries.removeAll { current[$0.registryID] == nil }
        for (id, device) in current where !known.contains(id) {
            entries.append(makeEntry(device, registryID: id))
        }
        entries.sort { $0.reading.locationID < $1.reading.locationID }
        let elementCount = entries.reduce(0) { $0 + $1.layout.elements.count }
        state.withLock {
            $0.deviceCount = self.entries.count
            $0.elementCount = elementCount
        }
        logger.info("UPS（HID）设备变化：\(self.entries.count, privacy: .public) 台")
    }

    private func makeEntry(_ device: IOHIDDevice, registryID: UInt64) -> Entry {
        func intProperty(_ key: String) -> Int { (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0 }
        var infos: [UPSElementInfo] = []
        var handles: [UPSElementInfo: IOHIDElement] = [:]
        let elements = (IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement]) ?? []
        for element in elements where IOHIDElementGetType(element) == kIOHIDElementTypeFeature {
            let page = IOHIDElementGetUsagePage(element)
            guard page == UPSUsage.powerDevice || page == UPSUsage.batterySystem else { continue }
            let parent = IOHIDElementGetParent(element)
            let info = UPSElementInfo(
                usage: UPSUsage.key(page, IOHIDElementGetUsage(element)),
                collection: parent.map { UPSUsage.key(IOHIDElementGetUsagePage($0), IOHIDElementGetUsage($0)) } ?? 0,
                reportID: IOHIDElementGetReportID(element), reportSize: IOHIDElementGetReportSize(element),
                reportCount: IOHIDElementGetReportCount(element), logicalMin: Int64(IOHIDElementGetLogicalMin(element)),
                unit: IOHIDElementGetUnit(element), unitExponent: IOHIDElementGetUnitExponent(element))
            // 同一描述的重复元素（不同集合里同名的会因 collection 不同而区分）只留第一份。
            if handles[info] == nil {
                infos.append(info)
                handles[info] = element
            }
        }
        let product = ((IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "")
            .trimmingCharacters(in: .whitespaces)
        let reading = Reading(
            vendorID: intProperty(kIOHIDVendorIDKey), productID: intProperty(kIOHIDProductIDKey),
            locationID: intProperty(kIOHIDLocationIDKey), product: product, telemetry: nil, staticInfo: UPSStaticInfo(),
            defaultedUnits: [], missingKeys: [])
        return Entry(registryID: registryID, device: device, layout: UPSReportLayout(elements: infos), handles: handles, reading: reading)
    }

    // MARK: - 读取

    private func readAllLocked(includeStatic: Bool) -> [Reading] {
        let now = Date()
        for index in entries.indices {
            var entry = entries[index]
            let staticNeeded = includeStatic || entry.reading.staticInfo == UPSStaticInfo()
            let result = Self.read(entry, includeStatic: staticNeeded, now: now)
            entry.reading.telemetry = result.telemetry
            if let info = result.staticInfo { entry.reading.staticInfo = info }
            entry.reading.defaultedUnits = result.defaulted
            entry.reading.missingKeys = result.missing
            // 负载功率要用额定功率：静态项刚读到时补上。
            if var telemetry = entry.reading.telemetry, let load = telemetry.load, let rated = entry.reading.staticInfo.ratedActivePower {
                telemetry.loadPower = load * rated
                entry.reading.telemetry = telemetry
            }
            entries[index] = entry
        }
        return entries.map(\.reading)
    }

    /// 要读的一项：usage、集合优先级、物理量、标签（诊断用）。
    struct Field {
        var usage: UInt32
        var collections: [UInt32]
        var quantity: UPSReportLayout.Quantity
        var label: String
    }

    static let summaryFirst = [UPSUsage.powerSummary, UPSUsage.battery]
    static let statusFirst = [UPSUsage.presentStatus, UPSUsage.powerSummary]

    static let coreFields: [Field] = [
        Field(usage: UPSUsage.remainingCapacity, collections: summaryFirst, quantity: .plain, label: "RemainingCapacity"),
        Field(usage: UPSUsage.fullChargeCapacity, collections: summaryFirst, quantity: .plain, label: "FullChargeCapacity"),
        Field(usage: UPSUsage.capacityMode, collections: summaryFirst, quantity: .plain, label: "CapacityMode"),
        Field(usage: UPSUsage.runTimeToEmpty, collections: summaryFirst, quantity: .second, label: "RunTimeToEmpty"),
        Field(usage: UPSUsage.percentLoad, collections: [UPSUsage.powerConverter, UPSUsage.output], quantity: .plain, label: "PercentLoad"),
        Field(usage: UPSUsage.voltage, collections: [UPSUsage.input], quantity: .volt, label: "Input.Voltage"),
        Field(usage: UPSUsage.voltage, collections: [UPSUsage.battery, UPSUsage.powerSummary], quantity: .volt, label: "Battery.Voltage"),
    ]

    static let flagFields: [(UInt32, UPSStatusFlags)] = [
        (UPSUsage.acPresent, .acPresent), (UPSUsage.charging, .charging), (UPSUsage.discharging, .discharging),
        (UPSUsage.needReplacement, .needReplacement), (UPSUsage.overload, .overload),
        (UPSUsage.communicationLost, .communicationLost), (UPSUsage.shutdownImminent, .shutdownImminent),
        (UPSUsage.belowRemainingCapacityLimit, .belowRemainingCapacityLimit),
        (UPSUsage.remainingTimeLimitExpired, .remainingTimeLimitExpired), (UPSUsage.voltageNotRegulated, .voltageNotRegulated),
    ]

    static let staticFields: [Field] = [
        Field(usage: UPSUsage.configActivePower, collections: [UPSUsage.powerConverter, UPSUsage.output], quantity: .watt, label: "ConfigActivePower"),
        Field(usage: UPSUsage.configVoltage, collections: [UPSUsage.input], quantity: .volt, label: "Input.ConfigVoltage"),
        Field(usage: UPSUsage.lowVoltageTransfer, collections: [UPSUsage.input], quantity: .volt, label: "LowVoltageTransfer"),
        Field(usage: UPSUsage.highVoltageTransfer, collections: [UPSUsage.input], quantity: .volt, label: "HighVoltageTransfer"),
        Field(usage: UPSUsage.configVoltage, collections: [UPSUsage.battery, UPSUsage.powerSummary], quantity: .volt, label: "Battery.ConfigVoltage"),
        Field(usage: UPSUsage.manufacturerDate, collections: [UPSUsage.battery, UPSUsage.powerSummary], quantity: .plain, label: "ManufacturerDate"),
        Field(usage: UPSUsage.test, collections: [UPSUsage.battery], quantity: .plain, label: "Test"),
        Field(usage: UPSUsage.remainingCapacityLimit, collections: summaryFirst, quantity: .plain, label: "RemainingCapacityLimit"),
    ]

    /// 读一台设备。内核按报告更新：每个报告第一次用到时带 update，其余直接读。
    private static func read(_ entry: Entry, includeStatic: Bool, now: Date)
        -> (telemetry: UPSTelemetry?, staticInfo: UPSStaticInfo?, defaulted: [String], missing: [String])
    {
        var updated = Set<UInt32>()
        var anySuccess = false
        var defaulted: [String] = []
        var missing: [String] = []

        func value(_ info: UPSElementInfo) -> Int64? {
            guard let element = entry.handles[info] else { return nil }
            let slot = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
            defer { slot.deallocate() }
            let options = updated.contains(info.reportID)
                ? IOHIDDeviceGetValueOptions.withoutUpdate.rawValue : IOHIDDeviceGetValueOptions.withUpdate.rawValue
            guard IOHIDDeviceGetValueWithOptions(entry.device, element, slot, options) == kIOReturnSuccess else { return nil }
            updated.insert(info.reportID)
            anySuccess = true
            // Get 规则：值归设备所有，不释放。
            return UPSReportLayout.normalize(Int64(IOHIDValueGetIntegerValue(slot.pointee.takeUnretainedValue())), element: info)
        }

        func read(_ field: Field) -> Double? {
            guard let info = entry.layout.element(field.usage, in: field.collections) else {
                missing.append(field.label)
                return nil
            }
            guard let raw = value(info) else { return nil }
            let converted = UPSReportLayout.siValue(raw, element: info, as: field.quantity)
            if converted.defaulted { defaulted.append(field.label) }
            return converted.value
        }

        var values: [String: Double] = [:]
        for field in coreFields { values[field.label] = read(field) }
        var flags: UPSStatusFlags = []
        for (usage, flag) in flagFields {
            guard let info = entry.layout.element(usage, in: statusFirst), let raw = value(info) else { continue }
            if raw != 0 { flags.insert(flag) }
        }
        // 电量：CapacityMode 2 是百分比；否则按满充容量折算。
        var charge: Double?
        if let remaining = values["RemainingCapacity"] {
            if let mode = values["CapacityMode"], mode != 2 {
                if let full = values["FullChargeCapacity"], full > 0 { charge = remaining / full }
            } else {
                charge = remaining / 100
            }
        }
        // FullChargeCapacity / CapacityMode 不是每台都有，不算缺失的关键项。
        missing.removeAll { $0 == "FullChargeCapacity" || $0 == "CapacityMode" }
        let telemetry = anySuccess
            ? UPSTelemetry(
                time: now, load: values["PercentLoad"].map { $0 / 100 }, inputVoltage: values["Input.Voltage"],
                batteryVoltage: values["Battery.Voltage"], charge: charge.map { min(max($0, 0), 1) },
                runtime: values["RunTimeToEmpty"], flags: flags)
            : nil

        var staticInfo: UPSStaticInfo?
        if includeStatic, anySuccess {
            var s: [String: Double] = [:]
            for field in staticFields { s[field.label] = read(field) }
            missing.removeAll { label in staticFields.contains { $0.label == label } && label != "ConfigActivePower" }
            staticInfo = UPSStaticInfo(
                ratedActivePower: s["ConfigActivePower"].flatMap { $0 > 0 ? $0 : nil },
                ratedInputVoltage: s["Input.ConfigVoltage"].flatMap { $0 > 0 ? $0 : nil },
                lowTransferVoltage: s["LowVoltageTransfer"].flatMap { $0 > 0 ? $0 : nil },
                highTransferVoltage: s["HighVoltageTransfer"].flatMap { $0 > 0 ? $0 : nil },
                batteryNominalVoltage: s["Battery.ConfigVoltage"].flatMap { $0 > 0 ? $0 : nil },
                manufactureDate: s["ManufacturerDate"].flatMap { UPSStaticInfo.decodeHIDDate(Int($0)) },
                selfTestResult: s["Test"].flatMap { UPSSelfTestResult(rawValue: Int($0)) },
                remainingCapacityLimit: s["RemainingCapacityLimit"].map { $0 / 100 })
        }
        return (telemetry, staticInfo, defaulted, missing)
    }
}
