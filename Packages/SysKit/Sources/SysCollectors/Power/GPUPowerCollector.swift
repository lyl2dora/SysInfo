// GPU 功率与活跃采集器 `power.gpu`（功耗与散热模块设计 §4.3，D44；GPU 模块设计 §5，D57）。
//
// - 一个订阅里两个 AGX 通道：Energy Model 的「GPU Energy」与 GPU Stats 的「GPUPH」。IOReport 每次采样的开销主要是
//   醒来后第一次调用的固定成本，合并后与只读功率相同（1.3–1.8 ms/次，GPU 边界稿 §1.6）；
//   通道字典从 IOReportHub 取，全 app 只枚举一次（D34）；
// - 功率 = Δ能量 / Δ单调时钟。计数是累计量，采样间隔多长都不丢平均值；
// - 与 PMGR GPU 批次的交叉核对连续失败时，功率输出不可用（D44 §7）。M4 上 SMC 的 GPU 轨不是 GPU 功率，不用（边界稿 §3.3）；
// - GPU 活跃 = GPUPH 非 OFF 驻留的比例（上电时间，不是算力占用，D57 G1）；频率 = 活跃期间按驻留加权的平均频率，
//   P*k* 取 DVFS 表中第 *k* 个非零频率（D57 G2）。GPUPH 找不到时只影响活跃与频率，功率照常。

import Foundation
import Synchronization
import SysModel

public final class GPUPowerCollector: Collector {
    public static let collectorID: CollectorID = "power.gpu"
    public static let dataPath = "IOReport Energy Model / GPU Energy + GPU Stats / GPUPH (AGX, live)"
    static let group = "Energy Model"
    static let statsGroup = "GPU Stats"
    static let statsSubgroup = "GPU Performance States"

    public var id: CollectorID { Self.collectorID }
    public let ledger: PowerLedger

    private struct State {
        var subscription: IOReportSubscription?
        var joulesPerUnit: Double = 1e-9
        var lastTime: SampleTime?
        var channel: String?
        var hasResidency = false
        var table: GPUFrequencyTable?
        var tableProblem: String?
        var latest: GPUResidencySummary?
    }

    private let state = Mutex(State())
    private let hub: IOReportHub
    private let resolveProfile: @Sendable () -> ResolvedChipProfile?
    private let readPMGR: @Sendable () -> PMGRProperties?

    public convenience init(ledger: PowerLedger) {
        self.init(ledger: ledger, hub: .shared, resolveProfile: { PowerProfiles.resolve() }, readPMGR: { PMGRReader.read() })
    }

    init(
        ledger: PowerLedger, hub: IOReportHub, resolveProfile: @escaping @Sendable () -> ResolvedChipProfile?,
        readPMGR: @escaping @Sendable () -> PMGRProperties?
    ) {
        self.ledger = ledger
        self.hub = hub
        self.resolveProfile = resolveProfile
        self.readPMGR = readPMGR
    }

    /// 订阅到的通道（诊断页），例如 `GPU Energy [AGXAcceleratorG17X]`。
    public var channel: String? { state.withLock { $0.channel } }
    /// GPUPH 是否订阅到（GPU 活跃与频率）。
    public var hasResidency: Bool { state.withLock { $0.hasResidency } }
    /// GPU 档位表（诊断页）；找不到时为 nil，原因见 `tableProblem`。
    public var frequencyTable: GPUFrequencyTable? { state.withLock { $0.table } }
    public var tableProblem: String? { state.withLock { $0.tableProblem } }
    /// 最近一次的各档驻留（诊断页）。
    public var latestResidency: GPUResidencySummary? { state.withLock { $0.latest } }

    /// 能量单位换算成焦耳；不认识的单位为 nil。
    static func joulesPerUnit(_ label: String?) -> Double? {
        switch label?.trimmingCharacters(in: .whitespaces) {
        case "nJ": 1e-9
        case "uJ", "µJ": 1e-6
        case "mJ": 1e-3
        case "J": 1
        default: nil
        }
    }

    /// AGX 的 GPU Energy 通道。
    static func isAGXGPUEnergy(_ info: IOReportChannelInfo) -> Bool {
        info.key.name == "GPU Energy" && (info.driverName?.hasPrefix("AGX") ?? false)
    }

    /// AGX 的 GPUPH 通道（GPU Stats / GPU Performance States）。
    static func isGPUPH(_ info: IOReportChannelInfo) -> Bool {
        info.key.subgroup == statsSubgroup && info.key.name == "GPUPH" && (info.driverName?.hasPrefix("AGX") ?? false)
    }

    static func isGPUPH(_ delta: IOReportChannelDelta) -> Bool {
        delta.key.subgroup == statsSubgroup && delta.key.name == "GPUPH"
    }

    public func selfTest() -> SelfTestResult {
        var checks: [SelfTestCheck] = []
        let infos = hub.channels(inGroup: Self.group)?.filter(Self.isAGXGPUEnergy) ?? []
        let unit = infos.first.flatMap { Self.joulesPerUnit($0.unitLabel) }
        checks.append(
            SelfTestCheck(
                name: "power.gpu.channel", passed: infos.count == 1 && unit != nil,
                detail: infos.isEmpty
                    ? "no AGX GPU Energy channel" : infos.map { "\($0.driverName ?? "?") \($0.unitLabel ?? "?")" }.joined(separator: ", ")))
        let residency = hub.channels(inGroup: Self.statsGroup)?.filter(Self.isGPUPH) ?? []
        let profileKey = resolveProfile()?.profile.gpu?.dvfsTableKey
        let pmgr = readPMGR()
        // 订阅不跨隔离域：建立、核对、保存都在锁内完成（自检和采样本来就在引擎队列上串行执行）。
        state.withLock { s in
            s.subscription = nil
            s.joulesPerUnit = unit ?? 1e-9
            s.lastTime = nil
            s.hasResidency = false
            s.table = nil
            s.tableProblem = nil
            s.latest = nil
            // 驱动名形如「AGXAcceleratorG17X <id 0x…>」，诊断页只显示类名。
            s.channel = infos.first.map { "GPU Energy [\(($0.driverName ?? "?").split(separator: " ").first ?? "?")]" }
            guard infos.count == 1, unit != nil else { return }
            var selections: [(group: String, include: (IOReportChannelInfo) -> Bool)] = [
                (group: Self.group, include: Self.isAGXGPUEnergy)
            ]
            if residency.count == 1 { selections.append((group: Self.statsGroup, include: Self.isGPUPH)) }
            let subscription = hub.makeSubscription(selecting: selections)
            let snapshot = subscription?.snapshot()
            let first = snapshot?.first { $0.key.name == "GPU Energy" }?.integerValue
            let ok = first != nil
            checks.append(
                SelfTestCheck(
                    name: "power.gpu.subscription", passed: ok,
                    detail: first.map { "counter \($0), \(subscription?.channelCount ?? 0) channels" } ?? "subscription failed"))
            guard ok else { return }
            s.subscription = subscription

            // GPUPH：状态名第一个是 OFF，其余是 P1…（D57）。不通过时只停用活跃与频率。
            let names = snapshot?.first(where: Self.isGPUPH)?.stateNames ?? []
            let shapeOK = names.first == "OFF" && names.dropFirst().allSatisfy { (GPUResidencyMath.pStateIndex($0) ?? 0) > 0 }
            checks.append(
                SelfTestCheck(
                    name: "power.gpu.gpuph", passed: !names.isEmpty && shapeOK,
                    detail: names.isEmpty ? "no GPUPH channel" : "\(names.count) states: \(names.first ?? "?")…\(names.last ?? "?")",
                    severity: .advisory))
            guard !names.isEmpty, shapeOK else { return }
            s.hasResidency = true
            let pStates = names.count - 1
            let table = pmgr.flatMap { properties in
                GPUFrequencyDiscovery.table(
                    rawTables: properties.sramTables, cpuTableKeys: GPUFrequencyDiscovery.cpuTableKeys(properties),
                    pStateCount: pStates, preferredKey: profileKey)
            }
            s.table = table
            if table == nil {
                s.tableProblem = pmgr == nil ? "pmgr unreadable" : profileKey.map { "profile table \($0) unusable" } ?? "no GPU table found"
            }
            checks.append(
                SelfTestCheck(
                    name: "power.gpu.dvfs", passed: table != nil,
                    detail: table.map {
                        "voltage-states\($0.key)-sram, \($0.frequencies.count) steps, top \(Int($0.top / 1e6)) MHz, \($0.fromProfile ? "profile" : "inferred")"
                    } ?? (s.tableProblem ?? "none"), severity: .advisory))
        }
        return SelfTestResult(checks: checks, dataPath: Self.dataPath)
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        struct Output {
            var watts: Double?
            /// 本帧没有功率时的原因；只建立基线时两者都是 nil。
            var wattsProblem: UnavailableReason?
            var readFailed = false
            var summary: GPUResidencySummary?
            var table: GPUFrequencyTable?
            var hasResidency: Bool
            var usable: Bool
        }
        let output = state.withLock { s -> Output in
            guard let subscription = s.subscription else { return Output(hasResidency: false, usable: false) }
            guard let deltas = subscription.sampleDelta() else {
                return Output(readFailed: true, hasResidency: s.hasResidency, usable: true)  // 基线保留，lastTime 也不前移
            }
            defer { s.lastTime = time }
            guard let last = s.lastTime, time.monotonicNanos > last.monotonicNanos, !deltas.isEmpty else {
                return Output(hasResidency: s.hasResidency, usable: true)  // 只建立了基线
            }
            var out = Output(table: s.table, hasResidency: s.hasResidency, usable: true)
            if let energy = deltas.first(where: { $0.key.name == "GPU Energy" })?.integerValue {
                if energy >= 0 {
                    let seconds = Double(time.monotonicNanos - last.monotonicNanos) / 1e9
                    out.watts = Double(energy) * s.joulesPerUnit / seconds
                } else {
                    out.wattsProblem = .counterReset()  // 负差值按复位处理，不钳为 0
                }
            } else {
                out.wattsProblem = .readFailed("GPU Energy")
            }
            if s.hasResidency, let residency = deltas.first(where: Self.isGPUPH) {
                let summary = GPUResidencyMath.summarize(
                    names: residency.stateNames, residencies: residency.stateResidencies, table: s.table)
                out.summary = summary
                s.latest = summary
            }
            return out
        }
        guard output.usable else {
            return CollectorOutput(samples: [], status: .unavailable, dataPath: Self.dataPath)
        }
        if output.readFailed {
            // 显式给出不可用，并报 unavailable：连续多次时引擎会重新自检（K19）。
            let reason = UnavailableReason.readFailed("IOReportCreateSamples")
            var ids: [MetricID] = [.powerGPU]
            if output.hasResidency { ids += [.gpuActive, .gpuFrequency] }
            return CollectorOutput(
                samples: ids.map { .unavailable($0, reason: reason, at: time) }, status: .unavailable, dataPath: Self.dataPath)
        }
        var samples: [Sample] = []
        if let watts = output.watts {
            samples.append(
                ledger.isDisabled(.gpu)
                    ? Sample.unavailable(.powerGPU, reason: .selfTestFailed("cross-check"), at: time)
                    : Sample(id: .powerGPU, value: watts, time: time))
        } else if let problem = output.wattsProblem {
            samples.append(.unavailable(.powerGPU, reason: problem, at: time))
        }
        if output.hasResidency, let summary = output.summary {
            if let active = summary.active {
                samples.append(Sample(id: .gpuActive, value: active, time: time))
                samples.append(Self.frequencySample(summary, table: output.table, at: time))
            } else {
                let reason: UnavailableReason = summary.counterReset ? .counterReset("GPUPH") : .noElapsedTicks()
                samples.append(.unavailable(.gpuActive, reason: reason, at: time))
                samples.append(.unavailable(.gpuFrequency, reason: reason, at: time))
            }
        } else if !output.hasResidency, output.watts != nil || output.wattsProblem != nil {
            let reason = UnavailableReason.selfTestFailed("no GPUPH")
            samples.append(.unavailable(.gpuActive, reason: reason, at: time))
            samples.append(.unavailable(.gpuFrequency, reason: reason, at: time))
        }
        return CollectorOutput(
            samples: samples, status: output.wattsProblem == nil ? .ok : .degraded, dataPath: Self.dataPath)
    }

    static func frequencySample(_ summary: GPUResidencySummary, table: GPUFrequencyTable?, at time: SampleTime) -> Sample {
        guard let table else { return .unavailable(.gpuFrequency, reason: .notAttributed("no DVFS table"), at: time) }
        if summary.exceedsTable { return .unavailable(.gpuFrequency, reason: .selfTestFailed("state beyond table"), at: time) }
        guard let frequency = summary.frequency else { return .unavailable(.gpuFrequency, reason: .deviceIdle("gpu off"), at: time) }
        return Sample(id: .gpuFrequency, value: frequency, quality: table.fromProfile ? .measured : .inferred, time: time)
    }

    public func resetBaseline() {
        state.withLock {
            $0.subscription?.resetBaseline()
            $0.lastTime = nil
        }
    }
}
