// CPU 模块的指标标识（CPU 模块设计 §4.2）。命名一旦发布就不改。

extension MetricID {
    /// 整机用户态占用（含 nice），0…1。
    public static let cpuUsageUser: MetricID = "cpu.usage.user"
    /// 整机内核态占用，0…1。
    public static let cpuUsageSystem: MetricID = "cpu.usage.system"

    private static let clusterUsagePrefix = "cpu.usage.cluster."
    private static let perfLevelUsagePrefix = "cpu.usage.perflevel."

    /// 一个簇的平均占用，0…1。例如 `cpu.usage.cluster.d0c1`。
    public static func cpuUsageCluster(_ key: ClusterKey) -> MetricID {
        MetricID(clusterUsagePrefix + key.description)
    }

    /// 一个核档的平均占用，0…1。按序号命名（`cpu.usage.perflevel.0`），快慢语义只看序号。
    public static func cpuUsagePerfLevel(_ index: Int) -> MetricID {
        MetricID("\(perfLevelUsagePrefix)\(index)")
    }

    /// 若是每簇占用，返回簇键。
    public var cpuUsageClusterKey: ClusterKey? {
        guard rawValue.hasPrefix(Self.clusterUsagePrefix) else { return nil }
        return ClusterKey(string: String(rawValue.dropFirst(Self.clusterUsagePrefix.count)))
    }

    /// 若是每档占用，返回档序号。
    public var cpuUsagePerfLevelIndex: Int? {
        guard rawValue.hasPrefix(Self.perfLevelUsagePrefix),
            let index = Int(rawValue.dropFirst(Self.perfLevelUsagePrefix.count)), index >= 0
        else { return nil }
        return index
    }

    private static let clusterFrequencyPrefix = "cpu.freq.cluster."

    /// 一个簇的实际频率，Hz（按活跃驻留加权）。簇空闲时为不可用（clusterIdle）。
    public static func cpuFrequencyCluster(_ key: ClusterKey) -> MetricID {
        MetricID(clusterFrequencyPrefix + key.description)
    }

    /// 若是每簇频率，返回簇键。
    public var cpuFrequencyClusterKey: ClusterKey? {
        guard rawValue.hasPrefix(Self.clusterFrequencyPrefix) else { return nil }
        return ClusterKey(string: String(rawValue.dropFirst(Self.clusterFrequencyPrefix.count)))
    }
}
