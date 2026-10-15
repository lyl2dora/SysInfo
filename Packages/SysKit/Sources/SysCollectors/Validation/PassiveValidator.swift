// 拓扑与频率的被动核对（CPU 模块设计 §5.2、§5.4，边界稿 §7.5；第 2、3 步推迟到这里）。
//
// 用自然负载核对两件事，参照物都是内核按档的计数，汇总自全体进程的 resource coalition（AppSampler 的样本）：
// - 拓扑：perflevel0 的 CPU 时间占比（Σ 槽 22 / Σ 槽 24–30）≈ 按映射算出的 perflevel0 核忙碌 tick 占比，差 ≤5 个百分点；
// - 频率：某档忙碌 ≥30% 的时段里，内核的按档平均频率（Σ pcycles / Σ ptime；两档芯片上另一档用总量减去 perflevel0）
//   ≈ 该档各簇 IOReport 实际频率按忙碌加权的平均，误差 ≤3%（边界稿实测：实际通道 0.0–1%，请求通道 +7–17%）。
//
// 三个采集器的间隔不同（面板默认：占用 1 s、频率 5 s、coalition 2 s），窗口对不齐。但它们都落在同一个 tick 网格上：
// 在三者同一 tick 都有样本的「公共边界」之间，各自把自己的窗口累加起来（窗口时长取相邻两次样本的 tick 差），区间就是对齐的。
// 核对在每个公共边界做一次（区间短于 10 s 时继续累加）。

import Foundation
import SysModel

/// 一次被动核对的结果。
public struct PassiveFinding: Hashable, Sendable {
    /// 检查代码：`cpu.topology.passive`、`cpu.freq.passive.perflevel<i>`。
    public var check: String
    public var passed: Bool
    /// 读数（不本地化，不含设备唯一标识）。
    public var detail: String
    /// 区间长度，秒。
    public var spanSeconds: Int
}

public final class PassiveValidator {
    public struct Thresholds: Hashable, Sendable {
        public var shareTolerance = 0.05
        public var frequencyTolerance = 0.03
        public var minimumLevelBusy = 0.3
        /// 全体进程 CPU 至少这么多（按单核比例），拓扑核对才有意义。
        public var minimumActivity = 0.3
        public var minimumSpanSeconds: Int64 = 10
        /// 频率窗口不超过这么长才做频率判定，秒。内核的按档 cycles/时间按线程运行时间加权，IOReport 按簇活跃时间加权，
        /// 窗口里负载变化大时两者本来就会分开（2026-10-15 自查：后台 60 s 窗口 + 传感器校准的轮流满载，−21.6% 误报）。
        public var maximumFrequencyWindowSeconds: Double = 10

        public init() {}
    }

    private let topology: CPUTopology
    private let thresholds: Thresholds

    private enum Source: Hashable { case load, freq, coalition }

    private struct Accumulator {
        var levelBusy: [Int: Double] = [:]  // 核·秒
        var clusterBusy: [ClusterKey: Double] = [:]  // 核·秒
        /// 频率按「该频率窗口内本簇的忙碌核·秒」加权：Σ Hz × 忙碌、Σ 忙碌。
        /// 只按时长平均会让簇大半时间空闲的窗口（后台低频活动）占满权重，把均值拉低（2026-10-15 M5 实测 −12.8%）。
        var clusterHzWeighted: [ClusterKey: Double] = [:]
        var clusterHzWeight: [ClusterKey: Double] = [:]
        var coalitionCPU = 0.0  // 核·秒
        var coalitionP0 = 0.0
        var p0Cycles = 0.0
        var otherCycles = 0.0
        /// 区间里有超过上限的频率窗口：这一区间不做频率判定。
        var longFrequencyWindow = false
    }

    private var lastTick: [Source: Int64] = [:]
    private var seenAtTick: [Int64: Set<Source>] = [:]
    private var spanStart: Int64?
    private var accumulator = Accumulator()
    /// 上一个频率样本以来各簇的忙碌核·秒（跨区间保留，给下一个频率窗口加权）。
    private var busySinceFrequency: [ClusterKey: Double] = [:]

    public init(topology: CPUTopology, thresholds: Thresholds = Thresholds()) {
        self.topology = topology
        self.thresholds = thresholds
    }

    /// 喂一个 tick 结果（主结果和阻塞结果都喂）。到了公共边界且区间够长时返回核对结果。
    public func ingest(_ result: TickResult) -> [PassiveFinding] {
        let tick = result.tick
        var sources: Set<Source> = []
        for id in result.collectors {
            switch id {
            case CPULoadCollector.collectorID: sources.insert(.load)
            case CPUFrequencyCollector.collectorID: sources.insert(.freq)
            case AppSampler.collectorID: sources.insert(.coalition)
            default: break
            }
        }
        guard !sources.isEmpty else { return [] }
        let byID = Dictionary(result.samples.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // 同一 tick 内先处理占用、再处理频率：频率窗口的权重要用到截至本 tick 的忙碌量。
        for source in [Source.load, .freq, .coalition] where sources.contains(source) {
            defer { lastTick[source] = tick }
            guard let previous = lastTick[source], tick > previous else { continue }
            if source == .load {
                accumulateBusySinceFrequency(byID, Double(tick - previous))
            }
            guard spanStart != nil else {
                if source == .freq { busySinceFrequency = [:] }
                continue
            }
            let duration = Double(tick - previous)
            switch source {
            case .load: accumulateLoad(byID, duration)
            case .freq: accumulateFrequency(byID, duration)
            case .coalition: accumulateCoalition(byID, duration)
            }
        }
        seenAtTick[tick, default: []].formUnion(sources)
        seenAtTick = seenAtTick.filter { tick - $0.key < 600 }
        guard seenAtTick[tick] == [.load, .freq, .coalition] else { return [] }
        // 公共边界
        guard let start = spanStart else {
            spanStart = tick
            return []
        }
        guard tick - start >= thresholds.minimumSpanSeconds else { return [] }
        let findings = evaluate(span: Double(tick - start))
        spanStart = tick
        accumulator = Accumulator()
        return findings.map { var f = $0; f.spanSeconds = Int(tick - start); return f }
    }

    // MARK: - 累加

    private func accumulateLoad(_ s: [MetricID: Sample], _ duration: Double) {
        for level in topology.perfLevels {
            if let usage = s[.cpuUsagePerfLevel(level.index)]?.value {
                accumulator.levelBusy[level.index, default: 0] += usage * Double(level.cpuCount) * duration
            }
        }
        for cluster in topology.clusters {
            if let usage = s[.cpuUsageCluster(cluster.key)]?.value {
                accumulator.clusterBusy[cluster.key, default: 0] += usage * Double(cluster.cpus.count) * duration
            }
        }
    }

    private func accumulateBusySinceFrequency(_ s: [MetricID: Sample], _ duration: Double) {
        for cluster in topology.clusters {
            if let usage = s[.cpuUsageCluster(cluster.key)]?.value {
                busySinceFrequency[cluster.key, default: 0] += usage * Double(cluster.cpus.count) * duration
            }
        }
    }

    private func accumulateFrequency(_ s: [MetricID: Sample], _ duration: Double) {
        defer { busySinceFrequency = [:] }
        if duration > thresholds.maximumFrequencyWindowSeconds {
            accumulator.longFrequencyWindow = true
            return
        }
        for cluster in topology.clusters {
            guard let sample = s[.cpuFrequencyCluster(cluster.key)], let hz = sample.value, sample.quality == .measured,
                let busy = busySinceFrequency[cluster.key], busy > 0
            else { continue }
            accumulator.clusterHzWeighted[cluster.key, default: 0] += hz * busy
            accumulator.clusterHzWeight[cluster.key, default: 0] += busy
        }
    }

    private func accumulateCoalition(_ s: [MetricID: Sample], _ duration: Double) {
        guard let cpu = s[.appCoalitionCPU]?.value else { return }
        let cpuSeconds = cpu * duration
        accumulator.coalitionCPU += cpuSeconds
        guard let share = s[.appCoalitionPerfLevel0Share]?.value else { return }
        let p0 = share * cpuSeconds
        accumulator.coalitionP0 += p0
        if let hz = s[.appCoalitionPerfLevel0Frequency]?.value { accumulator.p0Cycles += hz * p0 }
        if let hz = s[.appCoalitionOtherLevelFrequency]?.value { accumulator.otherCycles += hz * (cpuSeconds - p0) }
    }

    // MARK: - 核对

    private func evaluate(span: Double) -> [PassiveFinding] {
        let a = accumulator
        var out: [PassiveFinding] = []
        let busyTotal = a.levelBusy.values.reduce(0, +)
        guard topology.quality.isOK, busyTotal > 0, a.coalitionCPU > 0 else { return out }

        // 拓扑
        if a.coalitionCPU / span >= thresholds.minimumActivity, let p0Busy = a.levelBusy[0] {
            let tickShare = p0Busy / busyTotal
            let coalitionShare = a.coalitionP0 / a.coalitionCPU
            let diff = coalitionShare - tickShare
            out.append(
                PassiveFinding(
                    check: "cpu.topology.passive", passed: abs(diff) <= thresholds.shareTolerance,
                    detail: "perflevel0 share: kernel \(pct(coalitionShare)), mapped ticks \(pct(tickShare))", spanSeconds: 0))
        }

        // 频率（perflevel0；两档芯片上另一档）。区间里有长频率窗口时不判定（见 maximumFrequencyWindowSeconds）。
        let levels = a.longFrequencyWindow ? [] : (topology.perfLevels.count == 2 ? [0, 1] : [0])
        for index in levels {
            guard let level = topology.perfLevels.first(where: { $0.index == index }),
                let busy = a.levelBusy[index], busy / (Double(level.cpuCount) * span) >= thresholds.minimumLevelBusy
            else { continue }
            let kernelSeconds = index == 0 ? a.coalitionP0 : a.coalitionCPU - a.coalitionP0
            let kernelCycles = index == 0 ? a.p0Cycles : a.otherCycles
            guard kernelSeconds > 0 else { continue }
            let kernelHz = kernelCycles / kernelSeconds
            var weighted = 0.0
            var weight = 0.0
            for key in level.clusters {
                guard let w = a.clusterHzWeight[key], w > 0, let hzWeighted = a.clusterHzWeighted[key] else { continue }
                weighted += hzWeighted
                weight += w
            }
            guard weight > 0 else { continue }
            let ours = weighted / weight
            let error = ours / kernelHz - 1
            out.append(
                PassiveFinding(
                    check: "cpu.freq.passive.perflevel\(index)", passed: abs(error) <= thresholds.frequencyTolerance,
                    detail: "kernel \(Int(kernelHz / 1e6)) MHz, IOReport actual \(Int(ours / 1e6)) MHz (\(signed(error)))",
                    spanSeconds: 0))
        }
        return out
    }

    private func pct(_ x: Double) -> String { "\((x * 1000).rounded() / 10)%" }
    private func signed(_ x: Double) -> String { "\(x >= 0 ? "+" : "")\((x * 1000).rounded() / 10)%" }
}
