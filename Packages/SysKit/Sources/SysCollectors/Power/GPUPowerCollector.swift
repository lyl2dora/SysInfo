// GPU 功率采集器 `power.gpu`（功耗与散热模块设计 §4.3，D44）。
//
// - 只订阅 Energy Model 组里 AGX 驱动的「GPU Energy」一个通道（真实节奏下 1.4–1.8 ms/次，边界稿 §2.8）；
//   通道字典从 IOReportHub 取，全 app 只枚举一次（D34）；
// - 功率 = Δ能量 / Δ单调时钟。计数是累计量，采样间隔多长都不丢平均值；
// - 与 PMGR GPU 批次的交叉核对连续失败时输出不可用（D44 §7）。M4 上 SMC 的 GPU 轨不是 GPU 功率，不用（边界稿 §3.3）。

import Foundation
import Synchronization
import SysModel

public final class GPUPowerCollector: Collector {
    public static let collectorID: CollectorID = "power.gpu"
    public static let dataPath = "IOReport Energy Model / GPU Energy (AGX, live)"
    static let group = "Energy Model"

    public var id: CollectorID { Self.collectorID }
    public let ledger: PowerLedger

    private struct State {
        var subscription: IOReportSubscription?
        var joulesPerUnit: Double = 1e-9
        var lastTime: SampleTime?
        var channel: String?
    }

    private let state = Mutex(State())
    private let hub: IOReportHub

    public init(ledger: PowerLedger, hub: IOReportHub = .shared) {
        self.ledger = ledger
        self.hub = hub
    }

    /// 订阅到的通道（诊断页），例如 `GPU Energy [AGXAcceleratorG17X]`。
    public var channel: String? { state.withLock { $0.channel } }

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

    public func selfTest() -> SelfTestResult {
        var checks: [SelfTestCheck] = []
        let infos = hub.channels(inGroup: Self.group)?.filter(Self.isAGXGPUEnergy) ?? []
        let unit = infos.first.flatMap { Self.joulesPerUnit($0.unitLabel) }
        checks.append(
            SelfTestCheck(
                name: "power.gpu.channel", passed: infos.count == 1 && unit != nil,
                detail: infos.isEmpty
                    ? "no AGX GPU Energy channel" : infos.map { "\($0.driverName ?? "?") \($0.unitLabel ?? "?")" }.joined(separator: ", ")))
        // 订阅不跨隔离域：建立、核对、保存都在锁内完成（自检和采样本来就在引擎队列上串行执行）。
        state.withLock { s in
            s.subscription = nil
            s.joulesPerUnit = unit ?? 1e-9
            s.lastTime = nil
            // 驱动名形如「AGXAcceleratorG17X <id 0x…>」，诊断页只显示类名。
            s.channel = infos.first.map { "GPU Energy [\(($0.driverName ?? "?").split(separator: " ").first ?? "?")]" }
            guard infos.count == 1, unit != nil else { return }
            let subscription = hub.makeSubscription(selecting: [(group: Self.group, include: Self.isAGXGPUEnergy)])
            let first = subscription?.snapshot()?.first?.integerValue
            let ok = first != nil && subscription?.channelCount == 1
            checks.append(
                SelfTestCheck(
                    name: "power.gpu.subscription", passed: ok, detail: first.map { "counter \($0)" } ?? "subscription failed"))
            if ok { s.subscription = subscription }
        }
        return SelfTestResult(checks: checks, dataPath: Self.dataPath)
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        let output = state.withLock { s -> (Double?, Bool) in
            guard let subscription = s.subscription else { return (nil, false) }
            guard let deltas = subscription.sampleDelta() else { return (nil, true) }
            defer { s.lastTime = time }
            guard let last = s.lastTime, let delta = deltas.first?.integerValue, delta >= 0,
                time.monotonicNanos > last.monotonicNanos
            else { return (nil, true) }
            let seconds = Double(time.monotonicNanos - last.monotonicNanos) / 1e9
            return (Double(delta) * s.joulesPerUnit / seconds, true)
        }
        guard output.1 else {
            return CollectorOutput(samples: [], status: .unavailable, dataPath: Self.dataPath)
        }
        guard let watts = output.0 else {
            return CollectorOutput(samples: [], status: .ok, dataPath: Self.dataPath)  // 只建立了基线
        }
        let sample =
            ledger.isDisabled(.gpu)
            ? Sample.unavailable(.powerGPU, reason: .selfTestFailed("cross-check"), at: time)
            : Sample(id: .powerGPU, value: watts, time: time)
        return CollectorOutput(samples: [sample], status: .ok, dataPath: Self.dataPath)
    }

    public func resetBaseline() {
        state.withLock {
            $0.subscription?.resetBaseline()
            $0.lastTime = nil
        }
    }
}
