// SoC 级功率、最热点与风扇采集器 `power.sensors`（功耗与散热模块设计 §4.2，D44）。走阻塞通道。
//
// - 读档案 system 段的键：SoC 功率 `PZC0`、SoC 实测输入 `PHPC`（只进诊断读数）、DRAM `PZD1`、最热点聚合键；
//   没有档案时用默认键（存在才读），质量标 inferred；
// - 风扇：自检时按 `FNum` 与键是否存在发现，模式键依次试 `F<i>md`、`F<i>Md`（D44）；
// - 最热点：有档案读聚合键；没有档案时用 HotspotLearner，每次另读全部温度键，学到之前为 `unavailable(learning)`；
// - DRAM 功率按采样间隔记进账本，供 PMGR 批次到来时交叉核对；核对连续失败时 `power.dram` 改为不可用（D44 §7）；
// - 低功耗模式：`ProcessInfo.isLowPowerModeEnabled`。

import Foundation
import Synchronization
import SysModel

/// 一个原始键的诊断读数。
public struct PowerKeyReading: Hashable, Sendable {
    public var key: String
    public var value: Double?
}

public final class PowerSensorCollector: Collector {
    public static let collectorID: CollectorID = "power.sensors"
    public static let dataPath = "AppleSMC (read-only) × chip profile system section"

    /// 诊断页列出的原始功率键（存在才读）。
    static let diagnosticKeys = ["PHPC", "PZC0", "PZD1", "PPSR", "PMVC", "PSTR", "PDTR"]
    /// 诊断读数最多多久刷新一次，纳秒（只给诊断页看，不必每次都读）。
    static let diagnosticsPeriod: UInt64 = 10_000_000_000
    /// 最热点的合理范围（°C）。
    static let hotspotRange: ClosedRange<Double> = -20...150
    /// DRAM 样本最多覆盖的秒数（后台 10 s 采样，留一点余量）。
    static let maxDRAMSpan: Double = 15

    public var id: CollectorID { Self.collectorID }
    public let lane: CollectorLane = .blocking
    public let ledger: PowerLedger

    /// 最热点的来源（诊断页）。
    public enum HotspotSource: Hashable, Sendable {
        case profile(key: String, note: String?)
        case learned(key: String)
        case learning(samples: Int)
        case unavailable
    }

    private struct State {
        var usable: Bool?
        var fromProfile = false
        var socKey: String?
        var socInputKey: String?
        var dramKey: String?
        var hotspotKey: String?
        var hotspotNote: String?
        var hotspotFromProfile = false
        var placeholders: [Double] = []
        var temperatureKeys: [String] = []
        var learner = HotspotLearner()
        var fans: [FanKeys] = []
        var lastTime: SampleTime?
        var diagnostics: [PowerKeyReading] = []
        var diagnosticsAt: UInt64 = 0
    }

    private let state = Mutex(State())
    private let smc: SMCReader
    private let resolveProfile: @Sendable () -> ResolvedChipProfile?

    public convenience init(ledger: PowerLedger) {
        self.init(smc: SMCReader(), ledger: ledger, resolveProfile: { PowerProfiles.resolve() })
    }

    init(smc: SMCReader, ledger: PowerLedger, resolveProfile: @escaping @Sendable () -> ResolvedChipProfile?) {
        self.smc = smc
        self.ledger = ledger
        self.resolveProfile = resolveProfile
    }

    /// 发现的风扇。
    public var fans: [FanKeys] { state.withLock { $0.fans } }
    /// 最热点的来源。
    public var hotspotSource: HotspotSource {
        state.withLock { s in
            if let key = s.hotspotKey {
                return s.hotspotFromProfile ? .profile(key: key, note: s.hotspotNote) : .learned(key: key)
            }
            return s.learner.gaveUp || s.temperatureKeys.isEmpty ? .unavailable : .learning(samples: s.learner.samples)
        }
    }
    /// 最近一次的原始功率键读数（诊断页）。
    public var diagnosticReadings: [PowerKeyReading] { state.withLock { $0.diagnostics } }
    /// 各指标的键（诊断页）：SoC、SoC 输入、DRAM；键来自档案还是默认。
    public var keys: (soc: String?, socInput: String?, dram: String?, fromProfile: Bool) {
        state.withLock { ($0.socKey, $0.socInputKey, $0.dramKey, $0.fromProfile) }
    }

    // MARK: - Collector

    public func selfTest() -> SelfTestResult {
        var checks: [SelfTestCheck] = []
        do {
            try smc.open()
        } catch {
            checks.append(SelfTestCheck(name: "power.sensors.smc", passed: false, detail: error.description))
            state.withLock { $0.usable = false }
            return SelfTestResult(checks: checks, dataPath: Self.dataPath)
        }
        let system = resolveProfile()?.profile.system
        let profile = system ?? PowerProfiles.fallback
        func present(_ key: String?) -> String? { key.flatMap { smc.hasKey($0) ? $0 : nil } }
        let soc = present(profile.socPowerKey)
        let socInput = present(profile.socInputPowerKey)
        let dram = present(profile.dramPowerKey)
        let missing = [profile.socPowerKey, profile.dramPowerKey].compactMap { $0 }.filter { !smc.hasKey($0) }
        checks.append(
            SelfTestCheck(
                name: "power.sensors.keys", passed: missing.isEmpty,
                detail: missing.isEmpty
                    ? "\(system == nil ? "default" : "profile") keys present: \([soc, dram].compactMap { $0 })"
                    : "missing \(missing)", severity: .advisory))

        // 最热点：档案的键要存在且读数合理（或是占位值）。
        var hotspotKey: String?
        if let key = system?.hotspotKey {
            let value = smc.value(key)
            let ok = value.map { Self.hotspotRange.contains($0) || isPlaceholder($0, in: system?.placeholders ?? []) } ?? false
            checks.append(
                SelfTestCheck(
                    name: "power.sensors.hotspot", passed: ok,
                    detail: "\(key) = \(value.map { String(format: "%.1f", $0) } ?? "unreadable")", severity: .advisory))
            if ok { hotspotKey = key }
        }
        // 没有档案的热点：准备学习用的温度键（全部 flt 温度键，枚举一次）。
        var temperatureKeys: [String] = []
        if system?.hotspotKey == nil, let all = try? smc.allKeys() {
            temperatureKeys = all.map(\.description).filter { $0.hasPrefix("T") }.filter { name in
                guard let key = SMCKey(fourCC: name), let info = try? smc.keyInfo(for: key) else { return false }
                return info.dataType == "flt "
            }
            checks.append(
                SelfTestCheck(
                    name: "power.sensors.hotspot", passed: true,
                    detail: "no profile key; learning over \(temperatureKeys.count) temperature keys", severity: .advisory))
        }

        // 风扇：FNum 为 0 或读不到时没有风扇（无风扇机型）。
        let fanCount = smc.value("FNum").map { Int($0) } ?? 0
        let fans = FanDiscovery.discover(count: fanCount) { smc.hasKey($0) }
        checks.append(
            SelfTestCheck(
                name: "power.sensors.fans", passed: true,
                detail: fans.isEmpty ? "no fans" : fans.map { "fan\($0.index) mode \($0.mode ?? "none")" }.joined(separator: ", "),
                severity: .advisory))

        let result = SelfTestResult(checks: checks, dataPath: Self.dataPath)
        state.withLock {
            $0.usable = result.isUsable
            $0.fromProfile = system != nil
            $0.socKey = soc
            $0.socInputKey = socInput
            $0.dramKey = dram
            $0.hotspotKey = hotspotKey
            $0.hotspotNote = system?.hotspotNote
            $0.hotspotFromProfile = hotspotKey != nil
            $0.placeholders = system?.placeholders ?? [0, -4, 40]
            $0.temperatureKeys = temperatureKeys
            $0.learner = HotspotLearner()
            $0.fans = fans
            $0.lastTime = nil
        }
        return result
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        let s = state.withLock { $0 }
        guard s.usable != false else {
            return CollectorOutput(samples: [], status: .unavailable, dataPath: Self.dataPath)
        }
        var samples: [Sample] = []
        let quality: DataQuality = s.fromProfile ? .measured : .inferred
        var failed = false

        func power(_ id: MetricID, _ key: String?) -> Double? {
            guard let key else {
                samples.append(.unavailable(id, reason: .readFailed("no key"), at: time))
                return nil
            }
            guard let value = smc.value(key), value >= 0, value < 1000 else {
                samples.append(.unavailable(id, reason: .readFailed(key), at: time))
                failed = true
                return nil
            }
            return value
        }
        if let soc = power(.powerSoC, s.socKey) {
            samples.append(Sample(id: .powerSoC, value: soc, quality: quality, time: time))
        }
        if let dram = power(.powerDRAM, s.dramKey) {
            let span = s.lastTime.map { min(Double(time.monotonicNanos &- $0.monotonicNanos) / 1e9, Self.maxDRAMSpan) } ?? 0
            if span > 0 { ledger.recordDRAM(watts: dram, seconds: span, at: time.wallClock) }
            if ledger.isDisabled(.dram) {
                samples.append(.unavailable(.powerDRAM, reason: .selfTestFailed("cross-check"), at: time))
            } else {
                samples.append(Sample(id: .powerDRAM, value: dram, quality: quality, time: time))
            }
        }

        // 最热点
        var learnedKey: String?
        var learnerSamples = 0
        if let key = s.hotspotKey {
            if let value = smc.value(key) {
                if Self.hotspotRange.contains(value), !isPlaceholder(value, in: s.placeholders) {
                    samples.append(Sample(id: .thermalSoCHotspot, value: value, time: time))
                } else {
                    samples.append(.unavailable(.thermalSoCHotspot, reason: .sensorPowerGated(key), at: time))
                }
            } else {
                samples.append(.unavailable(.thermalSoCHotspot, reason: .readFailed(key), at: time))
            }
        } else if !s.temperatureKeys.isEmpty, !s.learner.gaveUp {
            var readings: [String: Double] = [:]
            for key in s.temperatureKeys {
                if let v = smc.value(key), (10...150).contains(v), !isPlaceholder(v, in: s.placeholders) { readings[key] = v }
            }
            var learner = s.learner
            learner.observe(readings)
            learnedKey = learner.result
            learnerSamples = learner.samples
            state.withLock {
                $0.learner = learner
                if let learnedKey { $0.hotspotKey = learnedKey }
            }
            if let learnedKey, let v = readings[learnedKey] {
                samples.append(Sample(id: .thermalSoCHotspot, value: v, quality: .inferred, time: time))
            } else {
                samples.append(.unavailable(.thermalSoCHotspot, reason: .learning("\(learnerSamples) samples"), at: time))
            }
        } else {
            samples.append(.unavailable(.thermalSoCHotspot, reason: .notAttributed("no hotspot key"), at: time))
        }

        // 风扇
        for fan in s.fans {
            let pairs: [(MetricID, String?)] = [
                (.fanSpeed(fan.index), fan.actual), (.fanTarget(fan.index), fan.target),
                (.fanMinimum(fan.index), fan.minimum), (.fanMaximum(fan.index), fan.maximum),
                (.fanMode(fan.index), fan.mode),
            ]
            for (id, key) in pairs {
                guard let key else { continue }
                if let v = smc.value(key), v >= 0, v < 100_000 {
                    samples.append(Sample(id: id, value: v, time: time))
                } else {
                    samples.append(.unavailable(id, reason: .readFailed(key), at: time))
                }
            }
        }

        samples.append(
            Sample(id: .powerLowPowerMode, value: ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0, time: time))

        // 诊断读数：原始功率键（只读存在的键），最多每 10 s 一次。
        if s.diagnostics.isEmpty || time.monotonicNanos &- s.diagnosticsAt >= Self.diagnosticsPeriod {
            let diagnostics = Self.diagnosticKeys.compactMap { key -> PowerKeyReading? in
                guard smc.hasKey(key) else { return nil }
                return PowerKeyReading(key: key, value: smc.value(key))
            }
            state.withLock {
                $0.diagnostics = diagnostics
                $0.diagnosticsAt = time.monotonicNanos
            }
        }
        state.withLock { $0.lastTime = time }
        return CollectorOutput(samples: samples, status: failed ? .degraded : .ok, dataPath: Self.dataPath)
    }

    public func resetBaseline() {
        state.withLock { $0.lastTime = nil }
    }
}
