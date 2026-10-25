// 频率发现的单测（CPU 模块设计 §5.4、§9）。
// 通道名、状态数和 perf-domains 记录来自 research/probes/cpu-module/skeptic-topo-freq/{m5,m4,m2}_struct.txt。

import Foundation
import SysModel
import Testing
@testable import SysCollectors

private func states(_ vCount: Int, idleName: String = "IDLE") -> [String] {
    ["DOWN", idleName] + (0..<vCount).map { "V\($0)P\(vCount - 1 - $0)" }
}

private func cluster(_ id: UInt32, _ cpus: ClosedRange<Int>) -> CPUCluster {
    CPUCluster(key: ClusterKey(die: 0, cluster: id), cpus: Array(cpus), classKey: "x", perfLevel: nil)
}

/// 一个 perf-domains 记录（28 字节）。
private func domain(_ key: UInt8, _ name: String) -> Data {
    var bytes = [UInt8](repeating: 0, count: 28)
    bytes[0] = key
    for (i, b) in name.utf8.prefix(16).enumerated() { bytes[12 + i] = b }
    return Data(bytes)
}

/// 一张 -sram 表：每条 (频率, 电压)，小端 u32。
private func table(_ freqs: [UInt32]) -> Data {
    var bytes: [UInt8] = []
    for f in freqs {
        for v in [f, 800] { bytes += [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: v >> $0) } }
    }
    return Data(bytes)
}

@Suite struct FrequencyDiscoveryTests {
    // MARK: 通道映射

    @Test func m5ChannelsMapByStructureNotName() throws {
        let core = (0...5).map { "MCPU0\($0)" } + (0...5).map { "MCPU1\($0)" } + (0...5).map { "PCPU\($0)" }
        let complex = [
            StateChannelDescriptor(name: "PCPU", stateNames: states(20)),
            StateChannelDescriptor(name: "PCPM", stateNames: states(20)),
            StateChannelDescriptor(name: "PCPM_IDLE", stateNames: states(20, idleName: "NON_IDLE")),
            StateChannelDescriptor(name: "MCPU0", stateNames: states(15)),
            StateChannelDescriptor(name: "MCPM0", stateNames: states(15)),
            StateChannelDescriptor(name: "MCPM0_IDLE", stateNames: states(15, idleName: "NON_IDLE")),
            StateChannelDescriptor(name: "MCPU1", stateNames: states(15)),
            StateChannelDescriptor(name: "MCPM1", stateNames: states(15)),
            StateChannelDescriptor(name: "MCPM1_IDLE", stateNames: states(15, idleName: "NON_IDLE")),
        ]
        let map = FrequencyChannelMapper.map(
            coreChannels: core, complexChannels: complex, clusters: [cluster(0, 0...5), cluster(1, 6...11), cluster(2, 12...17)],
            logicalCPUCount: 18)
        let super_ = try map[ClusterKey(die: 0, cluster: 2)]!.get()
        #expect(super_.request == "PCPU" && super_.actual == "PCPM" && super_.rulesAgree)
        let m1 = try map[ClusterKey(die: 0, cluster: 1)]!.get()
        #expect(m1.request == "MCPU1" && m1.actual == "MCPM1" && m1.rulesAgree)
    }

    /// M2/M4：第二个 P 簇的逐核通道 PCPU100…，前缀里最长的是 PCPU1 而不是 PCPU。
    @Test func m4SecondPClusterTakesLongestPrefix() throws {
        let core = (0...3).map { "ECPU0\($0)0" } + (0...4).map { "PCPU0\($0)0" } + (0...4).map { "PCPU1\($0)0" }
        let complex = [
            StateChannelDescriptor(name: "ECPU", stateNames: states(7)),
            StateChannelDescriptor(name: "ECPM", stateNames: states(7)),
            StateChannelDescriptor(name: "ECPM_IDLE", stateNames: states(7, idleName: "NON_IDLE")),
            StateChannelDescriptor(name: "PCPU", stateNames: states(19)),
            StateChannelDescriptor(name: "PCPM", stateNames: states(19)),
            StateChannelDescriptor(name: "PCPM_IDLE", stateNames: states(19, idleName: "NON_IDLE")),
            StateChannelDescriptor(name: "PCPU1", stateNames: states(19)),
            StateChannelDescriptor(name: "PCPM1", stateNames: states(19)),
            StateChannelDescriptor(name: "PCPM1_IDLE", stateNames: states(19, idleName: "NON_IDLE")),
        ]
        let map = FrequencyChannelMapper.map(
            coreChannels: core, complexChannels: complex, clusters: [cluster(0, 0...3), cluster(1, 4...8), cluster(2, 9...13)],
            logicalCPUCount: 14)
        #expect(try map[ClusterKey(die: 0, cluster: 0)]!.get().actual == "ECPM")
        #expect(try map[ClusterKey(die: 0, cluster: 1)]!.get().request == "PCPU")
        let p1 = try map[ClusterKey(die: 0, cluster: 2)]!.get()
        #expect(p1.request == "PCPU1" && p1.actual == "PCPM1")
    }

    @Test func missingActualChannelFallsBackToRequestOnly() throws {
        let map = FrequencyChannelMapper.map(
            coreChannels: ["XCPU0", "XCPU1"], complexChannels: [StateChannelDescriptor(name: "XCPU", stateNames: states(3))],
            clusters: [cluster(0, 0...1)], logicalCPUCount: 2)
        let c = try map[ClusterKey(die: 0, cluster: 0)]!.get()
        #expect(c.request == "XCPU" && c.actual == nil)
    }

    @Test func coreChannelCountMismatchFailsEveryCluster() {
        let map = FrequencyChannelMapper.map(
            coreChannels: ["A0"], complexChannels: [], clusters: [cluster(0, 0...1)], logicalCPUCount: 2)
        #expect(throws: FrequencyChannelMapper.MapError.self) { try map[ClusterKey(die: 0, cluster: 0)]!.get() }
    }

    // MARK: pmgr 表

    @Test func parsesPerfDomainsAndAccClusters() throws {
        let domains = try #require(DVFSTableParser.perfDomains(domain(1, "ECPU") + domain(5, "PCPU") + domain(13, "PCPU1")))
        #expect(domains == ["ECPU": 1, "PCPU": 5, "PCPU1": 13])
        #expect(DVFSTableParser.perfDomains(Data([1, 2, 3])) == nil)
        #expect(DVFSTableParser.accClusters(Data([7, 2, 0, 0, 0, 0, 0, 0])) == [2: 7])
    }

    @Test func detectsUnitByMagnitude() throws {
        // M4/M5 是 kHz，M2 是 Hz。
        let khz = try DVFSTableParser.table(key: 5, data: table([1_260_000, 2_000_000, 4_512_000]), vStateCount: 3).get()
        #expect(khz.unit == "kHz" && khz.top == 4_512_000_000)
        let hz = try DVFSTableParser.table(key: 1, data: table([912_000_000, 2_424_000_000]), vStateCount: 2).get()
        #expect(hz.unit == "Hz" && hz.frequencies == [912e6, 2424e6])
    }

    @Test func rejectsBadTables() {
        // 无后缀表的「常数列」、表长不符、0 档、越界。
        #expect(throws: DVFSTableParser.TableError.notStrictlyIncreasing) {
            try DVFSTableParser.table(key: 5, data: table([52012, 52012, 52012]), vStateCount: 3).get()
        }
        #expect(throws: DVFSTableParser.TableError.lengthMismatch(table: 2, states: 3)) {
            try DVFSTableParser.table(key: 5, data: table([1_000_000, 2_000_000]), vStateCount: 3).get()
        }
        #expect(throws: DVFSTableParser.TableError.zeroEntry) {
            try DVFSTableParser.table(key: 5, data: table([0, 2_000_000]), vStateCount: 2).get()
        }
        #expect(throws: DVFSTableParser.TableError.topOutOfRange(mhz: 300)) {
            try DVFSTableParser.table(key: 5, data: table([100_000, 300_000]), vStateCount: 2).get()
        }
    }

    // MARK: 频率计算

    @Test func vStateIndexParsing() {
        #expect(FrequencyMath.vIndex("V0P18") == 0)
        #expect(FrequencyMath.vIndex("V17P1") == 17)
        #expect(FrequencyMath.vIndex("IDLE") == nil)
        #expect(FrequencyMath.vIndex("DOWN") == nil)
        #expect(FrequencyMath.vIndex("V") == nil)
        #expect(FrequencyMath.vIndex("VX") == nil)
        #expect(FrequencyMath.vStateCount(states(19, idleName: "NON_IDLE")) == 19)
    }

    @Test func weightsFrequencyByActiveResidency() {
        let t = DVFSTable(key: 1, frequencies: [1e9, 2e9, 3e9], unit: "kHz")
        let names = states(3)
        // DOWN 0、IDLE 500、V0 100、V1 0、V2 400：活跃 500，频率 (1×100 + 3×400) / 500 = 2.6 GHz。
        let reading = FrequencyMath.frequency(stateNames: names, residencies: [0, 500, 100, 0, 400], table: t)
        #expect(reading == .active(hz: 2.6e9, activeFraction: 0.5))
    }

    @Test func nearlyInactiveClusterIsIdle() {
        let t = DVFSTable(key: 1, frequencies: [1e9, 2e9], unit: "kHz")
        let reading = FrequencyMath.frequency(stateNames: states(2), residencies: [0, 100_000, 10, 0], table: t)
        guard case .idle = reading else {
            Issue.record("活跃占比 0.01% 应视为空闲，实际 \(reading)")
            return
        }
        #expect(FrequencyMath.frequency(stateNames: states(2), residencies: [0, 0, 0, 0], table: t) == .invalid("no residency"))
    }

    @Test func negativeResidencyIsCounterReset() {
        let t = DVFSTable(key: 1, frequencies: [1e9, 2e9], unit: "kHz")
        // 不能把负值钳成 0 后照常加权（会得出 2 GHz 并标 measured）
        #expect(FrequencyMath.frequency(stateNames: states(2), residencies: [0, 0, -500, 400], table: t) == .counterReset)
    }

    @Test func stateBeyondTableIsInvalid() {
        let t = DVFSTable(key: 1, frequencies: [1e9], unit: "kHz")
        guard case .invalid = FrequencyMath.frequency(stateNames: states(2), residencies: [0, 0, 1, 1], table: t) else {
            Issue.record("V1 超出表长时应为 invalid")
            return
        }
    }

    // MARK: 方案组装

    @Test func planUsesPerfDomainsAndReportsTableTops() {
        let core = (0...3).map { "ECPU0\($0)0" } + (0...3).map { "PCPU0\($0)0" }
        let complex = [
            StateChannelDescriptor(name: "ECPU", stateNames: states(2)), StateChannelDescriptor(name: "ECPM", stateNames: states(2)),
            StateChannelDescriptor(name: "PCPU", stateNames: states(3)), StateChannelDescriptor(name: "PCPM", stateNames: states(3)),
        ]
        let pmgr = PMGRProperties(
            perfDomains: domain(1, "ECPU") + domain(5, "PCPU"), accClusters: nil,
            sramTables: [1: table([1_000_000, 2_000_000]), 5: table([1_000_000, 2_000_000, 4_000_000]), 3: table([7, 7])])
        let plan = FrequencyPlan.build(
            clusters: [cluster(0, 0...3), cluster(1, 4...7)], logicalCPUCount: 8, coreChannels: core,
            complexChannels: complex, pmgr: pmgr)
        #expect(plan.failures.isEmpty)
        #expect(plan.clusters.allSatisfy { $0.problems.isEmpty && $0.tableSource == "perf-domains" })
        #expect(plan.tableTops == [ClusterKey(die: 0, cluster: 0): 2e9, ClusterKey(die: 0, cluster: 1): 4e9])
    }
}
