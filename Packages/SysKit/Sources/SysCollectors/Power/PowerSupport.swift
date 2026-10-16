// 功耗与散热模块的公共部件（功耗与散热模块设计 §4）：遥测读取、跨采集器的核对账本、风扇发现、热点学习、PMGR 命名。

import Foundation
import IOKit
import Synchronization
import SysModel

// MARK: - 遥测

/// 读 `AppleSmartBattery.PowerTelemetryData`（未文档的 IORegistry 属性，只读，0.15–0.23 ms/次）。
/// 台式机上也有这个服务（`BatteryInstalled = No`），不能据此判断有无电池（调研报告 §1.7）。
public final class TelemetryReader: Sendable {
    private let service = Mutex<io_service_t>(0)

    public init() {}

    deinit {
        service.withLock { s in
            if s != 0 { IOObjectRelease(s) }
        }
    }

    /// 读一次；服务或属性不存在时为 nil。
    public func read(at date: Date = Date()) -> PowerTelemetryReading? {
        service.withLock { s -> PowerTelemetryReading? in
            if s == 0 { s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery")) }
            guard s != 0,
                let raw = IORegistryEntryCreateCFProperty(s, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue(),
                let dict = raw as? [String: Any]
            else { return nil }
            func int(_ key: String) -> Int64? { (dict[key] as? NSNumber)?.int64Value }
            guard let power = int("AccumulatedSystemPowerIn"), let count = int("SystemPowerInAccumulatorCount") else {
                return nil
            }
            return PowerTelemetryReading(
                accumulatedSystemPowerIn: power, accumulatorCount: count,
                accumulatedWallEnergy: int("AccumulatedWallEnergyEstimate") ?? 0, wallClock: date)
        }
    }
}

/// 遥测换算（纯函数，单测覆盖）。
public enum TelemetryMath {
    /// 两次读数之间的遥测均值，W（ΔAccumulatedSystemPowerIn 是毫焦，Δcount 约等于秒数）。
    public static func meanWatts(from a: PowerTelemetryReading, to b: PowerTelemetryReading) -> Double? {
        let count = b.accumulatorCount - a.accumulatorCount
        let energy = b.accumulatedSystemPowerIn - a.accumulatedSystemPowerIn
        guard count > 0, energy >= 0 else { return nil }
        return Double(energy) / 1000 / Double(count)
    }

    /// 墙插功率估算，W（ΔAccumulatedWallEnergyEstimate 是微瓦时：× 3.6 / 1000 得焦耳）。
    public static func wallWatts(from a: PowerTelemetryReading, to b: PowerTelemetryReading) -> Double? {
        let count = b.accumulatorCount - a.accumulatorCount
        let energy = b.accumulatedWallEnergy - a.accumulatedWallEnergy
        guard count > 0, energy >= 0, b.accumulatedWallEnergy > 0 else { return nil }
        return Double(energy) * 3.6 / 1000 / Double(count)
    }
}

// MARK: - 账本

/// 功耗采集器之间共享的核对数据（功耗与散热模块设计 §4.6）：DRAM 功率与 ANE 估算能量的累计积分、交叉核对结论、遥测对账。
///
/// 几个采集器都在引擎的队列上串行运行，`Mutex` 只防 app 的诊断页同时来读。
public final class PowerLedger: Sendable {
    /// 交叉核对的项目名。
    public enum Check: String, Sendable, CaseIterable {
        case dram, gpu
        /// coalition 槽位 39 合计 ÷ PMGR ANE 批次（D58，实测 0.92–0.93）。
        case ane
    }

    /// 允许范围（1 s 采样时）；采样更稀时 DRAM 放宽到 ±5%（10 s 矩形积分的误差）。
    public static let ranges: [Check: ClosedRange<Double>] = [.dram: 0.98...1.02, .gpu: 0.9...1.1, .ane: 0.8...1.05]
    static let relaxedDRAMRange: ClosedRange<Double> = 0.95...1.05
    /// 连续失败多少次后把对应指标改为不可用。
    static let failuresToDisable = 2
    /// 遥测对账保留的段数（诊断页）。
    static let segmentLimit = 60
    /// DRAM 积分检查点保留时长：比一个批次（1800 s）加检测滞后长。
    static let checkpointRetention: TimeInterval = 7200

    private struct Checkpoint {
        var date: Date
        var joules: Double
        var covered: Double
        var samples: Int
    }

    private struct State {
        var dram: [Checkpoint] = []
        var ane: [Checkpoint] = []
        var checks: [Check: CrossCheckResult] = [:]
        var segments: [TelemetrySegment] = []
        var latestTelemetry: PowerTelemetryReading?
    }

    private let state = Mutex(State())

    public init() {}

    // MARK: DRAM 积分

    /// 记一个 DRAM 功率样本：它覆盖到上一个样本的 `seconds` 秒（调用方已按采样间隔封顶）。
    func recordDRAM(watts: Double, seconds: Double, at date: Date) {
        state.withLock { s in Self.append(&s.dram, joules: watts * seconds, seconds: seconds, at: date) }
    }

    /// 两个时刻之间的 DRAM 积分：焦耳、覆盖秒数、平均采样间隔。数据不覆盖这段时间时为 nil。
    func dramIntegral(from start: Date, to end: Date) -> (joules: Double, covered: Double, meanInterval: Double)? {
        state.withLock { s in Self.integral(s.dram, from: start, to: end) }
    }

    // MARK: ANE 估算积分（D58）

    /// 记一个 coalition 窗口里全部 coalition 的 ANE 能量（槽位 39 合计），窗口长 `seconds` 秒。
    func recordANE(joules: Double, seconds: Double, at date: Date) {
        guard seconds > 0, joules >= 0 else { return }
        state.withLock { s in Self.append(&s.ane, joules: joules, seconds: seconds, at: date) }
    }

    /// 两个时刻之间的 ANE 估算积分。
    func aneIntegral(from start: Date, to end: Date) -> (joules: Double, covered: Double, meanInterval: Double)? {
        state.withLock { s in Self.integral(s.ane, from: start, to: end) }
    }

    private static func append(_ list: inout [Checkpoint], joules: Double, seconds: Double, at date: Date) {
        let last = list.last ?? Checkpoint(date: date, joules: 0, covered: 0, samples: 0)
        list.append(
            Checkpoint(date: date, joules: last.joules + joules, covered: last.covered + seconds, samples: last.samples + 1))
        let cutoff = date.addingTimeInterval(-checkpointRetention)
        if let drop = list.firstIndex(where: { $0.date >= cutoff }), drop > 0 { list.removeFirst(drop) }
    }

    private static func integral(_ list: [Checkpoint], from start: Date, to end: Date)
        -> (joules: Double, covered: Double, meanInterval: Double)?
    {
        guard let first = list.last(where: { $0.date <= start }), let last = list.last(where: { $0.date <= end }),
            last.samples > first.samples
        else { return nil }
        let covered = last.covered - first.covered
        return (last.joules - first.joules, covered, covered / Double(last.samples - first.samples))
    }

    // MARK: 交叉核对

    /// 记一次核对。`ratio` 为 nil 表示这次不下结论（覆盖不足）。
    func record(_ check: Check, ratio: Double?, range: ClosedRange<Double>, at date: Date) {
        state.withLock { s in
            let previous = s.checks[check]
            let verdict: CrossCheckVerdict = ratio.map { range.contains($0) ? .passed : .failed } ?? .inconclusive
            let failures =
                verdict == .failed ? (previous?.consecutiveFailures ?? 0) + 1
                : verdict == .passed ? 0 : (previous?.consecutiveFailures ?? 0)
            s.checks[check] = CrossCheckResult(
                name: check.rawValue, verdict: verdict, ratio: ratio, range: range, at: date, consecutiveFailures: failures)
        }
    }

    /// 某项核对是否已连续失败到要停用对应指标。
    public func isDisabled(_ check: Check) -> Bool {
        state.withLock { ($0.checks[check]?.consecutiveFailures ?? 0) >= Self.failuresToDisable }
    }

    /// 全部核对的最新结果（没有结果的项为 pending）。
    public var checks: [CrossCheckResult] {
        state.withLock { s in
            Check.allCases.map {
                s.checks[$0]
                    ?? CrossCheckResult(
                        name: $0.rawValue, verdict: .pending, ratio: nil, range: Self.ranges[$0]!, at: nil,
                        consecutiveFailures: 0)
            }
        }
    }

    // MARK: 遥测

    func recordTelemetry(_ reading: PowerTelemetryReading, segment: TelemetrySegment?) {
        state.withLock { s in
            s.latestTelemetry = reading
            if let segment {
                s.segments.append(segment)
                if s.segments.count > Self.segmentLimit { s.segments.removeFirst(s.segments.count - Self.segmentLimit) }
            }
        }
    }

    /// 最近一次遥测读数（能耗补数用）。
    public var latestTelemetry: PowerTelemetryReading? { state.withLock { $0.latestTelemetry } }
    /// 最近的遥测对账段，旧的在前。
    public var telemetrySegments: [TelemetrySegment] { state.withLock { $0.segments } }
}

// MARK: - 风扇

/// 一个风扇的键（运行时发现，D44：模式键的大小写随芯片不同）。
public struct FanKeys: Hashable, Sendable {
    public var index: Int
    public var actual: String
    public var target: String
    public var minimum: String
    public var maximum: String
    /// 模式键；两种写法都不存在时为 nil。
    public var mode: String?
}

public enum FanDiscovery {
    /// 由风扇数和「某个键是否存在」得出各风扇的键。`exists` 只看 key-info 能否读到。
    public static func discover(count: Int, exists: (String) -> Bool) -> [FanKeys] {
        guard count > 0, count <= 8 else { return [] }
        return (0..<count).compactMap { i in
            let actual = "F\(i)Ac"
            guard exists(actual) else { return nil }
            let mode = ["F\(i)md", "F\(i)Md"].first(where: exists)
            return FanKeys(
                index: i, actual: actual, target: "F\(i)Tg", minimum: "F\(i)Mn", maximum: "F\(i)Mx", mode: mode)
        }
    }
}

// MARK: - 热点学习

/// 未知芯片的 SoC 最热点：找出「与全体有效温度键逐次最大值吻合」的聚合键（D44 PT7）。纯值类型，单测覆盖。
public struct HotspotLearner: Sendable {
    /// 至少观察这么多次才下结论。
    public static let minimumSamples = 20
    /// 最多观察这么多次；到时仍不够吻合就放弃（显示「—」）。
    public static let maximumSamples = 60
    /// 吻合比例的门槛。
    public static let threshold = 0.9
    static let tolerance = 0.05

    private var hits: [String: Int] = [:]
    private var lastValue: [String: Double] = [:]
    private var changed: Set<String> = []
    public private(set) var samples = 0
    public private(set) var result: String?
    public private(set) var gaveUp = false

    public init() {}

    /// 喂一次全部温度键的读数（调用方已排除占位值与超出范围的读数）。
    public mutating func observe(_ readings: [String: Double]) {
        guard result == nil, !gaveUp, !readings.isEmpty else { return }
        for (key, value) in readings {
            if let last = lastValue[key], last != value { changed.insert(key) }
            lastValue[key] = value
        }
        guard let top = readings.values.max() else { return }
        samples += 1
        for (key, value) in readings where top - value <= Self.tolerance { hits[key, default: 0] += 1 }
        guard samples >= Self.minimumSamples else { return }
        // 只认会变化的键：一直不变的键可能是停在旧值的读数。
        let best = hits.filter { changed.contains($0.key) }.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }
        if let best, Double(best.value) / Double(samples) >= Self.threshold {
            result = best.key
        } else if samples >= Self.maximumSamples {
            gaveUp = true
        }
    }
}

// MARK: - PMGR 命名

/// PMGR 通道名的归一化（D44：通道名随芯片不同，M5 `GPU0`/`DRAM0`…，M4 `GPU`/`DRAM`…且没有 FAB）。
public enum PMGRNaming {
    /// 已知顶层部件：归一化名 → 去掉末尾数字后的通道名。
    public static let known: [String: String] = [
        "cpu": "CPU Energy", "gpu": "GPU", "ane": "ANE", "ave": "AVE", "dram": "DRAM", "amcc": "AMCC", "dcs": "DCS",
        "fabric": "FAB", "afr": "AFR", "display": "DISP", "displayExt": "DISPEXT", "isp": "ISP", "msr": "MSR",
    ]

    /// 没有档案时，由通道名列表推出「归一化名 → 通道名」：顶层通道去掉末尾的 `0` 后与已知名单匹配。
    public static func components(from channelNames: [String]) -> [String: String] {
        var out: [String: String] = [:]
        let byBase = Dictionary(known.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        for name in channelNames {
            let base = name.hasSuffix("0") && name != "CPU Energy" ? String(name.dropLast()) : name
            if let normalized = byBase[base], out[normalized] == nil { out[normalized] = name }
        }
        return out
    }
}

// MARK: - 档案

enum PowerProfiles {
    /// 本机的档案（与 CPU 模块共用同一份解析结果的规则，D33、D37）。
    static func resolve() -> ResolvedChipProfile? {
        let topology = CPUTopologyService.shared.current ?? CPUTopologyService.shared.refresh()
        return ChipProfileStore.resolve(socID: ChipIdentity.socID(), build: SystemInfo.osBuild, topology: topology)
    }

    /// 没有档案时用的默认键（两台目标机与 M2 上都存在 PDTR、PZC0；M2 没有 PZD1，自检时按是否存在决定）。
    static let fallback = SystemProfile(
        systemPowerKey: "PDTR", socPowerKey: "PZC0", socInputPowerKey: "PHPC", dramPowerKey: "PZD1", hotspotKey: nil,
        hotspotNote: nil, pmgrComponents: [:], catalogGroups: [:], placeholders: [])
}

extension SMCReader {
    /// 键是否存在（key-info 能读到）。
    func hasKey(_ name: String) -> Bool {
        guard let key = SMCKey(fourCC: name) else { return false }
        return (try? keyInfo(for: key)) != nil
    }

    /// 读一个键的数值；不存在或不能解码时为 nil。
    func value(_ name: String) -> Double? {
        guard let key = SMCKey(fourCC: name) else { return nil }
        return (try? readValue(key)) ?? nil
    }
}

/// 占位值比较按 Float 精度：SMC 的 `flt` 解码成 Double 后，2.2 会变成 2.2000000477。
func isPlaceholder(_ value: Double, in placeholders: [Double]) -> Bool {
    let f = Float(value)
    return placeholders.contains { Float($0) == f }
}
