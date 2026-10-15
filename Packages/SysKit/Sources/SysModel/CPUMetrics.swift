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

    private static let clusterTemperaturePrefix = "cpu.temp.cluster."
    private static let clusterPowerPrefix = "cpu.power.cluster."

    /// 一个簇的温度，°C：簇内已归簇键（代表变体）有效读数的最大值。只给有温度行的簇（D33）。
    public static func cpuTemperatureCluster(_ key: ClusterKey) -> MetricID {
        MetricID(clusterTemperaturePrefix + key.description)
    }

    /// CPU 最高温，°C：所有 P 簇已归簇键的最大值，不含 E 簇附近读数（D33）。
    public static let cpuTemperatureMax: MetricID = "cpu.temp.max"

    /// 一个簇的实时功耗，W：专用功耗轨之和，不含 GPU。没有专用轨时不可用（D29）。
    public static func cpuPowerCluster(_ key: ClusterKey) -> MetricID {
        MetricID(clusterPowerPrefix + key.description)
    }

    /// CPU 总功耗，W：各簇之和；任何一簇不可用时整体不可用，不拿部分和充数。
    public static let cpuPowerTotal: MetricID = "cpu.power.total"

    public var cpuTemperatureClusterKey: ClusterKey? {
        guard rawValue.hasPrefix(Self.clusterTemperaturePrefix) else { return nil }
        return ClusterKey(string: String(rawValue.dropFirst(Self.clusterTemperaturePrefix.count)))
    }

    public var cpuPowerClusterKey: ClusterKey? {
        guard rawValue.hasPrefix(Self.clusterPowerPrefix) else { return nil }
        return ClusterKey(string: String(rawValue.dropFirst(Self.clusterPowerPrefix.count)))
    }

    /// 全体进程的 CPU（resource coalition 槽 24–30 之和），按单核比例。只用于被动核对与诊断。
    public static let appCoalitionCPU: MetricID = "app.coalition.cpu"
    /// 全体进程在 perflevel0 上的 CPU 时间占比，0…1（被动核对拓扑映射用）。
    public static let appCoalitionPerfLevel0Share: MetricID = "app.coalition.perflevel0.share"
    /// 全体进程在 perflevel0 上的平均频率，Hz（Σ pcycles / Σ ptime，被动核对频率用）。
    public static let appCoalitionPerfLevel0Frequency: MetricID = "app.coalition.perflevel0.hz"
    /// 全体进程在 perflevel0 以外的平均频率，Hz（两档芯片上即另一档）。
    public static let appCoalitionOtherLevelFrequency: MetricID = "app.coalition.otherlevels.hz"
}
