// sysinfo-cli memory / memtop / verify memory / verify memtop（内存模块设计 §8）。
//
// - memory：直接用采集器（不经调度器）逐次打印总量、构成、压力、Swap 与速率；--bandwidth 同时打印 DRAM 带宽估算；
// - memtop：按内存的 Top N（按应用或按进程）；--fallback 走 coalition 不可用时的同 uid 回退；
// - verify memory：与 `vm_stat`、`memory_pressure -Q` 各运行一次的输出对照（只在手动运行时 spawn，CLAUDE.md）；
// - verify memtop：与 setuid `top -l 1 -o mem` 运行一次的 MEM 列对照（同一 pid）。

import Foundation
import SysCollectors
import SysModel

extension SysInfoCLI {
    static func runMemory(interval: Double, count: Int, bandwidth: Bool, json: Bool) -> Int32 {
        let memory = MemoryCollector()
        let dram = DRAMBandwidthCollector()
        var collectors: [any Collector] = [memory]
        if bandwidth { collectors.append(dram) }
        for collector in collectors {
            let result = collector.selfTest()
            for check in result.checks where !check.passed || !json {
                let mark = check.passed ? "✓" : check.severity == .advisory ? "!" : "✗"
                printError("    \(mark) \(check.name)：\(check.detail)")
            }
        }
        if !json { print("\(machineLine()) · 数据路径 \(memory.usesVMStatistics ? MemoryCollector.dataPath : MemoryCollector.fallbackDataPath)") }
        let encoder = makeEncoder()
        var deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for index in 0...count {
            if index > 0 {
                deadline += UInt64(interval * 1e9)
                sleep(untilUptimeNanos: deadline)
            }
            let now = SampleTime.now()
            let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let outputs = collectors.map { $0.sample(at: now) }
            let cpuMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1e6
            guard index > 0 else { continue }  // 第 0 次只建立速率与带宽的基线
            let samples = outputs.flatMap(\.samples)
            if json {
                struct Record: Encodable { var index: Int; var samples: [Sample] }
                if let data = try? encoder.encode(Record(index: index, samples: samples)) {
                    print(String(decoding: data, as: UTF8.self))
                }
                continue
            }
            let byID: [MetricID: Sample] = Dictionary(samples.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            func gib(_ id: MetricID) -> String {
                guard let sample = byID[id] else { return "—" }
                guard let v = sample.value else { return "—(\(sample.quality))" }
                return String(format: "%.2f GiB", v / 1_073_741_824) + (sample.quality == .estimated ? "（估算）" : "")
            }
            func rate(_ id: MetricID) -> String { show(byID[id], format: "%.0f") }
            let level = MemoryPressureLevel(sampleValue: byID[.memoryPressureLevel]?.value).map { "\($0)" } ?? "—"
            print(
                "#\(index)  已用 \(gib(.memoryUsed))（\(show(byID[.memoryUsage].map(percentSample), format: "%.1f%%"))）"
                    + "  App \(gib(.memoryApp))  联动 \(gib(.memoryWired))  压缩 \(gib(.memoryCompressed))"
                    + "  缓存 \(gib(.memoryCached))  空闲 \(gib(.memoryFree))")
            print(
                "    压力 \(level) \(show(byID[.memoryPressure].map(percentSample), format: "%.0f%%"))"
                    + "  Swap \(gib(.memorySwapUsed)) / \(gib(.memorySwapTotal))"
                    + "  压缩比 \(show(byID[.memoryCompressionRatio], format: "%.2f"))"
                    + "  页入/出 \(rate(.memoryPageInRate))/\(rate(.memoryPageOutRate))"
                    + "  换入/出 \(rate(.memorySwapInRate))/\(rate(.memorySwapOutRate))"
                    + "  压缩/解压 \(rate(.memoryCompressionRate))/\(rate(.memoryDecompressionRate)) 次/秒"
                    + String(format: "  · %.2f ms CPU", cpuMs) + (outputs[0].staleCount > 0 ? " · 陈旧 \(outputs[0].staleCount)" : ""))
            if bandwidth {
                func gbs(_ id: MetricID) -> String {
                    guard let v = byID[id]?.value else { return "—" }
                    return String(format: "%.1f GB/s", v / 1e9)
                }
                print("    DRAM 带宽（\(dram.group ?? "—")，分档估算）读 \(gbs(.memoryBandwidthRead))  写 \(gbs(.memoryBandwidthWrite))")
            }
        }
        return 0
    }

    private static func percentSample(_ sample: Sample) -> Sample {
        guard let v = sample.value else { return sample }
        return Sample(id: sample.id, value: v * 100, quality: sample.quality, time: sample.time)
    }

    // MARK: - Top N

    static func runMemoryTopN(count: Int, interval: Double, rows: Int, grouping: TopNGrouping, fallback: Bool, json: Bool) -> Int32 {
        let encoder = makeEncoder()
        let sampler: AppSampler? = fallback ? nil : prepareAppSampler()
        if !fallback, sampler == nil { printError("coalition 不可用，改用同 uid 回退") }
        let builder = TopNBuilder()
        let same = SameUIDSampler()
        var deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for index in 1...count {
            if index > 1 {
                deadline += UInt64(interval * 1e9)
                sleep(untilUptimeNanos: deadline)
            }
            let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let list: [TopNRow]
            var note: String?
            if let sampler {
                _ = sampler.sample(at: .now())
                guard let footprints = sampler.latestFootprints else { return 1 }
                list = builder.buildMemory(footprints: footprints, rows: rows, grouping: grouping)
            } else {
                let result = same.sampleMemory(rows: rows)
                list = result.rows
                note = "只列同 uid 进程，另有 \(result.hiddenCount) 个读不到"
            }
            let cpuMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1e6
            if json {
                struct Record: Encodable { var index: Int; var rows: [TopNRow] }
                if let data = try? encoder.encode(Record(index: index, rows: list)) { print(String(decoding: data, as: UTF8.self)) }
                continue
            }
            print("#\(index)" + (note.map { "  \($0)" } ?? "") + String(format: "  · %.2f ms CPU", cpuMs))
            for row in list {
                let mib = Double(row.footprint ?? 0) / 1_048_576
                var line = String(format: "  %9.1f MiB  ", mib) + row.name
                if row.memberCount > 1 { line += " ×\(row.memberCount)" }
                if let top = row.topMember { line += "  （\(top.name) \(String(format: "%.1f MiB", Double(top.footprint ?? 0) / 1_048_576))）" }
                if let residual = row.residualFootprint, row.residualCount > 0 {
                    line += String(format: "  · 外部成员 %d 个 %.1f MiB", row.residualCount, Double(residual) / 1_048_576)
                }
                line += "  [\(row.eligibility.rawValue)]"
                print(line)
            }
        }
        return 0
    }

    // MARK: - 对照

    /// 运行一次外部命令，返回标准输出（只在手动对照时用）。
    static func capture(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    static func runVerifyMemory() -> Int32 {
        let memory = MemoryCollector()
        _ = memory.selfTest()
        let samples = memory.sample(at: .now()).samples
        guard let vmStat = capture("/usr/bin/vm_stat", []), let pressure = capture("/usr/bin/memory_pressure", ["-Q"]) else {
            printError("vm_stat 或 memory_pressure 运行失败")
            return 1
        }
        let byID: [MetricID: Sample] = Dictionary(samples.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let pageSize = Double(MemoryCollector.sysctlUInt64("hw.pagesize") ?? 16384)
        func vm(_ label: String) -> Double? {
            for line in vmStat.split(separator: "\n") where line.hasPrefix(label + ":") {
                let digits = line.dropFirst(label.count + 1).filter { $0.isNumber }
                return Double(String(digits)).map { $0 * pageSize }
            }
            return nil
        }
        print("\(machineLine()) · 与 vm_stat、memory_pressure -Q 对照（两者各运行一次，读数时刻相差几十毫秒）")
        var passed = true
        func row(
            _ title: String, _ ours: Double?, _ theirs: Double?, tolerance: Double = 0.02, unit: String = "GiB",
            slackMiB: Double = 32
        ) {
            guard let ours, let theirs else {
                print("  \(title)：缺读数")
                passed = false
                return
            }
            let scale = unit == "GiB" ? 1_073_741_824.0 : 1
            // 页面计数每秒都在变：允许 2% 或 32 MiB（取大）的差；空闲页波动最大，放宽到 128 MiB。
            let diff = abs(ours - theirs)
            let ok = diff <= max(abs(theirs) * tolerance, unit == "GiB" ? slackMiB * 1_048_576 : 1)
            passed = passed && ok
            print(String(format: "  %@：SysInfo %.3f %@ · 对照 %.3f %@ · %@", title, ours / scale, unit, theirs / scale, unit, ok ? "✓" : "✗"))
        }
        row("联动", byID[.memoryWired]?.value, vm("Pages wired down"))
        row("被压缩", byID[.memoryCompressed]?.value, vm("Pages occupied by compressor"))
        row("空闲（不含 speculative）", byID[.memoryFree]?.value, vm("Pages free"), slackMiB: 128)
        if let anon = vm("Anonymous pages"), let purgeable = vm("Pages purgeable") {
            row("App（anonymous − purgeable）", byID[.memoryApp]?.value, anon - purgeable, tolerance: 0.03)
        }
        if let file = vm("File-backed pages"), let purgeable = vm("Pages purgeable") {
            row("已缓存（file-backed + purgeable）", byID[.memoryCached]?.value, file + purgeable, tolerance: 0.03)
        }
        let freePercent = pressure.split(separator: "\n").first { $0.contains("free percentage") }
            .flatMap { line in Double(String(line.split(separator: ":").last?.filter { $0.isNumber } ?? "")) }
        row("压力（100 − free percentage）", byID[.memoryPressure]?.value.map { $0 * 100 }, freePercent.map { 100 - $0 }, tolerance: 0, unit: "%")
        print("  Swap：SysInfo \(show(byID[.memorySwapUsed], format: "%.0f")) B · sysctl \(capture("/usr/sbin/sysctl", ["-n", "vm.swapusage"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "—")")
        print(passed ? "全部一致" : "有不一致的项")
        return passed ? 0 : 1
    }

    static func runVerifyMemoryTopN(rows: Int) -> Int32 {
        guard let sampler = prepareAppSampler() else { return 1 }
        _ = sampler.sample(at: .now())
        guard let footprints = sampler.latestFootprints,
            let top = capture("/usr/bin/top", ["-l", "1", "-o", "mem", "-n", "\(rows * 3)", "-stats", "pid,mem,command"])
        else {
            printError("coalition 扫描或 top 运行失败")
            return 1
        }
        // top 的 MEM 列形如 1096M、4872M+、512K、5G，按 1024 换算。
        var theirs: [pid_t: Double] = [:]
        var header = true
        for line in top.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if header {
                if fields.first == "PID" { header = false }
                continue
            }
            guard fields.count >= 2, let pid = pid_t(fields[0]) else { continue }
            var text = String(fields[1])
            while let last = text.last, "+-".contains(last) { text.removeLast() }
            guard let unit = text.last, let number = Double(text.dropLast()) else { continue }
            let scale: Double = switch unit {
            case "K": 1024
            case "M": 1_048_576
            case "G": 1_073_741_824
            case "B": 1
            default: 0
            }
            if scale > 0 { theirs[pid] = number * scale }
        }
        let builder = TopNBuilder()
        let list = builder.buildMemory(footprints: footprints, rows: rows * 3, grouping: .byProcess)
        print("\(machineLine()) · 按进程的内存 Top N 与 top -l 1 -o mem 对照（top 的 MEM 只有 3 位有效数字）")
        var compared = 0
        var agreed = 0
        for row in list where row.kind == .process {
            guard let ours = row.footprint.map({ Double($0) }), let other = theirs[row.representativePID] else { continue }
            compared += 1
            // top 显示 3–4 位有效数字：允许 1% 或 1 MiB（取大），另加一个显示单位的舍入。
            let ok = abs(ours - other) <= max(other * 0.01, 1_048_576) + other * 0.005
            if ok { agreed += 1 }
            print(String(format: "  %@ pid %d：SysInfo %.1f MiB · top %.1f MiB", ok ? "✓" : "✗", row.representativePID, ours / 1_048_576, other / 1_048_576) + "  \(row.name)")
            if compared >= rows { break }
        }
        print("对照 \(compared) 个，一致 \(agreed) 个")
        return compared > 0 && agreed == compared ? 0 : 1
    }
}
