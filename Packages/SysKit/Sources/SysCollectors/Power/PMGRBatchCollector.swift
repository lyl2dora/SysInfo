// PMGR 30 分钟批次采集器 `power.pmgr`（功耗与散热模块设计 §4.4，D45）。走阻塞通道，60 s 一次。
//
// - Energy Model 中 PMGR 驱动的通道每 1800 s 批量发布一次（相位随开机变化，边界稿 §2.3），只能按计数器变化检测；
// - 只订阅顶层通道（按档案 pmgrComponents，没有档案时按 PMGRNaming 推出）与 AGX「GPU Energy」，不订阅几百个子通道；
// - 有 ≥3 个 PMGR 通道同时变化即为新批次。批次 = 本次快照 − 上一次变化时的快照；开机后第一次变化只建基线；
// - 每个批次顺带做交叉核对（D44 §7）：AGX ÷ PMGR GPU 在 0.9–1.1；PZD1 积分 ÷ PMGR DRAM 在 0.98–1.02
//   （采样稀于 1.5 s 时放宽到 ±5%）；coalition 槽位 39 积分 ÷ PMGR ANE 在 0.8–1.05（D58）。结论记进账本，连续两次失败时对应指标改为不可用；
// - 状态（上一次变化的快照与最近一批）可以导出、恢复：历史库持久化它，重启后能立即显示上一批，
//   同一次开机里也不必再等两个批次。

import Foundation
import Synchronization
import SysModel

/// 可持久化的批次状态。
public struct PMGRState: Codable, Hashable, Sendable {
    /// 上一次检测到变化时各部件的累计焦耳数（归一化名 → J）与 AGX 累计焦耳数。
    public var snapshot: [String: Double]
    public var agx: Double?
    public var at: Date
    /// 那次开机的时刻（`kern.boottime`）：开机变了，计数器已复位，快照作废。
    public var bootTime: Date
    public var latestBatch: PMGRBatch?
}

public final class PMGRBatchCollector: Collector {
    public static let collectorID: CollectorID = "power.pmgr"
    public static let dataPath = "IOReport Energy Model (PMGR, 30-minute batches) + AGX GPU Energy"
    static let group = "Energy Model"
    /// 同时变化的通道数达到这个数才算新批次。
    static let batchThreshold = 3

    public var id: CollectorID { Self.collectorID }
    public let lane: CollectorLane = .blocking
    public let ledger: PowerLedger

    private struct Channel {
        var normalized: String
        var joulesPerUnit: Double
        var isAGX: Bool
    }

    private struct State {
        var subscription: IOReportSubscription?
        /// 订阅里的通道名 → 说明。
        var channels: [String: Channel] = [:]
        var lastSeen: [String: Double]?
        var lastChange: PMGRState?
        var restored: PMGRState?
        var latestBatch: PMGRBatch?
        var batchesSeen = 0
    }

    private let state = Mutex(State())
    private let hub: IOReportHub
    private let resolveProfile: @Sendable () -> ResolvedChipProfile?
    private let bootTime: @Sendable () -> Date?

    public convenience init(ledger: PowerLedger) {
        self.init(ledger: ledger, hub: .shared, resolveProfile: { PowerProfiles.resolve() }, bootTime: { SystemInfo.bootTime })
    }

    init(
        ledger: PowerLedger, hub: IOReportHub, resolveProfile: @escaping @Sendable () -> ResolvedChipProfile?,
        bootTime: @escaping @Sendable () -> Date?
    ) {
        self.ledger = ledger
        self.hub = hub
        self.resolveProfile = resolveProfile
        self.bootTime = bootTime
    }

    /// 最近一个批次（可能是恢复来的上一次运行的数据）。
    public var latestBatch: PMGRBatch? { state.withLock { $0.latestBatch } }
    /// 订阅的部件（归一化名），诊断页列出。
    public var components: [String] { state.withLock { $0.channels.values.filter { !$0.isAGX }.map(\.normalized).sorted() } }
    /// 需要持久化的状态；还没有任何变化快照时为 nil。
    public var persistentState: PMGRState? {
        state.withLock { s in
            guard var change = s.lastChange else { return nil }
            change.latestBatch = s.latestBatch
            return change
        }
    }

    /// 恢复上一次运行的状态（在第一次采样之前调用）。
    public func restore(_ saved: PMGRState) {
        state.withLock { s in
            s.restored = saved
            if s.latestBatch == nil { s.latestBatch = saved.latestBatch }
        }
    }

    // MARK: - Collector

    public func selfTest() -> SelfTestResult {
        var checks: [SelfTestCheck] = []
        let infos = hub.channels(inGroup: Self.group) ?? []
        let pmgr = infos.filter { $0.driverName?.contains("PMGR") ?? false }
        let system = resolveProfile()?.profile.system
        let mapping =
            (system?.pmgrComponents).flatMap { $0.isEmpty ? nil : $0 } ?? PMGRNaming.components(from: pmgr.map(\.key.name))
        let wanted = Dictionary(mapping.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        var channels: [String: Channel] = [:]
        for info in pmgr {
            guard let normalized = wanted[info.key.name], let unit = GPUPowerCollector.joulesPerUnit(info.unitLabel) else {
                continue
            }
            channels[info.key.name] = Channel(normalized: normalized, joulesPerUnit: unit, isAGX: false)
        }
        if let agx = infos.first(where: GPUPowerCollector.isAGXGPUEnergy),
            let unit = GPUPowerCollector.joulesPerUnit(agx.unitLabel)
        {
            channels["GPU Energy"] = Channel(normalized: "agx", joulesPerUnit: unit, isAGX: true)
        }
        let hasCore = channels.values.contains { $0.normalized == "cpu" } && channels.values.contains { $0.normalized == "gpu" }
        checks.append(
            SelfTestCheck(
                name: "power.pmgr.channels", passed: hasCore,
                detail: "\(pmgr.count) PMGR channels; subscribed \(channels.values.map(\.normalized).sorted())"))
        state.withLock { s in
            s.subscription = nil
            s.channels = channels
            s.lastSeen = nil
            guard hasCore else { return }
            let names = Set(channels.keys)
            let subscription = hub.makeSubscription(selecting: [
                (group: Self.group, include: { info in
                    names.contains(info.key.name)
                        && ((info.driverName?.contains("PMGR") ?? false) || GPUPowerCollector.isAGXGPUEnergy(info))
                })
            ])
            checks.append(
                SelfTestCheck(
                    name: "power.pmgr.subscription", passed: subscription != nil,
                    detail: "\(subscription?.channelCount ?? 0) channels"))
            s.subscription = subscription
        }
        let result = SelfTestResult(checks: checks, dataPath: Self.dataPath)
        if !result.isUsable { state.withLock { $0.subscription = nil } }
        return result
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        let boot = bootTime()
        let event = state.withLock { s -> (usable: Bool, batch: PMGRBatch?) in
            guard let subscription = s.subscription, let values = subscription.snapshot() else { return (false, nil) }
            var current: [String: Double] = [:]
            var agx: Double?
            for value in values {
                guard let channel = s.channels[value.key.name] else { continue }
                let joules = Double(value.integerValue) * channel.joulesPerUnit
                if channel.isAGX {
                    agx = joules
                } else {
                    current[channel.normalized, default: 0] += joules
                }
            }
            let now = PMGRState(snapshot: current, agx: agx, at: time.wallClock, bootTime: boot ?? .distantPast, latestBatch: nil)
            defer { s.lastSeen = current }
            guard let lastSeen = s.lastSeen else {
                // 第一次：恢复的快照与当前一致（同一次开机、其间没有新批次）才接着用。
                if let restored = s.restored, let boot, abs(restored.bootTime.timeIntervalSince(boot)) < 2,
                    restored.snapshot == current
                {
                    s.lastChange = restored
                }
                s.restored = nil
                return (true, nil)
            }
            let changed = current.filter { name, value in lastSeen[name].map { $0 != value } ?? false }.count
            guard changed >= Self.batchThreshold else { return (true, nil) }
            defer {
                s.lastChange = now
                s.batchesSeen += 1
            }
            guard let previous = s.lastChange, current.allSatisfy({ name, value in (previous.snapshot[name] ?? 0) <= value })
            else { return (true, nil) }
            let joules = current.reduce(into: [String: Double]()) { $0[$1.key] = $1.value - (previous.snapshot[$1.key] ?? 0) }
            let agxJoules = bothPresent(agx, previous.agx).flatMap { $0 >= $1 ? $0 - $1 : nil }
            let batch = PMGRBatch(start: previous.at, end: time.wallClock, joules: joules, agxJoules: agxJoules)
            s.latestBatch = batch
            return (true, batch)
        }
        guard event.usable else {
            return CollectorOutput(samples: [], status: .unavailable, dataPath: Self.dataPath)
        }
        if let batch = event.batch { crossCheck(batch) }
        return CollectorOutput(samples: [], status: .ok, dataPath: Self.dataPath)
    }

    public func resetBaseline() {}

    /// 批次到达时的交叉核对（D44 §7）。
    /// GPU 核对需要的最低窗口均值，W：空闲时 GPU 只有几十毫瓦，比值会飘（M5 空闲实测 1.074，满载 1.002），
    /// 低于它时这一批不下结论，免得误判后停用 GPU 功率。
    static let minimumGPUWatts = 0.3
    /// ANE 核对的最低窗口均值，W（D58）：空闲时 ANE 批次只有零点几焦耳，比值没有意义。
    static let minimumANEWatts = 0.05

    func crossCheck(_ batch: PMGRBatch) {
        if let pmgr = batch.joules["gpu"], pmgr > 1, let agx = batch.agxJoules {
            let enough = pmgr / batch.seconds >= Self.minimumGPUWatts
            ledger.record(.gpu, ratio: enough ? agx / pmgr : nil, range: PowerLedger.ranges[.gpu]!, at: batch.end)
        }
        // ANE 估算（D58）：coalition 扫描不常驻（面板 Top N、历史的每应用记录），覆盖不足 90% 时不下结论。
        if let pmgr = batch.joules["ane"], pmgr > 0 {
            let integral = ledger.aneIntegral(from: batch.start, to: batch.end)
            let enough = pmgr / batch.seconds >= Self.minimumANEWatts
            let covered = integral.map { $0.covered >= batch.seconds * 0.9 } ?? false
            ledger.record(
                .ane, ratio: enough && covered ? integral.map { $0.joules / pmgr } : nil, range: PowerLedger.ranges[.ane]!,
                at: batch.end)
        }
        if let pmgr = batch.joules["dram"], pmgr > 1 {
            let integral = ledger.dramIntegral(from: batch.start, to: batch.end)
            let range = (integral?.meanInterval ?? 99) <= 1.5 ? PowerLedger.ranges[.dram]! : PowerLedger.relaxedDRAMRange
            let covered = integral.map { $0.covered >= batch.seconds * 0.9 } ?? false
            ledger.record(.dram, ratio: covered ? integral.map { $0.joules / pmgr } : nil, range: range, at: batch.end)
        }
    }
}

private func bothPresent(_ a: Double?, _ b: Double?) -> (Double, Double)? {
    guard let a, let b else { return nil }
    return (a, b)
}
