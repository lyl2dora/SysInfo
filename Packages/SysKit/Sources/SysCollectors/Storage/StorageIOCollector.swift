// 每盘吞吐采集器 `storage.io`（存储模块设计 §4.2，D54）：公开接口，inline 通道。
//
// - 每次读全部物理盘驱动（`IOBlockStorageDriver`）的 Statistics 字典，按盘差分出读写 B/s、IOPS 与平均延迟；
// - 以物理盘为单位，RAID 成员各算各的，不合计（D54）；
// - 计数回退（驱动重载、盘重新出现）按复位处理：该盘这一段不可用，不钳为 0（CLAUDE.md）；
// - 平均延迟 = Δ总时间 ÷ Δ次数；区间里没有读（写）时延迟不可用。不给忙碌率：总时间在并发 IO 下重叠计数（调研报告 §1.4）。
//
// 自检（K19）：至少找到一块物理盘，且至少一块有 Statistics（必需）；每块盘都有 Statistics（提示）。

import Foundation
import Synchronization
import SysModel

public final class StorageIOCollector: Collector {
    public static let collectorID: CollectorID = "storage.io"
    public static let dataPath = "IOBlockStorageDriver Statistics（每块物理盘）"

    public var id: CollectorID { Self.collectorID }

    private struct State {
        var usable: Bool?
        var warnings = false
        var previous: [DiskKey: (counters: DiskIOCounters, nanos: UInt64)] = [:]
        var latest: [DiskKey: DiskIOCounters] = [:]
    }

    private let inventory: DiskInventory
    private let state = Mutex(State())

    public init(inventory: DiskInventory = .shared) {
        self.inventory = inventory
    }

    /// 每块盘最近一次读到的累计计数（详情页的错误与重试、诊断页）。
    public var latestCounters: [DiskKey: DiskIOCounters] { state.withLock { $0.latest } }

    public func selfTest() -> SelfTestResult {
        inventory.invalidate()
        let snapshot = inventory.snapshot()
        let disks = snapshot.inventory.disks
        let readable = disks.filter { snapshot.entries[$0.key].flatMap(DiskInventory.readCounters) != nil }
        var checks = [
            SelfTestCheck(
                name: "storage.io.disks", passed: !disks.isEmpty && !readable.isEmpty,
                detail: "physical=\(disks.count) withStatistics=\(readable.count)")
        ]
        if !disks.isEmpty {
            checks.append(
                SelfTestCheck(
                    name: "storage.io.statistics", passed: readable.count == disks.count,
                    detail: "\(readable.count)/\(disks.count)", severity: .advisory))
        }
        let result = SelfTestResult(checks: checks, dataPath: Self.dataPath)
        state.withLock {
            $0.usable = result.isUsable
            $0.warnings = !result.warnings.isEmpty
            $0.previous = [:]
        }
        return result
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        let (usable, warnings) = state.withLock { ($0.usable, $0.warnings) }
        let snapshot = inventory.snapshot()
        if usable == false {
            let reason = UnavailableReason.selfTestFailed()
            return CollectorOutput(
                samples: snapshot.inventory.disks.flatMap { disk in
                    Self.ioMetrics.map { .unavailable(.storageDisk(disk.key, $0), reason: reason, at: time) }
                },
                status: .unavailable, dataPath: Self.dataPath)
        }
        var current: [DiskKey: DiskIOCounters] = [:]
        for disk in snapshot.inventory.disks {
            if let entry = snapshot.entries[disk.key], let counters = DiskInventory.readCounters(entry) {
                current[disk.key] = counters
            }
        }
        var samples: [Sample] = []
        var degraded = warnings
        state.withLock { s in
            for disk in snapshot.inventory.disks {
                guard let now = current[disk.key] else {
                    degraded = true
                    s.previous[disk.key] = nil
                    samples += Self.ioMetrics.map {
                        .unavailable(.storageDisk(disk.key, $0), reason: .readFailed("Statistics"), at: time)
                    }
                    continue
                }
                defer { s.previous[disk.key] = (now, time.monotonicNanos) }
                guard let previous = s.previous[disk.key], time.monotonicNanos > previous.nanos else { continue }  // 建立基线
                let rates = Self.rates(previous: previous.counters, current: now, elapsedNanos: time.monotonicNanos - previous.nanos)
                for metric in Self.ioMetrics {
                    let id = MetricID.storageDisk(disk.key, metric)
                    switch rates[metric] {
                    case .some(.some(let value)):
                        samples.append(Sample(id: id, value: value, time: time))
                    case .some(.none) where metric == .readLatency || metric == .writeLatency:
                        samples.append(.unavailable(id, reason: .noIO(), at: time))
                    default:
                        samples.append(.unavailable(id, reason: .counterReset(), at: time))
                    }
                }
            }
            // 消失的盘：丢掉基线。
            s.previous = s.previous.filter { current[$0.key] != nil }
            s.latest = current
        }
        return CollectorOutput(samples: samples, status: degraded ? .degraded : .ok, dataPath: Self.dataPath)
    }

    public func resetBaseline() {
        state.withLock { $0.previous = [:] }
    }

    // MARK: - 计算

    static let ioMetrics: [MetricID.DiskMetric] = [.read, .write, .readOps, .writeOps, .readLatency, .writeLatency]

    /// 两次读数之间的速率与平均延迟（纯函数）。
    /// 返回值：某项为 `nil`（键不存在）表示计数回退、按复位处理；`.some(nil)` 表示延迟这一项区间内没有 IO。
    static func rates(previous: DiskIOCounters, current: DiskIOCounters, elapsedNanos: UInt64) -> [MetricID.DiskMetric: Double?] {
        guard elapsedNanos > 0 else { return [:] }
        let seconds = Double(elapsedNanos) / 1e9
        func delta(_ a: UInt64, _ b: UInt64) -> UInt64? { b >= a ? b - a : nil }
        var out: [MetricID.DiskMetric: Double?] = [:]
        let reads = delta(previous.reads, current.reads)
        let writes = delta(previous.writes, current.writes)
        if let d = delta(previous.bytesRead, current.bytesRead) { out[.read] = Double(d) / seconds }
        if let d = delta(previous.bytesWritten, current.bytesWritten) { out[.write] = Double(d) / seconds }
        if let reads { out[.readOps] = Double(reads) / seconds }
        if let writes { out[.writeOps] = Double(writes) / seconds }
        if let reads, let time = delta(previous.readTimeNanos, current.readTimeNanos) {
            out[.readLatency] = reads > 0 ? .some(Double(time) / Double(reads) / 1e9) : .some(nil)
        }
        if let writes, let time = delta(previous.writeTimeNanos, current.writeTimeNanos) {
            out[.writeLatency] = writes > 0 ? .some(Double(time) / Double(writes) / 1e9) : .some(nil)
        }
        return out
    }
}

extension UnavailableReason {
    /// 区间内没有 IO，平均延迟无从谈起（UI 显示「—」）。
    public static func noIO(_ detail: String? = nil) -> Self { Self(code: "noIO", detail: detail) }
    /// 这块盘不支持该数据（例如非 NVMe 盘没有 SMART）。
    public static func notSupported(_ detail: String? = nil) -> Self { Self(code: "notSupported", detail: detail) }
}
