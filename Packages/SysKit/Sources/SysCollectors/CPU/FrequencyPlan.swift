// 频率采样方案：拓扑 + IOReport 通道 + pmgr DVFS 表 → 每簇用哪个通道、哪张表（CPU 模块设计 §5.4）。
// pmgr 的属性是公开 IOKit 读到的未文档化数据，不涉及私有符号。

import Foundation
import IOKit
import SysModel

/// pmgr 节点里与频率有关的属性。
public struct PMGRProperties: Hashable, Sendable {
    public var perfDomains: Data?
    public var accClusters: Data?
    /// `voltage-states<k>-sram` 的原始数据，键为 k。
    public var sramTables: [Int: Data]

    public init(perfDomains: Data?, accClusters: Data?, sramTables: [Int: Data]) {
        self.perfDomains = perfDomains
        self.accClusters = accClusters
        self.sramTables = sramTables
    }
}

public enum PMGRReader {
    /// 读 pmgr 节点（按名字匹配第一个）。读不到时返回 nil。
    public static func read() -> PMGRProperties? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("pmgr"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
            let props = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return nil }
        var tables: [Int: Data] = [:]
        for (key, value) in props {
            guard key.hasPrefix("voltage-states"), key.hasSuffix("-sram"), let data = value as? Data,
                let k = Int(key.dropFirst("voltage-states".count).dropLast("-sram".count))
            else { continue }
            tables[k] = data
        }
        return PMGRProperties(
            perfDomains: props["perf-domains"] as? Data, accClusters: props["acc-clusters"] as? Data,
            sramTables: tables)
    }
}

/// 一个簇的采样方案。
public struct ClusterFrequencyPlan: Hashable, Sendable {
    public var cluster: ClusterKey
    public var channels: ClusterFrequencyChannels
    /// 校验通过的表；不通过时为 nil，原因见 `problems`。
    public var table: DVFSTable?
    /// 表键号的来源：`perf-domains` 或 `acc-clusters`。
    public var tableSource: String?
    public var problems: [String]
}

/// 全部簇的采样方案。
public struct FrequencyPlan: Hashable, Sendable {
    public var clusters: [ClusterFrequencyPlan]
    /// 整体建不起来的原因（例如 IOReport 不可用）；能建起来时为空。
    public var failures: [String]

    /// 每簇 DVFS 表顶（Hz），供拓扑的频率依据使用（§5.2）。
    public var tableTops: [ClusterKey: Double] {
        Dictionary(uniqueKeysWithValues: clusters.compactMap { plan in plan.table.map { (plan.cluster, $0.top) } })
    }

    /// 由已读到的输入组装方案（纯函数，单测覆盖）。
    public static func build(
        clusters: [CPUCluster], logicalCPUCount: Int, coreChannels: [String],
        complexChannels: [StateChannelDescriptor], pmgr: PMGRProperties?
    ) -> FrequencyPlan {
        let mapped = FrequencyChannelMapper.map(
            coreChannels: coreChannels, complexChannels: complexChannels, clusters: clusters,
            logicalCPUCount: logicalCPUCount)
        let domains = pmgr?.perfDomains.flatMap(DVFSTableParser.perfDomains)
        let acc = pmgr?.accClusters.flatMap(DVFSTableParser.accClusters)
        var plans: [ClusterFrequencyPlan] = []
        var failures: [String] = []
        for cluster in clusters {
            switch mapped[cluster.key] {
            case .none:
                failures.append("\(cluster.key): not mapped")
            case .failure(let error)?:
                failures.append("\(cluster.key): \(error)")
            case .success(let channels)?:
                var problems: [String] = []
                if channels.actual == nil { problems.append("no actual channel; request only") }
                if !channels.rulesAgree { problems.append("actual-channel rules disagree") }
                let states = complexChannels.first { $0.name == channels.request }?.stateNames ?? []
                var key: Int?
                var source: String?
                if let k = domains?[channels.request] {
                    key = k
                    source = "perf-domains"
                } else if let k = acc?[cluster.key.cluster] {
                    key = k
                    source = "acc-clusters"
                }
                var table: DVFSTable?
                if let key {
                    if let data = pmgr?.sramTables[key] {
                        switch DVFSTableParser.table(key: key, data: data, vStateCount: FrequencyMath.vStateCount(states)) {
                        case .success(let t): table = t
                        case .failure(let error): problems.append("table \(key): \(error)")
                        }
                    } else {
                        problems.append("voltage-states\(key)-sram missing")
                    }
                } else {
                    problems.append("no table key for \(channels.request)")
                }
                plans.append(
                    ClusterFrequencyPlan(
                        cluster: cluster.key, channels: channels, table: table, tableSource: source, problems: problems))
            }
        }
        return FrequencyPlan(clusters: plans, failures: failures)
    }

    /// 读硬件组装方案。
    public static func discover(
        clusters: [CPUCluster], logicalCPUCount: Int, hub: IOReportHub = .shared, pmgr: PMGRProperties? = PMGRReader.read()
    ) -> FrequencyPlan {
        guard let infos = hub.channels(inGroup: "CPU Stats") else {
            return FrequencyPlan(clusters: [], failures: ["IOReport unavailable"])
        }
        let core = infos.filter { $0.key.subgroup == FrequencyPlan.coreSubgroup }.map(\.key.name)
        // 枚举结果里没有状态名，从一次样本里取（约 5–9 ms，只在建方案时做一次）。
        guard let states = hub.stateNames(inGroup: "CPU Stats", where: { $0.key.subgroup == FrequencyPlan.complexSubgroup })
        else {
            return FrequencyPlan(clusters: [], failures: ["IOReport sample for state names failed"])
        }
        let complex = infos.filter { $0.key.subgroup == FrequencyPlan.complexSubgroup }
            .map { StateChannelDescriptor(name: $0.key.name, stateNames: states[$0.key] ?? []) }
        return build(
            clusters: clusters, logicalCPUCount: logicalCPUCount, coreChannels: core, complexChannels: complex,
            pmgr: pmgr)
    }

    public static let coreSubgroup = "CPU Core Performance States"
    public static let complexSubgroup = "CPU Complex Performance States"
}
