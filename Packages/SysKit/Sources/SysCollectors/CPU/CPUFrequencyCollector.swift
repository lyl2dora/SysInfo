// CPU 频率采集器 `cpu.freq`（CPU 模块设计 §5.4，D29、D34）。
//
// 数据源：IOReport「CPU Stats / CPU Complex Performance States」里每簇的实际频率通道，
// 各 V 状态驻留 × DVFS 表，按活跃驻留加权平均。驻留是积分量，采样间隔多长都不丢平均值，
// 所以面板默认 5 s、后台 60 s（真实节奏下每次约 8.5–9.5 ms）。
//
// 自检（D05、K19，按簇逐项判定）：
// - 必需：IOReport 可用；拓扑至少能分簇；至少一个簇有合法的表；订阅建得起来；
// - 提示：每簇都有实际通道、两条实际通道规则一致、表合法；驻留增量之和 / 墙钟 ≈ timebase 频率；
// - 主动核对：采样线程自旋约 50 ms，用本线程的内核计数（cycles / CPU 时间）比对它所在簇的实际通道，阈值 ±5%。
//   实际通道不过、请求通道过：全部退回请求频率并标「估算」；两者都不过：频率不可用。
//   这一项只能验证线程所在的那个簇（通常是 perflevel0 或最慢档），其余簇靠被动核对（第 5 步，设计 §5.4）。

import Darwin
import Synchronization
import SysModel

/// 一个簇在最近一次采样里的频率细节（诊断页、`sysinfo-cli freq`）。
public struct ClusterFrequencyDetail: Hashable, Sendable {
    public var cluster: ClusterKey
    public var actual: ClusterFrequencyReading?
    public var request: ClusterFrequencyReading?
    /// 输出给 `cpu.freq.cluster.*` 的是哪一个。
    public var source: CPUFrequencyCollector.Source
}

public final class CPUFrequencyCollector: Collector {
    public static let collectorID: CollectorID = "cpu.freq"
    public static let dataPath = "IOReport CPU Stats / CPU Complex Performance States × pmgr voltage-states-sram"

    /// 输出的频率来自哪种通道。
    public enum Source: String, Hashable, Sendable {
        case actual
        /// 实际通道缺失或核对不过：退回请求频率，标为估算（多核时偏高 7–17%）。
        case request
    }

    public var id: CollectorID { Self.collectorID }

    private struct State: ~Copyable {
        var plan: FrequencyPlan?
        var planGeneration: UInt64?
        var subscription: IOReportSubscription?
        /// 自检必需项是否通过；nil 表示还没自检过。
        var usable: Bool?
        var warnings = false
        /// 主动核对的结论：全部簇统一用实际或请求通道。
        var forceRequest = false
        var details: [ClusterFrequencyDetail] = []
    }

    private let state = Mutex(State())
    private let hub: IOReportHub
    private let topology: CPUTopologyService

    public convenience init() {
        self.init(hub: .shared, topology: .shared)
    }

    init(hub: IOReportHub, topology: CPUTopologyService) {
        self.hub = hub
        self.topology = topology
    }

    /// 最近一次采样每个簇的细节。
    public var latestDetails: [ClusterFrequencyDetail] { state.withLock { $0.details } }

    /// 当前的采样方案（诊断页、CLI）。
    public var plan: FrequencyPlan? { state.withLock { $0.plan } }

    // MARK: - Collector

    public func selfTest() -> SelfTestResult {
        var checks: [SelfTestCheck] = []
        func finish(usable: Bool) -> SelfTestResult {
            let result = SelfTestResult(checks: checks, dataPath: Self.dataPath)
            state.withLock {
                $0.usable = usable && result.isUsable
                $0.warnings = !result.warnings.isEmpty
            }
            return result
        }

        guard hub.isAvailable else {
            checks.append(SelfTestCheck(name: "cpu.freq.ioreport", passed: false, detail: "libIOReport symbols missing"))
            return finish(usable: false)
        }
        checks.append(SelfTestCheck(name: "cpu.freq.ioreport", passed: true, detail: "available"))

        let topo = topology.current ?? topology.refresh()
        guard !topo.clusters.isEmpty else {
            checks.append(SelfTestCheck(name: "cpu.freq.topology", passed: false, detail: CPULoadCollector.describe(topo)))
            return finish(usable: false)
        }

        let plan = FrequencyPlan.discover(clusters: topo.clusters, logicalCPUCount: topo.logicalCPUCount, hub: hub)
        let withTable = plan.clusters.filter { $0.table != nil }
        checks.append(
            SelfTestCheck(
                name: "cpu.freq.plan", passed: !withTable.isEmpty,
                detail: "\(withTable.count)/\(topo.clusters.count) clusters have a valid DVFS table"
                    + (plan.failures.isEmpty ? "" : "; " + plan.failures.joined(separator: "; "))))
        let problems = plan.clusters.flatMap { p in p.problems.map { "\(p.cluster): \($0)" } } + plan.failures
        checks.append(
            SelfTestCheck(
                name: "cpu.freq.plan.complete", passed: problems.isEmpty,
                detail: problems.isEmpty ? Self.describe(plan) : problems.joined(separator: "; "), severity: .advisory))

        // 订阅不跨隔离域：建立、核对、保存都在锁内完成（自检和采样本来就在引擎队列上串行执行）。
        let generation = topology.generation
        let usable = state.withLock { s -> Bool in
            let subscription = makeSubscription(for: plan)
            checks.append(
                SelfTestCheck(
                    name: "cpu.freq.subscribe", passed: subscription != nil,
                    detail: subscription.map { "\($0.channelCount) channels" } ?? "subscription failed"))
            guard let subscription, !withTable.isEmpty else { return false }

            // 驻留积分：两次采样相隔约 200 ms。
            checks.append(Self.residencyCheck(subscription: subscription, plan: plan))
            // 主动核对：自旋 50 ms，最多试 3 次（线程跨簇迁移时结论不确定）。
            let spin = Self.spinCheck(subscription: subscription, plan: plan, topology: topo)
            checks.append(spin.check)

            subscription.resetBaseline()
            s.plan = plan
            s.planGeneration = generation
            s.subscription = subscription
            s.forceRequest = spin.forceRequest
            return spin.usable
        }
        return finish(usable: usable)
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        state.withLock { state in
            guard state.usable != false, let plan = state.plan, let subscription = state.subscription else {
                return CollectorOutput(samples: [], status: .unavailable, dataPath: Self.dataPath)
            }
            // 拓扑变了（簇的组成不同）：旧方案作废，输出不可用；引擎连续收到不可用后会重新自检（K19）。
            guard state.planGeneration == topology.generation else {
                let samples = plan.clusters.map {
                    Sample.unavailable(.cpuFrequencyCluster($0.cluster), reason: .selfTestFailed("topology changed"), at: time)
                }
                return CollectorOutput(samples: samples, status: .unavailable, dataPath: Self.dataPath)
            }
            guard let deltas = subscription.sampleDelta() else {
                let samples = plan.clusters.map {
                    Sample.unavailable(.cpuFrequencyCluster($0.cluster), reason: .readFailed("IOReportCreateSamples"), at: time)
                }
                return CollectorOutput(samples: samples, status: .unavailable, dataPath: Self.dataPath)
            }
            guard !deltas.isEmpty else {
                return CollectorOutput(samples: [], status: .ok, dataPath: Self.dataPath)  // 建立基线
            }
            let byName = Dictionary(deltas.map { ($0.key.name, $0) }, uniquingKeysWith: { a, _ in a })
            var samples: [Sample] = []
            var details: [ClusterFrequencyDetail] = []
            var degraded = state.warnings || state.forceRequest
            for cluster in plan.clusters {
                let id = MetricID.cpuFrequencyCluster(cluster.cluster)
                guard let table = cluster.table else {
                    samples.append(.unavailable(id, reason: .selfTestFailed("no valid DVFS table"), at: time))
                    degraded = true
                    continue
                }
                func reading(_ name: String?) -> ClusterFrequencyReading? {
                    guard let name, let delta = byName[name] else { return nil }
                    return FrequencyMath.frequency(stateNames: delta.stateNames, residencies: delta.stateResidencies, table: table)
                }
                let actual = reading(cluster.channels.actual)
                let request = reading(cluster.channels.request)
                let useRequest = state.forceRequest || actual == nil
                details.append(
                    ClusterFrequencyDetail(
                        cluster: cluster.cluster, actual: actual, request: request, source: useRequest ? .request : .actual))
                switch useRequest ? request : actual {
                case .active(let hz, _)?:
                    samples.append(Sample(id: id, value: hz, quality: useRequest ? .estimated : .measured, time: time))
                case .idle(let fraction)?:
                    samples.append(.unavailable(id, reason: .clusterIdle("active \(fraction)"), at: time))
                case .invalid(let why)?:
                    samples.append(.unavailable(id, reason: .readFailed(why), at: time))
                    degraded = true
                case nil:
                    samples.append(.unavailable(id, reason: .readFailed("channel missing in sample"), at: time))
                    degraded = true
                }
            }
            state.details = details
            return CollectorOutput(samples: samples, status: degraded ? .degraded : .ok, dataPath: Self.dataPath)
        }
    }

    public func resetBaseline() {
        state.withLock { $0.subscription?.resetBaseline() }
    }

    // MARK: - 订阅

    /// 只订阅方案里用到的簇通道（实际 + 请求），不订阅逐核通道。
    private func makeSubscription(for plan: FrequencyPlan) -> IOReportSubscription? {
        let names = Set(plan.clusters.flatMap { [$0.channels.request] + ($0.channels.actual.map { [$0] } ?? []) })
        guard !names.isEmpty else { return nil }
        return hub.makeSubscription(selecting: [
            (group: "CPU Stats", include: { $0.key.subgroup == FrequencyPlan.complexSubgroup && names.contains($0.key.name) })
        ])
    }

    static func describe(_ plan: FrequencyPlan) -> String {
        plan.clusters.map { p in
            let table = p.table.map { "k\($0.key) \($0.frequencies.count)×\($0.unit) top \(Int($0.top / 1e6))MHz" } ?? "no table"
            return "\(p.cluster): \(p.channels.actual ?? "-")/\(p.channels.request) \(table)"
        }.joined(separator: "; ")
    }

    // MARK: - 自检

    /// 驻留增量之和 / 墙钟应约等于 timebase 频率（边界稿 §2.2 实测 0.97–1.02；200 ms 窗口放宽到 0.95–1.05）。
    static func residencyCheck(subscription: IOReportSubscription, plan: FrequencyPlan) -> SelfTestCheck {
        subscription.resetBaseline()
        _ = subscription.sampleDelta()
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        usleep(200_000)
        let deltas = subscription.sampleDelta() ?? []
        let elapsed = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start)
        guard let timebase = MachTimebase.current, !deltas.isEmpty else {
            return SelfTestCheck(name: "cpu.freq.residency", passed: false, detail: "no samples", severity: .advisory)
        }
        let ticksPerNano = Double(timebase.denom) / Double(timebase.numer)
        let names = Set(plan.clusters.compactMap(\.channels.actual))
        var bad: [String] = []
        var ratios: [String] = []
        for delta in deltas where names.contains(delta.key.name) {
            let ratio = Double(delta.stateResidencies.reduce(0, +)) / (elapsed * ticksPerNano)
            ratios.append("\(delta.key.name)=\((ratio * 1000).rounded() / 1000)")
            if !(0.95...1.05).contains(ratio) { bad.append(delta.key.name) }
        }
        return SelfTestCheck(
            name: "cpu.freq.residency", passed: bad.isEmpty && !ratios.isEmpty,
            detail: ratios.joined(separator: " "), severity: .advisory)
    }

    struct SpinOutcome {
        var check: SelfTestCheck
        var forceRequest: Bool
        var usable: Bool
    }

    /// 主动核对。线程 ≥90% 的时间停在同一个簇上才下结论；最多试 3 次。
    static func spinCheck(subscription: IOReportSubscription, plan: FrequencyPlan, topology: CPUTopology) -> SpinOutcome {
        for _ in 0..<3 {
            guard let probe = spin(subscription: subscription, topology: topology, nanos: 50_000_000) else { continue }
            guard let cluster = plan.clusters.first(where: { $0.cluster == probe.cluster }), let table = cluster.table,
                let delta = probe.deltas.first(where: { $0.key.name == cluster.channels.actual })
                    ?? probe.deltas.first(where: { $0.key.name == cluster.channels.request })
            else { continue }
            func error(of name: String?) -> Double? {
                guard let name, let d = probe.deltas.first(where: { $0.key.name == name }),
                    case .active(let hz, _) = FrequencyMath.frequency(stateNames: d.stateNames, residencies: d.stateResidencies, table: table)
                else { return nil }
                return hz / probe.kernelHz - 1
            }
            _ = delta
            let actualError = error(of: cluster.channels.actual)
            let requestError = error(of: cluster.channels.request)
            let detail =
                "\(probe.cluster) kernel \(Int(probe.kernelHz / 1e6))MHz, actual \(percent(actualError)), request \(percent(requestError))"
            if let e = actualError, abs(e) <= 0.05 {
                return SpinOutcome(
                    check: SelfTestCheck(name: "cpu.freq.spin", passed: true, detail: detail, severity: .advisory),
                    forceRequest: false, usable: true)
            }
            if let e = requestError, abs(e) <= 0.05 {
                return SpinOutcome(
                    check: SelfTestCheck(
                        name: "cpu.freq.spin", passed: false, detail: detail + "; falling back to request", severity: .advisory),
                    forceRequest: true, usable: true)
            }
            return SpinOutcome(
                check: SelfTestCheck(name: "cpu.freq.spin", passed: false, detail: detail + "; both channels off"),
                forceRequest: false, usable: false)
        }
        // 3 次都没能停在同一个簇上：结论不确定，不算失败（D05：没有证据表明数值错误）。
        return SpinOutcome(
            check: SelfTestCheck(
                name: "cpu.freq.spin", passed: true, detail: "inconclusive (thread migrated)", severity: .advisory),
            forceRequest: false, usable: true)
    }

    private static func percent(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return "\(value >= 0 ? "+" : "")\((value * 1000).rounded() / 10)%"
    }

    struct SpinProbe {
        var cluster: ClusterKey
        var kernelHz: Double
        var deltas: [IOReportChannelDelta]
    }

    /// 在当前线程上自旋 `nanos`，同时记录线程落在哪个簇上；返回本线程的内核频率和同一窗口的 IOReport 增量。
    static func spin(subscription: IOReportSubscription, topology: CPUTopology, nanos: UInt64) -> SpinProbe? {
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)
        guard let timebase = MachTimebase.current else { return nil }
        subscription.resetBaseline()
        _ = subscription.sampleDelta()
        guard let before = ProcessPrivateInfo.threadCounts(threadID: tid) else { return nil }

        var onCluster: [ClusterKey: UInt64] = [:]
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var last = start
        var x: UInt64 = 0
        while true {
            for _ in 0..<2000 { x = x &* 6364136223846793005 &+ 1442695040888963407 }
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            var cpu = 0
            if pthread_cpu_number_np(&cpu) == 0, let key = topology.clusterKey(ofCPU: cpu) {
                onCluster[key, default: 0] += now - last
            }
            last = now
            if now - start >= nanos { break }
        }
        guard let after = ProcessPrivateInfo.threadCounts(threadID: tid), let deltas = subscription.sampleDelta(),
            !deltas.isEmpty, x != 1
        else { return nil }

        let total = onCluster.values.reduce(0, +)
        guard total > 0, let (cluster, time) = onCluster.max(by: { $0.value < $1.value }), Double(time) >= 0.9 * Double(total)
        else { return nil }
        var cycles: UInt64 = 0
        var ticks: UInt64 = 0
        for (a, b) in zip(after, before) {
            cycles += a.cycles &- b.cycles
            ticks += (a.userTimeTicks &- b.userTimeTicks) + (a.systemTimeTicks &- b.systemTimeTicks)
        }
        let cpuNanos = Double(timebase.nanoseconds(fromTicks: ticks))
        guard cycles > 0, cpuNanos > 0 else { return nil }
        return SpinProbe(cluster: cluster, kernelHz: Double(cycles) / cpuNanos * 1e9, deltas: deltas)
    }
}
