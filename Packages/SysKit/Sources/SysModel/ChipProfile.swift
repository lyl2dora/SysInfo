// 芯片档案（CPU 模块设计 §4.3，D33）。
//
// 档案的取值全部来自实测，不按键名推断（键名在每一代上都会误导：M5 的 Tm1E/Tm1I/Tm1p、M2 的 Tp1*、M4 的 Tp1*/Tp2*）。
// 内置档案放在 SysCollectors 的 Resources/ChipProfiles/*.json；本机校准的结果按「socID + 系统 build」另存。
// 档案里只有 SoC 标识、键名、簇键和数值范围，不含任何设备唯一标识（CLAUDE.md）。
//
// JSON 里的字典一律以字符串为键（簇键写成 `d0c1`），便于人读和比对。

public struct ChipProfile: Codable, Hashable, Sendable {
    public static let currentSchema = 1

    public var schema: Int
    /// SoC 标识：pmgr 节点下 PMGR 驱动的类名，例如 `AppleT6041PMGR`。档案按它匹配。
    public var socID: String
    /// 只作说明，例如 `M4 Pro (Mac16,11)`。
    public var description: String
    /// 已验证过的系统 build。
    public var verifiedBuilds: [String]
    /// 来源：哪台机器、哪天、哪个探针或校准生成的。
    public var source: String
    public var topology: TopologyExpectation
    public var temperature: TemperatureProfile
    public var power: PowerProfile

    public init(
        schema: Int = ChipProfile.currentSchema, socID: String, description: String, verifiedBuilds: [String],
        source: String, topology: TopologyExpectation, temperature: TemperatureProfile, power: PowerProfile
    ) {
        self.schema = schema
        self.socID = socID
        self.description = description
        self.verifiedBuilds = verifiedBuilds
        self.source = source
        self.topology = topology
        self.temperature = temperature
        self.power = power
    }
}

/// 拓扑期望：只用于核对运行时发现的拓扑，不用于发现。
public struct TopologyExpectation: Codable, Hashable, Sendable {
    /// 每档核数，下标为 perflevel。
    public var cpuCountsByLevel: [Int]
    /// 簇键 → perflevel。
    public var clusterLevels: [String: Int]

    public init(cpuCountsByLevel: [Int], clusterLevels: [String: Int]) {
        self.cpuCountsByLevel = cpuCountsByLevel
        self.clusterLevels = clusterLevels
    }

    /// 与运行时拓扑是否一致（档案只在一致时使用）。
    public func matches(_ topology: CPUTopology) -> Bool {
        guard topology.quality.isOK, topology.perfLevels.map(\.cpuCount) == cpuCountsByLevel else { return false }
        let actual = Dictionary(uniqueKeysWithValues: topology.clusters.compactMap { c in c.perfLevel.map { (c.key.description, $0) } })
        return actual == clusterLevels
    }
}

public struct TemperatureProfile: Codable, Hashable, Sendable {
    /// 簇键 → 代表变体的键（簇温度 = 其中有效读数的最大值）。没有温度行的簇不出现在这里（D33：E 簇不单列）。
    public var clusters: [String: [String]]
    /// 别名组：恒等或恒定偏移的键（只读代表变体，其余仅作核对）。
    public var aliasGroups: [[String]]
    /// 簇键 → 峰值变体（M2/M4 三元组的 x2），只进诊断页。
    public var peaks: [String: [String]]
    /// 簇键 → 「附近」读数，只进诊断页（例如 M4 E 簇的 Te*，D33）。
    public var nearby: [String: [String]]
    /// 不是 CPU 簇温度的键（SoC/GPU 区域等）：既不进簇温度，也不进 CPU 最高温。
    public var excluded: [String]
    /// 断电占位值：读数精确等于其中之一即为无读数（M4 实测 40.0、-4.0、0.0）。
    public var sentinels: [Double]
    /// 合理范围（°C），超出即为无读数。
    public var validRange: [Double]

    public init(
        clusters: [String: [String]], aliasGroups: [[String]], peaks: [String: [String]], nearby: [String: [String]],
        excluded: [String], sentinels: [Double], validRange: [Double]
    ) {
        self.clusters = clusters
        self.aliasGroups = aliasGroups
        self.peaks = peaks
        self.nearby = nearby
        self.excluded = excluded
        self.sentinels = sentinels
        self.validRange = validRange
    }

    /// 读数是否有效（不是占位值、在合理范围内）。
    public func isValid(_ value: Double) -> Bool {
        guard !sentinels.contains(value), validRange.count == 2 else { return false }
        return value >= validRange[0] && value <= validRange[1]
    }
}

public struct PowerProfile: Codable, Hashable, Sendable {
    /// 簇键 → 专用功耗轨（之和即该簇功耗，不含 GPU）。没有专用轨的芯片为空：功耗显示不可用，不估算（D29）。
    public var clusterRails: [String: [String]]
    /// GPU 轨：用于被动核对「GPU 负载时簇轨不涨」。
    public var gpuRails: [String]
    /// 同时承载 CPU 和 GPU 的轨，只作诊断。
    public var sharedRails: [String]

    public init(clusterRails: [String: [String]], gpuRails: [String], sharedRails: [String]) {
        self.clusterRails = clusterRails
        self.gpuRails = gpuRails
        self.sharedRails = sharedRails
    }
}
