// sysinfo-cli ipsref（D80、D86）：测本机满频最快核的「每秒指令数」参照值，开销测量按它把 app 的总指令折算成最快核等效时间。
//
// 在 userInteractive QoS 的单个线程上连续跑 CPU 面板同类的采集工作（占用、Top N 扫描与组装），让它落在最快档并升到高频；
// 前后读本进程的 rusage_info_v6，最快档指令 ÷ 最快档时间即该次的每秒指令数。只占一个核。
// D86：负载以内核调用为主，每条指令的耗时随整机后台负载变化，单次测量会被压低。所以连测 --runs 次（默认 3 次、
// 每次 --seconds 5 s），取最大值作参照值（最接近「满频、不受干扰」）；同时输出最佳一次的频率与每周期指令，
// 各次相差超过 5% 或频率低于最快档顶档的 85% 时（内核为主的负载本来就只到顶档的 93–96%）标为受干扰（disturbed）。受干扰只提示，不改退出码。
// --gap-ms 在每轮之间停顿，只作诊断：M4 上一旦有停顿，系统就把线程放到能效核，最快档时间不够，测不出参照值（D80）。
// 输出一行 JSON：{"p0_gips":…,"runs":[…],"spread":…,"p0_ghz":…,"p0_ipc":…,"p0_top_ghz":…,"disturbed":…,
// "p0_share":…,"p0_seconds":…,"gap_ms":…}；最佳一次的最快档时间不足 0.5 s 时视为不可信，退出码 1。

import Foundation
import SysCollectors
import SysModel

extension SysInfoCLI {
    /// 单次测量的原始计数（时间为 mach tick）。
    private struct IPSRun {
        var p0Instructions: UInt64
        var p0Cycles: UInt64
        var p0Ticks: UInt64
        var cpuTicks: UInt64
    }

    static func runIPSReference(seconds: Double, runs: Int, gapMs: Double) -> Int32 {
        guard let sampler = prepareAppSampler() else { return 1 }
        let load = CPULoadCollector()
        guard load.selfTest().isUsable else {
            printError("占用采集器自检未通过")
            return 1
        }
        let builder = TopNBuilder()
        let pid = getpid()

        // 工作线程里只记原始计数，换算放到线程外做。各次连续跑，中间不停顿，保持线程在最快档、高频上。
        nonisolated(unsafe) var results: [IPSRun] = []
        let done = DispatchSemaphore(value: 0)
        let worker = Thread {
            _ = sampler.sample(at: .now())
            _ = load.sample(at: .now())
            for _ in 0..<runs {
                guard let r0 = ProcessInfoReader.rusage(of: pid) else { break }
                let deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + UInt64(seconds * 1e9)
                while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < deadline {
                    _ = load.sample(at: .now())
                    _ = sampler.sample(at: .now())
                    if let window = sampler.latestWindow {
                        _ = builder.build(
                            window: window, rows: 5, grouping: .byApp, showPerfLevel0: showPerfLevel0(sampler),
                            slotsTrusted: sampler.auxiliarySlotsTrusted)
                    }
                    if gapMs > 0 { usleep(UInt32(gapMs * 1000)) }
                }
                guard let r1 = ProcessInfoReader.rusage(of: pid) else { break }
                results.append(
                    IPSRun(
                        p0Instructions: r1.ri_pinstructions - r0.ri_pinstructions,
                        p0Cycles: r1.ri_pcycles - r0.ri_pcycles,
                        p0Ticks: (r1.ri_user_ptime + r1.ri_system_ptime) - (r0.ri_user_ptime + r0.ri_system_ptime),
                        cpuTicks: (r1.ri_user_time + r1.ri_system_time) - (r0.ri_user_time + r0.ri_system_time)))
            }
            done.signal()
        }
        worker.qualityOfService = .userInteractive
        worker.start()
        done.wait()

        guard results.count == runs, results.allSatisfy({ $0.cpuTicks > 0 }) else {
            printError("读不到本进程的 rusage")
            return 1
        }
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        func ns(_ ticks: UInt64) -> Double { Double(ticks) * Double(tb.numer) / Double(max(tb.denom, 1)) }
        func gips(_ r: IPSRun) -> Double { r.p0Ticks > 0 ? Double(r.p0Instructions) / ns(r.p0Ticks) : 0 }

        let rates = results.map(gips)
        let bestIndex = rates.indices.max { rates[$0] < rates[$1] }!
        let best = results[bestIndex]
        let bestRate = rates[bestIndex]
        let p0Ns = ns(best.p0Ticks)
        let share = p0Ns / ns(best.cpuTicks)
        let ghz = p0Ns > 0 ? Double(best.p0Cycles) / p0Ns : 0
        let ipc = best.p0Cycles > 0 ? Double(best.p0Instructions) / Double(best.p0Cycles) : 0
        let spread = bestRate > 0 ? (bestRate - (rates.min() ?? 0)) / bestRate : 0

        // 最快档的顶档频率（DVFS 表顶，运行时发现，D20）。读不到时不做频率判断。
        let topology = CPUTopologyService.shared.refresh()
        let tops = FrequencyPlan.discover(clusters: topology.clusters, logicalCPUCount: topology.logicalCPUCount).tableTops
        let topHz = topology.perfLevels.first.map { level in level.clusters.compactMap { tops[$0] }.max() ?? 0 } ?? 0
        let topGHz = topHz / 1e9
        let slowClock = topGHz > 0 && ghz < topGHz * 0.85
        let disturbed = spread > 0.05 || slowClock

        let runsJSON = rates.map { String(format: "%.3f", $0) }.joined(separator: ",")
        print(
            String(
                format: "{\"p0_gips\":%.3f,\"runs\":[%@],\"spread\":%.3f,\"p0_ghz\":%.3f,\"p0_ipc\":%.2f,\"p0_top_ghz\":%.3f,"
                    + "\"disturbed\":%@,\"p0_share\":%.3f,\"p0_seconds\":%.2f,\"gap_ms\":%.0f}",
                bestRate, runsJSON, spread, ghz, ipc, topGHz, disturbed ? "true" : "false", share, p0Ns / 1e9, gapMs))
        if disturbed {
            var reasons: [String] = []
            if spread > 0.05 { reasons.append(String(format: "各次相差 %.0f%%", spread * 100)) }
            if slowClock { reasons.append(String(format: "最快档频率 %.2f GHz，低于顶档 %.2f GHz 的 85%%", ghz, topGHz)) }
            printError("参照值可能受后台负载干扰：" + reasons.joined(separator: "；"))
        }
        guard p0Ns >= 0.5e9 else {
            printError(String(format: "最快档时间只有 %.2f s，参照值不可信", p0Ns / 1e9))
            return 1
        }
        return 0
    }
}
