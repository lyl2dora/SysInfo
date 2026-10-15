// 频率发现（CPU 模块设计 §5.4，边界稿 §7.2）。纯函数部分，单测覆盖；读硬件的部分在 PMGRReader。
//
// 通道按结构规则识别，不按名字猜含义（同名不同义：`PCPM` 在 M5 上是 Super 簇，在 M2/M4 上是第一个 P 簇）：
// 1. 逐核通道：子组「CPU Core Performance States」里按出现顺序第 k 条对应 logical cpu k，不从名字解析核号；
// 2. 请求簇通道：子组「CPU Complex Performance States」里，是本簇全部逐核通道名前缀的最长一条；
// 3. 实际簇通道：状态名与请求通道完全相同、名字等长且只差一个字符、不是任何逐核通道名的前缀；
//    复核用「把请求名里的 CPU 换成 CPM」的简单规则，两条规则不一致时报告；
// 4. DVFS 表：pmgr 的 `perf-domains`（28 字节一条：byte0 为表键，offset 12 起 16 字节为域名），
//    域名 == 请求簇通道名 → `voltage-states<k>-sram`；没有 perf-domains 时用 `acc-clusters`（8 字节一条）。

import Foundation
import SysModel

/// 一个状态类通道的名字和状态名（来自 IOReport 枚举）。
public struct StateChannelDescriptor: Hashable, Sendable {
    public var name: String
    public var stateNames: [String]

    public init(name: String, stateNames: [String]) {
        self.name = name
        self.stateNames = stateNames
    }
}

/// 一个簇的频率通道。
public struct ClusterFrequencyChannels: Hashable, Sendable {
    public var cluster: ClusterKey
    /// 本簇各核的逐核通道名（与 `CPUCluster.cpus` 顺序相同）。
    public var coreChannels: [String]
    /// 请求簇通道名。
    public var request: String
    /// 实际簇通道名（规则 3）；找不到时为 nil，只能退回请求频率。
    public var actual: String?
    /// 两条实际通道规则是否一致；不一致时 `actual` 仍取规则 3 的结果，诊断页报告。
    public var rulesAgree: Bool
}

/// 一个簇的 DVFS 频率表。
public struct DVFSTable: Hashable, Sendable {
    /// pmgr 的表键号 k（`voltage-states<k>-sram`）。
    public var key: Int
    /// 各档频率，Hz，严格递增；下标与 `V<i>P<j>` 状态的 i 对应。
    public var frequencies: [Double]
    /// 原始单位：`Hz` 或 `kHz`（M2 是 Hz，M4、M5 是 kHz）。
    public var unit: String

    public var top: Double { frequencies.last ?? 0 }
}

public enum FrequencyChannelMapper {
    public enum MapError: Error, Hashable, Sendable, CustomStringConvertible {
        case coreChannelCountMismatch(channels: Int, cpus: Int)
        case noRequestChannel(ClusterKey)

        public var description: String {
            switch self {
            case .coreChannelCountMismatch(let channels, let cpus): "core channels \(channels) != cpus \(cpus)"
            case .noRequestChannel(let key): "no request channel for \(key)"
            }
        }
    }

    /// 为每个簇找出请求与实际通道。`coreChannels` 按出现顺序排列（下标即 logical cpu）。
    public static func map(
        coreChannels: [String], complexChannels: [StateChannelDescriptor], clusters: [CPUCluster],
        logicalCPUCount: Int
    ) -> [ClusterKey: Result<ClusterFrequencyChannels, MapError>] {
        var out: [ClusterKey: Result<ClusterFrequencyChannels, MapError>] = [:]
        guard coreChannels.count == logicalCPUCount else {
            let error = MapError.coreChannelCountMismatch(channels: coreChannels.count, cpus: logicalCPUCount)
            for cluster in clusters { out[cluster.key] = .failure(error) }
            return out
        }
        for cluster in clusters {
            let names = cluster.cpus.map { coreChannels[$0] }
            // 规则 2：本簇全部逐核通道名的前缀里最长的一条。
            let request = complexChannels
                .filter { channel in names.allSatisfy { $0.hasPrefix(channel.name) } }
                .max { $0.name.count < $1.name.count }
            guard let request else {
                out[cluster.key] = .failure(.noRequestChannel(cluster.key))
                continue
            }
            // 规则 3
            let actual = complexChannels.first { candidate in
                candidate.name != request.name && candidate.name.count == request.name.count
                    && candidate.stateNames == request.stateNames
                    && zip(candidate.name, request.name).filter { $0 != $1 }.count == 1
                    && !coreChannels.contains { $0.hasPrefix(candidate.name) }
            }
            // 复核规则：CPU → CPM
            let replaced = request.name.replacingOccurrences(of: "CPU", with: "CPM")
            let simple = complexChannels.contains { $0.name == replaced } && replaced != request.name ? replaced : nil
            out[cluster.key] = .success(
                ClusterFrequencyChannels(
                    cluster: cluster.key, coreChannels: names, request: request.name, actual: actual?.name,
                    rulesAgree: actual?.name == simple))
        }
        return out
    }
}

public enum DVFSTableParser {
    /// `perf-domains`：域名 → 表键号。长度不是 28 的整数倍时返回 nil。
    public static func perfDomains(_ data: Data) -> [String: Int]? {
        guard !data.isEmpty, data.count % 28 == 0 else { return nil }
        let bytes = [UInt8](data)
        var out: [String: Int] = [:]
        for offset in stride(from: 0, to: bytes.count, by: 28) {
            let nameBytes = bytes[(offset + 12)..<(offset + 28)].prefix { $0 != 0 }
            let name = String(decoding: nameBytes, as: UTF8.self)
            if !name.isEmpty { out[name] = Int(bytes[offset]) }
        }
        return out
    }

    /// `acc-clusters`：cluster-id → 表键号（8 字节一条：byte0 为表键，byte1 为 cluster-id）。
    public static func accClusters(_ data: Data) -> [UInt32: Int]? {
        guard !data.isEmpty, data.count % 8 == 0 else { return nil }
        let bytes = [UInt8](data)
        var out: [UInt32: Int] = [:]
        for offset in stride(from: 0, to: bytes.count, by: 8) { out[UInt32(bytes[offset + 1])] = Int(bytes[offset]) }
        return out
    }

    public enum TableError: Error, Hashable, Sendable, CustomStringConvertible {
        case malformed(bytes: Int)
        case lengthMismatch(table: Int, states: Int)
        case notStrictlyIncreasing
        case zeroEntry
        case topOutOfRange(mhz: Double)

        public var description: String {
            switch self {
            case .malformed(let b): "malformed table (\(b) bytes)"
            case .lengthMismatch(let t, let s): "table has \(t) entries, channel has \(s) V states"
            case .notStrictlyIncreasing: "not strictly increasing (constant column?)"
            case .zeroEntry: "zero entry"
            case .topOutOfRange(let mhz): "top \(Int(mhz)) MHz outside 500–10000"
            }
        }
    }

    /// 解析并校验 `voltage-states<k>-sram`（每条 8 字节：频率 u32、电压 u32，小端）。
    /// 单位按量级判断：最大值 ≥1e8 当 Hz，否则当 kHz。只接受 -sram 表：CPU 域的无后缀表第一列是常数，不是频率。
    public static func table(key: Int, data: Data, vStateCount: Int) -> Result<DVFSTable, TableError> {
        guard !data.isEmpty, data.count % 8 == 0 else { return .failure(.malformed(bytes: data.count)) }
        let bytes = [UInt8](data)
        let raw: [UInt32] = stride(from: 0, to: bytes.count, by: 8).map { o in
            UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
        }
        guard raw.count == vStateCount else { return .failure(.lengthMismatch(table: raw.count, states: vStateCount)) }
        guard !raw.contains(0) else { return .failure(.zeroEntry) }
        guard zip(raw, raw.dropFirst()).allSatisfy({ $0 < $1 }) else { return .failure(.notStrictlyIncreasing) }
        let isHz = (raw.max() ?? 0) >= 100_000_000
        let hz = raw.map { Double($0) * (isHz ? 1 : 1000) }
        let topMHz = (hz.last ?? 0) / 1e6
        guard (500...10_000).contains(topMHz) else { return .failure(.topOutOfRange(mhz: topMHz)) }
        return .success(DVFSTable(key: key, frequencies: hz, unit: isHz ? "Hz" : "kHz"))
    }
}

/// 一个簇通道在一段区间内的频率。
public enum ClusterFrequencyReading: Hashable, Sendable {
    /// 活跃：按活跃驻留加权的平均频率（Hz），以及活跃驻留占全部驻留的比例。
    case active(hz: Double, activeFraction: Double)
    /// 几乎不活跃（活跃驻留占比低于阈值）：UI 显示「空闲」，不显示 0 或最低档。
    case idle(activeFraction: Double)
    /// 状态与表对不上，或驻留全为 0。
    case invalid(String)
}

public enum FrequencyMath {
    /// 活跃驻留占比低于它就算空闲（0.2%）。
    public static let idleThreshold = 0.002

    /// `V<i>P<j>` 状态的 i；其他状态（DOWN、IDLE、OFF…）返回 nil，算非活跃。
    public static func vIndex(_ state: String) -> Int? {
        guard state.first == "V" else { return nil }
        let digits = state.dropFirst().prefix { $0.isNumber }
        guard !digits.isEmpty, state.dropFirst(digits.count + 1).first == "P" else { return nil }
        return Int(digits)
    }

    /// 通道里 V 状态的个数（表长必须等于它）。
    public static func vStateCount(_ states: [String]) -> Int {
        states.compactMap(vIndex).count
    }

    /// 频率 = Σ(V_i 驻留 × f_i) / Σ 活跃驻留。
    public static func frequency(stateNames: [String], residencies: [Int64], table: DVFSTable) -> ClusterFrequencyReading {
        guard stateNames.count == residencies.count else { return .invalid("states/residencies mismatch") }
        var weighted = 0.0
        var active = 0.0
        var total = 0.0
        for (name, residency) in zip(stateNames, residencies) {
            let r = Double(max(residency, 0))
            total += r
            guard let i = vIndex(name) else { continue }
            guard i < table.frequencies.count else { return .invalid("V\(i) beyond table (\(table.frequencies.count))") }
            weighted += r * table.frequencies[i]
            active += r
        }
        guard total > 0 else { return .invalid("no residency") }
        let fraction = active / total
        guard fraction >= idleThreshold, active > 0 else { return .idle(activeFraction: fraction) }
        return .active(hz: weighted / active, activeFraction: fraction)
    }
}
