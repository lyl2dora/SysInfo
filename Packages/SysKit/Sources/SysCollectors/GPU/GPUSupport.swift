// GPU 与加速器模块的公共部件（GPU 模块设计 §5）：DVFS 档位表、GPUPH 驻留换算、温度键选择、媒体引擎底数。
// 纯函数部分单测覆盖；读硬件的部分沿用 PMGRReader（pmgr 属性是公开 IOKit 读到的未文档化数据）。

import Foundation
import SysModel

// MARK: - DVFS 档位表

public enum GPUFrequencyDiscovery {
    /// 单位判定：表中最大频率 ≥ 1e8 视为 Hz（GPU 表是 Hz；M4、M5 的 CPU 表是 kHz，M2 的 CPU 表是 Hz，所以另按 CPU 表键排除）。
    static let hertzThreshold: UInt32 = 100_000_000

    /// 解出一张表的非零频率（Hz），按表里的顺序（不排序，M4 中间几档不单调）。不是 Hz 表时为 nil。
    public static func hertzFrequencies(_ data: Data) -> [Double]? {
        let pairs = data.count / 8
        guard pairs > 0 else { return nil }
        var out: [Double] = []
        var maximum: UInt32 = 0
        data.withUnsafeBytes { raw in
            for i in 0..<pairs {
                let f = raw.loadUnaligned(fromByteOffset: i * 8, as: UInt32.self).littleEndian
                maximum = max(maximum, f)
                if f > 0 { out.append(Double(f)) }
            }
        }
        return maximum >= hertzThreshold ? out : nil
    }

    /// 选 GPU 档位表（GPU 模块设计 §5）。
    /// - 档案指定了键：用它，非零档数必须在 1…`pStateCount` 之间，否则不用（返回 nil，频率显示不可用）；
    /// - 没有档案：在 Hz 表里排除 CPU 用到的表，取非零档数最多且不超过 `pStateCount` 的一张；档数相同取键号最小的。
    public static func table(
        rawTables: [Int: Data], cpuTableKeys: Set<Int>, pStateCount: Int, preferredKey: Int?
    ) -> GPUFrequencyTable? {
        guard pStateCount > 0 else { return nil }
        if let preferredKey {
            guard let data = rawTables[preferredKey], let frequencies = hertzFrequencies(data),
                (1...pStateCount).contains(frequencies.count)
            else { return nil }
            return GPUFrequencyTable(key: preferredKey, frequencies: frequencies, fromProfile: true)
        }
        let candidates = rawTables.compactMap { key, data -> (Int, [Double])? in
            guard !cpuTableKeys.contains(key), let frequencies = hertzFrequencies(data),
                frequencies.count >= 4, frequencies.count <= pStateCount
            else { return nil }
            return (key, frequencies)
        }
        guard let best = candidates.max(by: { a, b in a.1.count != b.1.count ? a.1.count < b.1.count : a.0 > b.0 }) else {
            return nil
        }
        return GPUFrequencyTable(key: best.0, frequencies: best.1, fromProfile: false)
    }

    /// CPU 用到的表键（perf-domains 与 acc-clusters 里出现的），推断 GPU 表时排除。
    public static func cpuTableKeys(_ properties: PMGRProperties) -> Set<Int> {
        var keys = Set<Int>()
        if let data = properties.perfDomains, let domains = DVFSTableParser.perfDomains(data) {
            keys.formUnion(domains.values)
        }
        if let data = properties.accClusters, let clusters = DVFSTableParser.accClusters(data) {
            keys.formUnion(clusters.values)
        }
        return keys
    }
}

// MARK: - GPUPH 驻留

/// 一次 GPUPH 差分的换算结果。
public struct GPUResidencySummary: Hashable, Sendable {
    /// 非 OFF 驻留的比例；间隔内没有驻留（计数器没走）时为 nil。
    public var active: Double?
    /// 活跃期间按驻留加权的平均频率，Hz；全程 OFF、或没有档位表时为 nil。
    public var frequency: Double?
    /// 活跃期间的平均档位（P 档序号按驻留加权），诊断页用。
    public var averageState: Double?
    /// 各状态的驻留（含 OFF），诊断页用。
    public var states: [GPUStateResidency]
    /// 有驻留的 P 档超出了档位表：表与芯片不符，频率不可信。
    public var exceedsTable: Bool
    /// 有状态的驻留增量为负（计数器复位）：这一段丢弃，活跃比例与频率都为 nil。
    public var counterReset: Bool = false
}

public enum GPUResidencyMath {
    /// 状态名 `P<k>` 的档位序号；`OFF` 为 0；其他名字为 nil。
    public static func pStateIndex(_ name: String) -> Int? {
        if name == "OFF" { return 0 }
        guard name.hasPrefix("P"), let k = Int(name.dropFirst()), k > 0 else { return nil }
        return k
    }

    public static func summarize(names: [String], residencies: [Int64], table: GPUFrequencyTable?) -> GPUResidencySummary {
        let count = min(names.count, residencies.count)
        guard residencies.prefix(count).allSatisfy({ $0 >= 0 }) else {
            return GPUResidencySummary(
                active: nil, frequency: nil, averageState: nil, states: [], exceedsTable: false, counterReset: true)
        }
        let values = (0..<count).map { Double(residencies[$0]) }
        let total = values.reduce(0, +)
        guard total > 0 else {
            return GPUResidencySummary(active: nil, frequency: nil, averageState: nil, states: [], exceedsTable: false)
        }
        var active = 0.0
        var weightedState = 0.0
        var weightedFrequency = 0.0
        var frequencyWeight = 0.0
        var exceeds = false
        var states: [GPUStateResidency] = []
        for i in 0..<count {
            let index = pStateIndex(names[i])
            let frequency = index.flatMap { $0 > 0 ? table?.frequency(ofPState: $0) : nil }
            states.append(GPUStateResidency(name: names[i], share: values[i] / total, frequency: frequency))
            guard let index, index > 0, values[i] > 0 else { continue }
            active += values[i]
            weightedState += Double(index) * values[i]
            if let frequency {
                weightedFrequency += frequency * values[i]
                frequencyWeight += values[i]
            } else if table != nil {
                exceeds = true
            }
        }
        return GPUResidencySummary(
            active: active / total,
            frequency: frequencyWeight > 0 && !exceeds ? weightedFrequency / frequencyWeight : nil,
            averageState: active > 0 ? weightedState / active : nil, states: states, exceedsTable: exceeds)
    }
}

// MARK: - 温度

public enum GPUTemperatureMath {
    /// 没有档案时的占位值（两台目标机实测的并集）与下限。
    public static let fallbackSentinels: [Double] = [-4, 0, 2.2, 2.4, 40]
    public static let fallbackRange: ClosedRange<Double> = 10...130

    /// 代表键有效读数的最大值；全部无效时为 nil。
    public static func maximum(_ readings: [String: Double], isValid: (Double) -> Bool) -> Double? {
        readings.values.filter(isValid).max()
    }

    /// 没有档案时的有效性判定。
    public static func fallbackValid(_ value: Double) -> Bool {
        !fallbackSentinels.contains(value) && fallbackRange.contains(value)
    }
}

// MARK: - 媒体引擎底数

/// 一个媒体引擎的中断速率底数学习（GPU 模块设计 §5）：本次运行观察到的最小值。
/// M5 的 avd 空闲时恒有约 90 次/s；M4 为 0。前 `minimumSamples` 个样本是学习期（返回 nil），之后输出减去底数的速率。
/// 代价：app 启动后一直在解码、从未停过时，底数会停在解码的速率上，直到第一次停下来。
public struct InterruptBaseline: Hashable, Sendable {
    public static let minimumSamples = 10

    public private(set) var samples = 0
    public private(set) var minimum: Double?

    public init() {}

    public var isLearning: Bool { samples < Self.minimumSamples }
    public var baseline: Double { minimum ?? 0 }

    /// 记一个原始速率；学习期返回 nil，否则返回减去底数后的速率（钳到 ≥0）。
    public mutating func observe(_ rate: Double) -> Double? {
        samples += 1
        minimum = min(minimum ?? rate, rate)
        return isLearning ? nil : max(rate - baseline, 0)
    }
}
