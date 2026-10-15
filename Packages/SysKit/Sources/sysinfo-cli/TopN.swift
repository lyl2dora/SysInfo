// sysinfo-cli topn / verify topn / verify passive（CPU 模块设计 §8）。
//
// - topn：Top N（按应用或按进程）；--fallback 走 coalition 不可用时的同 uid 回退，--refresh-all 走手动 setuid ps；
// - verify topn：同一窗口里与 setuid `/bin/ps` 的 TIME 差分对照（按 coalition 汇总）；kernel_task 不在 ps 里，不参与对照；
// - verify passive：经调度器按面板默认间隔采样（占用 1 s、频率 5 s、coalition 2 s），跑拓扑与频率的被动核对；
//   --yes 时在本进程内施加负载，保证有忙碌的时段。

import Foundation
import Synchronization
import SysCollectors
import SysModel

extension SysInfoCLI {
    static func prepareAppSampler() -> AppSampler? {
        _ = CPUTopologyService.shared.refresh()
        let sampler = AppSampler()
        let result = sampler.selfTest()
        for check in result.checks where !check.passed {
            printError("    \(check.severity == .advisory ? "!" : "✗") \(check.name)：\(check.detail)")
        }
        return result.isUsable ? sampler : nil
    }

    static func showPerfLevel0(_ sampler: AppSampler) -> Bool {
        guard let topology = CPUTopologyService.shared.current, topology.quality.isOK else { return false }
        return topology.perfLevels.count == 2 && sampler.auxiliarySlotsTrusted
    }

    static func runTopN(
        interval: Double, count: Int, rows: Int, grouping: TopNGrouping, fallback: Bool, refreshAll: Bool, json: Bool
    ) -> Int32 {
        let encoder = makeEncoder()
        func emit(_ index: Int, _ list: [TopNRow], note: String? = nil) {
            if json {
                struct Record: Encodable { var index: Int; var rows: [TopNRow] }
                if let data = try? encoder.encode(Record(index: index, rows: list)) { print(String(decoding: data, as: UTF8.self)) }
                return
            }
            print("#\(index)" + (note.map { "  \($0)" } ?? ""))
            for row in list {
                let cpu = String(format: "%5.1f%%", row.cpu * 100)
                var line = "  \(cpu)  \(row.name)"
                if row.memberCount > 1 { line += "（等 \(row.memberCount) 个）" }
                if let top = row.topMember, let c = top.cpu { line += "  · \(top.name) \(String(format: "%.1f%%", c * 100))" }
                if let p0 = row.perfLevel0Share { line += String(format: "  [p0 %.0f%%]", p0 * 100) }
                if let w = row.energyWatts { line += String(format: "  %.2f W", w) }
                line += "  \(row.eligibility.isAllowed ? "可结束" : row.eligibility.rawValue)"
                print(line)
            }
            fflush(stdout)
        }
        if !json { print("\(machineLine()) · \(fallback ? "同 uid 回退" : refreshAll ? "setuid ps 刷新全部" : grouping.rawValue) · \(rows) 行") }

        if refreshAll {
            do {
                emit(1, try PSSnapshot.refreshAll(interval: interval, rows: rows))
                return 0
            } catch {
                printError("ps 失败：\(error)")
                return 1
            }
        }
        if fallback {
            let sampler = SameUIDSampler()
            _ = sampler.sample(rows: rows)
            for index in 1...count {
                usleep(UInt32(interval * 1e6))
                let result = sampler.sample(rows: rows)
                emit(index, result.rows, note: "另有 \(result.hiddenCount) 个系统或其他用户进程不可见")
            }
            return 0
        }
        guard let sampler = prepareAppSampler() else { return 1 }
        let builder = TopNBuilder()
        _ = sampler.sample(at: .now())
        var deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var index = 0
        while index < count {
            deadline += UInt64(interval * 1e9)
            sleep(untilUptimeNanos: deadline)
            let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            _ = sampler.sample(at: .now())
            guard let window = sampler.latestWindow else { continue }
            let list = builder.build(
                window: window, rows: rows, grouping: grouping, showPerfLevel0: showPerfLevel0(sampler),
                slotsTrusted: sampler.auxiliarySlotsTrusted)
            let ms = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1e6
            index += 1
            // 第一轮成员的 rusage 只建立基线，副标题从第二轮起才有。
            emit(index, list, note: String(format: "扫描 %d 个 coalition + 组装 %.2f ms CPU", window.coalitions.count, ms))
        }
        return 0
    }

    /// 退出码：前 10 名 coalition 与 ps 的差都 ≤0.5 个百分点（单核 = 100%）时为 0。
    static func runVerifyTopN(seconds: Double) -> Int32 {
        guard let sampler = prepareAppSampler() else { return 1 }
        print("\(machineLine()) · 窗口 \(seconds) s，对照 setuid /bin/ps 的 TIME 差分")
        do {
            // ps 每次要跑几十毫秒，TIME 取样的时刻按运行区间的中点算；AppSampler 的两次扫描紧挨着两次 ps。
            func timedPS() throws(PSSnapshot.PSError) -> (snapshot: [pid_t: Double], at: UInt64) {
                let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                let snapshot = try PSSnapshot.take()
                let t1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                return (snapshot, t0 + (t1 - t0) / 2)
            }
            _ = sampler.sample(at: .now())
            let (a, ta) = try timedPS()
            usleep(UInt32(seconds * 1e6))
            let (b, tb) = try timedPS()
            _ = sampler.sample(at: .now())
            let elapsed = Double(tb - ta) / 1e9
            guard let window = sampler.latestWindow else { return 1 }
            let ps = PSSnapshot.delta(a, b, seconds: elapsed)
            let own = CoalitionReader.coalition(ofPID: getpid())
            var rows: [(name: String, ours: Double, ps: Double)] = []
            for delta in window.coalitions.prefix(40) {
                guard delta.id != own, let pids = CoalitionReader.members(of: delta.id, tasksHint: Int(delta.tasks)),
                    !pids.contains(0)
                else { continue }
                let ours = Double(delta.cpuNanos) / Double(window.elapsedNanos)
                let theirs = pids.reduce(0) { $0 + (ps[$1] ?? 0) }
                let name = TopNBuilder.resolveName(path: pids.first.flatMap(ProcessInfoReader.path(of:)), command: "", pid: pids.first ?? -1).name
                rows.append((name, ours, theirs))
            }
            rows.sort { max($0.ours, $0.ps) > max($1.ours, $1.ps) }
            var worst = 0.0
            for row in rows.prefix(10) {
                let diff = (row.ours - row.ps) * 100
                worst = max(worst, abs(diff))
                print(String(format: "  %6.2f%%  ps %6.2f%%  差 %+5.2f pp  %@", row.ours * 100, row.ps * 100, diff, row.name))
            }
            print(worst <= 0.5 ? "对照通过：前 10 名差 ≤0.5 pp（最大 \(String(format: "%.2f", worst))）" : "对照未通过：最大差 \(String(format: "%.2f", worst)) pp")
            print("（不含 kernel_task 所在的 coalition：pid 0 不在 ps 里；也不含本命令所在的 coalition：ps 子进程会算进去）")
            return worst <= 0.5 ? 0 : 1
        } catch {
            printError("ps 失败：\(error)")
            return 1
        }
    }

    /// 退出码：至少有一次核对，且全部通过时为 0。
    static func runVerifyPassive(seconds: Double, load: Bool) async -> Int32 {
        let topology = CPUTopologyService.shared.refresh()
        guard topology.quality.isOK, let fastest = topology.perfLevels.first else {
            printError("拓扑未判定出核档")
            return 1
        }
        print(machineLine())
        if load {
            print("将在本进程内施加负载：前一半时间 \(fastest.cpuCount) 个 UI 线程，后一半 \(topology.logicalCPUCount) 个 utility 线程，共约 \(Int(seconds)) s。")
        }
        let engine = SamplingEngine(collectors: [CPULoadCollector(), CPUFrequencyCollector(), AppSampler()])
        _ = await engine.runSelfTests()
        let events = await engine.events()
        let validator = PassiveValidator(topology: topology)
        let findings = Mutex([PassiveFinding]())
        let reader = Task {
            for await event in events {
                guard case .tick(let result) = event else { continue }
                let new = validator.ingest(result)
                for f in new { print("  \(f.passed ? "✓" : "✗") \(f.check)（\(f.spanSeconds) s）：\(f.detail)") }
                findings.withLock { $0 += new }
            }
        }
        let tokens = [
            await engine.addDemand(Demand(collectors: [CPULoadCollector.collectorID], interval: 1, source: .cli)),
            await engine.addDemand(Demand(collectors: [CPUFrequencyCollector.collectorID], interval: 5, source: .cli)),
            await engine.addDemand(Demand(collectors: [AppSampler.collectorID], interval: 2, source: .cli)),
        ]
        if load {
            let first = Spinners(count: fastest.cpuCount, qos: .userInteractive)
            try? await Task.sleep(for: .seconds(seconds / 2))
            first.finish()
            let second = Spinners(count: topology.logicalCPUCount, qos: .utility)
            try? await Task.sleep(for: .seconds(seconds / 2))
            second.finish()
        } else {
            try? await Task.sleep(for: .seconds(seconds))
        }
        for token in tokens { await engine.remove(token) }
        try? await Task.sleep(for: .milliseconds(300))
        reader.cancel()
        let all = findings.withLock { $0 }
        if all.isEmpty { print("没有可核对的时段（负载太轻；加 --yes 施加负载）") }
        return !all.isEmpty && all.allSatisfy(\.passed) ? 0 : 1
    }
}
