// 温度与功耗（CPU 模块设计 §5.5、§9）：芯片档案、SensorMath 的口径、校准分析。不读硬件。

import Foundation
import SysModel
import Testing
@testable import SysCollectors

private let time = SampleTime(monotonicNanos: 1, wallClock: .init(timeIntervalSince1970: 0))
private func key(_ c: UInt32) -> ClusterKey { ClusterKey(die: 0, cluster: c) }

/// M4 Pro 型拓扑：d0c0 为 E（perflevel1，4 核），d0c1、d0c2 为 P（perflevel0，各 5 核）。
private func m4Topology() -> CPUTopology {
    CPUTopology(
        logicalCPUCount: 14,
        clusters: [
            CPUCluster(key: key(0), cpus: Array(0...3), classKey: "e", perfLevel: 1),
            CPUCluster(key: key(1), cpus: Array(4...8), classKey: "p", perfLevel: 0),
            CPUCluster(key: key(2), cpus: Array(9...13), classKey: "p", perfLevel: 0),
        ],
        perfLevels: [
            PerfLevel(index: 0, name: "Performance", cpuCount: 10, clusters: [key(1), key(2)]),
            PerfLevel(index: 1, name: "Efficiency", cpuCount: 4, clusters: [key(0)]),
        ],
        quality: .ok, evidence: [])
}

@Suite struct ChipProfileTests {
    @Test func bundledProfilesLoadAndMatchTheirTopology() throws {
        let profiles = ChipProfileStore.bundledProfiles()
        #expect(Set(profiles.map(\.socID)) == ["AppleT6050PMGR", "AppleT6041PMGR"])
        let m4 = try #require(profiles.first { $0.socID == "AppleT6041PMGR" })
        #expect(m4.topology.matches(m4Topology()))
        // D33：E 簇不单列温度行；两个 P 簇共用同一组键（调研 §9.3 的 P0/P1 拆分是假象）。
        #expect(m4.temperature.clusters["d0c0"] == nil)
        #expect(m4.temperature.clusters["d0c1"] == m4.temperature.clusters["d0c2"])
        #expect(m4.temperature.sentinels.contains(40.0))
        #expect(m4.power.clusterRails["d0c1"] == ["RP05", "RP06"])
    }

    @Test func resolveRejectsMismatchedTopology() {
        var other = m4Topology()
        other.perfLevels[0].cpuCount = 12
        #expect(
            ChipProfileStore.resolve(socID: "AppleT6041PMGR", build: "26A434", topology: m4Topology(), useCalibration: false)?
                .origin == .bundled)
        #expect(ChipProfileStore.resolve(socID: "AppleT6041PMGR", build: nil, topology: other, useCalibration: false) == nil)
        #expect(ChipProfileStore.resolve(socID: "AppleT9999PMGR", build: nil, topology: m4Topology(), useCalibration: false) == nil)
    }
}

@Suite struct SensorMathTests {
    private let profile = ChipProfile(
        socID: "test", description: "", verifiedBuilds: [], source: "",
        topology: TopologyExpectation(cpuCountsByLevel: [10, 4], clusterLevels: ["d0c0": 1, "d0c1": 0, "d0c2": 0]),
        temperature: TemperatureProfile(
            clusters: ["d0c1": ["Tp01", "Tp05"], "d0c2": ["Tp01", "Tp05"]], aliasGroups: [], peaks: ["d0c1": ["Tp02"]],
            nearby: ["d0c0": ["Te05"]], excluded: [], sentinels: [40.0, -4.0, 0.0], validRange: [10, 125]),
        power: PowerProfile(clusterRails: ["d0c1": ["RP05", "RP06"], "d0c2": ["RP00"]], gpuRails: ["RP07"], sharedRails: []))

    private func value(_ samples: [Sample], _ id: MetricID) -> Sample? { samples.first { $0.id == id } }

    @Test func powerGatedClustersShowNoReadingInsteadOf40() throws {
        let values = ["Tp01": 40.0, "Tp05": 40.0, "Tp02": 40.0, "Te05": 42.0, "RP05": 0.1, "RP06": 0.0, "RP00": 0.0, "RP07": 0]
        let (samples, readings) = SensorMath.evaluate(profile: profile, values: values, clusters: [key(0), key(1), key(2)], at: time)
        let p0 = try #require(value(samples, .cpuTemperatureCluster(key(1))))
        #expect(p0.quality == .unavailable(.sensorPowerGated()))
        #expect(value(samples, .cpuTemperatureMax)?.quality == .unavailable(.sensorPowerGated()))
        #expect(value(samples, .cpuTemperatureCluster(key(0))) == nil, "E 簇没有温度行（D33）")
        #expect(readings.first { $0.key == "Te05" }?.role == .nearby)
        #expect(readings.first { $0.key == "Tp01" }?.valid == false)
    }

    @Test func clusterTemperatureIsMaxOfValidRepresentatives() throws {
        let values = ["Tp01": 61.5, "Tp05": 64.0, "Tp02": 70.0, "Te05": 50, "RP05": 8.6, "RP06": 0.3, "RP00": 8.4, "RP07": 0]
        let (samples, _) = SensorMath.evaluate(profile: profile, values: values, clusters: [key(0), key(1), key(2)], at: time)
        #expect(value(samples, .cpuTemperatureCluster(key(1)))?.value == 64.0, "峰值变体 Tp02 不计入簇温度")
        #expect(value(samples, .cpuTemperatureMax)?.value == 64.0)
        #expect(value(samples, .cpuPowerCluster(key(1)))?.value == 8.9)
        #expect(value(samples, .cpuPowerCluster(key(0)))?.quality == .unavailable(.noDedicatedRail()))
        #expect(value(samples, .cpuPowerTotal)?.quality.isUnavailable == true, "有簇没有专用轨时不拿部分和充数")
    }

    @Test func missingRailReadingMakesClusterUnavailable() {
        let (samples, _) = SensorMath.evaluate(
            profile: profile, values: ["RP05": 1], clusters: [key(1)], at: time)
        #expect(samples.first { $0.id == .cpuPowerCluster(key(1)) }?.quality.isUnavailable == true)
    }

    @Test func unknownChipIsLearningAndHasNoRails() {
        let samples = SensorMath.unknownChipSamples(clusters: [key(0), key(1)], at: time)
        #expect(samples.first { $0.id == .cpuTemperatureMax }?.quality == .unavailable(.learning("no chip profile")))
        #expect(samples.filter { $0.id.cpuPowerClusterKey != nil }.allSatisfy { $0.quality.isUnavailable })
    }
}

@Suite struct CalibrationAnalysisTests {
    /// 合成录制：M4 型拓扑，按 Calibration.plan 的段顺序；P 两簇来回切换（乒乓），E 簇只在 ui14 段加载。
    private func synthetic() -> CalibrationRecording {
        let topology = m4Topology()
        let phases = Calibration.plan(for: topology)
        let keys = ["Tp01", "Tp00", "Tp02", "Te05", "Tg04", "Tp1j", "RP05", "RP00", "RP02", "PP0b", "RP07", "TPXX"]
        var rows: [CalibrationRecording.Row] = []
        var t = 0.0
        var heat = [0.0, 0.0, 0.0, 0.0]  // P、E、GPU 三路一阶热响应 + 全局缓慢升温
        var i = 0
        for phase in phases {
            for _ in 0..<Int(phase.seconds * 2) {
                let threads = phase.cpuThreads
                let pOn = threads >= 5 ? (threads >= 10 ? 1.0 : 0.5) : 0
                let flip = threads == 5 ? (i / 3 % 2 == 0 ? 1.0 : 0.0) : 0.5  // 乒乓：每 1.5 s 换一次簇
                let uP0 = threads == 5 ? flip : pOn
                let uP1 = threads == 5 ? 1 - flip : pOn
                let uE = threads >= 14 ? 1.0 : 0
                let g = phase.gpu ? 1.0 : 0
                let a = 1 - exp(-0.5 / 3)
                heat[0] += a * (20 * (uP0 + uP1) / 2 - heat[0])
                heat[1] += a * (3 * uE - heat[1])
                heat[2] += a * (25 * g - heat[2])
                heat[3] += 0.02 * ((uP0 + uP1) / 2 + g)
                let pAwake = uP0 + uP1 > 0.2
                let base = 40 + heat[3]
                let tp = pAwake ? base + heat[0] + 0.1 * heat[2] : 40.0  // P 核键：空闲断电读出 40.0
                let te = 45 + heat[3] + heat[1] + 0.4 * heat[0] + 0.3 * heat[2]  // E 附近：被 P 和 GPU 淹没
                let tg = g > 0 || heat[2] > 1 ? 40 + heat[2] + heat[3] : -4.0  // GPU 键：空闲读 -4.0
                let tGpuDomain = g > 0 ? 45 + heat[2] + 0.3 * heat[0] : (pAwake ? 45 + heat[0] : 40.0)  // 随 GPU 唤醒
                let noise = Double((i * 7919) % 13) / 100
                rows.append(
                    .init(
                        t: t, phase: phase.name, utilization: [uE, uP0, uP1], gpuOn: phase.gpu,
                        values: [
                            tp == 40 ? 40 : tp + 6.3 + noise, tp == 40 ? 40 : tp + noise, tp == 40 ? 40 : tp + 7 + noise * 3,
                            te + noise, tg, tGpuDomain, 9 * uP0 + 0.05, 9 * uP1 + 0.05, 0.8 * uE + 0.01, 9.05 * uP1 + 0.04,
                            25 * g + 0.1, 40.0,
                        ]))
                t += 0.5
                i += 1
            }
        }
        return CalibrationRecording(
            socID: "synthetic", osBuild: "test", modelIdentifier: "test", topology: topology,
            clusters: [key(0), key(1), key(2)], keys: keys, rows: rows)
    }

    @Test func attributesSharedPClusterKeysAndDetectsStructure() {
        let result = CalibrationAnalysis.analyze(synthetic(), socID: "synthetic", description: "", build: "test")
        let t = result.profile.temperature
        // 占位值要在 ≥3 个键里各自反复出现才算：40.0 有 4 个键（Tp00/01/02、TPXX），-4.0 只有 Tg04 一个。
        #expect(result.sentinels == [40.0])
        // 两个 P 簇来回切换，分不出归属：键归整组，两个簇的列表相同。
        #expect(t.clusters["d0c1"] == ["Tp01"], "\(t.clusters)")
        #expect(t.clusters["d0c2"] == ["Tp01"])
        #expect(t.aliasGroups.contains(["Tp00", "Tp01"]), "x1 = x0 + 6.3 是别名，代表取均值高的 Tp01")
        #expect(t.peaks["d0c1"] == ["Tp02"], "\(t.peaks)")
        #expect(t.clusters["d0c0"] == nil, "E 簇的键被 P/GPU 淹没，不判入")
        #expect(!(t.clusters.values.joined().contains("Tp1j")), "随 GPU 唤醒的键属于 GPU 供电域")
        let p = result.profile.power
        #expect(p.clusterRails["d0c1"] == ["RP05"])
        #expect(p.clusterRails["d0c2"]?.count == 1, "RP00 与 PP0b 是同一路电的重复测量，只留一个：\(p.clusterRails)")
        #expect(p.clusterRails["d0c0"] == ["RP02"])
        #expect(p.gpuRails == ["RP07"])
    }

    @Test func planStepsFollowClusterSizesFastestFirst() {
        let names = Calibration.plan(for: m4Topology()).map(\.name)
        #expect(names == ["idle", "gpu", "idle", "ui5", "ui10", "ui14", "ui10", "ui5", "idle"])
        let total = Calibration.plan(for: m4Topology()).reduce(0) { $0 + $1.seconds }
        #expect(total <= 60, "D18：校准总时长不超过 60 s")
    }
}
