// sysinfo-cli gpu / gputop（GPU 模块设计 §8，D57、D58）。
//
// - gpu：直接用采集器（不经调度器）逐次打印 GPU 活跃、频率、功率、温度、ANE 上电与估算功率、媒体引擎活动、GPU 内存；
//   --diag 另打印各档驻留、PWRCTRL、节流驻留、PMP 带宽、ANE 中断与 Device Utilization % 原值；
// - gputop：按 GPU 时间的 Top N（按应用或按进程），附 GPU 与 ANE 能耗。

import Foundation
import SysCollectors
import SysModel

extension SysInfoCLI {
    static func runGPU(interval: Double, count: Int, diagnostics: Bool, json: Bool) -> Int32 {
        _ = CPUTopologyService.shared.refresh()
        let gpu = GPUPowerCollector(ledger: PowerLedger())
        let temperature = GPUTemperatureCollector()
        let accelerators = GPUAcceleratorCollector()
        let media = MediaEngineCollector()
        let details = GPUDiagnosticsCollector()
        let apps = AppSampler()
        var collectors: [any Collector] = [gpu, temperature, accelerators, media, apps]
        if diagnostics { collectors.append(details) }
        for collector in collectors {
            let result = collector.selfTest()
            for check in result.checks where !check.passed || (!json && collector.id != AppSampler.collectorID) {
                let mark = check.passed ? "✓" : check.severity == .advisory ? "!" : "✗"
                printError("    \(mark) \(check.name)：\(check.detail)")
            }
        }
        if !json {
            print(machineLine())
            if let table = gpu.frequencyTable {
                print(
                    "档位表 voltage-states\(table.key)-sram（\(table.fromProfile ? "档案" : "推断")）："
                        + table.frequencies.enumerated().map { "P\($0.offset + 1)=\(Int($0.element / 1e6))" }.joined(separator: " ")
                        + " MHz")
            } else {
                print("档位表：不可用（\(gpu.tableProblem ?? "—")）")
            }
            let keys = temperature.keys
            let source: String =
                switch keys.source {
                case .profile: "档案"
                case .allKeys: "全部 Tg 键（无档案）"
                case .none: "无"
                }
            print("温度键（\(source)）：\(keys.names.joined(separator: " "))")
            let nodes = accelerators.nodes
            print(
                "ANE 节点 \(nodes.ane ?? "—")\(nodes.aneBehindExclave ? "（在 Exclave 后面）" : "") · GPU \(nodes.accelerator ?? "—")"
                    + " · 媒体中断 \(media.diagnostics.devices.joined(separator: " "))")
        }
        let encoder = makeEncoder()
        var deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for index in 0...count {
            if index > 0 {
                deadline += UInt64(interval * 1e9)
                sleep(untilUptimeNanos: deadline)
            }
            let now = SampleTime.now()
            var costs: [CollectorID: Double] = [:]
            var samples: [Sample] = []
            for collector in collectors {
                let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                let output = collector.sample(at: now)
                costs[collector.id] = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1e6
                samples += output.samples
            }
            guard index > 0 else { continue }  // 第 0 次只建立差分基线
            let byID: [MetricID: Sample] = Dictionary(samples.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            if json {
                struct Record: Encodable {
                    var index: Int
                    var samples: [Sample]
                    var costMs: [String: Double]
                }
                let gpuSamples = samples.filter { ![MetricID.appCoalitionCPU].contains($0.id) && !$0.id.rawValue.hasPrefix("app.") }
                let record = Record(
                    index: index, samples: gpuSamples,
                    costMs: Dictionary(uniqueKeysWithValues: costs.map { ($0.key.rawValue, $0.value) }))
                if let data = try? encoder.encode(record) { print(String(decoding: data, as: UTF8.self)) }
                continue
            }
            func percent(_ id: MetricID) -> String {
                guard let sample = byID[id] else { return "—" }
                guard let v = sample.value else { return "—(\(reasonCode(sample)))" }
                return String(format: "%.1f%%", v * 100)
            }
            func mhz(_ id: MetricID) -> String {
                guard let sample = byID[id] else { return "—" }
                guard let v = sample.value else { return "—(\(reasonCode(sample)))" }
                return String(format: "%.0f MHz", v / 1e6) + (sample.quality == .inferred ? "（推断）" : "")
            }
            func mib(_ id: MetricID) -> String { byID[id]?.value.map { String(format: "%.0f MiB", $0 / 1_048_576) } ?? "—" }
            let ane = byID[.anePowered]?.value.map { $0 > 0 ? "开" : "关" } ?? "—"
            let cost = costs.filter { $0.key != AppSampler.collectorID }.values.reduce(0, +)
            print(
                "#\(index)  活跃 \(percent(.gpuActive))  频率 \(mhz(.gpuFrequency))  功率 \(show(byID[.powerGPU], format: "%.2f W"))"
                    + "  温度 \(show(byID[.gpuTemperature], format: "%.1f °C"))"
                    + "  ANE \(ane) \(show(byID[.anePowerEstimated], format: "%.2f W（估算）"))"
                    + "  编码/解码/ProRes \(show(byID[.mediaEncodeRate], format: "%.0f"))/\(show(byID[.mediaDecodeRate], format: "%.0f"))/\(show(byID[.mediaProResRate], format: "%.0f")) 次/秒"
                    + "  GPU 内存 \(mib(.gpuMemoryInUse)) / \(mib(.gpuMemoryAllocated))"
                    + String(format: "  · %.2f ms CPU（不含 coalition 扫描 %.2f ms）", cost, costs[AppSampler.collectorID] ?? 0))
            if diagnostics {
                if let residency = gpu.latestResidency {
                    let states = residency.states.filter { $0.share >= 0.005 }
                        .map { "\($0.name) \(String(format: "%.0f%%", $0.share * 100))" }.joined(separator: " ")
                    print("    各档 \(states)  平均档位 \(residency.averageState.map { String(format: "%.1f", $0) } ?? "—")")
                }
                let r = details.readings
                let pwr = r.powerControl.map { "\($0.name) \(String(format: "%.0f%%", $0.value * 100))" }.joined(separator: " ")
                let bw = r.bandwidth.map { "\($0.name) \(String(format: "%.1f", $0.value / 1e9))" }.joined(separator: " ")
                print(
                    "    PWRCTRL \(pwr.isEmpty ? "—" : pwr)  热限制 \(r.thermalLimited.map { String(format: "%.1f%%", $0 * 100) } ?? "—")"
                        + "  功率区 \(r.powerZoned.map { String(format: "%.1f%%", $0 * 100) } ?? "—")"
                        + "  AF BW（\(r.bandwidthGroup ?? "—")，GB/s）\(bw.isEmpty ? "—" : bw)"
                        + "  ANE 中断 \(r.aneInterruptsMissing ? "缺失" : r.aneInterrupts.map { String(format: "%.0f/s", $0) } ?? "—")"
                        + "  Device Utilization % \(r.deviceUtilization.map { String(format: "%.0f", $0) } ?? "—")（不可靠）")
                let m = media.diagnostics
                let raw = [MetricID.mediaEncodeRate, .mediaDecodeRate, .mediaProResRate].map { id in
                    "\(String(format: "%.0f", m.raw[id] ?? 0))−\(String(format: "%.0f", m.baselines[id] ?? 0))"
                }
                print("    媒体中断原值−底数 编码 \(raw[0])  解码 \(raw[1])  ProRes \(raw[2])")
            }
        }
        return 0
    }

    private static func reasonCode(_ sample: Sample) -> String {
        if case .unavailable(let reason) = sample.quality { return reason.code }
        return "?"
    }

    // MARK: - Top N

    static func runGPUTopN(count: Int, interval: Double, rows: Int, grouping: TopNGrouping, json: Bool) -> Int32 {
        let encoder = makeEncoder()
        guard let sampler = prepareAppSampler() else {
            printError("coalition 不可用：GPU Top N 没有回退（没有按进程的公开 GPU 计数）")
            return 1
        }
        let builder = TopNBuilder()
        _ = sampler.sample(at: .now())
        var deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for index in 1...count {
            deadline += UInt64(interval * 1e9)
            sleep(untilUptimeNanos: deadline)
            let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            _ = sampler.sample(at: .now())
            guard let window = sampler.latestWindow else { return 1 }
            let list = builder.buildGPU(window: window, rows: rows, grouping: grouping)
            let cpuMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1e6
            if json {
                struct Record: Encodable { var index: Int; var rows: [TopNRow] }
                if let data = try? encoder.encode(Record(index: index, rows: list)) { print(String(decoding: data, as: UTF8.self)) }
                continue
            }
            let totalANE = Double(window.totalANEEnergyNanojoules) / 1e9 / (Double(window.elapsedNanos) / 1e9)
            print("#\(index)  全部应用 ANE \(String(format: "%.2f W", totalANE))" + String(format: "  · %.2f ms CPU", cpuMs))
            for row in list {
                var line = String(
                    format: "  GPU %5.1f%%  %6.2f W  ANE %5.2f W  ", min(row.gpuShare ?? 0, 9.99) * 100, row.gpuWatts ?? 0,
                    row.aneWatts ?? 0) + row.name
                if row.memberCount > 1 { line += " ×\(row.memberCount)" }
                line += "  [\(row.eligibility.rawValue)]"
                print(line)
            }
        }
        return 0
    }
}
