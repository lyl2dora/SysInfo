// sysinfo-cli：跨机对照用的命令行（M0 设计 §7，D25）。
//
// - selftest：运行所有采集器的自检并打印结果；
// - cpu：直接用 CPU 负载采集器（不经调度器）逐次打印总占用、用户/系统、每档、每簇和每核占用；
// - topo：打印拓扑发现的结果和三种档次依据（CPU 模块设计 §8）；
// - freq、verify freq：每簇频率，以及按档与内核计数对照（Freq.swift）；
// - engine：经 SamplingEngine 采样，验证「没有需求时定时器停掉、不再 tick」（M0 验收 5）。
//
// 输出里只有机型标识（如 Mac17,16）和系统 build 号，不含序列号等设备唯一标识。

import Foundation
import SysCollectors
import SysModel

@main
struct SysInfoCLI {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.isEmpty ? "help" : arguments.removeFirst()

        do {
            switch command {
            case "help", "-h", "--help":
                printUsage()
            case "version", "--version":
                print("sysinfo-cli（SysKit）私有层版本 \(PrivateLayer.version)")
            case "selftest":
                let options = try Options(arguments, flags: ["--json"], values: [])
                exit(runSelfTest(json: options.flag("--json")))
            case "cpu":
                let options = try Options(arguments, flags: ["--json"], values: ["--interval", "--count"])
                let interval = try options.double("--interval", default: 1, range: 0.1...3600)
                let count = try options.int("--count", default: 5, range: 1...1_000_000)
                exit(runCPU(interval: interval, count: count, json: options.flag("--json")))
            case "freq":
                let options = try Options(arguments, flags: ["--json"], values: ["--interval", "--count"])
                let interval = try options.double("--interval", default: 5, range: 0.1...3600)
                let count = try options.int("--count", default: 3, range: 1...1_000_000)
                exit(runFreq(interval: interval, count: count, json: options.flag("--json")))
            case "verify":
                guard let what = arguments.first else { throw UsageError("verify 需要指定对象：freq") }
                let options = try Options(Array(arguments.dropFirst()), flags: ["--yes"], values: [])
                switch what {
                case "freq": exit(runVerifyFreq(confirmed: options.flag("--yes")))
                default: throw UsageError("未知的 verify 对象：\(what)")
                }
            case "sensors":
                let options = try Options(arguments, flags: ["--json", "--raw"], values: ["--interval", "--count"])
                let interval = try options.double("--interval", default: 2, range: 0.5...3600)
                let count = try options.int("--count", default: 3, range: 1...1_000_000)
                exit(runSensors(interval: interval, count: count, raw: options.flag("--raw"), json: options.flag("--json")))
            case "calibrate":
                let options = try Options(
                    arguments, flags: ["--yes", "--verbose"], values: ["--save-recording", "--from-recording", "--emit-profile"])
                exit(
                    runCalibrate(
                        confirmed: options.flag("--yes"), saveRecording: options.value("--save-recording"),
                        fromRecording: options.value("--from-recording"), emitProfile: options.value("--emit-profile"),
                        verbose: options.flag("--verbose")))
            case "topo":
                let options = try Options(arguments, flags: ["--json"], values: [])
                exit(runTopo(json: options.flag("--json")))
            case "engine":
                let options = try Options(arguments, flags: [], values: ["--demand", "--idle"])
                let demand = try options.double("--demand", default: 3, range: 1...600)
                let idle = try options.double("--idle", default: 3, range: 1...600)
                exit(await runEngineCheck(demandSeconds: demand, idleSeconds: idle))
            default:
                throw UsageError("未知子命令：\(command)")
            }
        } catch let error as UsageError {
            printError(error.message)
            printUsage(to: FileHandle.standardError)
            exit(64)  // EX_USAGE
        } catch {
            printError("\(error)")
            exit(1)
        }
    }

    static func printUsage(to handle: FileHandle = .standardOutput) {
        let usage = """
            用法：sysinfo-cli <子命令> [选项]

            子命令：
              selftest [--json]                       运行所有采集器的自检并打印结果；全部通过时退出码为 0
              cpu [--interval 1] [--count 5] [--json] 直接用采集器逐次打印总占用、用户/系统、每档、每簇和每核占用
                                                      （--json 为每行一个 JSON）
              topo [--json]                           打印 CPU 拓扑：簇、核档、三种档次依据及其是否一致
              freq [--interval 5] [--count 3] [--json]
                                                      逐次打印每簇实际频率（另附请求频率作对照）
              sensors [--interval 2] [--count 3] [--raw] [--json]
                                                      簇温度、CPU 最高温、簇功耗；--raw 打出每个键的原始值并标出占位值
              calibrate [--yes] [--save-recording r.json] [--from-recording r.json] [--emit-profile p.json] [--verbose]
                                                      传感器校准：约 58 s（CPU 负载 30 s、GPU 负载 12 s），生成芯片档案并与内置档案比对；
                                                      不带 --yes 只打印计划；--from-recording 离线重新分析，不施加负载
              verify freq [--yes]                     分段施加约 17 s 的 CPU 负载，按档对照实际频率通道与内核计数；
                                                      不带 --yes 只打印将要做什么
              engine [--demand 3] [--idle 3]          经调度器采样：登记需求若干秒后注销，再等若干秒，
                                                      检查 tick 计数不再增长、定时器已停
              version                                 打印版本信息
              help                                    打印本帮助

            """
        handle.write(Data(usage.utf8))
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    // MARK: - 机器信息

    static func machineLine() -> String {
        let model = SystemInfo.modelIdentifier ?? "?"
        let build = SystemInfo.osBuild ?? "?"
        let cpus = SystemInfo.logicalCPUCount.map(String.init) ?? "?"
        return "\(model) · macOS build \(build) · hw.logicalcpu=\(cpus) · 私有层 v\(PrivateLayer.version)"
    }

    struct MachineInfo: Encodable {
        var model: String?
        var osBuild: String?
        var logicalCPU: Int?
        var privateLayerVersion: UInt32

        static var current: MachineInfo {
            MachineInfo(
                model: SystemInfo.modelIdentifier, osBuild: SystemInfo.osBuild,
                logicalCPU: SystemInfo.logicalCPUCount, privateLayerVersion: PrivateLayer.version)
        }
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    // MARK: - selftest

    struct SelfTestReport: Encodable {
        var machine: MachineInfo
        var passed: Bool
        var collectors: [Entry]

        struct Entry: Encodable {
            var id: String
            /// 全部检查都通过（包括提示项）。
            var passed: Bool
            /// 必需项都通过：数据源可以使用（提示项不通过时状态为 degraded）。
            var usable: Bool
            var dataPath: String
            var checks: [SelfTestCheck]
        }
    }

    /// 退出码：全部通过为 0；有任何一项（含提示项）没通过为 1。
    static func runSelfTest(json: Bool) -> Int32 {
        let entries = StandardCollectors.make().map { collector in
            let result = collector.selfTest()
            return SelfTestReport.Entry(
                id: collector.id.rawValue, passed: result.passed, usable: result.isUsable, dataPath: result.dataPath,
                checks: result.checks)
        }
        let passed = entries.allSatisfy(\.passed)

        if json {
            let report = SelfTestReport(machine: .current, passed: passed, collectors: entries)
            print(String(decoding: (try? makeEncoder().encode(report)) ?? Data(), as: UTF8.self))
        } else {
            print(machineLine())
            for entry in entries {
                let verdict = entry.passed ? "通过" : (entry.usable ? "降级" : "失败")
                print("\(verdict)  \(entry.id)  [\(entry.dataPath)]")
                for check in entry.checks {
                    let mark = check.passed ? "✓" : (check.severity == .advisory ? "!" : "✗")
                    print("    \(mark) \(check.name)：\(check.detail)")
                }
            }
            print(passed ? "自检全部通过" : "自检未全部通过（! 为提示项：数据源照常使用，状态降级；✗ 为必需项）")
        }
        return passed ? 0 : 1
    }

    // MARK: - cpu

    struct CPURecord: Encodable {
        var index: Int
        var time: Date
        var intervalSeconds: Double
        /// 总占用 0…1；不可用时为 null。
        var total: Double?
        var totalQuality: String
        /// 每核占用 0…1，顺序与 host_processor_info 一致；不可用的核为 null。
        var cores: [Double?]
        var user: Double?
        var system: Double?
        /// 每档占用，键为档序号；拓扑降级时为空。
        var perfLevels: [String: Double?]
        /// 每簇占用，键为簇键（如 d0c1）。
        var clusters: [String: Double?]
    }

    static func runCPU(interval: Double, count: Int, json: Bool) -> Int32 {
        let collector = CPULoadCollector()
        let selfTest = collector.selfTest()
        if !selfTest.isUsable {
            printError("警告：cpu.load 自检的必需项未通过，样本将标为不可用：")
        } else if !selfTest.passed {
            printError("警告：cpu.load 自检有提示项未通过，照常采样，状态为降级：")
        }
        for check in selfTest.checks where !check.passed {
            printError("    \(check.name)：\(check.detail)")
        }
        if !json {
            print("\(machineLine()) · 间隔 \(interval) s · \(count) 次")
        }

        let encoder = makeEncoder()
        let intervalNanos = UInt64(interval * 1_000_000_000)
        var deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        _ = collector.sample(at: .now())  // 建立基线

        var index = 0
        while index < count {
            deadline += intervalNanos
            sleep(untilUptimeNanos: deadline)
            let time = SampleTime.now()
            let output = collector.sample(at: time)
            guard let record = cpuRecord(from: output, index: index + 1, time: time, interval: interval) else {
                // 陈旧或核数变化：没有样本，本次不计数，等下一个间隔。
                if !json { print("（本次读数陈旧或核数变化，跳过；陈旧计数 \(output.staleCount)）") }
                continue
            }
            index += 1
            if json {
                if let data = try? encoder.encode(record) {
                    print(String(decoding: data, as: UTF8.self))
                }
            } else {
                print(textLine(record))
            }
            fflush(stdout)
        }
        return selfTest.passed ? 0 : 1
    }

    static func cpuRecord(from output: CollectorOutput, index: Int, time: SampleTime, interval: Double) -> CPURecord? {
        guard let total = output.samples.first(where: { $0.id == .cpuUsageTotal }) else { return nil }
        let cores = output.samples.compactMap { s in s.id.cpuCoreIndex.map { ($0, s.value) } }
            .sorted { $0.0 < $1.0 }.map(\.1)
        var levels: [String: Double?] = [:]
        var clusters: [String: Double?] = [:]
        for sample in output.samples {
            if let level = sample.id.cpuUsagePerfLevelIndex { levels[String(level)] = sample.value }
            if let key = sample.id.cpuUsageClusterKey { clusters[key.description] = sample.value }
        }
        return CPURecord(
            index: index, time: time.wallClock, intervalSeconds: interval, total: total.value,
            totalQuality: qualityName(total.quality), cores: cores,
            user: output.samples.first { $0.id == .cpuUsageUser }?.value,
            system: output.samples.first { $0.id == .cpuUsageSystem }?.value,
            perfLevels: levels, clusters: clusters)
    }

    static func textLine(_ record: CPURecord) -> String {
        let total = record.total.map { PercentFormat.string(fromRatio: $0, fractionDigits: 1) } ?? "不可用"
        let quality = record.totalQuality == "measured" ? "" : "（\(record.totalQuality)）"
        let cores = record.cores.enumerated().map { index, value in
            "\(index):\(value.map { PercentFormat.string(fromRatio: $0) } ?? "—")"
        }
        let clock = record.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
        func pct(_ value: Double??) -> String {
            (value ?? nil).map { PercentFormat.string(fromRatio: $0) } ?? "—"
        }
        let split = "用户 \(pct(record.user)) 系统 \(pct(record.system))"
        let levels = record.perfLevels.keys.sorted().map { "档\($0):\(pct(record.perfLevels[$0]))" }
        let clusters = record.clusters.keys.sorted().map { "\($0):\(pct(record.clusters[$0]))" }
        return "#\(record.index) \(clock)  总占用 \(total)\(quality)  \(split)  \(levels.joined(separator: " "))  "
            + "簇 \(clusters.joined(separator: " "))  每核 \(cores.joined(separator: " "))"
    }

    static func qualityName(_ quality: DataQuality) -> String {
        switch quality {
        case .measured: "measured"
        case .batched30min: "batched30min"
        case .estimated: "estimated"
        case .relative: "relative"
        case .inferred: "inferred"
        case .unavailable(let reason): "unavailable:\(reason)"
        }
    }

    static func sleep(untilUptimeNanos deadline: UInt64) {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard deadline > now else { return }
        var request = timespec(
            tv_sec: Int((deadline - now) / 1_000_000_000), tv_nsec: Int((deadline - now) % 1_000_000_000))
        var remaining = timespec()
        while nanosleep(&request, &remaining) != 0, errno == EINTR {
            request = remaining
        }
    }

    // MARK: - engine

    static func runEngineCheck(demandSeconds: Double, idleSeconds: Double) async -> Int32 {
        let engine = SamplingEngine(collectors: StandardCollectors.make())
        print(machineLine())

        let selfTests = await engine.runSelfTests()
        for (id, result) in selfTests.sorted(by: { $0.key < $1.key }) {
            print("自检 \(id)：\(result.passed ? "通过" : "未通过")")
        }

        let events = await engine.events()
        let printer = Task {
            for await event in events {
                guard case .tick(let result) = event else { continue }
                let total = result.samples.first { $0.id == .cpuUsageTotal }?.value
                let selfCPU = result.samples.first { $0.id == .appSelfCPU }?.value
                // tick 定在整秒之后约 50 ms，leeway 100 ms：这里打印实际触发时刻相对整秒的偏移。
                let offset = result.time.wallClock.timeIntervalSince1970 - Double(result.tick)
                let line = [
                    "tick \(result.tick)",
                    String(format: "+%.3f s", offset),
                    "#\(result.status.tickCount)",
                    "采集器 \(result.collectors.map(\.rawValue).joined(separator: ","))",
                    "总占用 \(total.map { PercentFormat.string(fromRatio: $0, fractionDigits: 1) } ?? "—")",
                    "本进程 \(selfCPU.map { PercentFormat.string(fromRatio: $0, fractionDigits: 2) } ?? "—")",
                    "耗时 \(result.cost.wallNanos / 1000) µs（CPU \(result.cost.cpuNanos / 1000) µs）",
                ]
                print(line.joined(separator: "  "))
            }
        }

        let token = await engine.addDemand(
            Demand(collectors: Set(engine.collectorIDs), interval: 1, source: .cli))
        print("已登记需求，采样 \(demandSeconds) s …")
        try? await Task.sleep(for: .seconds(demandSeconds))

        await engine.remove(token)
        let afterRemoval = await engine.status
        print("已注销需求：tick 计数 \(afterRemoval.tickCount)，定时器\(afterRemoval.isTimerArmed ? "仍在排定" : "已停")")
        try? await Task.sleep(for: .seconds(idleSeconds))

        let afterIdle = await engine.status
        printer.cancel()

        let passed = afterRemoval.tickCount > 0 && !afterRemoval.isTimerArmed && !afterIdle.isTimerArmed
            && afterIdle.tickCount == afterRemoval.tickCount
        print(
            "空闲 \(idleSeconds) s 后：tick 计数 \(afterIdle.tickCount)（注销时 \(afterRemoval.tickCount)），"
                + "定时器\(afterIdle.isTimerArmed ? "仍在排定" : "已停")")
        for health in afterIdle.health {
            let average = health.averageCost.map { "\($0.wallNanos / 1000) µs（CPU \($0.cpuNanos / 1000) µs）" } ?? "—"
            print("  \(health.id)：\(health.status.rawValue)，采样 \(health.sampleCount) 次，平均耗时 \(average)")
        }
        print(passed ? "通过：无需求时引擎不再 tick" : "失败：注销需求后引擎仍在 tick 或定时器未停")
        return passed ? 0 : 1
    }
}

// MARK: - 参数解析

struct UsageError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

/// 极简的选项解析：`--flag` 与 `--name value`（也接受 `--name=value`）。
struct Options {
    private var flags: Set<String> = []
    private var values: [String: String] = [:]

    init(_ arguments: [String], flags allowedFlags: Set<String>, values allowedValues: Set<String>) throws {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            var name = argument
            var inlineValue: String?
            if let equals = argument.firstIndex(of: "="), argument.hasPrefix("--") {
                name = String(argument[..<equals])
                inlineValue = String(argument[argument.index(after: equals)...])
            }
            if allowedFlags.contains(name), inlineValue == nil {
                flags.insert(name)
            } else if allowedValues.contains(name) {
                guard let value = inlineValue ?? iterator.next() else {
                    throw UsageError("选项 \(name) 缺少取值")
                }
                values[name] = value
            } else {
                throw UsageError("未知选项：\(argument)")
            }
        }
    }

    func flag(_ name: String) -> Bool {
        flags.contains(name)
    }

    func value(_ name: String) -> String? {
        values[name]
    }

    func double(_ name: String, default defaultValue: Double, range: ClosedRange<Double>) throws -> Double {
        guard let raw = values[name] else { return defaultValue }
        guard let value = Double(raw), value.isFinite, range.contains(value) else {
            throw UsageError("选项 \(name) 的取值无效：\(raw)（范围 \(range.lowerBound)…\(range.upperBound)）")
        }
        return value
    }

    func int(_ name: String, default defaultValue: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = values[name] else { return defaultValue }
        guard let value = Int(raw), range.contains(value) else {
            throw UsageError("选项 \(name) 的取值无效：\(raw)（范围 \(range.lowerBound)…\(range.upperBound)）")
        }
        return value
    }
}
