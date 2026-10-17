// 网络速率采集器 `network.io`（网络模块设计 §5.2，D60）：公开接口，inline 通道。
//
// - 每次按缓存的 index 读清单里每个接口的 IFMIB（约 0.003 ms/个），差分出入 / 出 B/s；
// - 负差值按复位处理：该接口这一段不可用，不钳为 0（CLAUDE.md）；index 或类型变化、接口消失时丢弃基线；
// - 输出每个接口（物理 `net.if.*`、虚拟 `net.vif.*`）、主接口（D60：隧道时取下层物理接口）与物理合计；
//   任何地方都不把全部接口相加（虚拟机、VPN 流量会在多个接口上重复计数）；
// - 主接口刚切换、还没有基线时这一段不出样本；
// - 差分用连续时钟（含睡眠）：睡眠期间（Power Nap 等）计数照样增长，用不含睡眠的时钟会把它算成一个尖峰。
//
// 自检（K19）：至少一个接口能读 IFMIB（必需）；有主接口（提示：离线时不通过，但照常出数）。

import Foundation
import Synchronization
import SysModel

public final class NetworkIOCollector: Collector {
    public static let collectorID: CollectorID = "network.io"
    public static let dataPath = "sysctl IFMIB（net.link.generic.ifdata.<idx>.general）"

    public var id: CollectorID { Self.collectorID }

    private struct Baseline {
        var index: UInt32
        var physical: Bool
        var counters: NetworkCounters
        var nanos: UInt64
    }

    private struct State {
        var usable: Bool?
        var previous: [String: Baseline] = [:]
        var latest: [String: NetworkCounters] = [:]
        var lastState: NetworkState = .empty
    }

    private let inventory: NetworkInventory
    private let state = Mutex(State())

    public init(inventory: NetworkInventory = .shared) {
        self.inventory = inventory
    }

    /// 每个接口最近一次读到的累计计数（诊断页、CLI）。
    public var latestCounters: [String: NetworkCounters] { state.withLock { $0.latest } }

    /// 最近一次采样所用的清单。
    public var lastState: NetworkState { state.withLock { $0.lastState } }

    public func selfTest() -> SelfTestResult {
        inventory.invalidate()
        let snapshot = inventory.snapshot()
        let readable = snapshot.interfaces.filter { NetworkSysctl.read(index: $0.index) != nil }
        let anyIndex = NetworkInventory.interfaceIndices().contains { NetworkSysctl.read(index: $0.1) != nil }
        var checks = [
            SelfTestCheck(
                name: "network.io.ifmib", passed: anyIndex,
                detail: "listed=\(snapshot.interfaces.count) readable=\(readable.count) ifmibdata=\(MemoryLayout<ifmibdata>.size)B")
        ]
        checks.append(
            SelfTestCheck(
                name: "network.io.primary", passed: snapshot.primary != nil,
                detail: "primary=\(snapshot.primary ?? "-") defaultRoute=\(snapshot.defaultRouteInterface ?? "-") vpn=\(snapshot.vpnActive)",
                severity: .advisory))
        let result = SelfTestResult(checks: checks, dataPath: Self.dataPath)
        state.withLock {
            $0.usable = result.isUsable
            $0.previous = [:]
        }
        return result
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        let usable = state.withLock { $0.usable }
        let snapshot = inventory.snapshot()
        let directions = MetricID.NetworkDirection.allCases
        if usable == false {
            let reason = UnavailableReason.selfTestFailed()
            var samples = snapshot.interfaces.flatMap { interface in
                directions.map { Sample.unavailable(.network(interface, $0), reason: reason, at: time) }
            }
            samples += directions.flatMap {
                [Sample.unavailable(.networkPrimary($0), reason: reason, at: time), .unavailable(.networkPhysical($0), reason: reason, at: time)]
            }
            return CollectorOutput(samples: samples, status: .unavailable, dataPath: Self.dataPath)
        }
        var current: [String: NetworkCounters] = [:]
        var readFailed = false
        for interface in snapshot.interfaces {
            if let reading = NetworkSysctl.read(index: interface.index) {
                current[interface.name] = reading.counters
            } else {
                readFailed = true
            }
        }
        if readFailed { inventory.invalidate() }  // index 变了：下一次重建清单
        var samples: [Sample] = []
        var degraded = false
        state.withLock { s in
            var rates: [String: (in: Double?, out: Double?)] = [:]
            for interface in snapshot.interfaces {
                guard let now = current[interface.name] else {
                    degraded = true
                    s.previous[interface.name] = nil
                    samples += directions.map { .unavailable(.network(interface, $0), reason: .readFailed("IFMIB"), at: time) }
                    continue
                }
                defer {
                    s.previous[interface.name] = Baseline(
                        index: interface.index, physical: interface.isPhysical, counters: now, nanos: time.continuousNanos)
                }
                guard let previous = s.previous[interface.name], previous.index == interface.index,
                    previous.physical == interface.isPhysical, time.continuousNanos > previous.nanos
                else { continue }  // 建立基线
                let r = Self.rates(previous: previous.counters, current: now, elapsedNanos: time.continuousNanos - previous.nanos)
                rates[interface.name] = r
                for (direction, value) in [(MetricID.NetworkDirection.in, r.in), (.out, r.out)] {
                    let id = MetricID.network(interface, direction)
                    if let value {
                        samples.append(Sample(id: id, value: value, time: time))
                    } else {
                        samples.append(.unavailable(id, reason: .counterReset(), at: time))
                    }
                }
            }
            // 主接口。
            if let primary = snapshot.primary {
                if let r = rates[primary] {
                    for (direction, value) in [(MetricID.NetworkDirection.in, r.in), (.out, r.out)] {
                        let id = MetricID.networkPrimary(direction)
                        samples.append(value.map { Sample(id: id, value: $0, time: time) } ?? .unavailable(id, reason: .counterReset(), at: time))
                    }
                }
            } else {
                samples += directions.map { .unavailable(.networkPrimary($0), reason: .offline(), at: time) }
            }
            // 物理合计：只在每个活跃物理接口都有速率时给出，否则这一段不出样本（不拿部分接口冒充合计）。
            let physical = snapshot.physical
            let physicalRates = physical.compactMap { rates[$0.name] }
            if !physical.isEmpty, physicalRates.count == physical.count {
                for direction in directions {
                    let values = physicalRates.map { direction == .in ? $0.in : $0.out }
                    let id = MetricID.networkPhysical(direction)
                    if values.allSatisfy({ $0 != nil }) {
                        samples.append(Sample(id: id, value: values.reduce(0) { $0 + ($1 ?? 0) }, time: time))
                    } else {
                        samples.append(.unavailable(id, reason: .counterReset(), at: time))
                    }
                }
            } else if physical.isEmpty {
                samples += directions.map { .unavailable(.networkPhysical($0), reason: .offline(), at: time) }
            }
            // 消失的接口：丢掉基线。
            s.previous = s.previous.filter { current[$0.key] != nil }
            s.latest = current
            s.lastState = snapshot
        }
        return CollectorOutput(samples: samples, status: degraded ? .degraded : .ok, dataPath: Self.dataPath)
    }

    public func resetBaseline() {
        state.withLock { $0.previous = [:] }
    }

    /// 两次读数之间的入 / 出速率（纯函数）：计数回退的方向为 nil（按复位处理）。
    static func rates(previous: NetworkCounters, current: NetworkCounters, elapsedNanos: UInt64) -> (in: Double?, out: Double?) {
        guard elapsedNanos > 0 else { return (nil, nil) }
        let seconds = Double(elapsedNanos) / 1e9
        let rateIn = current.bytesIn >= previous.bytesIn ? Double(current.bytesIn - previous.bytesIn) / seconds : nil
        let rateOut = current.bytesOut >= previous.bytesOut ? Double(current.bytesOut - previous.bytesOut) / seconds : nil
        return (rateIn, rateOut)
    }
}
