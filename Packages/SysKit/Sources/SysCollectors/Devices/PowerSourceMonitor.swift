// 电源设备清单（电源设备设计 §4.1，D84）：`devices.sources` 与 app、历史记录器共用一份。
//
// - 事件驱动：公开 `IOPSNotificationCreateRunLoopSource` 与私有配件通知挂在一条专用 run loop 线程上；
//   任一通知后去抖 1 s 重建快照，代数加一，回调订阅方。外接电源时实测每分钟约 2 次（UPS 的剩余时间在跳）；
// - 重建：私有 `IOPSCopyPowerSourcesByType(0)` 可用时以它为准（UPS、内置电池、配件），否则用公开
//   `IOPSCopyPowerSourcesInfo`（只有 UPS 与内置电池）。两者的 blob 都交给公开的列表 / 描述函数解析，单次约 18 µs；
// - 只按 `Type` 归类：UPS、InternalBattery、Accessory Source，其余忽略（不把任何电源都当成电池，调研报告 §2.5）；
// - 不保存 `Accessory Identifier`（设备唯一标识）与 `Power Source ID`（重插后会变）；配件键是 `Group Identifier`
//   的加盐哈希（与盘的键同一套盐，D84 PD7）。

import Foundation
import IOKit.ps
internal import CSysPrivate
import os
import Synchronization
import SysModel

public final class PowerSourceMonitor: Sendable {
    /// app、CLI 与采集器共用的实例。
    public static let shared = PowerSourceMonitor()

    /// 通知去抖。
    static let debounce: DispatchTimeInterval = .seconds(1)

    /// 订阅凭据：释放或 `cancel()` 即取消订阅。
    public final class Observation: Sendable {
        private let cancelAction: @Sendable () -> Void
        private let cancelled = Atomic<Bool>(false)

        init(cancel: @escaping @Sendable () -> Void) { cancelAction = cancel }

        public func cancel() {
            guard !cancelled.exchange(true, ordering: .acquiringAndReleasing) else { return }
            cancelAction()
        }

        deinit { cancel() }
    }

    /// 诊断信息。
    public struct Status: Hashable, Sendable {
        /// 公开电源通知已挂上。
        public var publicNotify: Bool
        /// 私有配件通知已挂上。
        public var accessoryNotify: Bool
        /// 私有按类型接口可用（配件可见）。
        public var accessoriesAvailable: Bool
        public var generation: UInt64
        public var lastRebuild: Date?
        /// 最近一次重建的原因：`initial`、`notify`、`accessoryNotify`、`refresh`。
        public var lastReason: String
        /// 至今收到的通知数。
        public var notifyCount: UInt64
    }

    private struct State {
        var snapshot: PowerDeviceSnapshot?
        var generation: UInt64 = 0
        var observers: [UInt64: @Sendable (PowerDeviceSnapshot) -> Void] = [:]
        var nextObserverID: UInt64 = 0
        var started = false
        var publicNotify = false
        var accessoryNotify = false
        var pending = false
        var pendingReason = ""
        var lastRebuild: Date?
        var lastReason = ""
        var notifyCount: UInt64 = 0
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "zone.lyl.sysinfo.devices.monitor", qos: .utility)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "sysinfo-cli", category: "devices")

    public init() {}

    /// 最近一次的快照；还没建过时现建一次（不挂通知）。
    public var latest: PowerDeviceSnapshot {
        if let snapshot = state.withLock({ $0.snapshot }) { return snapshot }
        return rebuild(reason: "initial")
    }

    public var generation: UInt64 { state.withLock { $0.generation } }

    public var status: Status {
        state.withLock {
            Status(
                publicNotify: $0.publicNotify, accessoryNotify: $0.accessoryNotify,
                accessoriesAvailable: $0.snapshot?.accessoriesAvailable ?? (csp_ps_available() != 0), generation: $0.generation,
                lastRebuild: $0.lastRebuild, lastReason: $0.lastReason, notifyCount: $0.notifyCount)
        }
    }

    /// 挂上变化通知（重复调用没有副作用）。
    public func start() {
        let first = state.withLock { s -> Bool in
            guard !s.started else { return false }
            s.started = true
            return true
        }
        guard first else { return }
        let thread = Thread { [weak self] in self?.runLoopMain() }
        thread.name = "zone.lyl.sysinfo.devices.runloop"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// 订阅快照变化：每次重建且内容变了时回调（在监视器的队列上）。
    public func observe(_ handler: @escaping @Sendable (PowerDeviceSnapshot) -> Void) -> Observation {
        start()
        let id = state.withLock { s -> UInt64 in
            s.nextObserverID += 1
            s.observers[s.nextObserverID] = handler
            return s.nextObserverID
        }
        return Observation { [weak self] in
            _ = self?.state.withLock { $0.observers.removeValue(forKey: id) }
        }
    }

    /// 立即重建一次（自检、唤醒、CLI）。
    @discardableResult
    public func refresh() -> PowerDeviceSnapshot {
        rebuild(reason: "refresh")
    }

    // MARK: - 通知

    /// 专用线程：挂上两路通知后一直跑 run loop（通知很少，线程平时阻塞，不占 CPU）。
    private func runLoopMain() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let runLoop = CFRunLoopGetCurrent()
        if let source = IOPSNotificationCreateRunLoopSource(
            { context in
                guard let context else { return }
                Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue().notified(reason: "notify")
            }, context)?.takeRetainedValue()
        {
            CFRunLoopAddSource(runLoop, source, .defaultMode)
            state.withLock { $0.publicNotify = true }
        } else {
            logger.error("IOPSNotificationCreateRunLoopSource 失败，电源设备只在刷新时更新")
        }
        if let source = csp_ps_acc_notify_create(
            { context in
                guard let context else { return }
                Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue().notified(reason: "accessoryNotify")
            }, context)
        {
            CFRunLoopAddSource(runLoop, source, .defaultMode)
            state.withLock { $0.accessoryNotify = true }
        }
        // 先建一次，订阅方马上有数据。
        queue.async { [weak self] in self?.rebuild(reason: "initial") }
        while true {
            CFRunLoopRunInMode(.defaultMode, 3600, false)
        }
    }

    private func notified(reason: String) {
        let schedule = state.withLock { s -> Bool in
            s.notifyCount += 1
            s.pendingReason = reason
            guard !s.pending else { return false }
            s.pending = true
            return true
        }
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + Self.debounce) { [weak self] in
            guard let self else { return }
            let reason = self.state.withLock { s -> String in
                s.pending = false
                return s.pendingReason
            }
            self.rebuild(reason: reason)
        }
    }

    @discardableResult
    private func rebuild(reason: String) -> PowerDeviceSnapshot {
        let snapshot = Self.read()
        let (changed, observers) = state.withLock { s -> (Bool, [@Sendable (PowerDeviceSnapshot) -> Void]) in
            let changed = s.snapshot.map { $0.devices != snapshot.devices || $0.accessoriesAvailable != snapshot.accessoriesAvailable }
                ?? true
            s.snapshot = snapshot
            s.lastRebuild = snapshot.time
            s.lastReason = reason
            if changed { s.generation += 1 }
            return (changed, Array(s.observers.values))
        }
        if changed { observers.forEach { $0(snapshot) } }
        return snapshot
    }

    // MARK: - 读取与解析

    /// 读一次全部电源设备。
    public static func read(now: Date = Date()) -> PowerDeviceSnapshot {
        var accessoriesAvailable = false
        var descriptions: [[String: Any]] = []
        if csp_ps_available() != 0, let blob = csp_ps_copy_by_type(0) {
            let list = descriptionsOf(blob)
            if let list {
                accessoriesAvailable = true
                descriptions = list
            }
        }
        if !accessoriesAvailable, let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            descriptions = descriptionsOf(blob) ?? []
        }
        return PowerDeviceSnapshot(
            time: now, devices: parse(descriptions, accessoryKey: { DiskIdentity.key(["accessory", $0]).rawValue }),
            accessoriesAvailable: accessoriesAvailable)
    }

    /// 用公开函数解析 blob；列表取不到时为 nil。
    private static func descriptionsOf(_ blob: CFTypeRef) -> [[String: Any]]? {
        guard let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        return list.compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
    }

    /// 把 IOPS 的描述字典解析成设备（纯函数，单测用）。`accessoryKey` 把 Group Identifier 变成键里的哈希。
    public static func parse(_ descriptions: [[String: Any]], accessoryKey: (String) -> String) -> [PowerDevice] {
        var ups: [PowerDevice] = []
        var batteries: [PowerDevice] = []
        var groups: [String: [[String: Any]]] = [:]
        var groupOrder: [String] = []
        for item in descriptions {
            if let present = item["Is Present"] as? Bool, !present { continue }
            switch item["Type"] as? String {
            case "UPS":
                ups.append(device(item, kind: .ups, key: .internalBattery))
            case "InternalBattery":
                batteries.append(device(item, kind: .internalBattery, key: .internalBattery))
            case "Accessory Source":
                // 没有 Group Identifier 时按名字成组（名字也没有就单独一组）。
                let group = (item["Group Identifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "name:\(trimmedName(item) ?? UUID().uuidString)"
                if groups[group] == nil { groupOrder.append(group) }
                groups[group, default: []].append(item)
            default:
                continue
            }
        }
        // UPS 键：同一 Vendor/Product 的多台按出现顺序加序号。
        var seen: [String: Int] = [:]
        for index in ups.indices {
            let vid = ups[index].vendorID ?? 0, pid = ups[index].productID ?? 0
            let n = seen["\(vid):\(pid)", default: 0]
            seen["\(vid):\(pid)"] = n + 1
            ups[index].key = .ups(vendorID: vid, productID: pid, index: n)
        }
        if batteries.count > 1 {
            for index in batteries.indices.dropFirst() { batteries[index].key = PowerDeviceKey(rawValue: "battery:\(index)") }
        }
        let accessories = groupOrder.compactMap { group -> PowerDevice? in
            accessoryDevice(groups[group] ?? [], key: .accessory(hash: accessoryKey(group)))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return ups + batteries + accessories
    }

    private static func trimmedName(_ item: [String: Any]) -> String? {
        guard let name = (item["Name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        return name
    }

    /// 电量：Current / Max Capacity（UPS、配件的 Max 都是 100；内置电池按百分比给）。
    static func level(_ item: [String: Any]) -> Double? {
        guard let current = (item["Current Capacity"] as? NSNumber)?.doubleValue else { return nil }
        let max = (item["Max Capacity"] as? NSNumber)?.doubleValue ?? 100
        guard max > 0, current >= 0 else { return nil }
        return min(current / max, 1)
    }

    /// IOPS 的分钟数：-1 表示计算中、65535 表示未知；0 在外接电源时也常见，按未知处理。
    static func minutes(_ value: Any?) -> Double? {
        guard let minutes = (value as? NSNumber)?.doubleValue, minutes > 0, minutes < 65535 else { return nil }
        return minutes * 60
    }

    static func part(_ item: [String: Any], role: PowerDevicePartRole) -> PowerDevicePart {
        PowerDevicePart(
            role: role, name: ((item["Part Name"] as? String) ?? "").trimmingCharacters(in: .whitespaces), level: level(item),
            isCharging: (item["Is Charging"] as? Bool) ?? false, isCharged: (item["Is Charged"] as? Bool) ?? false,
            lowWarnLevel: (item["Low Warn Level"] as? NSNumber).map { $0.doubleValue / 100 })
    }

    private static func device(_ item: [String: Any], kind: PowerDeviceKind, key: PowerDeviceKey) -> PowerDevice {
        PowerDevice(
            key: key, kind: kind, name: trimmedName(item) ?? "", transport: item["Transport Type"] as? String,
            parts: [part(item, role: .main)], powerSourceState: PowerSourceState(iopsValue: item["Power Source State"] as? String),
            timeToEmpty: minutes(item["Time to Empty"]), timeToFull: minutes(item["Time to Full Charge"]),
            vendorID: (item["Vendor ID"] as? NSNumber)?.intValue, productID: (item["Product ID"] as? NSNumber)?.intValue,
            inputVoltage: kind == .ups ? upsInputVoltage(item) : nil)
    }

    /// UPS 的输入电压：IOPS `Voltage`（mV）只在外接电源且像市电（≥ 80 V）时才是输入电压。
    /// 2026-10-19 放电实测：由电池供电时它报电池电压（约 24 V），恢复市电后 15 s 以上仍停在 26 V。
    static func upsInputVoltage(_ item: [String: Any]) -> Double? {
        guard PowerSourceState(iopsValue: item["Power Source State"] as? String) == .external,
            let millivolts = (item["Voltage"] as? NSNumber)?.doubleValue, millivolts >= 80_000
        else { return nil }
        return millivolts / 1000
    }

    /// 一组配件项合成一台设备：Combined 项展开 `Combined Parts`（左右耳），其余项（充电盒）按 Part 归位。
    private static func accessoryDevice(_ items: [[String: Any]], key: PowerDeviceKey) -> PowerDevice? {
        guard !items.isEmpty else { return nil }
        var parts: [PowerDevicePart] = []
        for item in items {
            let role = PowerDevicePartRole(partIdentifier: item["Part Identifier"] as? String)
            if role == .combined, let subparts = item["Combined Parts"] as? [[String: Any]] {
                for sub in subparts {
                    if let present = sub["Is Present"] as? Bool, !present { continue }
                    parts.append(part(sub, role: PowerDevicePartRole(partIdentifier: sub["Part Identifier"] as? String)))
                }
            }
            // 合成项自己也留着（`level` 先取它）；单独上报的部件（充电盒）直接收。
            parts.append(part(item, role: role == .main ? .main : role))
        }
        // 同一角色只留一份（合成项展开的左右耳与单独上报的左右耳可能重复）。
        var unique: [PowerDevicePart] = []
        for part in parts where !unique.contains(where: { $0.role == part.role }) { unique.append(part) }
        unique.sort { $0.role.order < $1.role.order }
        // 设备名：非充电盒项的名字优先（「AirPods Pro」），否则第一项的名字。
        let primary = items.first { PowerDevicePartRole(partIdentifier: $0["Part Identifier"] as? String) != .case } ?? items[0]
        let name = trimmedName(primary) ?? items.compactMap(trimmedName).first ?? ""
        return PowerDevice(
            key: key, kind: .accessory, name: name, transport: primary["Transport Type"] as? String, parts: unique,
            powerSourceState: PowerSourceState(iopsValue: primary["Power Source State"] as? String),
            timeToEmpty: minutes(primary["Time to Empty"]), timeToFull: minutes(primary["Time to Full Charge"]),
            vendorID: (primary["Vendor ID"] as? NSNumber)?.intValue, productID: (primary["Product ID"] as? NSNumber)?.intValue,
            accessoryCategory: primary["Accessory Category"] as? String)
    }
}
