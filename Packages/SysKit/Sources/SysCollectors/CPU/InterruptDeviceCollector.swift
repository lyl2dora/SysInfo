// 中断来源采集器 `cpu.irq.devices`（CPU 模块设计 §5.6，D29 C8 = A）。
//
// - 只在面板展开「中断来源」时登记需求，每 5 s 一次，收起即停；
// - IOReport「Interrupt Statistics (by index)」组，只认通道名「First Level Interrupt Handler Count」
//   （通道名前面有补齐的空格，比较前去掉首尾空白）；设备名取子组名去掉末尾的中断序号（`i2c5 0` → `i2c5`），
//   同一设备的多个中断源合并；
// - 输出按每秒次数降序的设备列表（诊断读数，不出样本、不入历史）；
// - 订阅在第一次需要时才建（建订阅要 28–31 ms，D34），之后复用。与 CPM 订阅属于不同驱动，单独订阅（D34）。

import Foundation
import Synchronization
import SysModel

/// 一个中断来源。
public struct InterruptSource: Hashable, Sendable {
    public var device: String
    /// 每秒次数。
    public var perSecond: Double
}

public final class InterruptDeviceCollector: Collector {
    public static let collectorID: CollectorID = "cpu.irq.devices"
    public static let group = "Interrupt Statistics (by index)"
    public static let channelName = "First Level Interrupt Handler Count"
    public static let dataPath = "IOReport \(group) / \(channelName)"

    public var id: CollectorID { Self.collectorID }

    private struct State: ~Copyable {
        var subscription: IOReportSubscription?
        var previousNanos: UInt64?
        var latest: [InterruptSource] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// 最近一次的设备列表（按每秒次数降序）。
    public var latestSources: [InterruptSource] { state.withLock { $0.latest } }

    public func selfTest() -> SelfTestResult {
        let hub = IOReportHub.shared
        guard hub.isAvailable else {
            return SelfTestResult(
                checks: [SelfTestCheck(name: "cpu.irq.devices.ioreport", passed: false, detail: "IOReport unavailable")],
                dataPath: Self.dataPath)
        }
        let channels = hub.channels(inGroup: Self.group)?.filter { Self.isFirstLevelCount($0.key) } ?? []
        return SelfTestResult(
            checks: [
                SelfTestCheck(
                    name: "cpu.irq.devices.channels", passed: !channels.isEmpty,
                    detail: "\(channels.count) channels, \(Set(channels.map { Self.device($0.key.subgroup) }).count) devices")
            ],
            dataPath: Self.dataPath)
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        state.withLock { s in
            if s.subscription == nil {
                s.subscription = IOReportHub.shared.makeSubscription(selecting: [
                    (group: Self.group, include: { Self.isFirstLevelCount($0.key) })
                ])
                s.previousNanos = nil
            }
            guard let subscription = s.subscription, let deltas = subscription.sampleDelta() else {
                return CollectorOutput(samples: [], status: .unavailable, dataPath: Self.dataPath)
            }
            defer { s.previousNanos = time.monotonicNanos }
            guard let previous = s.previousNanos, time.monotonicNanos > previous else {
                return CollectorOutput(samples: [], status: .ok, dataPath: Self.dataPath)  // 建立基线
            }
            s.latest = Self.sources(deltas, elapsedNanos: time.monotonicNanos - previous)
            return CollectorOutput(samples: [], status: .ok, dataPath: Self.dataPath)
        }
    }

    public func resetBaseline() {
        state.withLock {
            $0.subscription?.resetBaseline()
            $0.previousNanos = nil
        }
    }

    static func isFirstLevelCount(_ key: IOReportChannelKey) -> Bool {
        key.name.trimmingCharacters(in: .whitespaces) == channelName
    }

    /// 子组名去掉末尾的中断序号：`i2c5 0` → `i2c5`；没有序号时原样返回。
    static func device(_ subgroup: String) -> String {
        let trimmed = subgroup.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.lastIndex(of: " "), Int(trimmed[trimmed.index(after: space)...]) != nil else {
            return trimmed
        }
        return String(trimmed[..<space])
    }

    /// 按设备合并、换算成每秒次数并降序（纯函数，便于单测）。负的增量按复位处理：这个设备这一段整个丢弃，不出部分和。
    static func sources(_ deltas: [IOReportChannelDelta], elapsedNanos: UInt64) -> [InterruptSource] {
        let seconds = Double(elapsedNanos) / 1e9
        guard seconds > 0 else { return [] }
        var byDevice: [String: Int64] = [:]
        var reset: Set<String> = []
        for d in deltas where isFirstLevelCount(d.key) {
            let name = device(d.key.subgroup)
            if d.integerValue < 0 { reset.insert(name) }
            byDevice[name, default: 0] += d.integerValue
        }
        return byDevice.filter { $0.value > 0 && !reset.contains($0.key) }
            .map { InterruptSource(device: $0.key, perSecond: Double($0.value) / seconds) }
            .sorted { $0.perSecond > $1.perSecond }
    }
}
