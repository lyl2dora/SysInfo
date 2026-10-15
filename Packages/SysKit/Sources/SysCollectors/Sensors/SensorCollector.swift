// CPU 温度与功耗采集器 `cpu.sensors`（CPU 模块设计 §5.5，D29、D33）。走阻塞通道：SMC 读取会阻塞。
//
// - 只读芯片档案里的最小键集：每簇代表变体、峰值变体、「附近」读数、簇功耗轨、GPU 轨；
// - 读数精确等于档案里的占位值、或超出合理范围，即为无读数（M4 的 Tp* 断电时恰好读出 40.0）；
//   一个簇的键全部无读数时，簇温度为 `unavailable(sensorPowerGated)`，UI 显示「—」，不显示 40 °C；
// - CPU 最高温只取有温度行的簇（档案里只有 P 簇，D33：E 簇不单列，其附近读数只进诊断页）；
// - 簇功耗 = 专用轨之和，不含 GPU；没有专用轨的芯片为 `unavailable(noDedicatedRail)`，不估算（D29）；
// - 未知芯片（没有匹配的档案）：温度为 `unavailable(learning)`，功耗为 `unavailable(noDedicatedRail)`，
//   直到用户在诊断页做「传感器校准」生成本机档案（被动学习在后续步骤接入，见设计偏离记录）。

import Synchronization
import SysModel

/// 一个键在最近一次采样里的读数（诊断页、`sysinfo-cli sensors --raw`）。
public struct SensorKeyReading: Hashable, Sendable {
    public enum Role: String, Hashable, Sendable {
        case cluster, peak, nearby, clusterRail, gpuRail, sharedRail
    }

    public var key: String
    public var role: Role
    public var cluster: ClusterKey?
    /// 原始数值；读失败时为 nil。
    public var raw: Double?
    /// 是否为有效读数（不是占位值、在合理范围内）。功耗轨恒为 true。
    public var valid: Bool
}

/// 纯函数部分：由档案和读数算出样本（单测覆盖）。
public enum SensorMath {
    /// 本次要读的键，以及每个键的角色。
    public static func keyPlan(_ profile: ChipProfile) -> [(key: String, role: SensorKeyReading.Role, cluster: ClusterKey?)] {
        var out: [(String, SensorKeyReading.Role, ClusterKey?)] = []
        func add(_ map: [String: [String]], _ role: SensorKeyReading.Role) {
            for cluster in map.keys.sorted() {
                for key in map[cluster]! { out.append((key, role, ClusterKey(string: cluster))) }
            }
        }
        add(profile.temperature.clusters, .cluster)
        add(profile.temperature.peaks, .peak)
        add(profile.temperature.nearby, .nearby)
        add(profile.power.clusterRails, .clusterRail)
        for key in profile.power.gpuRails { out.append((key, .gpuRail, nil)) }
        for key in profile.power.sharedRails { out.append((key, .sharedRail, nil)) }
        return out
    }

    /// 由读数算出样本。`clusters` 是运行时拓扑的全部簇（没有专用轨或没有温度行的簇也要出功耗样本）。
    public static func evaluate(
        profile: ChipProfile, values: [String: Double], clusters: [ClusterKey], at time: SampleTime
    ) -> (samples: [Sample], readings: [SensorKeyReading]) {
        let temperature = profile.temperature
        var readings: [SensorKeyReading] = []
        for (key, role, cluster) in keyPlan(profile) {
            let raw = values[key]
            let isTemperature = role == .cluster || role == .peak || role == .nearby
            let valid = raw.map { isTemperature ? temperature.isValid($0) : true } ?? false
            readings.append(SensorKeyReading(key: key, role: role, cluster: cluster, raw: raw, valid: valid))
        }

        var samples: [Sample] = []
        var clusterMax: [Double] = []
        var anyTemperatureCluster = false
        var allGated = true
        for name in temperature.clusters.keys.sorted() {
            guard let key = ClusterKey(string: name) else { continue }
            anyTemperatureCluster = true
            let id = MetricID.cpuTemperatureCluster(key)
            let mine = readings.filter { $0.role == .cluster && $0.cluster == key }
            let valid = mine.filter(\.valid).compactMap(\.raw)
            if let max = valid.max() {
                samples.append(Sample(id: id, value: max, time: time))
                clusterMax.append(max)
                allGated = false
            } else if mine.contains(where: { $0.raw.map(temperature.sentinels.contains) ?? false }) {
                samples.append(.unavailable(id, reason: .sensorPowerGated(), at: time))
            } else {
                samples.append(.unavailable(id, reason: .readFailed("no valid key"), at: time))
                allGated = false
            }
        }
        if let max = clusterMax.max() {
            samples.append(Sample(id: .cpuTemperatureMax, value: max, time: time))
        } else {
            let reason: UnavailableReason =
                anyTemperatureCluster && allGated ? .sensorPowerGated() : .notAttributed("no cluster temperature")
            samples.append(.unavailable(.cpuTemperatureMax, reason: reason, at: time))
        }

        var total = 0.0
        var totalOK = !clusters.isEmpty
        for key in clusters.sorted() {
            let id = MetricID.cpuPowerCluster(key)
            guard let rails = profile.power.clusterRails[key.description], !rails.isEmpty else {
                samples.append(.unavailable(id, reason: .noDedicatedRail(), at: time))
                totalOK = false
                continue
            }
            let watts = rails.compactMap { values[$0] }
            guard watts.count == rails.count, watts.allSatisfy({ $0 >= 0 && $0 < 1000 }) else {
                samples.append(.unavailable(id, reason: .readFailed("rail missing"), at: time))
                totalOK = false
                continue
            }
            let sum = watts.reduce(0, +)
            samples.append(Sample(id: id, value: sum, time: time))
            total += sum
        }
        samples.append(
            totalOK
                ? Sample(id: .cpuPowerTotal, value: total, time: time)
                : .unavailable(.cpuPowerTotal, reason: .noDedicatedRail("not every cluster has a rail"), at: time))
        return (samples, readings)
    }

    /// 未知芯片：温度学习中、功耗没有专用轨。
    public static func unknownChipSamples(clusters: [ClusterKey], at time: SampleTime) -> [Sample] {
        clusters.sorted().map { Sample.unavailable(.cpuPowerCluster($0), reason: .noDedicatedRail("unknown chip"), at: time) }
            + [
                .unavailable(.cpuPowerTotal, reason: .noDedicatedRail("unknown chip"), at: time),
                .unavailable(.cpuTemperatureMax, reason: .learning("no chip profile"), at: time),
            ]
    }
}

public final class SensorCollector: Collector {
    public static let collectorID: CollectorID = "cpu.sensors"
    public static let dataPath = "AppleSMC (read-only) × chip profile"

    public var id: CollectorID { Self.collectorID }
    public let lane: CollectorLane = .blocking

    private struct State {
        var profile: ResolvedChipProfile?
        var clusters: [ClusterKey] = []
        var keyInfos: [SMCKeyInfo] = []
        var usable: Bool?
        var warnings = false
        var readings: [SensorKeyReading] = []
        var socID: String?
    }

    private let state = Mutex(State())
    private let smc: SMCReader
    private let topology: CPUTopologyService
    private let resolveProfile: @Sendable (_ socID: String?, _ topology: CPUTopology) -> ResolvedChipProfile?

    public convenience init(useCalibration: Bool = true) {
        self.init(
            smc: SMCReader(), topology: .shared,
            resolveProfile: { socID, topology in
                ChipProfileStore.resolve(
                    socID: socID, build: SystemInfo.osBuild, topology: topology, useCalibration: useCalibration)
            })
    }

    init(
        smc: SMCReader, topology: CPUTopologyService,
        resolveProfile: @escaping @Sendable (String?, CPUTopology) -> ResolvedChipProfile?
    ) {
        self.smc = smc
        self.topology = topology
        self.resolveProfile = resolveProfile
    }

    /// 当前使用的档案（诊断页、CLI）；未知芯片为 nil。
    public var profile: ResolvedChipProfile? { state.withLock { $0.profile } }
    /// 本机 SoC 标识。
    public var socID: String? { state.withLock { $0.socID } }
    /// 最近一次采样每个键的读数。
    public var latestReadings: [SensorKeyReading] { state.withLock { $0.readings } }

    // MARK: - Collector

    public func selfTest() -> SelfTestResult {
        var checks: [SelfTestCheck] = []
        do {
            try smc.open()
            let count = try smc.keyCount()
            checks.append(SelfTestCheck(name: "cpu.sensors.smc", passed: count > 0, detail: "\(count) keys"))
        } catch {
            checks.append(SelfTestCheck(name: "cpu.sensors.smc", passed: false, detail: error.description))
            return finish(checks, profile: nil, socID: nil, clusters: [], infos: [])
        }

        let topo = topology.current ?? topology.refresh()
        let socID = ChipIdentity.socID()
        let clusters = topo.clusters.map(\.key)
        guard let resolved = resolveProfile(socID, topo) else {
            checks.append(
                SelfTestCheck(
                    name: "cpu.sensors.profile", passed: false,
                    detail: "no chip profile for \(socID ?? "unknown SoC") matching this topology", severity: .advisory))
            return finish(checks, profile: nil, socID: socID, clusters: clusters, infos: [])
        }
        checks.append(
            SelfTestCheck(
                name: "cpu.sensors.profile", passed: true,
                detail: "\(resolved.profile.socID) (\(resolved.profile.description)), \(resolved.origin.rawValue)"))
        checks.append(
            SelfTestCheck(
                name: "cpu.sensors.build", passed: resolved.buildVerified,
                detail: "system build \(SystemInfo.osBuild ?? "?"); verified \(resolved.profile.verifiedBuilds)",
                severity: .advisory))

        // 档案里的键都要存在；缺键只影响对应的簇（逐项判定，D24）。
        var infos: [SMCKeyInfo] = []
        var missing: [String] = []
        for entry in SensorMath.keyPlan(resolved.profile) {
            guard let key = SMCKey(fourCC: entry.key), let info = try? smc.keyInfo(for: key) else {
                missing.append(entry.key)
                continue
            }
            infos.append(info)
        }
        checks.append(
            SelfTestCheck(
                name: "cpu.sensors.keys", passed: missing.isEmpty,
                detail: missing.isEmpty ? "\(infos.count) keys present" : "missing \(missing)", severity: .advisory))

        // 读一次：温度键要么有效、要么是占位值；不应出现范围外的非占位值。
        let values = read(infos)
        let temperature = resolved.profile.temperature
        let roles = Dictionary(SensorMath.keyPlan(resolved.profile).map { ($0.key, $0.role) }, uniquingKeysWith: { a, _ in a })
        let implausible = values.filter { key, value in
            guard let role = roles[key], role == .cluster || role == .peak || role == .nearby else { return false }
            return !temperature.isValid(value) && !temperature.sentinels.contains(value)
        }.keys.sorted()
        checks.append(
            SelfTestCheck(
                name: "cpu.sensors.range", passed: implausible.isEmpty,
                detail: implausible.isEmpty ? "all readings valid or power-gated" : "implausible \(implausible)",
                severity: .advisory))
        return finish(checks, profile: resolved, socID: socID, clusters: clusters, infos: infos)
    }

    private func finish(
        _ checks: [SelfTestCheck], profile: ResolvedChipProfile?, socID: String?, clusters: [ClusterKey], infos: [SMCKeyInfo]
    ) -> SelfTestResult {
        let result = SelfTestResult(checks: checks, dataPath: Self.dataPath)
        state.withLock {
            $0.profile = profile
            $0.socID = socID
            $0.clusters = clusters
            $0.keyInfos = infos
            $0.usable = result.isUsable
            $0.warnings = !result.warnings.isEmpty
        }
        return result
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        let (usable, profile, clusters, infos, warnings) = state.withLock {
            ($0.usable, $0.profile, $0.clusters, $0.keyInfos, $0.warnings)
        }
        guard usable != false else {
            return CollectorOutput(samples: [], status: .unavailable, dataPath: Self.dataPath)
        }
        guard let profile else {
            return CollectorOutput(
                samples: SensorMath.unknownChipSamples(clusters: clusters, at: time), status: .degraded,
                dataPath: Self.dataPath)
        }
        let values = read(infos)
        let (samples, readings) = SensorMath.evaluate(
            profile: profile.profile, values: values, clusters: clusters, at: time)
        state.withLock { $0.readings = readings }
        let failed = values.count < infos.count
        return CollectorOutput(
            samples: samples, status: failed || warnings ? .degraded : .ok, dataPath: Self.dataPath)
    }

    public func resetBaseline() {}

    /// 批量读取并解码；读失败的键不出现在结果里。
    private func read(_ infos: [SMCKeyInfo]) -> [String: Double] {
        var out: [String: Double] = [:]
        for info in infos {
            guard let bytes = try? smc.readRaw(info), let value = SMCDecoder.decode(info, bytes: bytes) else { continue }
            out[info.key.description] = value
        }
        return out
    }
}
