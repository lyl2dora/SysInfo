// CPU 拓扑的值类型（CPU 模块设计 §4.1，边界稿 §7.1）。
//
// 一切按簇、按档的显示都基于这里。拓扑在运行时发现（D20）：
// - 核按 cluster-id 分簇，簇键带上 die-id（多 die 芯片上 cluster-id 是否全局唯一没有实测）；
// - 簇按「核类别」归到 perflevel，类别只当不透明字符串比较，不解释 E/M/P 字母的含义（CLAUDE.md）；
// - 档次判定不成立时降级：只显示每簇（clustersOnly）或只显示每核（coresOnly），不猜。

/// 簇键：(die-id, cluster-id)。字符串形式为 `d0c1`，用在 MetricID 里。
public struct ClusterKey: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var die: UInt32
    public var cluster: UInt32

    public init(die: UInt32, cluster: UInt32) {
        self.die = die
        self.cluster = cluster
    }

    /// 解析 `d<die>c<cluster>`。
    public init?(string: String) {
        guard string.first == "d", let c = string.firstIndex(of: "c"),
            let die = UInt32(string[string.index(after: string.startIndex)..<c]),
            let cluster = UInt32(string[string.index(after: c)...])
        else { return nil }
        self.init(die: die, cluster: cluster)
    }

    public var description: String { "d\(die)c\(cluster)" }

    public static func < (lhs: ClusterKey, rhs: ClusterKey) -> Bool {
        (lhs.die, lhs.cluster) < (rhs.die, rhs.cluster)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        let string = try c.decode(String.self)
        guard let key = ClusterKey(string: string) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "不是合法的簇键：\(string)")
        }
        self = key
    }
}

/// 一个簇。
public struct CPUCluster: Hashable, Codable, Sendable {
    public var key: ClusterKey
    /// 簇内的逻辑核编号（与 `host_processor_info` 的下标一致），升序。
    public var cpus: [Int]
    /// 核类别：设备树 `compatible` 的第一个字符串加 `cluster-type`，只用来比较是否相同。
    public var classKey: String
    /// 所属 perflevel；档次判定不成立时为 nil。
    public var perfLevel: Int?

    public init(key: ClusterKey, cpus: [Int], classKey: String, perfLevel: Int?) {
        self.key = key
        self.cpus = cpus
        self.classKey = classKey
        self.perfLevel = perfLevel
    }
}

/// 一个核档（`hw.perflevelN`）。序号越小越快（内核约定）。
public struct PerfLevel: Hashable, Codable, Sendable {
    public var index: Int
    /// `hw.perflevelN.name` 原文，例如 `Super`、`Performance`、`Efficiency`。由 app 本地化。
    public var name: String
    public var cpuCount: Int
    public var clusters: [ClusterKey]

    public init(index: Int, name: String, cpuCount: Int, clusters: [ClusterKey]) {
        self.index = index
        self.name = name
        self.cpuCount = cpuCount
        self.clusters = clusters
    }
}

/// 拓扑的可信程度。
public enum TopologyQuality: Hashable, Codable, Sendable {
    /// 簇和档都可信。
    case ok
    /// 簇可信，档次判定不成立（依据冲突或无法确定）：只按簇显示，不做档汇总。
    case clustersOnly(reason: String)
    /// 核数对不上：只显示每核，不分簇。
    case coresOnly(reason: String)

    public var isOK: Bool { self == .ok }
}

/// 一种「核类别 → perflevel」判定依据的结果（诊断页显示）。
public struct PerfLevelEvidence: Hashable, Codable, Sendable {
    public enum Method: String, Hashable, Codable, Sendable, CaseIterable {
        /// 类别总核数 = `hw.perflevelN.logicalcpu_max`，簇大小 = `cpusperl2`，且匹配唯一。
        case coreCount
        /// DVFS 表顶频率降序对应 perflevel 0..n-1。
        case frequency
        /// 设备树 `l2-cache-size` 降序对应 perflevel 0..n-1（只比大小）。
        case l2Size
    }

    public var method: Method
    /// 类别 → perflevel；这种依据不成立时为 nil。
    public var mapping: [String: Int]?
    /// 依据不成立的原因，或成立时的说明。
    public var detail: String

    public init(method: Method, mapping: [String: Int]?, detail: String) {
        self.method = method
        self.mapping = mapping
        self.detail = detail
    }
}

/// 一台机器的 CPU 拓扑。
public struct CPUTopology: Hashable, Codable, Sendable {
    public var logicalCPUCount: Int
    /// 按簇键升序。`coresOnly` 时为空。
    public var clusters: [CPUCluster]
    /// 按序号升序。档次判定不成立时为空。
    public var perfLevels: [PerfLevel]
    public var quality: TopologyQuality
    public var evidence: [PerfLevelEvidence]

    public init(
        logicalCPUCount: Int, clusters: [CPUCluster], perfLevels: [PerfLevel], quality: TopologyQuality,
        evidence: [PerfLevelEvidence]
    ) {
        self.logicalCPUCount = logicalCPUCount
        self.clusters = clusters
        self.perfLevels = perfLevels
        self.quality = quality
        self.evidence = evidence
    }

    /// 逻辑核 → 簇键。
    public func clusterKey(ofCPU cpu: Int) -> ClusterKey? {
        clusters.first { $0.cpus.contains(cpu) }?.key
    }
}
