// 拓扑判定的单测（CPU 模块设计 §5.2、§9）。
// 真实机型的输入来自 research/probes/cpu-module/skeptic-topo-freq/{m5,m4,m2}_struct.txt（只有核号、簇号、
// 类别名和缓存大小，没有设备唯一标识）；合成输入移植自 topo-freq/assign_sim.c 与 sk_conflict.c。

import Foundation
import SysModel
import Testing
@testable import SysCollectors

private typealias Core = TopologyInputs.DTCore
private typealias Level = TopologyInputs.LevelInfo
private let MB: UInt64 = 1 << 20

/// 按簇生成核：clusters 是 [(die, cluster, 核数, compatible, cluster-type, L2 字节)]，逻辑核号顺序递增。
private func cores(_ clusters: [(UInt32, UInt32, Int, String, String, UInt64?)]) -> [Core] {
    var out: [Core] = []
    for (die, cluster, n, compat, type, l2) in clusters {
        for _ in 0..<n {
            out.append(Core(logicalID: out.count, die: die, cluster: cluster, compatible: compat, clusterType: type, l2Size: l2))
        }
    }
    return out
}

private func inputs(
    _ dt: [Core], _ levels: [Level], tableTop: [ClusterKey: Double]? = nil, ioReportCores: Int? = nil
) -> TopologyInputs {
    TopologyInputs(
        dtCores: dt, levels: levels, logicalCPUMax: dt.count, hostProcessorCount: dt.count,
        ioReportCoreChannelCount: ioReportCores, tableTopByCluster: tableTop)
}

private func key(_ c: UInt32, die: UInt32 = 0) -> ClusterKey { ClusterKey(die: die, cluster: c) }

@Suite struct TopologyResolverTests {
    // MARK: 真实机型

    @Test func m5ProSuperAndPerformance() {
        let dt = cores([
            (0, 0, 6, "apple,sawtooth", "M", 8 * MB), (0, 1, 6, "apple,sawtooth", "M", 8 * MB),
            (0, 2, 6, "apple,everest", "P", 16 * MB),
        ])
        let t = TopologyResolver.resolve(
            inputs(
                dt, [Level(name: "Super", logicalCPUMax: 6, cpusPerL2: 6), Level(name: "Performance", logicalCPUMax: 12, cpusPerL2: 6)],
                tableTop: [key(0): 4380e6, key(1): 4380e6, key(2): 4608e6], ioReportCores: 18))
        #expect(t.quality == .ok)
        #expect(t.perfLevels.map(\.name) == ["Super", "Performance"])
        #expect(t.perfLevels[0].clusters == [key(2)])
        #expect(t.perfLevels[1].clusters == [key(0), key(1)])
        #expect(t.clusters.first { $0.key == key(2) }?.cpus == Array(12...17))
        #expect(t.evidence.allSatisfy { $0.mapping != nil }, "三种依据都应成立且一致")
    }

    @Test func m4ProPerformanceAndEfficiency() {
        let dt = cores([
            (0, 0, 4, "apple,sawtooth", "E", 4 * MB), (0, 1, 5, "apple,everest", "P", 16 * MB),
            (0, 2, 5, "apple,everest", "P", 16 * MB),
        ])
        let t = TopologyResolver.resolve(
            inputs(
                dt, [Level(name: "Performance", logicalCPUMax: 10, cpusPerL2: 5), Level(name: "Efficiency", logicalCPUMax: 4, cpusPerL2: 4)],
                tableTop: [key(0): 2592e6, key(1): 4512e6, key(2): 4512e6]))
        #expect(t.quality == .ok)
        #expect(t.perfLevels[0].clusters == [key(1), key(2)])
        #expect(t.perfLevels[1].clusters == [key(0)])
        #expect(t.clusters.first { $0.key == key(1) }?.cpus == Array(4...8))
    }

    /// M2 Max：设备树里 P 簇的 L2 写 8 MB（sysctl 是 16 MB），只能比大小，仍应成立。
    @Test func m2MaxWithInconsistentL2StillResolves() {
        let dt = cores([
            (0, 0, 4, "apple,blizzard", "E", 4 * MB), (0, 1, 4, "apple,avalanche", "P", 8 * MB),
            (0, 2, 4, "apple,avalanche", "P", 8 * MB),
        ])
        let t = TopologyResolver.resolve(
            inputs(dt, [Level(name: "Performance", logicalCPUMax: 8, cpusPerL2: 4), Level(name: "Efficiency", logicalCPUMax: 4, cpusPerL2: 4)]))
        #expect(t.quality == .ok)
        #expect(t.perfLevels[0].clusters == [key(1), key(2)])
    }

    // MARK: 合成输入

    /// M1 4P+4E：两档核数相等，核数依据不成立，由 L2 和频率决定。
    @Test func m1EqualCountsFallBackToL2AndFrequency() {
        let dt = cores([(0, 0, 4, "apple,icestorm", "E", 4 * MB), (0, 1, 4, "apple,firestorm", "P", 12 * MB)])
        let levels = [Level(name: "Performance", logicalCPUMax: 4, cpusPerL2: 4), Level(name: "Efficiency", logicalCPUMax: 4, cpusPerL2: 4)]
        let t = TopologyResolver.resolve(inputs(dt, levels, tableTop: [key(0): 2064e6, key(1): 3204e6]))
        #expect(t.quality == .ok)
        #expect(t.evidence.first { $0.method == .coreCount }?.mapping == nil)
        #expect(t.perfLevels[0].clusters == [key(1)])
    }

    /// M1 Ultra：两个 die 上 cluster-id 重复，簇键必须带 die-id。
    @Test func m1UltraKeepsDiesApart() {
        let dt = cores([
            (0, 0, 2, "apple,icestorm", "E", 4 * MB), (0, 1, 4, "apple,firestorm", "P", 12 * MB),
            (0, 2, 4, "apple,firestorm", "P", 12 * MB), (1, 0, 2, "apple,icestorm", "E", 4 * MB),
            (1, 1, 4, "apple,firestorm", "P", 12 * MB), (1, 2, 4, "apple,firestorm", "P", 12 * MB),
        ])
        let levels = [Level(name: "Performance", logicalCPUMax: 16, cpusPerL2: 4), Level(name: "Efficiency", logicalCPUMax: 4, cpusPerL2: 2)]
        let t = TopologyResolver.resolve(inputs(dt, levels))
        #expect(t.quality == .ok)
        #expect(t.clusters.count == 6)
        #expect(t.perfLevels[1].clusters == [key(0, die: 0), key(0, die: 1)])
        #expect(t.perfLevels[0].cpuCount == 16)
    }

    @Test func hypotheticalThreeLevelChip() {
        let dt = cores([
            (0, 0, 4, "x,little", "E", 4 * MB), (0, 1, 6, "x,mid", "M", 8 * MB), (0, 2, 2, "x,big", "P", 16 * MB),
        ])
        let levels = [
            Level(name: "Super", logicalCPUMax: 2, cpusPerL2: 2), Level(name: "Performance", logicalCPUMax: 6, cpusPerL2: 6),
            Level(name: "Efficiency", logicalCPUMax: 4, cpusPerL2: 4),
        ]
        let t = TopologyResolver.resolve(inputs(dt, levels))
        #expect(t.quality == .ok)
        #expect(t.perfLevels.map(\.clusters) == [[key(2)], [key(1)], [key(0)]])
    }

    /// 频率和 L2 都与核数依据相反（sk_conflict.c）：必须降级为只按簇，不能静默取第一个。
    @Test func conflictingEvidenceDegradesToClustersOnly() {
        let dt = cores([(0, 0, 4, "a", "E", 16 * MB), (0, 1, 8, "b", "P", 4 * MB)])
        let levels = [Level(name: "Performance", logicalCPUMax: 8, cpusPerL2: 8), Level(name: "Efficiency", logicalCPUMax: 4, cpusPerL2: 4)]
        let t = TopologyResolver.resolve(inputs(dt, levels, tableTop: [key(0): 3500e6, key(1): 2000e6]))
        guard case .clustersOnly(let reason) = t.quality else {
            Issue.record("应降级为 clustersOnly，实际 \(t.quality)")
            return
        }
        #expect(reason.contains("conflict"))
        #expect(t.perfLevels.isEmpty)
        #expect(t.clusters.count == 2 && t.clusters.allSatisfy { $0.perfLevel == nil })
    }

    /// 只有 L2 依据成立，但它给出的每档核数与 sysctl 不符：同样降级。
    @Test func mappingMustMatchSysctlCoreCounts() {
        let dt = cores([(0, 0, 4, "a", "E", 16 * MB), (0, 1, 4, "b", "P", 4 * MB)])
        // 两档都是 4 核，核数依据不成立；L2 说 a 更快。sysctl 的 cpusperl2 与簇大小不符也不影响这一步。
        let levels = [Level(name: "Performance", logicalCPUMax: 4, cpusPerL2: 4), Level(name: "Efficiency", logicalCPUMax: 4, cpusPerL2: 4)]
        let t = TopologyResolver.resolve(inputs(dt, levels))
        #expect(t.quality == .ok, "核数相等时 L2 映射与 sysctl 一致，应成立")
        let lopsided = [Level(name: "Performance", logicalCPUMax: 6, cpusPerL2: 6), Level(name: "Efficiency", logicalCPUMax: 2, cpusPerL2: 2)]
        let bad = TopologyResolver.resolve(TopologyInputs(
            dtCores: dt, levels: lopsided, logicalCPUMax: 8, hostProcessorCount: 8))
        guard case .clustersOnly = bad.quality else {
            Issue.record("每档核数与 sysctl 不符时应降级，实际 \(bad.quality)")
            return
        }
    }

    @Test func undeterminedWhenNoEvidence() {
        // 核数相等、L2 相同、没有频率表：三种依据都不成立。
        let dt = cores([(0, 0, 4, "a", "E", 4 * MB), (0, 1, 4, "b", "P", 4 * MB)])
        let levels = [Level(name: "Performance", logicalCPUMax: 4, cpusPerL2: 4), Level(name: "Efficiency", logicalCPUMax: 4, cpusPerL2: 4)]
        let t = TopologyResolver.resolve(inputs(dt, levels))
        #expect(t.quality == .clustersOnly(reason: "no evidence determines perflevels"))
    }

    @Test func coreCountMismatchDegradesToCoresOnly() {
        let dt = cores([(0, 0, 4, "a", "E", 4 * MB), (0, 1, 4, "b", "P", 12 * MB)])
        let levels = [Level(name: "Performance", logicalCPUMax: 4, cpusPerL2: 4), Level(name: "Efficiency", logicalCPUMax: 4, cpusPerL2: 4)]
        var i = inputs(dt, levels)
        i.hostProcessorCount = 10  // 例如有被屏蔽的核
        let t = TopologyResolver.resolve(i)
        guard case .coresOnly(let reason) = t.quality else {
            Issue.record("核数不等时应降级为 coresOnly，实际 \(t.quality)")
            return
        }
        #expect(reason.contains("host_processor_info=10"))
        #expect(t.clusters.isEmpty && t.logicalCPUCount == 10)

        var j = inputs(dt, levels, ioReportCores: 7)
        j.hostProcessorCount = 8
        guard case .coresOnly = TopologyResolver.resolve(j).quality else {
            Issue.record("IOReport 逐核通道数不等时也应降级")
            return
        }
    }

    @Test func classCountMustEqualPerfLevelCount() {
        let dt = cores([(0, 0, 4, "a", "E", 4 * MB), (0, 1, 4, "b", "P", 12 * MB)])
        let t = TopologyResolver.resolve(inputs(dt, [Level(name: "Performance", logicalCPUMax: 8, cpusPerL2: 4)]))
        guard case .clustersOnly(let reason) = t.quality else {
            Issue.record("类别数与 nperflevels 不等时应降级，实际 \(t.quality)")
            return
        }
        #expect(reason.contains("nperflevels=1"))
    }

    // MARK: 读取辅助

    @Test func deviceTreeHelpers() {
        #expect(TopologyReader.littleEndianInteger(Data([0x02, 0, 0, 0])) == 2)
        #expect(TopologyReader.littleEndianInteger(Data([0, 0, 0, 1])) == 1 << 24)
        #expect(TopologyReader.littleEndianInteger(Data([1, 2, 3])) == nil)
        #expect(TopologyReader.nulSeparatedStrings(Data("apple,everest\0ARM,v8\0".utf8)) == ["apple,everest", "ARM,v8"])
        #expect(TopologyReader.nulSeparatedStrings(Data("P\0".utf8)) == ["P"])
    }

    @Test func clusterKeyStringRoundTrip() {
        #expect(ClusterKey(die: 1, cluster: 12).description == "d1c12")
        #expect(ClusterKey(string: "d1c12") == ClusterKey(die: 1, cluster: 12))
        #expect(ClusterKey(string: "c1") == nil)
        #expect(ClusterKey(string: "d0cX") == nil)
        #expect(MetricID.cpuUsageCluster(key(2)).cpuUsageClusterKey == key(2))
        #expect(MetricID.cpuUsagePerfLevel(1).cpuUsagePerfLevelIndex == 1)
        #expect(MetricID.cpuUsageTotal.cpuUsageClusterKey == nil)
    }
}

