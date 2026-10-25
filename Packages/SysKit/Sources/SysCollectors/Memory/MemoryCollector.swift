// 内存采集器 `memory.vm`（内存模块设计 §4.1，D49）。全部是公开接口，走 inline 通道。
//
// - 页面队列：`vm.page_free_count`、`vm.page_pageable_internal_count`、`vm.page_pageable_external_count`、
//   `vm.page_purgeable_count`、`vm.page_wired_count`。sysctl 不受 `host_statistics` 的全系统节流（调研报告 §0-7）；
// - 被压缩、压缩比与累计计数（页入 / 页出、换入 / 换出、压缩 / 解压）：`host_statistics64(HOST_VM_INFO64)` rev6。
//   它受节流：与上次逐字节相同的结果按陈旧处理，沿用上次的被压缩页数，这一次不出速率（CLAUDE.md）；
// - 口径照活动监视器（D49 M1）：已用 = App（internal − purgeable）+ 联动 + 被压缩；已缓存文件 = external + purgeable；
//   空闲只取 free（external 已含 speculative，再加会重复，D49 事实更正）；
// - 压力：`kern.memorystatus_vm_pressure_level`、`kern.memorystatus_level`；另挂 dispatch 内存压力事件，
//   一个采样间隔里出现过的最差等级也计入，后台 10 s 一次的采样不会漏掉短暂的警告；
// - Swap：`vm.swapusage`。
//
// 自检（K19）：必需项是 `hw.memsize`、页大小与五个页面队列都读得到；提示项是 `host_statistics64` 返回 rev6
// （不过时被压缩改用 `vm.compressor_bytes_used` 估算、速率不可用）、页面队列之和与 `hw.memsize_usable` 相差不超过 3%、
// 压力 sysctl 可读。

import Darwin
import Dispatch
import Foundation
import Synchronization
import SysModel

/// 一次读取的原始计数（页数或字节），纯数据，便于单测。
struct MemoryCounts: Hashable, Sendable {
    var pageSize: UInt64
    var physicalBytes: UInt64
    var usableBytes: UInt64?
    var free: UInt64
    var internalPages: UInt64
    var externalPages: UInt64
    var purgeable: UInt64
    var wired: UInt64
    /// 压缩器占用的页；nil 表示读不到（host_statistics64 失败），由 `compressedBytesFallback` 代替。
    var compressorPages: UInt64?
    /// 回退：`vm.compressor_bytes_used`（压缩后的数据量，比占用页略少），只在上一项为 nil 时使用。
    var compressedBytesFallback: UInt64?
    /// 压缩器里存放的原始页数。
    var uncompressedPagesInCompressor: UInt64?

    func bytes(_ pages: UInt64) -> Double { Double(pages) * Double(pageSize) }

    var appBytes: Double { bytes(internalPages >= purgeable ? internalPages - purgeable : 0) }
    var wiredBytes: Double { bytes(wired) }
    /// 被压缩；回退值的质量为估算。
    var compressedBytes: (value: Double, estimated: Bool)? {
        if let compressorPages { return (bytes(compressorPages), false) }
        if let compressedBytesFallback { return (Double(compressedBytesFallback), true) }
        return nil
    }
    var usedBytes: Double { appBytes + wiredBytes + (compressedBytes?.value ?? 0) }
    var cachedBytes: Double { bytes(externalPages + purgeable) }
    var freeBytes: Double { bytes(free) }

    /// 各队列之和（free + internal + external + wired + 被压缩），与 `hw.memsize_usable` 对照。
    var queueSumBytes: Double { bytes(free + internalPages + externalPages + wired) + (compressedBytes?.value ?? 0) }

    /// 压缩比；没有被压缩的页时为 nil。
    var compressionRatio: Double? {
        guard let compressorPages, compressorPages > 0, let uncompressed = uncompressedPagesInCompressor else { return nil }
        return Double(uncompressed) / Double(compressorPages)
    }
}

/// `host_statistics64` 里用来算速率的累计计数。
struct MemoryEventCounts: Hashable, Sendable {
    var pageins: UInt64
    var pageouts: UInt64
    var swapins: UInt64
    var swapouts: UInt64
    var compressions: UInt64
    var decompressions: UInt64

    static let metricIDs: [MetricID] = [
        .memoryPageInRate, .memoryPageOutRate, .memorySwapInRate, .memorySwapOutRate, .memoryCompressionRate,
        .memoryDecompressionRate,
    ]

    func value(_ id: MetricID) -> UInt64 {
        switch id {
        case .memoryPageInRate: pageins
        case .memoryPageOutRate: pageouts
        case .memorySwapInRate: swapins
        case .memorySwapOutRate: swapouts
        case .memoryCompressionRate: compressions
        default: decompressions
        }
    }

    /// 两次读数之间的每秒次数（纯函数）。某个计数回退时按复位处理，那一项不可用（不钳为 0）。
    static func rates(previous: Self, current: Self, elapsedNanos: UInt64) -> [MetricID: Double?] {
        guard elapsedNanos > 0 else { return [:] }
        let seconds = Double(elapsedNanos) / 1e9
        var out: [MetricID: Double?] = [:]
        for id in metricIDs {
            let a = previous.value(id)
            let b = current.value(id)
            out[id] = b >= a ? Double(b - a) / seconds : nil
        }
        return out
    }
}

/// `host_statistics64` 的一次读数。
struct VMStatistics: Sendable {
    var raw: vm_statistics64_data_t
    var count: mach_msg_type_number_t

    var events: MemoryEventCounts {
        MemoryEventCounts(
            pageins: raw.pageins, pageouts: raw.pageouts, swapins: raw.swapins, swapouts: raw.swapouts,
            compressions: raw.compressions, decompressions: raw.decompressions)
    }

    /// 与另一次读数逐字节相同（节流期间返回的是缓存值）。
    func isIdentical(to other: VMStatistics) -> Bool {
        withUnsafeBytes(of: raw) { a in withUnsafeBytes(of: other.raw) { b in a.elementsEqual(b) } }
    }
}

public final class MemoryCollector: Collector {
    public static let collectorID: CollectorID = "memory.vm"
    public static let dataPath = "sysctl vm.page_* + host_statistics64(HOST_VM_INFO64 rev6) + memorystatus + vm.swapusage"
    public static let fallbackDataPath = "sysctl vm.page_* + vm.compressor_bytes_used（host_statistics64 不可用）"

    public var id: CollectorID { Self.collectorID }

    /// rev6 的 `HOST_VM_INFO64_COUNT`（104；C 宏导入不进 Swift）。
    static let vmInfo64Count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

    /// 页面队列之和与 `hw.memsize_usable` 允许的相对偏差（提示项）。
    static let queueSumTolerance = 0.03

    private struct State {
        var usable: Bool?
        var warnings = false
        /// host_statistics64 可用（rev6）。
        var vmStatisticsOK = true
        var previous: (stats: VMStatistics, nanos: UInt64)?
        var staleCount: UInt64 = 0
        /// 上一次采样之后，dispatch 事件报告过的最差等级。
        var eventPeak: MemoryPressureLevel?
        /// 最近一次自检时页面队列之和与 usable 的比值（诊断页）。
        var queueSumRatio: Double?
    }

    private let state = Mutex(State())
    private let pressureSource: any DispatchSourceMemoryPressure

    public init() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: DispatchQueue(label: "zone.lyl.sysinfo.memory.pressure", qos: .utility))
        pressureSource = source
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let event = source.data
            let level: MemoryPressureLevel =
                event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
            self.state.withLock { s in s.eventPeak = max(s.eventPeak ?? level, level) }
        }
        source.activate()
    }

    deinit {
        pressureSource.cancel()
    }

    /// 最近一次自检时页面队列之和 ÷ `hw.memsize_usable`（诊断页）。
    public var queueSumRatio: Double? { state.withLock { $0.queueSumRatio } }

    /// host_statistics64 是否按 rev6 使用（否则被压缩为估算、速率不可用）。
    public var usesVMStatistics: Bool { state.withLock { $0.vmStatisticsOK } }

    // MARK: - Collector

    public func selfTest() -> SelfTestResult {
        var checks: [SelfTestCheck] = []
        let counts = Self.readCounts(statistics: nil)
        checks.append(
            SelfTestCheck(
                name: "memory.vm.sysctl", passed: counts != nil && (counts?.physicalBytes ?? 0) > 0,
                detail: counts.map { "memsize=\($0.physicalBytes) pagesize=\($0.pageSize)" } ?? "sysctl vm.page_* failed"))
        let statistics = Self.readVMStatistics()
        let statisticsOK = statistics.map { $0.count == Self.vmInfo64Count } ?? false
        checks.append(
            SelfTestCheck(
                name: "memory.vm.hostStatistics", passed: statisticsOK,
                detail: statistics.map { "count=\($0.count) expected=\(Self.vmInfo64Count)" } ?? "host_statistics64 failed",
                severity: .advisory))
        var ratio: Double?
        if var counts {
            if statisticsOK, let statistics {
                counts.compressorPages = UInt64(statistics.raw.compressor_page_count)
            } else {
                counts.compressedBytesFallback = Self.sysctlUInt64("vm.compressor_bytes_used")
            }
            if let usable = counts.usableBytes, usable > 0 {
                ratio = counts.queueSumBytes / Double(usable)
            }
            let ok = ratio.map { abs($0 - 1) <= Self.queueSumTolerance } ?? false
            checks.append(
                SelfTestCheck(
                    name: "memory.vm.queueSum", passed: ok,
                    detail: ratio.map { "sum/usable=\(String(format: "%.4f", $0))" } ?? "hw.memsize_usable unavailable",
                    severity: .advisory))
        }
        let pressure = Self.readPressure()
        checks.append(
            SelfTestCheck(
                name: "memory.vm.pressure", passed: pressure.level != nil && pressure.availablePercent != nil,
                detail: "level=\(pressure.level.map(String.init) ?? "?") available=\(pressure.availablePercent.map(String.init) ?? "?")%",
                severity: .advisory))
        let result = SelfTestResult(checks: checks, dataPath: statisticsOK ? Self.dataPath : Self.fallbackDataPath)
        state.withLock {
            if $0.usable == false, result.isUsable { $0.previous = nil }
            $0.usable = result.isUsable
            $0.warnings = !result.warnings.isEmpty
            $0.vmStatisticsOK = statisticsOK
            if !statisticsOK { $0.previous = nil }
            $0.queueSumRatio = ratio
        }
        return result
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        let (usable, statisticsOK) = state.withLock { ($0.usable, $0.vmStatisticsOK) }
        let path = statisticsOK ? Self.dataPath : Self.fallbackDataPath
        if usable == false {
            let reason = UnavailableReason.selfTestFailed()
            return CollectorOutput(
                samples: Self.allIDs.map { .unavailable($0, reason: reason, at: time) }, status: .unavailable, dataPath: path)
        }
        let statistics = statisticsOK ? Self.readVMStatistics() : nil
        guard var counts = Self.readCounts(statistics: statistics) else {
            let reason = UnavailableReason.readFailed("sysctl vm.page_*")
            return CollectorOutput(
                samples: Self.allIDs.map { .unavailable($0, reason: reason, at: time) }, status: .unavailable, dataPath: path)
        }
        let pressure = Self.readPressure()
        let swap = Self.readSwap()

        var samples: [Sample] = []
        var degraded = false
        var stale = false
        var rates: [MetricID: Double?] = [:]
        let (peak, staleCount): (MemoryPressureLevel?, UInt64) = state.withLock { s in
            let peak = s.eventPeak
            s.eventPeak = nil
            if let statistics {
                if let previous = s.previous, statistics.isIdentical(to: previous.stats) {
                    // 节流期间的缓存值：被压缩沿用它（与上次相同），不出速率，基线不动。
                    s.staleCount += 1
                    stale = true
                } else {
                    if let previous = s.previous, time.monotonicNanos > previous.nanos {
                        rates = MemoryEventCounts.rates(
                            previous: previous.stats.events, current: statistics.events,
                            elapsedNanos: time.monotonicNanos - previous.nanos)
                    }
                    s.previous = (statistics, time.monotonicNanos)
                }
            } else if statisticsOK {
                s.previous = nil  // 这一次读失败：重建基线
            }
            return (peak, s.staleCount)
        }
        if statistics == nil {
            // 自检判定不是 rev6（回退路径），或这一次读失败：被压缩改用 `vm.compressor_bytes_used` 估算。
            if statisticsOK { degraded = true }
            counts.compressedBytesFallback = Self.sysctlUInt64("vm.compressor_bytes_used")
        }

        samples.append(Sample(id: .memoryPhysical, value: Double(counts.physicalBytes), time: time))
        let compressed = counts.compressedBytes
        let usedQuality: DataQuality = compressed?.estimated == false ? .measured : .estimated
        samples.append(Sample(id: .memoryUsed, value: counts.usedBytes, quality: usedQuality, time: time))
        samples.append(
            Sample(id: .memoryUsage, value: counts.usedBytes / Double(counts.physicalBytes), quality: usedQuality, time: time))
        samples.append(Sample(id: .memoryApp, value: counts.appBytes, time: time))
        samples.append(Sample(id: .memoryWired, value: counts.wiredBytes, time: time))
        if let compressed {
            samples.append(
                Sample(id: .memoryCompressed, value: compressed.value, quality: compressed.estimated ? .estimated : .measured, time: time))
        } else {
            samples.append(.unavailable(.memoryCompressed, reason: .readFailed("compressor"), at: time))
        }
        samples.append(Sample(id: .memoryCached, value: counts.cachedBytes, time: time))
        samples.append(Sample(id: .memoryFree, value: counts.freeBytes, time: time))
        if let ratio = counts.compressionRatio {
            samples.append(Sample(id: .memoryCompressionRatio, value: ratio, time: time))
        } else {
            samples.append(
                .unavailable(
                    .memoryCompressionRatio,
                    reason: counts.compressorPages == 0 ? .nothingCompressed() : .readFailed("host_statistics64"), at: time))
        }

        if let available = pressure.availablePercent {
            samples.append(Sample(id: .memoryPressure, value: 1 - Double(min(max(available, 0), 100)) / 100, time: time))
        } else {
            degraded = true
            samples.append(.unavailable(.memoryPressure, reason: .readFailed("kern.memorystatus_level"), at: time))
        }
        let current = pressure.level.flatMap(MemoryPressureLevel.init(rawValue:))
        if let level = [current, peak].compactMap({ $0 }).max() {
            samples.append(Sample(id: .memoryPressureLevel, value: Double(level.rawValue), time: time))
        } else {
            degraded = true
            samples.append(
                .unavailable(.memoryPressureLevel, reason: .readFailed("kern.memorystatus_vm_pressure_level"), at: time))
        }

        if let swap {
            samples.append(Sample(id: .memorySwapUsed, value: Double(swap.used), time: time))
            samples.append(Sample(id: .memorySwapTotal, value: Double(swap.total), time: time))
        } else {
            degraded = true
            samples.append(.unavailable(.memorySwapUsed, reason: .readFailed("vm.swapusage"), at: time))
            samples.append(.unavailable(.memorySwapTotal, reason: .readFailed("vm.swapusage"), at: time))
        }

        if !statisticsOK {
            let reason = UnavailableReason.selfTestFailed("host_statistics64")
            samples += MemoryEventCounts.metricIDs.map { .unavailable($0, reason: reason, at: time) }
        } else if !stale {
            for id in MemoryEventCounts.metricIDs {
                guard let rate = rates[id] else { continue }  // 建立基线
                if let rate {
                    samples.append(Sample(id: id, value: rate, time: time))
                } else {
                    samples.append(.unavailable(id, reason: .counterReset(), at: time))
                }
            }
        }

        let warnings = state.withLock { $0.warnings }
        return CollectorOutput(
            samples: samples, status: degraded || warnings || !statisticsOK ? .degraded : .ok, dataPath: path,
            staleCount: staleCount)
    }

    public func resetBaseline() {
        state.withLock {
            $0.previous = nil
            $0.eventPeak = nil
        }
    }

    // MARK: - 读取

    static let allIDs: [MetricID] =
        [
            .memoryPhysical, .memoryUsed, .memoryUsage, .memoryApp, .memoryWired, .memoryCompressed, .memoryCached,
            .memoryFree, .memoryCompressionRatio, .memoryPressure, .memoryPressureLevel, .memorySwapUsed, .memorySwapTotal,
        ] + MemoryEventCounts.metricIDs

    /// 读页面队列；`statistics` 给出时同时填入被压缩页与压缩器里的原始页数。
    static func readCounts(statistics: VMStatistics?) -> MemoryCounts? {
        guard let pageSize = sysctlUInt64("hw.pagesize"), pageSize > 0, let physical = sysctlUInt64("hw.memsize"),
            let free = sysctlUInt64("vm.page_free_count"), let internalPages = sysctlUInt64("vm.page_pageable_internal_count"),
            let externalPages = sysctlUInt64("vm.page_pageable_external_count"),
            let purgeable = sysctlUInt64("vm.page_purgeable_count"), let wired = sysctlUInt64("vm.page_wired_count")
        else { return nil }
        return MemoryCounts(
            pageSize: pageSize, physicalBytes: physical, usableBytes: sysctlUInt64("hw.memsize_usable"), free: free,
            internalPages: internalPages, externalPages: externalPages, purgeable: purgeable, wired: wired,
            compressorPages: statistics.map { UInt64($0.raw.compressor_page_count) },
            uncompressedPagesInCompressor: statistics.map { $0.raw.total_uncompressed_pages_in_compressor })
    }

    static func readVMStatistics() -> VMStatistics? {
        var raw = vm_statistics64_data_t()
        var count = Self.vmInfo64Count
        let kr = withUnsafeMutablePointer(to: &raw) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(CPULoadCollector.host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return VMStatistics(raw: raw, count: count)
    }

    static func readPressure() -> (level: Int?, availablePercent: Int?) {
        (sysctlUInt64("kern.memorystatus_vm_pressure_level").map(Int.init), sysctlUInt64("kern.memorystatus_level").map(Int.init))
    }

    static func readSwap() -> (total: UInt64, used: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0, size == MemoryLayout<xsw_usage>.size else {
            return nil
        }
        return (usage.xsu_total, usage.xsu_used)
    }

    /// 读 4 或 8 字节的无符号整数 sysctl。
    public static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 8: return value
        case 4: return value & 0xffff_ffff
        default: return nil
        }
    }
}

extension UnavailableReason {
    /// 压缩器里没有页，压缩比无从谈起（UI 显示「—」）。
    public static func nothingCompressed(_ detail: String? = nil) -> Self { Self(code: "nothingCompressed", detail: detail) }
}

/// 诊断页的内存读数（D49：MTE、ECC 只放诊断页，含义未经验证）。读一次约 0.1 ms，只在诊断页刷新时调用。
public struct MemoryDiagnosticReadings: Hashable, Sendable {
    public var pageSize: UInt64?
    public var physicalBytes: UInt64?
    public var usableBytes: UInt64?
    /// 引导时被占用的页（`boot_stolen_count`，rev6）。
    public var bootStolenPages: UInt64?
    /// 可执行文件映射的常驻页、共享区页（rev6）。
    public var executablePages: UInt64?
    public var sharedRegionPages: UInt64?
    /// ECC 纠错计数（`vm.vm_ecc_corrected_count` / `_uncorrected_count`）；没有这个 sysctl 时为 nil。
    public var eccCorrected: UInt64?
    public var eccUncorrected: UInt64?
    /// MTE（只在有 `vm.mte.*` 的芯片上，2026-10-16 实测只有 M5）：带标签的页、标签存储区页数。
    public var mteTaggedPages: UInt64?
    public var mteTagStoragePages: UInt64?
    public var mteFreeTagStoragePages: UInt64?

    public static func read() -> Self {
        let stats = MemoryCollector.readVMStatistics()
        let rev6 = stats?.count == MemoryCollector.vmInfo64Count
        let mte = MemoryCollector.sysctlUInt64("vm.mte.tagged")
        return Self(
            pageSize: MemoryCollector.sysctlUInt64("hw.pagesize"), physicalBytes: MemoryCollector.sysctlUInt64("hw.memsize"),
            usableBytes: MemoryCollector.sysctlUInt64("hw.memsize_usable"),
            bootStolenPages: rev6 ? stats?.raw.boot_stolen_count : nil, executablePages: rev6 ? stats?.raw.executable_count : nil,
            sharedRegionPages: rev6 ? stats?.raw.shared_region_count : nil,
            eccCorrected: MemoryCollector.sysctlUInt64("vm.vm_ecc_corrected_count"),
            eccUncorrected: MemoryCollector.sysctlUInt64("vm.vm_ecc_uncorrected_count"), mteTaggedPages: mte,
            mteTagStoragePages: mte != nil && rev6 ? stats?.raw.total_tag_storage_pages : nil,
            mteFreeTagStoragePages: mte != nil && rev6 ? stats?.raw.free_tag_storage_pages : nil)
    }
}
