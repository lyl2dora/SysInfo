// NVMe SMART 采集器 `storage.smart`（存储模块设计 §4.3，D54、D55）：公开接口（CSysStorage），blocking 通道。
//
// - 每次读取都「打开 → 读 → 关闭」，不常驻（D56）：NVMe SMART 的用户态连接是独占的（kIOReturnExclusiveAccess），
//   常驻会让其他读 SMART 的程序与另一个 SysInfo 实例（D16）都读不到。单盘一次约 0.7–1.0 ms CPU（§1.1）；
//   被别的程序占用时先隔 `busyRetryDelays` 重试（D93：各 SysInfo 实例的 tick 都对齐到整秒，同时开着两个实例时
//   每秒同一时刻抢这个连接，对方一次只占约 1 ms）；重试仍被占用则这一轮跳过该盘（保留上一次读数），
//   连续 3 轮占用才标为不可用；
// - 焦点盘（D55）：`focus` 为 nil 时每次读全部盘（面板存储 tab、诊断页、CLI）；为集合时每次只读这些盘
//   （菜单栏 widget 绑定的盘），其余盘距上次读满 `backgroundSeconds` 才读一次（给历史）；
// - 只读 SMART / Health 日志与 Identify Controller，不发任何会改变设备状态的命令（D54）；
// - 非 NVMe 盘（USB、SATA）不开启 ATA SMART，温度等指标不可用（`notSupported`）。
//
// 自检（K19、D24 逐盘判定）：有 SMART 盘时至少一块读得到（必需）；每块盘的综合温度在 −20–120 °C、
// 已用寿命 ≤ 255、备用块 ≤ 100（提示）。不合理的盘标为不可用，不显示可能错误的数值（D05）。

import CSysStorage
import Foundation
import Synchronization
import SysModel

/// 一块盘的 SMART 连接状态（诊断页）。
public struct DiskSMARTStatus: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case ok
        /// 不是 NVMe 盘（不支持 NVMe SMART）。
        case notSupported
        /// 打开连接失败，附 IOReturn / HRESULT。
        case openFailed(Int32)
        /// 被别的程序独占（kIOReturnExclusiveAccess），附连续次数。
        case busy(Int)
        /// 读取失败，附 IOReturn。
        case readFailed(Int32)
        /// 读数不合理（自检未通过），附说明。
        case implausible(String)
    }

    public var state: State
    /// 最近一次读取的线程 CPU 时间，纳秒。
    public var lastCPUNanos: UInt64?
    /// 最近一次成功读取的墙钟时刻。
    public var lastRead: Date?

    public init(state: State, lastCPUNanos: UInt64? = nil, lastRead: Date? = nil) {
        self.state = state
        self.lastCPUNanos = lastCPUNanos
        self.lastRead = lastRead
    }
}

/// 一个打开的 SMART 连接。只在一次读取里存在，用完立即关闭（D56）。
private final class SMARTHandle {
    let pointer: OpaquePointer

    private init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        cst_smart_close(pointer)
    }

    /// 打开连接；失败时返回错误码（IOReturn / HRESULT）。
    static func open(_ entry: DiskInventory.Entry) -> (handle: SMARTHandle?, result: Int32) {
        var result: Int32 = 0
        guard let pointer = cst_smart_open(entry.device.entry, &result) else { return (nil, result) }
        return (SMARTHandle(pointer: pointer), 0)
    }

    func read() -> (bytes: [UInt8], result: Int32) {
        var buffer = [UInt8](repeating: 0, count: Int(CST_SMART_LOG_SIZE))
        let r = buffer.withUnsafeMutableBufferPointer { cst_smart_read(pointer, $0.baseAddress!) }
        return (buffer, r)
    }

    func readIdentify() -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: Int(CST_IDENTIFY_SIZE))
        let r = buffer.withUnsafeMutableBufferPointer { cst_smart_identify(pointer, $0.baseAddress!) }
        return r == 0 ? buffer : nil
    }
}

public final class SMARTCollector: Collector {
    public static let collectorID: CollectorID = "storage.smart"
    public static let dataPath = "NVMeSMARTLibExternal（SMARTReadData + GetIdentifyData，每次读取打开后即关闭）"

    public var id: CollectorID { Self.collectorID }
    public let lane: CollectorLane = .blocking

    /// 非焦点盘的最短读取间隔，秒（略短于历史的 60 s，避免定时器抖动让它隔一轮才读）。
    public static let backgroundSeconds: Double = 55

    static let sampleMetrics: [MetricID.DiskMetric] = [.temp, .life, .spare, .mediaErrors, .warning, .dataRead, .dataWritten]

    /// kIOReturnExclusiveAccess。
    static let exclusiveAccess: Int32 = Int32(bitPattern: 0xE000_02BE)
    /// 连续这么多轮被占用才标为不可用。
    static let busyLimit = 3
    /// 打开时被占用的重试间隔（D93）；blocking 通道，最坏多等 50 ms。
    static let busyRetryDelays: [Duration] = [.milliseconds(25), .milliseconds(25)]

    /// 打开连接；结果是 kIOReturnExclusiveAccess 时按 `delays` 依次等待后重试，其他错误不重试。
    static func openRetrying<Handle>(
        delays: [Duration] = busyRetryDelays, sleep: (Duration) -> Void = sleepBlocking,
        open: () -> (handle: Handle?, result: Int32)
    ) -> (handle: Handle?, result: Int32) {
        var opened = open()
        for delay in delays where opened.handle == nil && opened.result == exclusiveAccess {
            sleep(delay)
            opened = open()
        }
        return opened
    }

    private static func sleepBlocking(_ duration: Duration) {
        let (seconds, attoseconds) = duration.components
        Thread.sleep(forTimeInterval: Double(seconds) + Double(attoseconds) / 1e18)
    }

    private struct State {
        var usable: Bool?
        /// Identify Controller 是静态信息：每块盘只读一次，按盘缓存（D56 之后连接不常驻）。
        var identify: [DiskKey: [UInt8]] = [:]
        var busyCounts: [DiskKey: Int] = [:]
        var records: [DiskKey: SMARTRecord] = [:]
        var statuses: [DiskKey: DiskSMARTStatus] = [:]
        var lastReadNanos: [DiskKey: UInt64] = [:]
        /// 自检判定读数不合理的盘。
        var implausible: Set<DiskKey> = []
        var focus: Set<DiskKey>?
        var generation: UInt64?
    }

    private let inventory: DiskInventory
    private let state = Mutex(State())

    public init(inventory: DiskInventory = .shared) {
        self.inventory = inventory
    }

    /// 焦点盘（D55）：nil 表示每次读全部盘。
    public func setFocus(_ keys: Set<DiskKey>?) {
        state.withLock { $0.focus = keys }
    }

    /// 每块盘最近一次的 SMART 读数（详情页）。自检判为读数不合理的盘不给出（D05：不显示可能错误的数值）。
    public var latestRecords: [DiskKey: SMARTRecord] {
        state.withLock { s in s.records.filter { !s.implausible.contains($0.key) } }
    }

    /// 每块盘的连接状态（诊断页）。
    public var statuses: [DiskKey: DiskSMARTStatus] { state.withLock { $0.statuses } }

    // MARK: - Collector

    public func selfTest() -> SelfTestResult {
        inventory.invalidate()
        let snapshot = inventory.snapshot()
        state.withLock {
            $0.identify = [:]
            $0.busyCounts = [:]
            $0.implausible = []
            $0.generation = snapshot.inventory.generation
        }
        let capable = snapshot.inventory.disks.filter(\.smartCapable)
        var checks: [SelfTestCheck] = []
        var readable = 0
        for disk in capable {
            guard let entry = snapshot.entries[disk.key] else { continue }
            let outcome = read(disk, entry: entry, at: Date())
            guard let record = outcome else { continue }
            readable += 1
            let problem = Self.implausibility(record)
            checks.append(
                SelfTestCheck(
                    name: "storage.smart.plausible", passed: problem == nil,
                    detail: "\(disk.bsdName ?? "?"): \(problem ?? "temp=\(Int(record.temperatureCelsius)) used=\(record.percentageUsed)% spare=\(record.availableSpare)%")",
                    severity: .advisory))
            if let problem {
                state.withLock {
                    $0.implausible.insert(disk.key)
                    $0.records[disk.key] = nil
                    $0.statuses[disk.key] = DiskSMARTStatus(state: .implausible(problem))
                }
            }
        }
        checks.insert(
            SelfTestCheck(
                name: "storage.smart.read", passed: capable.isEmpty || readable > 0,
                detail: capable.isEmpty ? "no NVMe disks" : "\(readable)/\(capable.count) readable"),
            at: 0)
        let result = SelfTestResult(checks: checks, dataPath: Self.dataPath)
        state.withLock {
            $0.usable = result.isUsable
            // 自检读到的数不进 MetricStore：清掉读取时间，下一次采样照常读全部盘，
            // 否则非焦点盘要等 backgroundSeconds 才有第一个样本（启动后盘温「—」最多 55 s）。
            $0.lastReadNanos = [:]
        }
        return result
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        let snapshot = inventory.snapshot()
        let (usable, focus) = state.withLock { s -> (Bool?, Set<DiskKey>?) in
            if s.generation != snapshot.inventory.generation {
                // 盘插拔：丢掉已不在的盘的缓存与读数。
                let keys = Set(snapshot.inventory.disks.map(\.key))
                s.identify = s.identify.filter { keys.contains($0.key) }
                s.busyCounts = s.busyCounts.filter { keys.contains($0.key) }
                s.records = s.records.filter { keys.contains($0.key) }
                s.statuses = s.statuses.filter { keys.contains($0.key) }
                s.lastReadNanos = s.lastReadNanos.filter { keys.contains($0.key) }
                s.generation = snapshot.inventory.generation
            }
            return (s.usable, s.focus)
        }
        if usable == false {
            let reason = UnavailableReason.selfTestFailed()
            return CollectorOutput(
                samples: snapshot.inventory.disks.flatMap { disk in
                    Self.sampleMetrics.map { .unavailable(.storageDisk(disk.key, $0), reason: reason, at: time) }
                },
                status: .unavailable, dataPath: Self.dataPath)
        }
        var samples: [Sample] = []
        var degraded = false
        for disk in snapshot.inventory.disks {
            let due = state.withLock { s -> Bool in
                guard let focus, !focus.contains(disk.key) else { return true }
                guard let last = s.lastReadNanos[disk.key] else { return true }
                return Double(time.continuousNanos &- last) / 1e9 >= Self.backgroundSeconds
            }
            guard due else { continue }
            guard disk.smartCapable else {
                state.withLock { $0.statuses[disk.key] = DiskSMARTStatus(state: .notSupported) }
                samples.append(.unavailable(.storageDisk(disk.key, .temp), reason: .notSupported("NVMe SMART"), at: time))
                continue
            }
            if state.withLock({ $0.implausible.contains(disk.key) }) {
                degraded = true
                samples += Self.sampleMetrics.map {
                    .unavailable(.storageDisk(disk.key, $0), reason: .selfTestFailed("implausible SMART"), at: time)
                }
                continue
            }
            guard let entry = snapshot.entries[disk.key] else { continue }
            let record = read(disk, entry: entry, at: time.wallClock)
            if record == nil, let busy = state.withLock({ $0.busyCounts[disk.key] }), busy < Self.busyLimit {
                continue  // 被别的程序占用：这一轮跳过，保留上一次读数
            }
            guard let record else {
                degraded = true
                samples += Self.sampleMetrics.map {
                    .unavailable(.storageDisk(disk.key, $0), reason: .readFailed("SMARTReadData"), at: time)
                }
                continue
            }
            samples += Self.samples(record, key: disk.key, at: time)
        }
        return CollectorOutput(samples: samples, status: degraded ? .degraded : .ok, dataPath: Self.dataPath)
    }

    public func resetBaseline() {}

    // MARK: - 读取

    /// 读一块盘：打开 → 读 SMART（首次另读 Identify）→ 关闭。成功时更新最新读数与状态。
    private func read(_ disk: PhysicalDisk, entry: DiskInventory.Entry, at date: Date) -> SMARTRecord? {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let opened = Self.openRetrying { SMARTHandle.open(entry) }
        guard let handle = opened.handle else {
            state.withLock { s in
                if opened.result == Self.exclusiveAccess {
                    let count = (s.busyCounts[disk.key] ?? 0) + 1
                    s.busyCounts[disk.key] = count
                    s.statuses[disk.key] = DiskSMARTStatus(
                        state: .busy(count), lastCPUNanos: s.statuses[disk.key]?.lastCPUNanos, lastRead: s.statuses[disk.key]?.lastRead)
                } else {
                    s.busyCounts[disk.key] = nil
                    s.statuses[disk.key] = DiskSMARTStatus(state: .openFailed(opened.result))
                }
            }
            return nil
        }
        let (bytes, result) = handle.read()
        guard result == 0, var record = SMARTParser.healthLog(bytes) else {
            state.withLock {
                $0.busyCounts[disk.key] = nil
                $0.statuses[disk.key] = DiskSMARTStatus(state: .readFailed(result))
            }
            return nil
        }
        let cachedIdentify = state.withLock { $0.identify[disk.key] }
        if let identify = cachedIdentify ?? handle.readIdentify() {
            SMARTParser.applyIdentify(identify, to: &record)
            if cachedIdentify == nil { state.withLock { $0.identify[disk.key] = identify } }
        }
        let cost = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- start
        let readAt = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)  // 与 SampleTime.continuousNanos 同一时钟
        state.withLock {
            $0.busyCounts[disk.key] = nil
            $0.lastReadNanos[disk.key] = readAt
            $0.records[disk.key] = record
            if !$0.implausible.contains(disk.key) {
                $0.statuses[disk.key] = DiskSMARTStatus(state: .ok, lastCPUNanos: cost, lastRead: date)
            }
        }
        return record
    }

    static func samples(_ record: SMARTRecord, key: DiskKey, at time: SampleTime) -> [Sample] {
        var out: [Sample] = []
        if record.temperatureCelsius > -273 {
            out.append(Sample(id: .storageDisk(key, .temp), value: record.temperatureCelsius, time: time))
        } else {
            out.append(.unavailable(.storageDisk(key, .temp), reason: .notSupported("composite temperature"), at: time))
        }
        out.append(Sample(id: .storageDisk(key, .life), value: Double(record.percentageUsed) / 100, time: time))
        out.append(Sample(id: .storageDisk(key, .spare), value: Double(record.availableSpare) / 100, time: time))
        out.append(Sample(id: .storageDisk(key, .mediaErrors), value: record.mediaErrors, time: time))
        out.append(Sample(id: .storageDisk(key, .warning), value: Double(record.criticalWarning.rawValue), time: time))
        out.append(Sample(id: .storageDisk(key, .dataRead), value: record.bytesRead, time: time))
        out.append(Sample(id: .storageDisk(key, .dataWritten), value: record.bytesWritten, time: time))
        return out
    }

    /// 读数是否合理；不合理时返回说明。
    static func implausibility(_ record: SMARTRecord) -> String? {
        // -273 是「没有综合温度」的哨兵（0 K），只让温度标为不支持，不算整盘不合理。
        if record.temperatureCelsius > -273, record.temperatureCelsius < -20 || record.temperatureCelsius > 120 {
            return "temperature \(Int(record.temperatureCelsius)) °C out of range"
        }
        if record.percentageUsed > 255 { return "percentage used \(record.percentageUsed)" }
        if record.availableSpare > 100 || record.availableSpareThreshold > 100 {
            return "spare \(record.availableSpare)/\(record.availableSpareThreshold)"
        }
        return nil
    }
}

/// NVMe SMART / Health 日志与 Identify Controller 的解析（纯函数，便于用金样本单测）。字节序一律小端（NVMe 规范）。
public enum SMARTParser {
    static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[o + $1]) << (8 * $1) } }
    static func u64(_ b: [UInt8], _ o: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[o + $1]) << (8 * $1) } }
    /// 16 字节计数，换成 Double（高 8 字节 × 2^64；实际计数远小于 2^53，精度足够）。
    static func u128(_ b: [UInt8], _ o: Int) -> Double { Double(u64(b, o)) + Double(u64(b, o + 8)) * 18_446_744_073_709_551_616 }

    /// 温度：开尔文 → 摄氏（NVMe 用整数开尔文，按 273 换算，与 smartctl 一致）。0 表示不支持。
    static func celsius(_ kelvin: UInt16) -> Double? { kelvin == 0 ? nil : Double(Int(kelvin) - 273) }

    /// 解析 512 字节的 SMART / Health 日志。长度不够时返回 nil。
    public static func healthLog(_ b: [UInt8]) -> SMARTRecord? {
        guard b.count >= 232 else { return nil }
        return SMARTRecord(
            criticalWarning: NVMeCriticalWarning(rawValue: b[0]),
            temperatureCelsius: celsius(u16(b, 1)) ?? -273, availableSpare: Int(b[3]), availableSpareThreshold: Int(b[4]),
            percentageUsed: Int(b[5]), enduranceGroupWarning: b[6], dataUnitsRead: u128(b, 32), dataUnitsWritten: u128(b, 48),
            hostReadCommands: u128(b, 64), hostWriteCommands: u128(b, 80), controllerBusyMinutes: u128(b, 96),
            powerCycles: u128(b, 112), powerOnHours: u128(b, 128), unsafeShutdowns: u128(b, 144), mediaErrors: u128(b, 160),
            errorLogEntries: u128(b, 176), warningTemperatureMinutes: u32(b, 192), criticalTemperatureMinutes: u32(b, 196),
            temperatureSensors: (0..<8).map { celsius(u16(b, 200 + 2 * $0)) },
            thermalTransitions: [u32(b, 216), u32(b, 220)], thermalSeconds: [u32(b, 224), u32(b, 228)])
    }

    /// 从 Identify Controller 补上厂商 ID、NVMe 版本与温度阈值。
    public static func applyIdentify(_ b: [UInt8], to record: inout SMARTRecord) {
        guard b.count >= 270 else { return }
        record.vendorID = u16(b, 0)
        record.nvmeVersion = u32(b, 80)
        record.warningThresholdCelsius = celsius(u16(b, 266))
        record.criticalThresholdCelsius = celsius(u16(b, 268))
    }

    /// Identify 里的型号（40 字节 ASCII，去掉尾部空格）。
    public static func modelNumber(_ b: [UInt8]) -> String? {
        guard b.count >= 64 else { return nil }
        return String(decoding: b[24..<64], as: UTF8.self).trimmingCharacters(in: .whitespaces.union(.controlCharacters))
    }
}
