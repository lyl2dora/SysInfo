// cpu.load 的用户/系统、每簇、每档汇总（CPU 模块设计 §5.3）：用假读数，不读真实硬件。

import Foundation
import SysModel
import Testing
@testable import SysCollectors

private let time = SampleTime(monotonicNanos: 1, wallClock: .init(timeIntervalSince1970: 0))

/// 4 个核：cpu0–1 为簇 d0c0（perflevel1），cpu2–3 为簇 d0c1（perflevel0）。
private func topology(_ quality: TopologyQuality = .ok, cpus: Int = 4) -> CPUTopology {
    let slow = ClusterKey(die: 0, cluster: 0)
    let fast = ClusterKey(die: 0, cluster: 1)
    let ok = quality.isOK
    return CPUTopology(
        logicalCPUCount: cpus,
        clusters: [
            CPUCluster(key: slow, cpus: [0, 1], classKey: "a/E", perfLevel: ok ? 1 : nil),
            CPUCluster(key: fast, cpus: [2, 3], classKey: "b/P", perfLevel: ok ? 0 : nil),
        ],
        perfLevels: ok
            ? [
                PerfLevel(index: 0, name: "Performance", cpuCount: 2, clusters: [fast]),
                PerfLevel(index: 1, name: "Efficiency", cpuCount: 2, clusters: [slow]),
            ] : [],
        quality: quality, evidence: [])
}

private func usage(_ before: [CoreTicks], _ after: [CoreTicks]) throws -> CPUUsage {
    guard case .usage(let usage) = CPUTickMath.delta(previous: before, current: after) else {
        throw TestFailure()
    }
    return usage
}

private struct TestFailure: Error {}

private func value(_ samples: [Sample], _ id: MetricID) -> Double? {
    samples.first { $0.id == id }?.value
}

@Suite struct CPULoadAggregateTests {
    // 每核 100 tick：cpu0 user 10 + nice 10、cpu1 system 20、cpu2 user 60、cpu3 user 40 + system 40。
    private let before = [CoreTicks](repeating: CoreTicks(user: 0, system: 0, idle: 0, nice: 0), count: 4)
    private let after = [
        CoreTicks(user: 10, system: 0, idle: 80, nice: 10), CoreTicks(user: 0, system: 20, idle: 80, nice: 0),
        CoreTicks(user: 60, system: 0, idle: 40, nice: 0), CoreTicks(user: 40, system: 40, idle: 20, nice: 0),
    ]

    @Test func userSystemClusterAndLevel() throws {
        let samples = CPULoadCollector.aggregateSamples(for: try usage(before, after), topology: topology(), at: time)
        #expect(value(samples, .cpuUsageUser) == 120.0 / 400)  // 20（含 nice 10）+ 0 + 60 + 40
        #expect(value(samples, .cpuUsageSystem) == 60.0 / 400)
        #expect(value(samples, .cpuUsageCluster(ClusterKey(die: 0, cluster: 0))) == 40.0 / 200)
        #expect(value(samples, .cpuUsageCluster(ClusterKey(die: 0, cluster: 1))) == 140.0 / 200)
        #expect(value(samples, .cpuUsagePerfLevel(0)) == 140.0 / 200)
        #expect(value(samples, .cpuUsagePerfLevel(1)) == 40.0 / 200)
        #expect(samples.allSatisfy { $0.quality == .measured })
    }

    @Test func droppedCoreMakesGroupEstimated() throws {
        var regressed = after
        regressed[1] = CoreTicks(user: 0, system: 0, idle: 0, nice: 0)
        let start = before.enumerated().map { i, t in i == 1 ? CoreTicks(user: 0, system: 5, idle: 5, nice: 0) : t }
        let samples = CPULoadCollector.aggregateSamples(for: try usage(start, regressed), topology: topology(), at: time)
        let slow = try #require(samples.first { $0.id == .cpuUsageCluster(ClusterKey(die: 0, cluster: 0)) })
        #expect(slow.quality == .estimated)
        #expect(slow.value == 20.0 / 100)
        #expect(samples.first { $0.id == .cpuUsagePerfLevel(0) }?.quality == .measured)
    }

    @Test func clustersOnlyTopologySkipsLevels() throws {
        let samples = CPULoadCollector.aggregateSamples(
            for: try usage(before, after), topology: topology(.clustersOnly(reason: "test")), at: time)
        #expect(samples.contains { $0.id.cpuUsageClusterKey != nil })
        #expect(!samples.contains { $0.id.cpuUsagePerfLevelIndex != nil })
    }

    @Test func topologyCoreCountMismatchSkipsGroups() throws {
        let samples = CPULoadCollector.aggregateSamples(for: try usage(before, after), topology: topology(cpus: 6), at: time)
        #expect(samples.map(\.id) == [.cpuUsageUser, .cpuUsageSystem])
    }

    @Test func selfTestRefreshesTopologyAsAdvisoryCheck() {
        let ticks = after
        let cpu = CPULoadCollector(
            readTicks: { .success(ticks) }, maxLogicalCPUCount: { 4 },
            topology: { topology(.clustersOnly(reason: "conflict")) },
            refreshTopology: { topology(.clustersOnly(reason: "conflict")) })
        let result = cpu.selfTest()
        let check = result.checks.first { $0.name == "cpu.topology" }
        #expect(check?.passed == false)
        #expect(check?.severity == .advisory)
        #expect(result.isUsable, "拓扑降级只是提示项，不停用 cpu.load")
    }
}
