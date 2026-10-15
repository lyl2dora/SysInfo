// sysinfo-cli power / pmgr（功耗与散热模块设计 §8）：直接用采集器（不经调度器）逐次打印功率、最热点、风扇；
// 以及 PMGR 批次的当前快照，--watch 时等到批次并打印分部件明细与交叉核对。

import Foundation
import SysCollectors
import SysModel

extension SysInfoCLI {
    static func runPower(interval: Double, count: Int, json: Bool) -> Int32 {
        _ = CPUTopologyService.shared.refresh()
        let ledger = PowerLedger()
        let rail = PowerRailCollector(ledger: ledger)
        let sensors = PowerSensorCollector(ledger: ledger)
        let gpu = GPUPowerCollector(ledger: ledger)
        var passed = true
        for collector in [rail, sensors, gpu] as [any Collector] {
            let result = collector.selfTest()
            passed = passed && result.passed
            for check in result.checks where !check.passed || !json {
                let mark = check.passed ? "✓" : check.severity == .advisory ? "!" : "✗"
                printError("    \(mark) \(check.name)：\(check.detail)")
            }
        }
        if !json {
            print("\(machineLine()) · 热点 \(describe(sensors.hotspotSource)) · 风扇 \(sensors.fans.count) 个")
        }
        let encoder = makeEncoder()
        var deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for index in 0...count {
            if index > 0 {
                deadline += UInt64(interval * 1e9)
                sleep(untilUptimeNanos: deadline)
            }
            let now = SampleTime.now()
            let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let collectors: [any Collector] = [rail, sensors, gpu]
            let samples = collectors.flatMap { $0.sample(at: now).samples }
            let cpuMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1e6
            guard index > 0 else { continue }  // 第 0 次只建立 GPU 的差分基线
            if json {
                struct Record: Encodable { var index: Int; var samples: [Sample] }
                if let data = try? encoder.encode(Record(index: index, samples: samples)) {
                    print(String(decoding: data, as: UTF8.self))
                }
                continue
            }
            let byID: [MetricID: Sample] = Dictionary(samples.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            func w(_ id: MetricID) -> String { show(byID[id], format: "%.2f W") }
            var line = "#\(index)  整机 \(w(.powerSystem))  SoC \(w(.powerSoC))  GPU \(w(.powerGPU))  DRAM \(w(.powerDRAM))"
            if let wall = byID[.powerWall] { line += "  墙插≈\(show(wall, format: "%.1f W"))" }
            line += "  热点 \(show(byID[.thermalSoCHotspot], format: "%.1f °C"))"
            for fan in sensors.fans {
                line += "  风扇\(fan.index) \(show(byID[.fanSpeed(fan.index)], format: "%.0f"))/\(show(byID[.fanTarget(fan.index)], format: "%.0f")) rpm"
                if let mode = byID[.fanMode(fan.index)]?.value { line += mode == 0 ? " 自动" : " 强制" }
            }
            if byID[.powerLowPowerMode]?.value == 1 { line += "  低功耗模式" }
            print(line + String(format: "  · %.2f ms CPU", cpuMs))
            if let segment = ledger.telemetrySegments.last, segment.end > now.wallClock.addingTimeInterval(-interval - 0.5) {
                let integrated = segment.integratedWatts.map { String(format: "%.2f W", $0) } ?? "覆盖不足"
                let verdict = segment.isDropped ? "累加器漏记" : segment.deviation.map { String(format: "%+.1f%%", $0 * 100) } ?? "—"
                print(
                    "    遥测：\(Int(segment.countDelta)) 次计数 \(String(format: "%.0f", segment.seconds)) s，均值 \(String(format: "%.2f W", segment.telemetryWatts))，PDTR 积分 \(integrated)，\(verdict)")
            }
            fflush(stdout)
        }
        if !json {
            let readings = sensors.diagnosticReadings.map { "\($0.key)=\($0.value.map { String(format: "%.2f", $0) } ?? "?")" }
            print("原始功率键：\(readings.joined(separator: " "))")
        }
        return passed ? 0 : 1
    }

    static func runPMGR(watch: Bool, timeout: Double) -> Int32 {
        let ledger = PowerLedger()
        let collector = PMGRBatchCollector(ledger: ledger)
        // --watch 时另按后台历史的节奏（10 s）采 DRAM 功率，喂给账本，批次到达时做 PZD1 ÷ PMGR DRAM 核对。
        _ = CPUTopologyService.shared.refresh()
        let sensors = PowerSensorCollector(ledger: ledger)
        if watch { _ = sensors.selfTest() }
        let result = collector.selfTest()
        for check in result.checks {
            printError("    \(check.passed ? "✓" : "✗") \(check.name)：\(check.detail)")
        }
        guard result.isUsable else { return 1 }
        _ = collector.sample(at: .now())
        print("\(machineLine()) · 部件 \(collector.components.joined(separator: " "))")
        guard watch else { return 0 }
        print("等待 PMGR 批次（每 60 s 检查一次，最多 \(Int(timeout)) s；批次每 1800 s 一次，第一次只建立基线）……")
        fflush(stdout)
        let start = Date()
        var batches = 0
        while Date().timeIntervalSince(start) < timeout {
            for _ in 0..<6 {
                _ = sensors.sample(at: .now())
                Thread.sleep(forTimeInterval: 10)
            }
            _ = collector.sample(at: .now())
            if let batch = collector.latestBatch, batch.end > start, batches == 0 || batch.end.timeIntervalSince(start) > 0 {
                batches += 1
                printBatch(batch)
                for check in ledger.checks {
                    print("    核对 \(check.name)：\(check.verdict.rawValue) \(check.ratio.map { String(format: "%.3f", $0) } ?? "")")
                }
                return 0
            }
            fflush(stdout)
        }
        print("超时：没有等到完整批次")
        return 1
    }

    static func printBatch(_ batch: PMGRBatch) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        print("批次 \(f.string(from: batch.start)) → \(f.string(from: batch.end))（\(Int(batch.seconds)) s）")
        for (name, joules) in batch.joules.sorted(by: { $0.value > $1.value }) {
            print(String(format: "    %-10@ %9.1f J  %7.3f W", name as NSString, joules, joules / batch.seconds))
        }
        if let agx = batch.agxJoules {
            print(String(format: "    AGX GPU Energy %9.1f J  %7.3f W", agx, agx / batch.seconds))
        }
    }

    static func describe(_ source: PowerSensorCollector.HotspotSource) -> String {
        switch source {
        case .profile(let key, _): "\(key)（档案）"
        case .learned(let key): "\(key)（学习）"
        case .learning(let n): "学习中（\(n) 次）"
        case .unavailable: "不可用"
        }
    }

    static func show(_ sample: Sample?, format: String) -> String {
        guard let sample else { return "—" }
        if let v = sample.value {
            return String(format: format, v) + (sample.quality == .inferred ? "（推断）" : "")
        }
        if case .unavailable(let reason) = sample.quality { return "不可用(\(reason.code))" }
        return "?"
    }
}

extension SysInfoCLI {
    /// 传感器目录：采样若干次（「恒定」至少要 3 次观察），按分组和质量列出。
    static func runCatalog(samples: Int, json: Bool, all: Bool) -> Int32 {
        _ = CPUTopologyService.shared.refresh()
        let catalog = SensorCatalog()
        let result = catalog.selfTest()
        guard result.isUsable else {
            result.checks.forEach { printError("    ✗ \($0.name)：\($0.detail)") }
            return 1
        }
        let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        _ = catalog.sample(at: .now())
        let firstMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1e6
        var lastMs = 0.0
        for _ in 1..<max(samples, 1) {
            Thread.sleep(forTimeInterval: 1)
            let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            _ = catalog.sample(at: .now())
            lastMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0) / 1e6
        }
        let entries = catalog.entries
        if json {
            struct Row: Encodable { var key: String; var type: String; var value: Double?; var quality: String; var group: String? }
            let rows = entries.map { Row(key: $0.key, type: $0.dataType, value: $0.value, quality: $0.quality.rawValue, group: $0.group) }
            if let data = try? makeEncoder().encode(rows) { print(String(decoding: data, as: UTF8.self)) }
            return 0
        }
        print("\(machineLine()) · \(entries.count) 个数值键 · 首次 \(String(format: "%.1f", firstMs)) ms CPU（含枚举），之后 \(String(format: "%.1f", lastMs)) ms")
        let byQuality = Dictionary(grouping: entries, by: \.quality)
        print("质量：" + SensorCatalogEntry.Quality.allValues.map { "\($0.rawValue) \(byQuality[$0]?.count ?? 0)" }.joined(separator: " · "))
        let byGroup = Dictionary(grouping: entries.filter { $0.group != nil }, by: { $0.group! })
        for (group, rows) in byGroup.sorted(by: { $0.key < $1.key }) {
            let valid = rows.filter { $0.quality == .valid }.compactMap(\.value)
            print("  \(group)：\(rows.count) 个键，有效 \(valid.count)\(valid.max().map { String(format: "，最高 %.1f", $0) } ?? "")")
        }
        if all {
            for e in entries {
                print("    \(e.key) \(e.dataType) \(e.value.map { String(format: "%.3f", $0) } ?? "—") \(e.quality.rawValue) \(e.group ?? "")")
            }
        }
        return 0
    }
}

extension SensorCatalogEntry.Quality {
    static let allValues: [Self] = [.valid, .placeholder, .constant, .nonTemperature, .unreadable]
}
