// sysinfo-cli freq / verify freq（CPU 模块设计 §8）。
//
// - freq：逐次打印每簇的实际频率和请求频率（请求频率只用于对照，产品里只进诊断页）；
// - verify freq：分段施加负载（总计约 17 s，需要 --yes），按档对照 IOReport 实际通道与内核按档计数
//   （本进程工作线程的 PROC_PIDTHREADCOUNTS：cycles / CPU 时间），移植自 skeptic-topo-freq/sk_verify.c。

import Foundation
import Synchronization
import SysCollectors
import SysModel

extension SysInfoCLI {
    struct FreqRecord: Encodable {
        struct Cluster: Encodable {
            var cluster: String
            var perfLevel: Int?
            /// 实际频率，Hz；空闲或不可用时为 null。
            var actualHz: Double?
            var requestHz: Double?
            /// active / idle / invalid / missing
            var actualState: String
            var activeFraction: Double?
            var source: String
        }

        var index: Int
        var time: Date
        var intervalSeconds: Double
        var clusters: [Cluster]
    }

    static func prepareFrequency() -> (CPUFrequencyCollector, CPUTopology)? {
        let topology = CPUTopologyService.shared.refresh()
        let collector = CPUFrequencyCollector()
        let result = collector.selfTest()
        for check in result.checks where !check.passed {
            printError("    \(check.severity == .advisory ? "!" : "✗") \(check.name)：\(check.detail)")
        }
        guard result.isUsable else {
            printError("cpu.freq 自检的必需项未通过")
            return nil
        }
        return (collector, topology)
    }

    static func runFreq(interval: Double, count: Int, json: Bool) -> Int32 {
        guard let (collector, topology) = prepareFrequency() else { return 1 }
        if !json { print("\(machineLine()) · 间隔 \(interval) s · \(count) 次") }
        let encoder = makeEncoder()
        _ = collector.sample(at: .now())
        var deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for index in 1...count {
            deadline += UInt64(interval * 1e9)
            sleep(untilUptimeNanos: deadline)
            let time = SampleTime.now()
            let cpuBefore = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            _ = collector.sample(at: time)
            let sampleCPUMillis = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuBefore) / 1e6
            let record = FreqRecord(
                index: index, time: time.wallClock, intervalSeconds: interval,
                clusters: collector.latestDetails.map { freqCluster($0, topology) })
            if json {
                if let data = try? encoder.encode(record) { print(String(decoding: data, as: UTF8.self)) }
            } else {
                let parts = record.clusters.map { c in
                    let level = c.perfLevel.map { "档\($0)" } ?? "?"
                    let actual = c.actualHz.map { "\(Int($0 / 1e6)) MHz" } ?? (c.actualState == "idle" ? "空闲" : c.actualState)
                    let request = c.requestHz.map { "\(Int($0 / 1e6))" } ?? "—"
                    return "\(c.cluster)(\(level)) \(actual)［请求 \(request)］"
                }
                print("#\(index)  " + parts.joined(separator: "  ") + "  · 采样 \((sampleCPUMillis * 100).rounded() / 100) ms CPU")
            }
            fflush(stdout)
        }
        return 0
    }

    static func freqCluster(_ detail: ClusterFrequencyDetail, _ topology: CPUTopology) -> FreqRecord.Cluster {
        func split(_ reading: ClusterFrequencyReading?) -> (Double?, String, Double?) {
            switch reading {
            case .active(let hz, let fraction)?: (hz, "active", fraction)
            case .idle(let fraction)?: (nil, "idle", fraction)
            case .invalid(let why)?: (nil, "invalid:\(why)", nil)
            case nil: (nil, "missing", nil)
            }
        }
        let actual = split(detail.actual)
        let request = split(detail.request)
        return FreqRecord.Cluster(
            cluster: detail.cluster.description,
            perfLevel: topology.clusters.first { $0.key == detail.cluster }?.perfLevel,
            actualHz: actual.0, requestHz: request.0, actualState: actual.1, activeFraction: actual.2,
            source: detail.source.rawValue)
    }

    // MARK: - verify freq

    /// 本进程内的自旋线程组，只结束自己创建的线程。
    final class Spinners: Sendable {
        let stop = Atomic<Bool>(false)
        let threadIDs = Mutex<[UInt64]>([])

        init(count: Int, qos: QualityOfService) {
            for _ in 0..<count {
                let thread = Thread { [self] in
                    var tid: UInt64 = 0
                    pthread_threadid_np(nil, &tid)
                    threadIDs.withLock { $0.append(tid) }
                    var x: UInt64 = 1
                    while !stop.load(ordering: .relaxed) {
                        for _ in 0..<20_000 { x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
                    }
                    if x == 42 { print(x) }
                }
                thread.qualityOfService = qos
                thread.start()
            }
        }

        func finish() {
            stop.store(true, ordering: .relaxed)
        }

        /// 各工作线程按 perflevel 的计数之和。
        func counts(levels: Int) -> [ProcessPrivateInfo.LevelCounts] {
            var sum = [ProcessPrivateInfo.LevelCounts](
                repeating: .init(instructions: 0, cycles: 0, userTimeTicks: 0, systemTimeTicks: 0, energyNanojoules: 0),
                count: levels)
            for tid in threadIDs.withLock({ $0 }) {
                guard let c = ProcessPrivateInfo.threadCounts(threadID: tid, maxLevels: levels) else { continue }
                for (i, level) in c.enumerated() where i < levels {
                    sum[i].cycles += level.cycles
                    sum[i].userTimeTicks += level.userTimeTicks
                    sum[i].systemTimeTicks += level.systemTimeTicks
                }
            }
            return sum
        }
    }

    struct VerifyPhase {
        var name: String
        var threads: Int
        var qos: QualityOfService
    }

    /// 退出码：每个档在内核时间占比 >10% 的阶段里，实际通道误差都 ≤1% 时为 0。
    static func runVerifyFreq(confirmed: Bool) -> Int32 {
        guard let (collector, topology) = prepareFrequency() else { return 1 }
        guard topology.quality.isOK, let fastest = topology.perfLevels.first, let slowest = topology.perfLevels.last else {
            printError("拓扑未判定出核档，无法按档对照")
            return 1
        }
        let phases = [
            VerifyPhase(name: "idle", threads: 0, qos: .default),
            VerifyPhase(name: "1×UI", threads: 1, qos: .userInteractive),
            VerifyPhase(name: "perflevel0 ×UI", threads: fastest.cpuCount, qos: .userInteractive),
            VerifyPhase(name: "all ×UTILITY", threads: topology.logicalCPUCount, qos: .utility),
            VerifyPhase(name: "slowest level ×BACKGROUND", threads: slowest.cpuCount, qos: .background),
        ]
        let window = 3.0
        let loadSeconds = Double(phases.filter { $0.threads > 0 }.count) * (window + 0.5)
        print(machineLine())
        print("将分 \(phases.count) 段施加 CPU 负载，共约 \(Int(loadSeconds)) s（每段 ≤\(Int(window + 0.5)) s，只在本进程内），段间空闲 1 s。")
        guard confirmed else {
            printError("确认后加 --yes 运行")
            return 64
        }
        guard let nanosPerTick = nanosecondsPerMachTick() else { return 1 }
        var allPassed = true
        for phase in phases {
            let spinners = Spinners(count: phase.threads, qos: phase.qos)
            usleep(500_000)  // 线程起来、频率爬升
            _ = collector.sample(at: .now())
            let before = spinners.counts(levels: topology.perfLevels.count)
            usleep(UInt32(window * 1e6))
            let after = spinners.counts(levels: topology.perfLevels.count)
            _ = collector.sample(at: .now())
            spinners.finish()
            let details = collector.latestDetails

            print("== \(phase.name)：\(phase.threads) 个线程，窗口 \(window) s")
            let totalTicks = zip(after, before).reduce(UInt64(0)) {
                $0 + ($1.0.userTimeTicks + $1.0.systemTimeTicks) - ($1.1.userTimeTicks + $1.1.systemTimeTicks)
            }
            for level in topology.perfLevels {
                let i = level.index
                let ticks = (after[i].userTimeTicks + after[i].systemTimeTicks) - (before[i].userTimeTicks + before[i].systemTimeTicks)
                let cycles = after[i].cycles - before[i].cycles
                let share = totalTicks > 0 ? Double(ticks) / Double(totalTicks) : 0
                let kernelHz = ticks > 0 ? Double(cycles) / (Double(ticks) * nanosPerTick) * 1e9 : 0
                let ours = levelFrequency(details, level: level, topology: topology)
                func err(_ hz: Double?) -> String {
                    guard let hz, kernelHz > 0 else { return "—" }
                    let e = (hz / kernelHz - 1) * 100
                    return "\(Int(hz / 1e6)) MHz (\(e >= 0 ? "+" : "")\((e * 100).rounded() / 100)%)"
                }
                var verdict = ""
                if share > 0.1, kernelHz > 0 {
                    if let hz = ours.actual, abs(hz / kernelHz - 1) <= 0.01 {
                        verdict = "✓"
                    } else {
                        verdict = "✗"
                        allPassed = false
                    }
                }
                print(
                    "  perflevel\(i) \(level.name)：内核 \(Int((share * 1000).rounded()) / 10)% 时间 @ \(Int(kernelHz / 1e6)) MHz"
                        + " | 实际通道 \(err(ours.actual)) | 请求通道 \(err(ours.request)) \(verdict)")
            }
            usleep(1_000_000)
        }
        print(allPassed ? "对照通过：各档实际通道误差 ≤1%" : "对照未通过")
        return allPassed ? 0 : 1
    }

    /// 档内各簇频率按「活跃驻留 × 核数」加权（与 sk_verify.c 同口径）。
    static func levelFrequency(_ details: [ClusterFrequencyDetail], level: PerfLevel, topology: CPUTopology)
        -> (actual: Double?, request: Double?)
    {
        func combine(_ pick: (ClusterFrequencyDetail) -> ClusterFrequencyReading?) -> Double? {
            var weighted = 0.0
            var weight = 0.0
            for detail in details where level.clusters.contains(detail.cluster) {
                guard case .active(let hz, let fraction)? = pick(detail) else { continue }
                let cores = Double(topology.clusters.first { $0.key == detail.cluster }?.cpus.count ?? 1)
                weighted += hz * fraction * cores
                weight += fraction * cores
            }
            return weight > 0 ? weighted / weight : nil
        }
        return (combine { $0.actual }, combine { $0.request })
    }

    /// mach tick → 纳秒的换算系数（运行时读取，不写死 125/3）。
    static func nanosecondsPerMachTick() -> Double? {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return nil }
        return Double(info.numer) / Double(info.denom)
    }
}
