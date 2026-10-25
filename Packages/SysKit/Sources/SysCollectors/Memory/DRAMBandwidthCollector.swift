// DRAM 带宽采集器 `memory.bandwidth`（内存模块设计 §4.2，D49 M3）：只在诊断页展开「DRAM 带宽」时登记需求。
//
// - 数据源：IOReport「DCS BW」子组里内存控制器汇总的 `AMCC RD`、`AMCC WR` 两个直方图通道（私有，经 IOReportHub）。
//   每个状态是一档带宽，状态名形如「16GB/s」「32GB/s」（档的上界）。取两次样本之间各档的事件增量，
//   按档中点加权平均，得到这段时间的估算带宽；
// - 只作相对量（质量 relative）：分档 16 GB/s 一档，空闲时也落在第一、二档（约 8 GB/s），2026-09-28 实测
//   DRAM 流式负载下与 CPU 侧流量相差约 5%，缓存内的拷贝不计入；
// - 组名随芯片不同（M5 `PMP0`、M4 `PMP`，2026-10-16 实测），按候选组依次找含「DCS BW」子组与 AMCC 通道的那个，
//   不按芯片写死；
// - 枚举一个组首次要 30–60 ms，所以启动自检不枚举，第一次有需求时才发现通道并订阅（之后的复检照常核对）。

import Foundation
import Synchronization
import SysModel

/// 直方图的分档：由状态名解析出每档的上界，算加权平均。纯函数，便于单测。
public struct BandwidthHistogram: Hashable, Sendable {
    /// 每档上界，字节/秒；顺序与状态一致。
    public var upperBounds: [Double]

    public init(upperBounds: [Double]) {
        self.upperBounds = upperBounds
    }

    /// 由状态名（「16GB/s」「512GB/s」「800MB/s」）解析；有任何一个解析不了时为 nil。
    public init?(stateNames: [String]) {
        guard !stateNames.isEmpty else { return nil }
        var bounds: [Double] = []
        for name in stateNames {
            guard let value = Self.parse(name) else { return nil }
            bounds.append(value)
        }
        // 上界必须严格递增，否则不是按带宽分档的直方图。
        guard zip(bounds, bounds.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        upperBounds = bounds
    }

    static func parse(_ name: String) -> Double? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [("GB/s", 1e9), ("MB/s", 1e6), ("KB/s", 1e3)]
        for (suffix, scale) in units where trimmed.hasSuffix(suffix) {
            guard let number = Double(trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)) else { return nil }
            return number * scale
        }
        return nil
    }

    /// 各档的中点：第一档取上界的一半，其余取相邻上界的中点。
    public var midpoints: [Double] {
        upperBounds.indices.map { i in i == 0 ? upperBounds[0] / 2 : (upperBounds[i - 1] + upperBounds[i]) / 2 }
    }

    /// 按事件增量加权的平均带宽；没有事件时为 nil。
    public func mean(counts: [Int64]) -> Double? {
        // 有负增量（计数器复位）时这一段不出数，不只跳过那一档。
        guard counts.count == upperBounds.count, counts.allSatisfy({ $0 >= 0 }) else { return nil }
        let mids = midpoints
        var weighted = 0.0
        var total = 0.0
        for (count, mid) in zip(counts, mids) where count > 0 {
            weighted += Double(count) * mid
            total += Double(count)
        }
        return total > 0 ? weighted / total : nil
    }
}

public final class DRAMBandwidthCollector: Collector {
    public static let collectorID: CollectorID = "memory.bandwidth"
    public static let dataPath = "IOReport DCS BW / AMCC RD, AMCC WR（分档估算，相对量）"
    /// 候选组（按顺序尝试）。只用来定位「DCS BW」子组，通道按子组和名字识别。
    static let candidateGroups = ["PMP0", "PMP"]
    static let subgroup = "DCS BW"
    static let readChannel = "AMCC RD"
    static let writeChannel = "AMCC WR"

    public var id: CollectorID { Self.collectorID }

    private struct State {
        var discovered = false
        var group: String?
        var subscription: IOReportSubscription?
        var read: BandwidthHistogram?
        var write: BandwidthHistogram?
        var failure: String?
    }

    private let state = Mutex(State())
    private let hub: IOReportHub

    public init(hub: IOReportHub = .shared) {
        self.hub = hub
    }

    /// 实际使用的组（诊断页）；还没发现时为 nil。
    public var group: String? { state.withLock { $0.group } }

    static func isAMCC(_ info: IOReportChannelInfo) -> Bool {
        info.key.subgroup == subgroup && (info.key.name == readChannel || info.key.name == writeChannel)
    }

    public func selfTest() -> SelfTestResult {
        var checks: [SelfTestCheck] = []
        checks.append(
            SelfTestCheck(
                name: "memory.bandwidth.ioreport", passed: hub.isAvailable,
                detail: hub.isAvailable ? "libIOReport resolved" : "libIOReport unavailable"))
        guard hub.isAvailable else { return SelfTestResult(checks: checks, dataPath: Self.dataPath) }
        // 还没用过：不在启动时枚举（30–60 ms），等第一次有需求。
        let discovered = state.withLock { $0.discovered }
        if discovered {
            state.withLock { $0 = State() }
            discover()
        }
        let (group, failure) = state.withLock { ($0.group, $0.failure) }
        checks.append(
            SelfTestCheck(
                name: "memory.bandwidth.channels", passed: !discovered || group != nil,
                detail: discovered ? (group.map { "\($0) / \(Self.subgroup)" } ?? failure ?? "not found") : "deferred until first use",
                severity: .advisory))
        return SelfTestResult(checks: checks, dataPath: Self.dataPath)
    }

    /// 找组、订阅、解析分档。订阅不跨隔离域：建立与保存都在锁内完成（自检和采样在引擎队列上串行执行）。
    private func discover() {
        let hub = hub
        state.withLock { s in
            s.discovered = true
            s.failure = "no \(Self.subgroup) AMCC channels in \(Self.candidateGroups.joined(separator: "/"))"
            for group in Self.candidateGroups {
                guard let infos = hub.channels(inGroup: group), infos.contains(where: Self.isAMCC) else { continue }
                guard let names = hub.stateNames(inGroup: group, where: Self.isAMCC) else {
                    s.failure = "\(group): state names unavailable"
                    continue
                }
                let read = names.first { $0.key.name == Self.readChannel }.flatMap { BandwidthHistogram(stateNames: $0.value) }
                let write = names.first { $0.key.name == Self.writeChannel }.flatMap { BandwidthHistogram(stateNames: $0.value) }
                guard let read, let write else {
                    s.failure = "\(group): unexpected state names"
                    continue
                }
                guard let subscription = hub.makeSubscription(selecting: [(group: group, include: Self.isAMCC)]) else {
                    s.failure = "\(group): subscription failed"
                    continue
                }
                s.group = group
                s.subscription = subscription
                s.read = read
                s.write = write
                s.failure = nil
                return
            }
        }
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        if !state.withLock({ $0.discovered }), hub.isAvailable { discover() }
        let result = state.withLock { s -> (read: Double?, write: Double?, ok: Bool) in
            guard let subscription = s.subscription, let read = s.read, let write = s.write else { return (nil, nil, false) }
            guard let deltas = subscription.sampleDelta() else { return (nil, nil, false) }
            let r = deltas.first { $0.key.name == Self.readChannel }.flatMap { read.mean(counts: $0.stateResidencies) }
            let w = deltas.first { $0.key.name == Self.writeChannel }.flatMap { write.mean(counts: $0.stateResidencies) }
            return (r, w, true)
        }
        guard result.ok else {
            let reason = UnavailableReason.readFailed(state.withLock { $0.failure } ?? "IOReport")
            return CollectorOutput(
                samples: [
                    .unavailable(.memoryBandwidthRead, reason: reason, at: time),
                    .unavailable(.memoryBandwidthWrite, reason: reason, at: time),
                ], status: .unavailable, dataPath: Self.dataPath)
        }
        var samples: [Sample] = []
        if let read = result.read { samples.append(Sample(id: .memoryBandwidthRead, value: read, quality: .relative, time: time)) }
        if let write = result.write { samples.append(Sample(id: .memoryBandwidthWrite, value: write, quality: .relative, time: time)) }
        return CollectorOutput(samples: samples, status: .ok, dataPath: Self.dataPath)
    }

    public func resetBaseline() {
        state.withLock { $0.subscription?.resetBaseline() }
    }
}
