// 整机功率采集器 `power.rail`（功耗与散热模块设计 §4.1，D44、D46）。走阻塞通道：SMC 读取会阻塞。
//
// - 每次读一个 SMC 键（档案的 systemPowerKey，没有档案时用 PDTR），输出 `power.system`；
// - 每次顺带读 `PowerTelemetryData`（0.15–0.23 ms）。计数器变化时：
//   - 输出 `power.wall`（公式值，estimated，D46）；
//   - 把这一段的 PDTR 积分与遥测均值对账，记进账本（诊断页逐段列出，累加器漏记的段标出）；
// - 未知芯片的 PDTR 先标 inferred，遥测对账连续 3 段一致后升为 measured（功耗与散热模块设计 §4.1）。

import Foundation
import Synchronization
import SysModel

public final class PowerRailCollector: Collector {
    public static let collectorID: CollectorID = "power.rail"
    public static let dataPath = "AppleSMC PDTR (read-only) + AppleSmartBattery.PowerTelemetryData"

    /// 积分时单个样本最多覆盖的秒数（D46）：超出部分不外推。
    static let maxSampleSpan: Double = 1.05
    /// 未知芯片：连续这么多段对账一致后，PDTR 升为 measured。
    static let agreementsToTrust = 3

    public var id: CollectorID { Self.collectorID }
    public let lane: CollectorLane = .blocking
    public let ledger: PowerLedger

    private struct State {
        var key: String?
        var fromProfile = false
        var usable: Bool?
        var agreements = 0
        var lastTime: SampleTime?
        var lastWatts: Double?
        var lastTelemetry: PowerTelemetryReading?
        /// 上一次遥测变化以来的 PDTR 积分与覆盖秒数。
        var segmentJoules = 0.0
        var segmentCovered = 0.0
        /// 当前这一段是否从一次计数变化开始：第一次读到的累加器值来自上一次发布，到下一次变化之间的差值
        /// 覆盖整个 60 s 周期，而积分只从第一次读取开始，两者不可比，所以第一段只建基线。
        var segmentAligned = false
    }

    private let state = Mutex(State())
    private let smc: SMCReader
    private let telemetry: TelemetryReader
    private let resolveProfile: @Sendable () -> ResolvedChipProfile?

    public convenience init(ledger: PowerLedger) {
        self.init(smc: SMCReader(), telemetry: TelemetryReader(), ledger: ledger, resolveProfile: { PowerProfiles.resolve() })
    }

    init(
        smc: SMCReader, telemetry: TelemetryReader, ledger: PowerLedger,
        resolveProfile: @escaping @Sendable () -> ResolvedChipProfile?
    ) {
        self.smc = smc
        self.telemetry = telemetry
        self.ledger = ledger
        self.resolveProfile = resolveProfile
    }

    /// 当前读的键；未通过自检时为 nil。
    public var key: String? { state.withLock { $0.key } }
    /// 键来自芯片档案（否则是默认的 PDTR）。
    public var keyFromProfile: Bool { state.withLock { $0.fromProfile } }

    // MARK: - Collector

    public func selfTest() -> SelfTestResult {
        var checks: [SelfTestCheck] = []
        let system = resolveProfile()?.profile.system
        let key = system?.systemPowerKey ?? PowerProfiles.fallback.systemPowerKey
        let value = smc.value(key)
        let plausible = value.map { $0 >= 0.3 && $0 <= 1000 } ?? false
        checks.append(
            SelfTestCheck(
                name: "power.rail.key", passed: plausible,
                detail: "\(key)\(system == nil ? " (default)" : "") = \(value.map { String(format: "%.2f W", $0) } ?? "unreadable")"))
        let reading = telemetry.read()
        checks.append(
            SelfTestCheck(
                name: "power.rail.telemetry", passed: reading != nil,
                detail: reading.map { "count \($0.accumulatorCount)" } ?? "PowerTelemetryData unavailable", severity: .advisory))
        let result = SelfTestResult(checks: checks, dataPath: Self.dataPath)
        state.withLock {
            $0.key = plausible ? key : nil
            $0.fromProfile = system != nil
            $0.usable = result.isUsable
            $0.lastTime = nil
            $0.lastWatts = nil
        }
        return result
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        let (key, usable) = state.withLock { ($0.key, $0.usable) }
        guard usable != false, let key else {
            return CollectorOutput(samples: [], status: .unavailable, dataPath: Self.dataPath)
        }
        var samples: [Sample] = []
        let watts = smc.value(key).flatMap { $0 >= 0 && $0 < 2000 ? $0 : nil }
        let reading = telemetry.read(at: time.wallClock)

        let (quality, segment, wall) = state.withLock { s -> (DataQuality, TelemetrySegment?, Double?) in
            // 积分：本样本覆盖到上一个样本，最多 1.05 s。
            if let last = s.lastTime, let w = watts, time.monotonicNanos > last.monotonicNanos {
                let span = min(Double(time.monotonicNanos - last.monotonicNanos) / 1e9, Self.maxSampleSpan)
                s.segmentJoules += w * span
                s.segmentCovered += span
            }
            s.lastTime = time
            s.lastWatts = watts

            var segment: TelemetrySegment?
            var wall: Double?
            if let reading {
                if let previous = s.lastTelemetry, reading.accumulatorCount != previous.accumulatorCount {
                    if reading.accumulatorCount > previous.accumulatorCount {
                        // 墙插估算按计数平均，与积分是否对齐无关。
                        wall = TelemetryMath.wallWatts(from: previous, to: reading)
                        if s.segmentAligned, let mean = TelemetryMath.meanWatts(from: previous, to: reading) {
                            let seconds = reading.wallClock.timeIntervalSince(previous.wallClock)
                            let covered = s.segmentCovered
                            segment = TelemetrySegment(
                                end: reading.wallClock, seconds: seconds,
                                countDelta: reading.accumulatorCount - previous.accumulatorCount, telemetryWatts: mean,
                                integratedWatts: covered >= seconds * 0.9 && covered > 0 ? s.segmentJoules / covered : nil)
                            if let deviation = segment?.deviation {
                                s.agreements = abs(deviation) < 0.05 ? s.agreements + 1 : 0
                            }
                        }
                    }
                    s.segmentJoules = 0
                    s.segmentCovered = 0
                    s.segmentAligned = true
                    s.lastTelemetry = reading
                } else if s.lastTelemetry == nil {
                    s.lastTelemetry = reading
                    s.segmentJoules = 0
                    s.segmentCovered = 0
                    s.segmentAligned = false
                }
            }
            let trusted = s.fromProfile || s.agreements >= Self.agreementsToTrust
            return (trusted ? .measured : .inferred, segment, wall)
        }
        if let reading { ledger.recordTelemetry(reading, segment: segment) }

        if let watts {
            samples.append(Sample(id: .powerSystem, value: watts, quality: quality, time: time))
        } else {
            samples.append(.unavailable(.powerSystem, reason: .readFailed(key), at: time))
        }
        if let wall {
            samples.append(Sample(id: .powerWall, value: wall, quality: .estimated, time: time))
        }
        // 系统总功率是本采集器唯一的直读量：读不到或越界即不可用，连续多次时引擎会重新自检（K19）。
        return CollectorOutput(samples: samples, status: watts == nil ? .unavailable : .ok, dataPath: Self.dataPath)
    }

    public func resetBaseline() {
        state.withLock {
            $0.lastTime = nil
            $0.segmentJoules = 0
            $0.segmentCovered = 0
            $0.segmentAligned = false
            $0.lastTelemetry = nil
        }
    }
}
