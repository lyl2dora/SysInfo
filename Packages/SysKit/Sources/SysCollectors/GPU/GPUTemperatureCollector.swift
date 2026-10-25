// GPU 温度采集器 `gpu.temperature`（GPU 模块设计 §5，D57 G4）。走阻塞通道（SMC）。
//
// - 有档案：读档案 `gpu.temperatureKeys`，取有效读数的最大值，占位值与合理范围取档案（M4 的 −4、0、2.2、2.4）；
// - 没有档案：自检时枚举全部 `Tg*`（flt），每次全读，去掉占位值与 < 10 °C 的读数后取最大值，质量标 inferred；
// - 全部是占位值（M4 GPU 关断时）：unavailable(sensorPowerGated)，界面显示「—」。

import Foundation
import Synchronization
import SysModel

public final class GPUTemperatureCollector: Collector {
    public static let collectorID: CollectorID = "gpu.temperature"
    public static let dataPath = "AppleSMC Tg* (read-only) × chip profile gpu section"

    public var id: CollectorID { Self.collectorID }
    public let lane: CollectorLane = .blocking

    /// 键从哪里来（诊断页）。
    public enum KeySource: Hashable, Sendable {
        case profile(note: String?)
        case allKeys
        case none
    }

    private struct State {
        var keys: [SMCKey] = []
        var source: KeySource = .none
        var profile: GPUChipProfile?
        var latest: [String: Double] = [:]
    }

    private let state = Mutex(State())
    private let smc: SMCReader
    private let resolveProfile: @Sendable () -> ResolvedChipProfile?

    public convenience init() {
        self.init(smc: SMCReader(), resolveProfile: { PowerProfiles.resolve() })
    }

    init(smc: SMCReader, resolveProfile: @escaping @Sendable () -> ResolvedChipProfile?) {
        self.smc = smc
        self.resolveProfile = resolveProfile
    }

    /// 读的键与来源（诊断页）。
    public var keys: (names: [String], source: KeySource) { state.withLock { ($0.keys.map(\.description), $0.source) } }
    /// 最近一次各键的原始读数（诊断页）。
    public var latestReadings: [String: Double] { state.withLock { $0.latest } }

    public func selfTest() -> SelfTestResult {
        var checks: [SelfTestCheck] = []
        do {
            try smc.open()
        } catch {
            checks.append(SelfTestCheck(name: "gpu.temperature.smc", passed: false, detail: error.description))
            state.withLock { $0.keys = []; $0.source = .none }
            return SelfTestResult(checks: checks, dataPath: Self.dataPath)
        }
        let profile = resolveProfile()?.profile.gpu
        var keys: [SMCKey] = []
        var source: KeySource = .none
        if let profile, !profile.temperatureKeys.isEmpty {
            keys = profile.temperatureKeys.compactMap(SMCKey.init(fourCC:)).filter { (try? smc.keyInfo(for: $0)) != nil }
            let missing = profile.temperatureKeys.count - keys.count
            checks.append(
                SelfTestCheck(
                    name: "gpu.temperature.keys", passed: !keys.isEmpty,
                    detail: "profile keys \(keys.count)/\(profile.temperatureKeys.count)\(missing > 0 ? ", \(missing) missing" : "")"))
            source = .profile(note: profile.note)
        } else {
            let all = (try? smc.allKeys()) ?? []
            keys = all.filter { $0.description.hasPrefix("Tg") }.filter { key in
                (try? smc.keyInfo(for: key))?.dataType == "flt "
            }
            checks.append(
                SelfTestCheck(
                    name: "gpu.temperature.keys", passed: !keys.isEmpty,
                    detail: "no profile; reading all \(keys.count) Tg keys", severity: keys.isEmpty ? .required : .advisory))
            source = keys.isEmpty ? .none : .allKeys
        }
        let result = SelfTestResult(checks: checks, dataPath: Self.dataPath)
        state.withLock {
            $0.keys = result.isUsable ? keys : []
            $0.source = result.isUsable ? source : .none
            $0.profile = profile
            $0.latest = [:]
        }
        return result
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        let (keys, source, profile) = state.withLock { ($0.keys, $0.source, $0.profile) }
        guard !keys.isEmpty else {
            return CollectorOutput(
                samples: [.unavailable(.gpuTemperature, reason: .notAttributed("no keys"), at: time)], status: .unavailable,
                dataPath: Self.dataPath)
        }
        let values = smc.readValues(keys)
        let readings = Dictionary(uniqueKeysWithValues: values.map { ($0.key.description, $0.value) })
        state.withLock { $0.latest = readings }
        let isValid: (Double) -> Bool = profile.map { p in { p.isValid($0) } } ?? GPUTemperatureMath.fallbackValid
        let sample: Sample
        if readings.isEmpty {
            sample = .unavailable(.gpuTemperature, reason: .readFailed("smc"), at: time)
        } else if let maximum = GPUTemperatureMath.maximum(readings, isValid: isValid) {
            let quality: DataQuality = if case .profile = source { .measured } else { .inferred }
            sample = Sample(id: .gpuTemperature, value: maximum, quality: quality, time: time)
        } else {
            sample = .unavailable(.gpuTemperature, reason: .sensorPowerGated("gpu off"), at: time)
        }
        return CollectorOutput(
            samples: [sample], status: .reads(attempted: keys.count, failed: keys.count - readings.count),
            dataPath: Self.dataPath)
    }

    public func resetBaseline() {}
}
