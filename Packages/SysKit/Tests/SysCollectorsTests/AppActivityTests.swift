// 应用活动与被动核对（CPU 模块设计 §5.7、§5.2、§5.4、§9）。纯函数部分不读硬件；硬件部分默认跳过。

import Darwin
import Foundation
import SysModel
import Testing
@testable import SysCollectors

private func time(_ seconds: Int64) -> SampleTime {
    SampleTime(monotonicNanos: UInt64(seconds) * 1_000_000_000, wallClock: Date(timeIntervalSince1970: Double(seconds)))
}

@Suite struct AppActivityTests {
    @Test func parsesPSTimeFormats() {
        #expect(PSSnapshot.seconds("0:01.23") == 1.23)
        #expect(PSSnapshot.seconds("12:34.50") == 754.5)
        #expect(PSSnapshot.seconds("1:02:03") == 3723)
        #expect(PSSnapshot.seconds("2-01:00:00") == 176_400.0)  // 2 天 + 1 小时
        #expect(PSSnapshot.seconds("x:01") == nil)
        let parsed = PSSnapshot.parse("  1   0:00.10\n 42  1:02.00\nbad line\n")
        #expect(parsed == [1: 0.1, 42: 62])
        // pid 复用造成的回退丢弃
        #expect(PSSnapshot.delta([1: 1, 2: 5], [1: 2, 2: 1, 3: 9], seconds: 2) == [1: 0.5])
    }

    @Test func terminationEligibilityFollowsD31() {
        #expect(ProcessControl.eligibility(uid: 501, pid: 900, ownUID: 501, ownPID: 100) == .allowed)
        #expect(ProcessControl.eligibility(uid: 501, pid: 100, ownUID: 501, ownPID: 100) == .isSelf)
        #expect(ProcessControl.eligibility(uid: 0, pid: 900, ownUID: 501, ownPID: 100) == .root)
        #expect(ProcessControl.eligibility(uid: 502, pid: 900, ownUID: 501, ownPID: 100) == .otherUser)
        #expect(ProcessControl.eligibility(uid: 501, pid: 1, ownUID: 501, ownPID: 100) == .root, "launchd")
        #expect(ProcessControl.eligibility(uid: nil, pid: 900, ownUID: 501, ownPID: 100) == .unknown)
    }

    @Test func refusesToSignalProcessesOfOtherUsers() {
        // launchd（pid 1，root）与自身：必须在发信号之前就被拒绝。
        func refusal(_ pid: pid_t) -> ProcessControl.TerminateError? {
            do {
                try ProcessControl.terminate(pid: pid, force: false)
                return nil
            } catch {
                return error
            }
        }
        #expect(refusal(1) == .notAllowed(.root))
        #expect(refusal(getpid()) == .notAllowed(.isSelf))
    }

    @Test func outermostAppBundle() {
        #expect(
            TopNBuilder.outermostApp(in: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator")
                == "/Applications/Xcode.app")
        #expect(TopNBuilder.outermostApp(in: "/usr/libexec/sysmond") == nil)
        #expect(TopNBuilder.resolveName(path: nil, command: "", pid: 0).name == "kernel_task")
        #expect(TopNBuilder.resolveName(path: "/usr/sbin/cfprefsd", command: "cfprefsd", pid: 7).name == "cfprefsd")
    }

    @Test func summarySamplesReconstructPerLevelFrequency() throws {
        let ns: UInt64 = 2_000_000_000
        let window = AppActivityWindow(
            time: time(10), elapsedNanos: ns,
            coalitions: [
                CoalitionDelta(
                    id: 1, tasks: 1, cpuNanos: 3_000_000_000, perfLevel0Nanos: 1_000_000_000, cycles: 7_000_000_000,
                    perfLevel0Cycles: 4_000_000_000, energyNanojoules: 0, membershipChanged: false, isNew: false)
            ])
        let samples = AppSampler.summarySamples(window, slotsTrusted: true, at: time(10))
        func v(_ id: MetricID) -> Double? { samples.first { $0.id == id }?.value }
        #expect(v(.appCoalitionCPU) == 1.5)
        #expect(v(.appCoalitionPerfLevel0Share) == 1.0 / 3)
        #expect(v(.appCoalitionPerfLevel0Frequency) == 4e9)
        #expect(v(.appCoalitionOtherLevelFrequency) == 1.5e9)
        let untrusted = AppSampler.summarySamples(window, slotsTrusted: false, at: time(10))
        #expect(untrusted.filter { $0.quality.isUnavailable }.count == 3)
    }
}

@Suite struct PassiveValidatorTests {
    /// 两档、各一个簇：d0c1 为 perflevel0（4 核），d0c0 为 perflevel1（4 核）。
    private let topology = CPUTopology(
        logicalCPUCount: 8,
        clusters: [
            CPUCluster(key: ClusterKey(die: 0, cluster: 0), cpus: Array(0...3), classKey: "e", perfLevel: 1),
            CPUCluster(key: ClusterKey(die: 0, cluster: 1), cpus: Array(4...7), classKey: "p", perfLevel: 0),
        ],
        perfLevels: [
            PerfLevel(index: 0, name: "Performance", cpuCount: 4, clusters: [ClusterKey(die: 0, cluster: 1)]),
            PerfLevel(index: 1, name: "Efficiency", cpuCount: 4, clusters: [ClusterKey(die: 0, cluster: 0)]),
        ],
        quality: .ok, evidence: [])

    private func status() -> EngineStatus {
        EngineStatus(
            tickCount: 0, lastTick: nil, nextTick: nil, demands: [], effectiveIntervals: [:], throttle: .normal,
            throttleReasons: [], health: [])
    }

    private func result(_ tick: Int64, _ collector: CollectorID, _ samples: [(MetricID, Double)]) -> TickResult {
        TickResult(
            tick: tick, time: time(tick), collectors: [collector],
            samples: samples.map { Sample(id: $0.0, value: $0.1, time: time(tick)) }, cost: SampleCost(wallNanos: 0, cpuNanos: 0),
            status: status())
    }

    /// 喂一段稳定负载：P 档 75% 忙、E 档 25% 忙，P 簇 3.0 GHz、E 簇 2.0 GHz；coalition 端给出 `kernelP0Hz`。
    private func run(kernelP0Hz: Double) -> [PassiveFinding] {
        let v = PassiveValidator(topology: topology)
        let p = ClusterKey(die: 0, cluster: 1)
        let e = ClusterKey(die: 0, cluster: 0)
        var findings: [PassiveFinding] = []
        for tick in Int64(100)...130 {
            findings += v.ingest(
                result(tick, CPULoadCollector.collectorID, [
                    (.cpuUsagePerfLevel(0), 0.75), (.cpuUsagePerfLevel(1), 0.25), (.cpuUsageCluster(p), 0.75),
                    (.cpuUsageCluster(e), 0.25),
                ]))
            if tick % 5 == 0 {
                findings += v.ingest(
                    result(tick, CPUFrequencyCollector.collectorID, [(.cpuFrequencyCluster(p), 3e9), (.cpuFrequencyCluster(e), 2e9)]))
            }
            if tick % 2 == 0 {
                // 全体进程 4 核：其中 3 核在 perflevel0 上
                findings += v.ingest(
                    result(tick, AppSampler.collectorID, [
                        (.appCoalitionCPU, 4.0), (.appCoalitionPerfLevel0Share, 0.75),
                        (.appCoalitionPerfLevel0Frequency, kernelP0Hz), (.appCoalitionOtherLevelFrequency, 2e9),
                    ]))
            }
        }
        return findings
    }

    @Test func agreesOnAlignedSpans() {
        let findings = run(kernelP0Hz: 3e9)
        // 公共边界每 10 s 一个（tick 100、110、120、130）→ 三个区间
        #expect(findings.filter { $0.check == "cpu.topology.passive" }.count == 3)
        #expect(findings.allSatisfy { $0.passed }, "\(findings)")
        #expect(!findings.contains { $0.check == "cpu.freq.passive.perflevel1" }, "E 档只有 25% 忙，低于 30% 门槛，不核对")
    }

    @Test func flagsRequestChannelLikeOverestimate() {
        // 内核实测 2.8 GHz，IOReport 给 3.0 GHz（+7%，像请求通道）：频率核对应失败，拓扑仍通过。
        let findings = run(kernelP0Hz: 2.8e9)
        #expect(findings.filter { $0.check == "cpu.freq.passive.perflevel0" }.allSatisfy { !$0.passed })
        #expect(findings.filter { $0.check == "cpu.topology.passive" }.allSatisfy { $0.passed })
    }
}

@Suite(.tags(.hardware), .hardwareOnly)
struct AppActivityHardwareTests {
    @Test func appSamplerSelfTestsAndSeesOwnCoalition() throws {
        let sampler = AppSampler()
        let result = sampler.selfTest()
        #expect(result.isUsable, "\(result.checks.filter { !$0.passed })")
        #expect(sampler.sample(at: .now()).samples.isEmpty, "第一次只建立基线")
        let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 300_000_000
        var x: UInt64 = 1
        while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < end { x = x &* 3 &+ 1 }
        #expect(x != 0)
        let output = sampler.sample(at: .now())
        let window = try #require(sampler.latestWindow)
        let mine = try #require(CoalitionReader.coalition(ofPID: getpid()))
        let own = try #require(window.coalitions.first { $0.id == mine })
        #expect(Double(own.cpuNanos) / Double(window.elapsedNanos) > 0.5, "自旋 300 ms 应计入本 coalition")
        #expect(output.samples.first { $0.id == .appCoalitionCPU }?.value ?? 0 > 0.5)

        let rows = TopNBuilder().build(window: window, rows: 5, grouping: .byApp, showPerfLevel0: false, slotsTrusted: true)
        #expect(!rows.isEmpty && rows.count <= 5)
        #expect(rows == rows.sorted { $0.cpu > $1.cpu })
    }

    @Test func sameUIDFallbackListsOwnProcess() {
        let sampler = SameUIDSampler()
        _ = sampler.sample(rows: 50)
        let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 200_000_000
        var x: UInt64 = 1
        while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < end { x = x &* 3 &+ 1 }
        #expect(x != 0)
        let result = sampler.sample(rows: 50)
        #expect(result.rows.contains { $0.representativePID == getpid() })
        #expect(result.hiddenCount > 0, "root 进程读不到")
    }
}
