// 逐核频率采集器 `cpu.freq.cores`（CPU 模块设计 §5.4、§7.4，D29：逐核频率只进诊断页）。
//
// - 只在诊断页可见时登记需求（2 s 一次）；订阅本方案里全部逐核通道（「CPU Core Performance States」），
//   频率按所属簇的 DVFS 表换算；
// - 被动判据的后半（偏离记录 2026-10-15 推迟到第 7 步）：同一窗口内再读一次每核 tick，
//   要求「每核 tick 忙碌比例」与「逐核通道活跃驻留比例」的相关系数 ≥ 0.99。两者都几乎不变（全空闲或全满载）时
//   相关系数没有意义，记为「不确定」；
// - 不出样本、不入历史，结果放在 `latest` 里给诊断页读。

import Synchronization
import SysModel

/// 一个核的逐核读数。
public struct CoreFrequencyDetail: Hashable, Sendable {
    public var cpu: Int
    public var cluster: ClusterKey
    public var reading: ClusterFrequencyReading?
    /// 每核 tick 忙碌比例（同一窗口）。
    public var busy: Double?
}

/// 一个窗口的逐核结果。
public struct CoreFrequencySnapshot: Hashable, Sendable {
    public var cores: [CoreFrequencyDetail]
    /// 忙碌比例与活跃驻留比例的相关系数；样本不够分散时为 nil。
    public var correlation: Double?

    public static let requiredCorrelation = 0.99

    public var correlationPassed: Bool? { correlation.map { $0 >= Self.requiredCorrelation } }
}

public final class CoreFrequencyCollector: Collector {
    public static let collectorID: CollectorID = "cpu.freq.cores"
    public static let dataPath = "IOReport CPU Stats / CPU Core Performance States × host_processor_info"

    public var id: CollectorID { Self.collectorID }

    private struct State: ~Copyable {
        var subscription: IOReportSubscription?
        var planKey: FrequencyPlan?
        var previousTicks: [CoreTicks]?
        var latest: CoreFrequencySnapshot?
    }

    private let state = Mutex(State())
    /// 频率方案由 `cpu.freq` 发现，这里只复用。
    private let plan: @Sendable () -> FrequencyPlan?

    public init(frequency: CPUFrequencyCollector) {
        plan = { frequency.plan }
    }

    public var latest: CoreFrequencySnapshot? { state.withLock { $0.latest } }

    public func selfTest() -> SelfTestResult {
        let count = plan()?.clusters.reduce(0) { $0 + $1.channels.coreChannels.count } ?? 0
        return SelfTestResult(
            checks: [
                SelfTestCheck(
                    name: "cpu.freq.cores.channels", passed: count > 0,
                    detail: count > 0 ? "\(count) core channels" : "no frequency plan yet")
            ],
            dataPath: Self.dataPath)
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        guard let plan = plan() else {
            return CollectorOutput(samples: [], status: .unavailable, dataPath: Self.dataPath)
        }
        let ticks = try? CPULoadCollector.readTicks().get()
        return state.withLock { s in
            if s.subscription == nil || s.planKey != plan {
                let names = Set(plan.clusters.flatMap(\.channels.coreChannels))
                s.subscription = IOReportHub.shared.makeSubscription(selecting: [
                    (group: "CPU Stats", include: { $0.key.subgroup == FrequencyPlan.coreSubgroup && names.contains($0.key.name) })
                ])
                s.planKey = plan
                s.previousTicks = nil
            }
            guard let subscription = s.subscription, let deltas = subscription.sampleDelta() else {
                return CollectorOutput(samples: [], status: .unavailable, dataPath: Self.dataPath)
            }
            defer { s.previousTicks = ticks }
            guard !deltas.isEmpty, let previous = s.previousTicks, let ticks else {
                return CollectorOutput(samples: [], status: .ok, dataPath: Self.dataPath)  // 建立基线
            }
            s.latest = Self.snapshot(plan: plan, deltas: deltas, previousTicks: previous, ticks: ticks)
            return CollectorOutput(samples: [], status: .ok, dataPath: Self.dataPath)
        }
    }

    public func resetBaseline() {
        state.withLock {
            $0.subscription?.resetBaseline()
            $0.previousTicks = nil
        }
    }

    /// 组装一个窗口的结果（纯函数，便于单测）。逐核通道按出现顺序对应本簇的逻辑核（§5.4）。
    static func snapshot(
        plan: FrequencyPlan, deltas: [IOReportChannelDelta], previousTicks: [CoreTicks], ticks: [CoreTicks],
        cpusByCluster: [ClusterKey: [Int]]? = nil
    ) -> CoreFrequencySnapshot {
        let byName = Dictionary(deltas.map { ($0.key.name, $0) }, uniquingKeysWith: { a, _ in a })
        let topology = cpusByCluster ?? Dictionary(
            uniqueKeysWithValues: (CPUTopologyService.shared.current?.clusters ?? []).map { ($0.key, $0.cpus) })
        var cores: [CoreFrequencyDetail] = []
        var pairs: [(busy: Double, active: Double)] = []
        for cluster in plan.clusters {
            let cpus = topology[cluster.cluster] ?? []
            for (offset, name) in cluster.channels.coreChannels.enumerated() where offset < cpus.count {
                let cpu = cpus[offset]
                let reading: ClusterFrequencyReading? =
                    if let table = cluster.table, let d = byName[name] {
                        FrequencyMath.frequency(stateNames: d.stateNames, residencies: d.stateResidencies, table: table)
                    } else { nil }
                var busy: Double?
                if cpu < ticks.count, cpu < previousTicks.count, ticks[cpu].isMonotonic(since: previousTicks[cpu]) {
                    let total = ticks[cpu].total - previousTicks[cpu].total
                    if total > 0 { busy = Double(ticks[cpu].busy - previousTicks[cpu].busy) / Double(total) }
                }
                cores.append(CoreFrequencyDetail(cpu: cpu, cluster: cluster.cluster, reading: reading, busy: busy))
                let active: Double? =
                    switch reading {
                    case .active(_, let f)?: f
                    case .idle(let f)?: f
                    default: nil
                    }
                if let busy, let active { pairs.append((busy, active)) }
            }
        }
        cores.sort { $0.cpu < $1.cpu }
        return CoreFrequencySnapshot(cores: cores, correlation: correlation(pairs))
    }

    /// 皮尔逊相关系数；点数少于 4、或任一方的标准差小于 0.02（几乎不变）时为 nil。
    static func correlation(_ pairs: [(busy: Double, active: Double)]) -> Double? {
        let n = Double(pairs.count)
        guard pairs.count >= 4 else { return nil }
        let mx = pairs.reduce(0) { $0 + $1.busy } / n
        let my = pairs.reduce(0) { $0 + $1.active } / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for p in pairs {
            sxy += (p.busy - mx) * (p.active - my)
            sxx += (p.busy - mx) * (p.busy - mx)
            syy += (p.active - my) * (p.active - my)
        }
        guard (sxx / n).squareRoot() >= 0.02, (syy / n).squareRoot() >= 0.02 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }
}
