// sysinfo-cli：跨机对照用的命令行（M0 设计 §7，D25）。
//
// - selftest：运行所有采集器的自检并打印结果；
// - cpu：直接用 CPU 负载采集器（不经调度器）逐次打印总占用、用户/系统、每档、每簇和每核占用；
// - topo：打印拓扑发现的结果和三种档次依据（CPU 模块设计 §8）；
// - freq、verify freq：每簇频率，以及按档与内核计数对照（Freq.swift）；
// - power、pmgr：功耗与散热（Power.swift）；
// - memory、memtop、verify memory、verify memtop：内存（Memory.swift）；
// - storage、smart、disktop、verify storage：存储（Storage.swift）；
// - gpu、gputop：GPU 与加速器（GPU.swift）；
// - network：网络（Network.swift）；
// - history：历史库的统计、导出与实录（History.swift）；
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
                guard let what = arguments.first else { throw UsageError("verify 需要指定对象：freq、topn、passive") }
                let options = try Options(Array(arguments.dropFirst()), flags: ["--yes"], values: ["--seconds"])
                switch what {
                case "freq": exit(runVerifyFreq(confirmed: options.flag("--yes")))
                case "topn": exit(runVerifyTopN(seconds: try options.double("--seconds", default: 5, range: 1...60)))
                case "passive":
                    exit(await runVerifyPassive(seconds: try options.double("--seconds", default: 30, range: 10...60), load: options.flag("--yes")))
                case "memory": exit(runVerifyMemory())
                case "memtop": exit(runVerifyMemoryTopN(rows: 10))
                case "storage": exit(runVerifyStorage(seconds: Int(try options.double("--seconds", default: 5, range: 1...60))))
                default: throw UsageError("未知的 verify 对象：\(what)")
                }
            case "topn":
                let options = try Options(
                    arguments, flags: ["--json", "--by-process", "--fallback", "--refresh-all"],
                    values: ["--interval", "--count", "--rows"])
                exit(
                    runTopN(
                        interval: try options.double("--interval", default: 2, range: 0.5...60),
                        count: try options.int("--count", default: 3, range: 1...1_000_000),
                        rows: try options.int("--rows", default: 10, range: 1...100),
                        grouping: options.flag("--by-process") ? .byProcess : .byApp, fallback: options.flag("--fallback"),
                        refreshAll: options.flag("--refresh-all"), json: options.flag("--json")))
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
            case "rusage":
                let options = try Options(arguments, flags: [], values: ["--pid"])
                guard let raw = options.value("--pid"), let pid = Int32(raw) else { throw UsageError("rusage 需要 --pid") }
                exit(runRusage(pid: pid))
            case "cores":
                let options = try Options(arguments, flags: [], values: ["--interval", "--count"])
                exit(
                    runCoreFrequency(
                        interval: try options.double("--interval", default: 2, range: 0.5...60),
                        count: try options.int("--count", default: 3, range: 1...100)))
            case "irq":
                let options = try Options(arguments, flags: [], values: ["--interval", "--count", "--rows"])
                exit(
                    runInterruptSources(
                        interval: try options.double("--interval", default: 5, range: 1...60),
                        count: try options.int("--count", default: 2, range: 1...100),
                        rows: try options.int("--rows", default: 10, range: 1...100)))
            case "power":
                let options = try Options(arguments, flags: ["--json"], values: ["--interval", "--count"])
                exit(
                    runPower(
                        interval: try options.double("--interval", default: 1, range: 0.5...3600),
                        count: try options.int("--count", default: 5, range: 1...1_000_000), json: options.flag("--json")))
            case "memory":
                let options = try Options(arguments, flags: ["--json", "--bandwidth"], values: ["--interval", "--count"])
                exit(
                    runMemory(
                        interval: try options.double("--interval", default: 1, range: 0.5...3600),
                        count: try options.int("--count", default: 5, range: 1...1_000_000), bandwidth: options.flag("--bandwidth"),
                        json: options.flag("--json")))
            case "memtop":
                let options = try Options(arguments, flags: ["--json", "--by-process", "--fallback"], values: ["--interval", "--count", "--rows"])
                exit(
                    runMemoryTopN(
                        count: try options.int("--count", default: 1, range: 1...1_000_000),
                        interval: try options.double("--interval", default: 5, range: 0.5...60),
                        rows: try options.int("--rows", default: 10, range: 1...100),
                        grouping: options.flag("--by-process") ? .byProcess : .byApp, fallback: options.flag("--fallback"),
                        json: options.flag("--json")))
            case "gpu":
                let options = try Options(arguments, flags: ["--json", "--diag"], values: ["--interval", "--count"])
                exit(
                    runGPU(
                        interval: try options.double("--interval", default: 1, range: 0.5...3600),
                        count: try options.int("--count", default: 5, range: 1...1_000_000), diagnostics: options.flag("--diag"),
                        json: options.flag("--json")))
            case "gputop":
                let options = try Options(arguments, flags: ["--json", "--by-process"], values: ["--interval", "--count", "--rows"])
                exit(
                    runGPUTopN(
                        count: try options.int("--count", default: 1, range: 1...1_000_000),
                        interval: try options.double("--interval", default: 2, range: 0.5...60),
                        rows: try options.int("--rows", default: 10, range: 1...100),
                        grouping: options.flag("--by-process") ? .byProcess : .byApp, json: options.flag("--json")))
            case "network":
                let options = try Options(
                    arguments, flags: ["--json", "--diag", "--wifi", "--addresses"], values: ["--interval", "--count", "--latency"])
                exit(
                    runNetwork(
                        interval: try options.double("--interval", default: 1, range: 0.5...3600),
                        count: try options.int("--count", default: 3, range: 1...1_000_000), diagnostics: options.flag("--diag"),
                        wifi: options.flag("--wifi"), latency: options.value("--latency"), addresses: options.flag("--addresses"),
                        json: options.flag("--json")))
            case "storage":
                let options = try Options(arguments, flags: ["--json"], values: ["--interval", "--count"])
                exit(
                    runStorage(
                        interval: try options.double("--interval", default: 1, range: 0.5...3600),
                        count: try options.int("--count", default: 3, range: 1...1_000_000), json: options.flag("--json")))
            case "disktop":
                let options = try Options(arguments, flags: ["--json", "--by-process", "--fallback"], values: ["--interval", "--count", "--rows"])
                exit(
                    runDiskTopN(
                        count: try options.int("--count", default: 1, range: 1...1_000_000),
                        interval: try options.double("--interval", default: 2, range: 0.5...60),
                        rows: try options.int("--rows", default: 10, range: 1...100),
                        grouping: options.flag("--by-process") ? .byProcess : .byApp, fallback: options.flag("--fallback"),
                        json: options.flag("--json")))
            case "smart":
                let options = try Options(arguments, flags: ["--json"], values: [])
                exit(runSMART(json: options.flag("--json")))
            case "pmgr":
                let options = try Options(arguments, flags: ["--watch"], values: ["--timeout"])
                exit(runPMGR(watch: options.flag("--watch"), timeout: try options.double("--timeout", default: 1900, range: 60...7200)))
            case "catalog":
                let options = try Options(arguments, flags: ["--json", "--all"], values: ["--samples"])
                exit(
                    runCatalog(
                        samples: try options.int("--samples", default: 4, range: 1...60), json: options.flag("--json"),
                        all: options.flag("--all")))
            case "apps":
                let options = try Options(arguments, flags: ["--json"], values: ["--interval", "--count", "--rows", "--sort", "--range", "--db"])
                guard let sort = AppSortKey(rawValue: options.value("--sort") ?? "cpu") else {
                    throw UsageError("--sort 取 \(AppSortKey.allCases.map(\.rawValue).joined(separator: "、"))")
                }
                guard let range = AppActivityRange(rawValue: options.value("--range") ?? "now") else {
                    throw UsageError("--range 取 \(AppActivityRange.allCases.map(\.rawValue).joined(separator: "、"))")
                }
                exit(
                    runApps(
                        interval: try options.double("--interval", default: 2, range: 0.5...60),
                        count: try options.int("--count", default: 1, range: 1...1_000_000),
                        rows: try options.int("--rows", default: 20, range: 1...10_000), sort: sort, range: range,
                        db: options.value("--db"), json: options.flag("--json")))
            case "assertions":
                let options = try Options(arguments, flags: ["--json"], values: ["--watch"])
                exit(
                    runAssertions(
                        watchSeconds: try options.value("--watch").map { _ in try options.double("--watch", default: 30, range: 1...3600) },
                        json: options.flag("--json")))
            case "history":
                exit(try await runHistory(arguments))
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
              topn [--interval 2] [--count 3] [--rows 10] [--by-process] [--fallback] [--refresh-all] [--json]
                                                      Top N：默认按应用（coalition）；--fallback 为同 uid 回退，
                                                      --refresh-all 为手动 setuid ps 刷新全部
              verify topn [--seconds 5]               与 setuid /bin/ps 的 TIME 差分对照前 10 名
              verify passive [--seconds 30] [--yes]   经调度器跑拓扑与频率的被动核对；--yes 在本进程内施加负载
              verify freq [--yes]                     分段施加约 17 s 的 CPU 负载，按档对照实际频率通道与内核计数；
                                                      不带 --yes 只打印将要做什么
              rusage --pid PID                        打印进程的 rusage_info_v6 按档计数（一行 JSON，开销测量按 D40 折算用）
              cores [--interval 2] [--count 3]       逐核频率（诊断用），以及每核 tick 忙碌与逐核通道活跃的相关系数（要求 ≥0.99）
              irq [--interval 5] [--count 2] [--rows 10]
                                                      中断来源：按设备的每秒中断次数（IOReport Interrupt Statistics）
              power [--interval 1] [--count 5] [--json]
                                                      整机 / SoC / GPU / DRAM 功率、墙插估算、SoC 最热点、风扇、低功耗模式，
                                                      以及遥测与 PDTR 积分的逐段对账
              memory [--interval 1] [--count 5] [--bandwidth] [--json]
                                                      内存总量与构成（活动监视器口径）、压力、Swap、压缩比与各速率；
                                                      --bandwidth 同时打印 DRAM 带宽的分档估算（相对量）
              memtop [--rows 10] [--count 1] [--by-process] [--fallback] [--json]
                                                      按内存 footprint 的 Top N（按应用或按进程）
              verify memory                           与 vm_stat、memory_pressure -Q 各运行一次的结果对照
              verify memtop                           按进程的内存 Top N 与 top -l 1 -o mem 对照
              gpu [--interval 1] [--count 5] [--diag] [--json]
                                                      GPU 活跃、频率、功率、温度，ANE 上电与估算功率，媒体引擎活动，GPU 内存；
                                                      --diag 另打印各档驻留、PWRCTRL、节流、PMP 带宽、ANE 中断、Device Utilization %
              gputop [--interval 2] [--count 1] [--rows 10] [--by-process] [--json]
                                                      按 GPU 时间的 Top N（coalition 槽位 8），附 GPU 与 ANE 能耗
              network [--interval 1] [--count 3] [--diag] [--wifi] [--latency gateway|地址] [--addresses] [--json]
                                                      网络接口清单（类型、物理判定、链路速率）、主接口与 VPN，逐次打印各接口入 / 出速率；
                                                      --diag 加原始计数，--wifi 读 CoreWLAN，--latency 每次发一个 ICMP 探测包，
                                                      --addresses 才打印本机地址、网关与 DNS
              storage [--interval 1] [--count 3] [--json]
                                                      物理盘清单、RAID 组、容量组，以及每盘读写、IOPS、延迟、温度与寿命
              smart [--json]                          每块物理盘的 NVMe SMART 全字段
              apps [--interval 2] [--count 1] [--rows 20] [--sort cpu|power|memory|gpu|ane|disk|wakeups]
                   [--range now|hour|today|week|month] [--db PATH] [--json]
                                                      应用活动全表（D67）：「现在」为实时扫描，附应用合计与 SoC 功率；
                                                      其余时段读历史库的按应用汇总与电源断言区间
              assertions [--watch 秒]                 当前电源断言（合并、归属、coalition）与通知自检；--watch 事件驱动地打印变化
              disktop [--interval 2] [--count 1] [--rows 10] [--by-process] [--fallback] [--json]
                                                      按磁盘读写的 Top N（按应用或按进程）；--fallback 为同 uid 回退
              verify storage [--seconds 5]            每盘读写与 iostat -d 同一时间窗对照，容量组可用空间与 df -k 对照
              pmgr [--watch] [--timeout 1900]         PMGR 订阅的部件；--watch 等到下一个 30 分钟批次，打印分部件明细与交叉核对
              catalog [--samples 4] [--all] [--json]  传感器目录：全部 T/V/I/P/F 数值键的质量（有效 / 占位 / 恒定 / 非温度）与已验证分组
              history stats [--db PATH]               历史库概况（默认读 Debug 版数据目录 zone.lyl.sysinfo.dev）
              history export --out PATH [--format csv|jsonl] [--granularity minute|hour] [--hours 24]
                             [--metrics cpu.usage.,cpu.temp.] [--no-apps] [--db PATH]
                                                      导出历史：csv 为文件夹（system.csv、apps.csv、metadata.json）
              history energy [--db PATH]              能耗：今天、昨天、近 7 天的 kWh（积分与系统累计补数分开列出）
              history record --db PATH [--seconds 180] [--menubar] [--no-apps]
                                                      经调度器记录若干秒并打印写入结果；--menubar 加一个 1 s 的占用需求
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

    // MARK: - rusage

    /// 进程的按档计数（D40）：时间换算成纳秒；只对同 uid 的进程可读。
    static func runRusage(pid: pid_t) -> Int32 {
        guard let r = ProcessInfoReader.rusage(of: pid) else {
            printError("读不到 pid \(pid) 的 rusage")
            return 1
        }
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        func ns(_ ticks: UInt64) -> UInt64 { ticks * UInt64(tb.numer) / UInt64(max(tb.denom, 1)) }
        // 最快档的顶档频率（DVFS 表顶，运行时发现，D20）：最快档时间太少时按周期数折算用（D40）。
        let topology = CPUTopologyService.shared.refresh()
        let tops = FrequencyPlan.discover(clusters: topology.clusters, logicalCPUCount: topology.logicalCPUCount).tableTops
        let fastest = topology.perfLevels.first.map { level in level.clusters.compactMap { tops[$0] }.max() ?? 0 } ?? 0
        print(
            "{\"cpu_ns\":\(ns(r.ri_user_time + r.ri_system_time)),\"p0_ns\":\(ns(r.ri_user_ptime + r.ri_system_ptime)),"
                + "\"instructions\":\(r.ri_instructions),\"p0_instructions\":\(r.ri_pinstructions),"
                + "\"cycles\":\(r.ri_cycles),\"p0_cycles\":\(r.ri_pcycles),\"energy_nj\":\(r.ri_energy_nj),"
                + "\"p0_top_hz\":\(Int(fastest))}")
        return 0
    }

    // MARK: - cores

    static func runCoreFrequency(interval: Double, count: Int) -> Int32 {
        print(machineLine())
        _ = CPUTopologyService.shared.refresh()
        let frequency = CPUFrequencyCollector()
        guard frequency.selfTest().isUsable else {
            printError("频率采集器自检未通过")
            return 1
        }
        let cores = CoreFrequencyCollector(frequency: frequency)
        _ = cores.sample(at: .now())
        var failed = false
        for index in 1...count {
            sleep(untilUptimeNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + UInt64(interval * 1e9))
            let started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            _ = cores.sample(at: .now())
            let cost = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started) / 1e6
            guard let snapshot = cores.latest else { continue }
            let r = snapshot.correlation.map { String(format: "%.4f", $0) } ?? "不确定（各核差异太小）"
            print(String(format: "#%d  相关系数 %@，本次采样 %.2f ms CPU", index, r, cost))
            for c in snapshot.cores {
                let f: String
                switch c.reading {
                case .active(let hz, let a)?: f = String(format: "%5.0f MHz 活跃 %5.1f%%", hz / 1e6, a * 100)
                case .idle(let a)?: f = String(format: "   空闲   活跃 %5.1f%%", a * 100)
                case .invalid(let why)?: f = "✗ \(why)"
                case nil: f = "—"
                }
                print("  cpu\(c.cpu) \(c.cluster)  \(f)  忙碌 \(c.busy.map { String(format: "%5.1f%%", $0 * 100) } ?? "—")")
            }
            if snapshot.correlationPassed == false { failed = true }
        }
        return failed ? 1 : 0
    }

    // MARK: - irq

    static func runInterruptSources(interval: Double, count: Int, rows: Int) -> Int32 {
        print(machineLine())
        let collector = InterruptDeviceCollector()
        let test = collector.selfTest()
        print("自检：\(test.checks.map { "\($0.name) \($0.passed ? "✓" : "✗") \($0.detail)" }.joined(separator: "；"))")
        guard test.isUsable else { return 1 }
        _ = collector.sample(at: .now())
        for index in 1...count {
            sleep(untilUptimeNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + UInt64(interval * 1e9))
            let started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            _ = collector.sample(at: .now())
            let cost = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started) / 1e6
            let sources = collector.latestSources
            let total = sources.reduce(0) { $0 + $1.perSecond }
            print(String(format: "#%d  %d 个设备，共 %.0f/s，本次采样 %.2f ms CPU", index, sources.count, total, cost))
            for s in sources.prefix(rows) {
                print(String(format: "  %8.0f/s  %@", s.perSecond, s.device))
            }
        }
        return 0
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
