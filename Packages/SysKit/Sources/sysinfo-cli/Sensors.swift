// sysinfo-cli sensors（CPU 模块设计 §8）：簇温度、CPU 最高温、簇功耗；--raw 打出档案里每个键的原始值并标出占位值。

import Foundation
import SysCollectors
import SysModel

extension SysInfoCLI {
    static func runSensors(interval: Double, count: Int, raw: Bool, json: Bool) -> Int32 {
        _ = CPUTopologyService.shared.refresh()
        let collector = SensorCollector()
        let result = collector.selfTest()
        for check in result.checks where !check.passed {
            printError("    \(check.severity == .advisory ? "!" : "✗") \(check.name)：\(check.detail)")
        }
        guard result.isUsable else { return 1 }
        if !json {
            let profile = collector.profile.map { "\($0.profile.socID) · \($0.profile.description) · \($0.origin.rawValue)" }
                ?? "无匹配档案（SoC \(collector.socID ?? "?")）"
            print("\(machineLine()) · 档案 \(profile)")
        }
        let encoder = makeEncoder()
        var deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for index in 1...count {
            if index > 1 {
                deadline += UInt64(interval * 1e9)
                sleep(untilUptimeNanos: deadline)
            }
            let wall0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let output = collector.sample(at: .now())
            let wallMs = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - wall0) / 1e6
            let cpuMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1e6
            if json {
                struct Record: Encodable { var index: Int; var samples: [Sample] }
                if let data = try? encoder.encode(Record(index: index, samples: output.samples)) {
                    print(String(decoding: data, as: UTF8.self))
                }
                continue
            }
            func show(_ sample: Sample, unit: String) -> String {
                if let v = sample.value { return String(format: "%.1f %@", v, unit) }
                if case .unavailable(let reason) = sample.quality {
                    switch reason.code {
                    case "sensorPowerGated": return "—（断电）"
                    case "noDedicatedRail": return "不可用（无专用轨）"
                    case "learning": return "学习中"
                    default: return "不可用（\(reason.code)）"
                    }
                }
                return "?"
            }
            var parts: [String] = []
            for s in output.samples {
                if let k = s.id.cpuTemperatureClusterKey { parts.append("\(k) \(show(s, unit: "°C"))") }
            }
            if let max = output.samples.first(where: { $0.id == .cpuTemperatureMax }) { parts.append("最高 \(show(max, unit: "°C"))") }
            var power: [String] = []
            for s in output.samples {
                if let k = s.id.cpuPowerClusterKey { power.append("\(k) \(show(s, unit: "W"))") }
            }
            if let total = output.samples.first(where: { $0.id == .cpuPowerTotal }) { power.append("合计 \(show(total, unit: "W"))") }
            print("#\(index)  温度 \(parts.joined(separator: "  "))  |  功耗 \(power.joined(separator: "  "))"
                + String(format: "  · SMC %.1f ms 墙钟 / %.2f ms CPU", wallMs, cpuMs))
            if raw {
                for reading in collector.latestReadings {
                    let value = reading.raw.map { String(format: "%.3f", $0) } ?? "读取失败"
                    let flag = reading.valid ? "" : "（无效/占位）"
                    print("    \(reading.key) \(reading.role.rawValue) \(reading.cluster?.description ?? "-") \(value)\(flag)")
                }
            }
            fflush(stdout)
        }
        return result.passed ? 0 : 1
    }
}
