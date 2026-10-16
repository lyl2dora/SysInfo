// 媒体引擎活动采集器 `gpu.media`（GPU 模块设计 §5，D57 G6）。只在 GPU 面板可见时有需求。
//
// - IOReport「Interrupt Statistics (by index)」组的一级中断计数，设备名（子组名去掉末尾序号）以 `ave`（编码）、
//   `avd`（解码）、`apr`（ProRes）开头的通道；同一引擎的多个中断源合并（M5 的 avd0 0 / avd0 1 等）；
// - 两台实测：HEVC / H.264 编码 ≈ 2 × 帧率，HEVC 解码 ≈ 3.3 × 帧率，ProRes ≈ 1 × 帧率。比例随编码器不同，
//   只作「是否在工作 + 相对强度」，不换算帧率，质量标 relative；
// - 每个引擎减去学到的空闲底数（本次运行的最小值，前 10 个样本为学习期；M5 的 avd 空闲约 90 次/s）；
//   底数在采集器里跨面板开合保留，同一次运行只学一次；
// - 订阅在第一次采样时才建（中断组枚举由 IOReportHub 缓存，与 `cpu.irq.devices` 共用）。

import Foundation
import Synchronization
import SysModel

public final class MediaEngineCollector: Collector {
    public static let collectorID: CollectorID = "gpu.media"
    public static let dataPath = "IOReport \(InterruptDeviceCollector.group) / ave*, avd*, apr* first-level interrupts"

    /// 引擎：设备名前缀 → 指标。
    static let engines: [(prefix: String, metric: MetricID)] = [
        ("ave", .mediaEncodeRate), ("avd", .mediaDecodeRate), ("apr", .mediaProResRate),
    ]

    public var id: CollectorID { Self.collectorID }

    private struct State: ~Copyable {
        var subscription: IOReportSubscription?
        var previousNanos: UInt64?
        var baselines: [MetricID: InterruptBaseline] = [:]
        var raw: [MetricID: Double] = [:]
        var devices: [String] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// 诊断页：订阅到的设备、各引擎的原始速率与底数（学习期为当前最小值）。
    public var diagnostics: (devices: [String], raw: [MetricID: Double], baselines: [MetricID: Double]) {
        state.withLock { s in (s.devices, s.raw, s.baselines.mapValues(\.baseline)) }
    }

    static func engine(of subgroup: String) -> MetricID? {
        let device = InterruptDeviceCollector.device(subgroup)
        return engines.first { device.hasPrefix($0.prefix) }?.metric
    }

    static func isEngineChannel(_ key: IOReportChannelKey) -> Bool {
        InterruptDeviceCollector.isFirstLevelCount(key) && engine(of: key.subgroup) != nil
    }

    public func selfTest() -> SelfTestResult {
        let hub = IOReportHub.shared
        guard hub.isAvailable else {
            return SelfTestResult(
                checks: [SelfTestCheck(name: "gpu.media.ioreport", passed: false, detail: "IOReport unavailable")],
                dataPath: Self.dataPath)
        }
        let channels = hub.channels(inGroup: InterruptDeviceCollector.group)?.filter { Self.isEngineChannel($0.key) } ?? []
        let devices = Set(channels.map { InterruptDeviceCollector.device($0.key.subgroup) }).sorted()
        state.withLock {
            $0.subscription = nil
            $0.previousNanos = nil
            $0.devices = devices
        }
        return SelfTestResult(
            checks: [
                SelfTestCheck(
                    name: "gpu.media.channels", passed: !channels.isEmpty,
                    detail: "\(channels.count) channels: \(devices.joined(separator: ", "))")
            ],
            dataPath: Self.dataPath)
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        state.withLock { s in
            if s.subscription == nil {
                s.subscription = IOReportHub.shared.makeSubscription(selecting: [
                    (group: InterruptDeviceCollector.group, include: { Self.isEngineChannel($0.key) })
                ])
                s.previousNanos = nil
            }
            guard let subscription = s.subscription, let deltas = subscription.sampleDelta() else {
                return CollectorOutput(samples: [], status: .unavailable, dataPath: Self.dataPath)
            }
            defer { s.previousNanos = time.monotonicNanos }
            guard let previous = s.previousNanos, time.monotonicNanos > previous, !deltas.isEmpty else {
                return CollectorOutput(samples: [], status: .ok, dataPath: Self.dataPath)  // 建立基线
            }
            let seconds = Double(time.monotonicNanos - previous) / 1e9
            var counts: [MetricID: Double] = [:]
            for delta in deltas {
                guard let metric = Self.engine(of: delta.key.subgroup), delta.integerValue >= 0 else { continue }
                counts[metric, default: 0] += Double(delta.integerValue)
            }
            var samples: [Sample] = []
            for (_, metric) in Self.engines {
                guard let count = counts[metric] else { continue }
                let rate = count / seconds
                s.raw[metric] = rate
                var baseline = s.baselines[metric] ?? InterruptBaseline()
                let active = baseline.observe(rate)
                s.baselines[metric] = baseline
                if let active {
                    samples.append(Sample(id: metric, value: active, quality: .relative, time: time))
                } else {
                    samples.append(.unavailable(metric, reason: .learning("idle floor"), at: time))
                }
            }
            return CollectorOutput(samples: samples, status: .ok, dataPath: Self.dataPath)
        }
    }

    public func resetBaseline() {
        state.withLock {
            $0.subscription?.resetBaseline()
            $0.previousNanos = nil
        }
    }
}
