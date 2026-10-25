// GPU 细节采集器 `gpu.diagnostics`（GPU 模块设计 §5，D57 G10）：只在诊断页展开「GPU 细节」时有需求。
//
// 不出样本，只更新诊断读数：
// - GPU Stats 的 PWRCTRL（功率控制原因码）、GPU_CLTM（热限制下的档位，NO_CLTM 以外的驻留）、PZRSDNCY（功率区，NO_ZONE 以外的驻留）；
//   两台在所有负载下都没触发过节流（GPU 边界稿 §1.2），语义按名字推断；
// - PMP 组（M5 `PMP0`、M4 `PMP`，运行时发现）「AF BW」子组里 AGX / ANE / AVE / AVD 的 RD+WR 直方图，按分档中点估算带宽，相对量；
//   M5 没有 AVE 的 AF BW 通道；
// - ANE 一级中断：M4 可读，M5 的 ANE 在 Exclave 后面，订阅成功但样本里静默缺失；
// - `Device Utilization %` 原值，标「不可靠，仅供对照」。
// 每组单独订阅（不同驱动，D34），第一次采样时才建；PMP 一次 4–8 ms，所以只在展开时采。

import Foundation
import IOKit
import Synchronization
import SysModel

/// 一个带名字的读数（诊断页）。
public struct GPUNamedValue: Hashable, Sendable {
    public var name: String
    public var value: Double
}

/// 诊断页的 GPU 细节读数。
public struct GPUDiagnosticReadings: Hashable, Sendable {
    /// PWRCTRL 驻留最多的原因码与占比（0…1），最多 3 个。
    public var powerControl: [GPUNamedValue] = []
    /// GPU_CLTM 中受热限制（非 NO_CLTM 且非 OFF）的驻留比例。
    public var thermalLimited: Double?
    /// PZRSDNCY 中处于功率区（非 NO_ZONE）的驻留比例。
    public var powerZoned: Double?
    /// PMP 组名与各部件的估算带宽（字节/秒，相对量）。
    public var bandwidthGroup: String?
    public var bandwidth: [GPUNamedValue] = []
    /// ANE 一级中断，次/秒；通道缺失（M5）时为 nil。
    public var aneInterrupts: Double?
    public var aneInterruptsMissing = false
    /// `Device Utilization %` 原值（0–100）。
    public var deviceUtilization: Double?
}

public final class GPUDiagnosticsCollector: Collector {
    public static let collectorID: CollectorID = "gpu.diagnostics"
    public static let dataPath = "IOReport GPU Stats (PWRCTRL, GPU_CLTM, PZRSDNCY) + PMP AF BW + ane0 interrupts"

    static let statsGroup = "GPU Stats"
    static let stateChannels: Set<String> = ["PWRCTRL", "GPU_CLTM", "PZRSDNCY"]
    static let pmpCandidates = ["PMP0", "PMP"]
    static let bandwidthSubgroup = "AF BW"
    static let bandwidthParts = ["AGX", "ANE", "AVE", "AVD"]

    public var id: CollectorID { Self.collectorID }

    private struct State: ~Copyable {
        var built = false
        var stats: IOReportSubscription?
        var pmp: IOReportSubscription?
        var pmpGroup: String?
        var histograms: [String: BandwidthHistogram] = [:]
        var ane: IOReportSubscription?
        var previousNanos: UInt64?
        var readings = GPUDiagnosticReadings()
        var accelerator: io_service_t = 0
    }

    private let state = Mutex(State())

    public init() {}

    deinit {
        state.withLock { s in
            if s.accelerator != 0 { IOObjectRelease(s.accelerator) }
        }
    }

    /// 最近一次的细节读数。
    public var readings: GPUDiagnosticReadings { state.withLock { $0.readings } }

    static func isStateChannel(_ info: IOReportChannelInfo) -> Bool {
        stateChannels.contains(info.key.name) && (info.driverName?.hasPrefix("AGX") ?? false)
    }

    /// AF BW 里 AGX / ANE / AVE / AVD 的 RD+WR 通道（M5 是 `ANE L0 RD+WR`，M4 是 `ANE0 L0 RD+WR`）。
    static func isBandwidthChannel(_ info: IOReportChannelInfo) -> Bool {
        info.key.subgroup == bandwidthSubgroup && info.key.name.hasSuffix("RD+WR")
            && bandwidthParts.contains { info.key.name.hasPrefix($0) }
    }

    static func part(of name: String) -> String? { bandwidthParts.first { name.hasPrefix($0) } }

    static func isANEInterrupt(_ key: IOReportChannelKey) -> Bool {
        InterruptDeviceCollector.isFirstLevelCount(key) && InterruptDeviceCollector.device(key.subgroup) == "ane0"
    }

    public func selfTest() -> SelfTestResult {
        let available = IOReportHub.shared.isAvailable
        state.withLock {
            $0.built = false
            $0.stats = nil
            $0.pmp = nil
            $0.ane = nil
            $0.previousNanos = nil
        }
        return SelfTestResult(
            checks: [
                SelfTestCheck(
                    name: "gpu.diagnostics.ioreport", passed: available,
                    detail: available ? "deferred until first use" : "IOReport unavailable")
            ],
            dataPath: Self.dataPath)
    }

    private func build(_ s: inout State) {
        let hub = IOReportHub.shared
        s.built = true
        s.stats = hub.makeSubscription(selecting: [(group: Self.statsGroup, include: Self.isStateChannel)])
        for group in Self.pmpCandidates {
            guard let infos = hub.channels(inGroup: group), infos.contains(where: Self.isBandwidthChannel),
                let names = hub.stateNames(inGroup: group, where: Self.isBandwidthChannel)
            else { continue }
            var histograms: [String: BandwidthHistogram] = [:]
            for (key, states) in names { if let h = BandwidthHistogram(stateNames: states) { histograms[key.name] = h } }
            guard !histograms.isEmpty else { continue }
            s.pmp = hub.makeSubscription(selecting: [
                (group: group, include: { Self.isBandwidthChannel($0) && histograms[$0.key.name] != nil })
            ])
            s.pmpGroup = group
            s.histograms = histograms
            break
        }
        s.ane = hub.makeSubscription(selecting: [
            (group: InterruptDeviceCollector.group, include: { Self.isANEInterrupt($0.key) })
        ])
        if s.accelerator == 0 { s.accelerator = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator")) }
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        state.withLock { s in
            if !s.built { build(&s) }
            let stats = s.stats?.sampleDelta()
            let pmp = s.pmp?.sampleDelta()
            let ane = s.ane?.sampleDelta()
            if (s.stats != nil && stats == nil) || (s.pmp != nil && pmp == nil) || (s.ane != nil && ane == nil) {
                // 某个订阅读失败时它保留原基线，而另几个已前移；三者共用一个时间戳，全部重建基线才能对齐。
                s.stats?.resetBaseline()
                s.pmp?.resetBaseline()
                s.ane?.resetBaseline()
                s.previousNanos = nil
                return CollectorOutput(samples: [], status: .ok, dataPath: Self.dataPath)
            }
            defer { s.previousNanos = time.monotonicNanos }
            var r = GPUDiagnosticReadings()
            r.bandwidthGroup = s.pmpGroup
            r.deviceUtilization = s.accelerator != 0 ? GPUAcceleratorCollector.deviceUtilization(s.accelerator) : nil
            guard let previous = s.previousNanos, time.monotonicNanos > previous else {
                return CollectorOutput(samples: [], status: .ok, dataPath: Self.dataPath)  // 建立基线
            }
            let seconds = Double(time.monotonicNanos - previous) / 1e9
            for delta in stats ?? [] {
                let total = Double(delta.stateResidencies.reduce(0) { $0 + max($1, 0) })
                guard total > 0 else { continue }
                let shares = delta.stateResidencies.map { Double(max($0, 0)) / total }
                switch delta.key.name {
                case "PWRCTRL":
                    r.powerControl = zip(delta.stateNames, shares).filter { $0.1 >= 0.01 }.sorted { $0.1 > $1.1 }
                        .prefix(3).map { GPUNamedValue(name: $0.0, value: $0.1) }
                case "GPU_CLTM":
                    r.thermalLimited = zip(delta.stateNames, shares).filter { $0.0 != "OFF" && $0.0 != "NO_CLTM" }
                        .reduce(0) { $0 + $1.1 }
                case "PZRSDNCY":
                    r.powerZoned = zip(delta.stateNames, shares).filter { $0.0 != "NO_ZONE" }.reduce(0) { $0 + $1.1 }
                default: break
                }
            }
            var byPart: [String: Double] = [:]
            for delta in pmp ?? [] {
                guard let histogram = s.histograms[delta.key.name], let part = Self.part(of: delta.key.name) else { continue }
                // 直方图的事件数没有发生时视为 0（通道在，只是这段时间没有流量）。
                byPart[part, default: 0] += histogram.mean(counts: delta.stateResidencies) ?? 0
            }
            r.bandwidth = Self.bandwidthParts.compactMap { part in byPart[part].map { GPUNamedValue(name: part, value: $0) } }
            if let ane {
                let count = ane.filter { Self.isANEInterrupt($0.key) }.reduce(Int64(0)) { $0 + max($1.integerValue, 0) }
                r.aneInterruptsMissing = ane.isEmpty
                r.aneInterrupts = ane.isEmpty ? nil : Double(count) / seconds
            } else {
                r.aneInterruptsMissing = true
            }
            s.readings = r
            return CollectorOutput(samples: [], status: .ok, dataPath: Self.dataPath)
        }
    }

    public func resetBaseline() {
        state.withLock {
            $0.stats?.resetBaseline()
            $0.pmp?.resetBaseline()
            $0.ane?.resetBaseline()
            $0.previousNanos = nil
        }
    }
}
