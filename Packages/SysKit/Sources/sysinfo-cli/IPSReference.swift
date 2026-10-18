// sysinfo-cli ipsref（D80）：测本机最快档的「每秒指令数」参照值，开销测量按它把 app 的总指令折算成最快档等效时间。
//
// 在 userInteractive QoS 的单个线程上连续跑 CPU 面板同类的采集工作（占用、Top N 扫描与组装），让它落在最快档并升到高频；
// 前后读本进程的 rusage_info_v6，最快档指令 ÷ 最快档时间即参照值（满频最快核的每秒指令数）。只占一个核，
// 时长由 --seconds 定（默认 10 s，上限 30 s）。
// --gap-ms 在每轮之间停顿，只作诊断：M4 上一旦有停顿，系统就把线程放到能效核，最快档时间不够，测不出参照值（D80）。
// 输出一行 JSON：{"p0_gips":…,"p0_share":…,"p0_seconds":…,"gap_ms":…}；最快档时间不足 0.5 s 时视为不可信，退出码 1。

import Foundation
import SysCollectors
import SysModel

extension SysInfoCLI {
    static func runIPSReference(seconds: Double, gapMs: Double) -> Int32 {
        guard let sampler = prepareAppSampler() else { return 1 }
        let load = CPULoadCollector()
        guard load.selfTest().isUsable else {
            printError("占用采集器自检未通过")
            return 1
        }
        let builder = TopNBuilder()
        let pid = getpid()
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        func ns(_ ticks: UInt64) -> Double { Double(ticks) * Double(tb.numer) / Double(max(tb.denom, 1)) }

        nonisolated(unsafe) var outcome: (p0Instructions: UInt64, p0Ns: Double, cpuNs: Double)?
        let done = DispatchSemaphore(value: 0)
        let worker = Thread {
            _ = sampler.sample(at: .now())
            _ = load.sample(at: .now())
            guard let r0 = ProcessInfoReader.rusage(of: pid) else { done.signal(); return }
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
            if let r1 = ProcessInfoReader.rusage(of: pid) {
                outcome = (
                    r1.ri_pinstructions - r0.ri_pinstructions,
                    ns((r1.ri_user_ptime + r1.ri_system_ptime) - (r0.ri_user_ptime + r0.ri_system_ptime)),
                    ns((r1.ri_user_time + r1.ri_system_time) - (r0.ri_user_time + r0.ri_system_time)))
            }
            done.signal()
        }
        worker.qualityOfService = .userInteractive
        worker.start()
        done.wait()

        guard let outcome, outcome.cpuNs > 0 else {
            printError("读不到本进程的 rusage")
            return 1
        }
        let share = outcome.p0Ns / outcome.cpuNs
        let gips = outcome.p0Ns > 0 ? Double(outcome.p0Instructions) / outcome.p0Ns : 0
        print(String(format: "{\"p0_gips\":%.3f,\"p0_share\":%.3f,\"p0_seconds\":%.2f,\"gap_ms\":%.0f}", gips, share, outcome.p0Ns / 1e9, gapMs))
        guard outcome.p0Ns >= 0.5e9 else {
            printError(String(format: "最快档时间只有 %.2f s，参照值不可信", outcome.p0Ns / 1e9))
            return 1
        }
        return 0
    }
}
