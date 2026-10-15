// 拓扑判定（CPU 模块设计 §5.2，边界稿 §7.1）。纯函数，单测覆盖。
//
// 1. 四处核数交叉校验：设备树、`hw.logicalcpu_max`、`host_processor_info`、IOReport 逐核通道。不等时只显示每核。
// 2. 按 (die-id, cluster-id) 分簇；核类别 = `compatible` 首串 + `cluster-type`，只比较是否相同。
// 3. 三种「类别 → perflevel」依据（核数、DVFS 表顶频率、L2 大小）各自只在构成完整一一对应时才算成立；
//    成立的依据两两核对，任何冲突都降级为只显示每簇。参考实现 topo_discover.h「取第一个有结果的」
//    会在冲突时静默给出错误结果（边界稿 §2.1 复核修正），这里不照搬。
// 4. 最终映射还要满足 sysctl 给出的每档核数，否则同样降级。

import SysModel

/// 拓扑判定的输入（全部来自运行时读取）。
public struct TopologyInputs: Hashable, Sendable {
    /// 设备树 `IODeviceTree:/cpus` 下的一个核。
    public struct DTCore: Hashable, Sendable {
        public var logicalID: Int
        public var die: UInt32
        public var cluster: UInt32
        /// `compatible` 的第一个字符串，例如 `apple,everest`。
        public var compatible: String
        /// `cluster-type`，例如 `P`、`E`、`M`。只当不透明字符串使用。
        public var clusterType: String
        /// `l2-cache-size`，字节；缺失时为 nil。M2 上与 sysctl 不一致，只能比大小。
        public var l2Size: UInt64?

        public init(
            logicalID: Int, die: UInt32, cluster: UInt32, compatible: String, clusterType: String, l2Size: UInt64?
        ) {
            self.logicalID = logicalID
            self.die = die
            self.cluster = cluster
            self.compatible = compatible
            self.clusterType = clusterType
            self.l2Size = l2Size
        }

        var classKey: String { "\(compatible)/\(clusterType)" }
        var clusterKey: ClusterKey { ClusterKey(die: die, cluster: cluster) }
    }

    /// `hw.perflevelN.*`。
    public struct LevelInfo: Hashable, Sendable {
        public var name: String
        public var logicalCPUMax: Int
        public var cpusPerL2: Int

        public init(name: String, logicalCPUMax: Int, cpusPerL2: Int) {
            self.name = name
            self.logicalCPUMax = logicalCPUMax
            self.cpusPerL2 = cpusPerL2
        }
    }

    public var dtCores: [DTCore]
    /// 下标即 perflevel 序号，个数即 `hw.nperflevels`。
    public var levels: [LevelInfo]
    public var logicalCPUMax: Int?
    public var hostProcessorCount: Int?
    /// IOReport「CPU Core Performance States」的逐核通道数；拿不到时为 nil，不参与核对。
    public var ioReportCoreChannelCount: Int?
    /// 每簇 DVFS 表顶频率（Hz），由频率发现提供；没有时为 nil，频率依据不参与。
    public var tableTopByCluster: [ClusterKey: Double]?

    public init(
        dtCores: [DTCore], levels: [LevelInfo], logicalCPUMax: Int?, hostProcessorCount: Int?,
        ioReportCoreChannelCount: Int? = nil, tableTopByCluster: [ClusterKey: Double]? = nil
    ) {
        self.dtCores = dtCores
        self.levels = levels
        self.logicalCPUMax = logicalCPUMax
        self.hostProcessorCount = hostProcessorCount
        self.ioReportCoreChannelCount = ioReportCoreChannelCount
        self.tableTopByCluster = tableTopByCluster
    }
}

public enum TopologyResolver {
    public static func resolve(_ inputs: TopologyInputs) -> CPUTopology {
        let cores = inputs.dtCores.sorted { $0.logicalID < $1.logicalID }
        let count = cores.count

        // 1. 核数交叉校验
        var mismatches: [String] = []
        if count == 0 { mismatches.append("DT has no cores") }
        if Set(cores.map(\.logicalID)) != Set(0..<count) { mismatches.append("DT logical-cpu-id not 0..<\(count)") }
        if inputs.logicalCPUMax != count { mismatches.append("hw.logicalcpu_max=\(inputs.logicalCPUMax.map(String.init) ?? "?")") }
        if inputs.hostProcessorCount != count {
            mismatches.append("host_processor_info=\(inputs.hostProcessorCount.map(String.init) ?? "?")")
        }
        if let channels = inputs.ioReportCoreChannelCount, channels != count {
            mismatches.append("IOReport core channels=\(channels)")
        }
        guard mismatches.isEmpty else {
            return CPUTopology(
                logicalCPUCount: inputs.hostProcessorCount ?? count, clusters: [], perfLevels: [],
                quality: .coresOnly(reason: "DT=\(count); " + mismatches.joined(separator: "; ")), evidence: [])
        }

        // 2. 分簇
        var byCluster: [ClusterKey: [TopologyInputs.DTCore]] = [:]
        for core in cores { byCluster[core.clusterKey, default: []].append(core) }
        var clusters = byCluster.keys.sorted().map { key -> CPUCluster in
            let members = byCluster[key]!
            return CPUCluster(
                key: key, cpus: members.map(\.logicalID).sorted(), classKey: members[0].classKey, perfLevel: nil)
        }
        func clustersOnly(_ reason: String, _ evidence: [PerfLevelEvidence]) -> CPUTopology {
            CPUTopology(
                logicalCPUCount: count, clusters: clusters, perfLevels: [], quality: .clustersOnly(reason: reason),
                evidence: evidence)
        }
        let mixed = byCluster.filter { Set($0.value.map(\.classKey)).count > 1 }.keys.sorted()
        if !mixed.isEmpty {
            return clustersOnly("mixed core classes in cluster \(mixed.map(\.description).joined(separator: ","))", [])
        }

        // 3. 三种依据
        let classes = Array(Set(clusters.map(\.classKey))).sorted()
        guard !inputs.levels.isEmpty, classes.count == inputs.levels.count else {
            return clustersOnly("\(classes.count) core classes vs nperflevels=\(inputs.levels.count)", [])
        }
        let evidence = [
            byCoreCount(classes: classes, clusters: clusters, levels: inputs.levels),
            byFrequency(classes: classes, clusters: clusters, tableTop: inputs.tableTopByCluster),
            byL2Size(classes: classes, cores: cores),
        ]
        let valid = evidence.compactMap { e in e.mapping.map { (e.method, $0) } }
        guard let (_, mapping) = valid.first else {
            return clustersOnly("no evidence determines perflevels", evidence)
        }
        for (method, other) in valid.dropFirst() where other != mapping {
            return clustersOnly("evidence conflict: \(valid[0].0.rawValue) vs \(method.rawValue)", evidence)
        }

        // 4. 最终映射核对 sysctl 的每档核数
        for (index, level) in inputs.levels.enumerated() {
            let total = clusters.filter { mapping[$0.classKey] == index }.reduce(0) { $0 + $1.cpus.count }
            if total != level.logicalCPUMax {
                return clustersOnly(
                    "perflevel\(index) has \(total) cores by mapping, sysctl says \(level.logicalCPUMax)", evidence)
            }
        }

        for i in clusters.indices { clusters[i].perfLevel = mapping[clusters[i].classKey] }
        let perfLevels = inputs.levels.enumerated().map { index, level in
            PerfLevel(
                index: index, name: level.name, cpuCount: level.logicalCPUMax,
                clusters: clusters.filter { $0.perfLevel == index }.map(\.key))
        }
        return CPUTopology(
            logicalCPUCount: count, clusters: clusters, perfLevels: perfLevels, quality: .ok, evidence: evidence)
    }

    // MARK: - 依据

    /// 核数：每档恰好匹配一个类别（类别总核数相等、每簇大小等于 cpusperl2），且一一对应。
    static func byCoreCount(classes: [String], clusters: [CPUCluster], levels: [TopologyInputs.LevelInfo])
        -> PerfLevelEvidence
    {
        var mapping: [String: Int] = [:]
        for (index, level) in levels.enumerated() {
            let candidates = classes.filter { cls in
                let members = clusters.filter { $0.classKey == cls }
                return members.reduce(0) { $0 + $1.cpus.count } == level.logicalCPUMax
                    && members.allSatisfy { $0.cpus.count == level.cpusPerL2 }
            }
            guard candidates.count == 1 else {
                return PerfLevelEvidence(
                    method: .coreCount, mapping: nil,
                    detail: "perflevel\(index) (\(level.logicalCPUMax)×, \(level.cpusPerL2)/L2) matches \(candidates.count) classes")
            }
            mapping[candidates[0]] = index
        }
        guard mapping.count == classes.count else {
            return PerfLevelEvidence(method: .coreCount, mapping: nil, detail: "not one-to-one")
        }
        return PerfLevelEvidence(method: .coreCount, mapping: mapping, detail: "unique match")
    }

    /// DVFS 表顶频率：类别的表顶取其各簇的最大值，互不相同时降序对应 perflevel。
    static func byFrequency(classes: [String], clusters: [CPUCluster], tableTop: [ClusterKey: Double]?)
        -> PerfLevelEvidence
    {
        guard let tableTop else {
            return PerfLevelEvidence(method: .frequency, mapping: nil, detail: "no DVFS tables")
        }
        var top: [String: Double] = [:]
        for cluster in clusters {
            guard let value = tableTop[cluster.key], value > 0 else {
                return PerfLevelEvidence(method: .frequency, mapping: nil, detail: "no table for \(cluster.key)")
            }
            top[cluster.classKey] = max(top[cluster.classKey] ?? 0, value)
        }
        return descendingMapping(.frequency, top, unit: 1e6, unitName: "MHz")
    }

    /// L2 大小：类别内一致且各类别互不相同时，降序对应 perflevel。
    static func byL2Size(classes: [String], cores: [TopologyInputs.DTCore]) -> PerfLevelEvidence {
        var size: [String: Double] = [:]
        for cls in classes {
            let values = Set(cores.filter { $0.classKey == cls }.map(\.l2Size))
            guard values.count == 1, let value = values.first!, value > 0 else {
                return PerfLevelEvidence(method: .l2Size, mapping: nil, detail: "l2-cache-size missing or mixed in \(cls)")
            }
            size[cls] = Double(value)
        }
        return descendingMapping(.l2Size, size, unit: 1_048_576, unitName: "MB")
    }

    private static func descendingMapping(
        _ method: PerfLevelEvidence.Method, _ values: [String: Double], unit: Double, unitName: String
    ) -> PerfLevelEvidence {
        let sorted = values.sorted { ($0.value, $0.key) > ($1.value, $1.key) }
        let detail = sorted.map { "\($0.key)=\(Int(($0.value / unit).rounded()))\(unitName)" }.joined(separator: ", ")
        guard Set(values.values).count == values.count else {
            return PerfLevelEvidence(method: method, mapping: nil, detail: "tie: " + detail)
        }
        var mapping: [String: Int] = [:]
        for (index, entry) in sorted.enumerated() { mapping[entry.key] = index }
        return PerfLevelEvidence(method: method, mapping: mapping, detail: detail)
    }
}
