// sysinfo-cli history：历史库的统计、导出与实录（CPU 模块设计 §6、§8）。
//
// - stats / export 默认读 Debug 版的数据目录（`zone.lyl.sysinfo.dev`，D16），不碰日用版；
// - record 必须显式给 `--db`：经调度器跑 HistoryRecorder 若干秒，用于在两台机器上核对聚合与开销。
//   在对照机上只写 /tmp/sysinfo-remote（D18）。

import Foundation
import SysCollectors
import SysModel
import SysStore

extension SysInfoCLI {
    static let devBundleIdentifier = "zone.lyl.sysinfo.dev"

    static func historyURL(_ path: String?) throws -> URL {
        if let path { return URL(fileURLWithPath: path) }
        guard let url = HistoryStore.defaultURL(bundleIdentifier: devBundleIdentifier) else {
            throw UsageError("找不到 Application Support 目录")
        }
        return url
    }

    static func runHistory(_ arguments: [String]) async throws -> Int32 {
        guard let what = arguments.first else { throw UsageError("history 需要指定动作：stats、export、record") }
        let rest = Array(arguments.dropFirst())
        switch what {
        case "stats":
            let options = try Options(rest, flags: [], values: ["--db"])
            let url = try historyURL(options.value("--db"))
            guard FileManager.default.fileExists(atPath: url.path) else {
                printError("历史库不存在：\(url.path)")
                return 1
            }
            printStats(try HistoryStore(url: url).stats())
            return 0
        case "export":
            let options = try Options(
                rest, flags: ["--no-apps"], values: ["--db", "--out", "--format", "--granularity", "--hours", "--metrics"])
            guard let out = options.value("--out") else { throw UsageError("export 需要 --out") }
            let format: HistoryExportOptions.Format
            switch options.value("--format") ?? "csv" {
            case "csv": format = .csv
            case "jsonl": format = .jsonLines
            case let other: throw UsageError("未知格式：\(other)（csv、jsonl）")
            }
            guard let granularity = HistoryGranularity(rawValue: options.value("--granularity") ?? "minute") else {
                throw UsageError("粒度只能是 minute 或 hour")
            }
            let hours = try options.double("--hours", default: 24, range: 0.1...24 * 3650)
            let now = Date()
            let store = try HistoryStore(url: try historyURL(options.value("--db")))
            let files = try HistoryExporter.export(
                store,
                options: HistoryExportOptions(
                    from: now.addingTimeInterval(-hours * 3600), to: now, granularity: granularity, format: format,
                    metricPrefixes: options.value("--metrics").map { $0.split(separator: ",").map(String.init) },
                    includeApps: !options.flag("--no-apps"), appVersion: "sysinfo-cli \(PrivateLayer.version)"),
                to: URL(fileURLWithPath: out))
            for file in files {
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
                print("写出 \(file.path)（\(size) 字节）")
            }
            return 0
        case "record":
            let options = try Options(rest, flags: ["--menubar", "--no-apps"], values: ["--db", "--seconds"])
            guard let db = options.value("--db") else { throw UsageError("record 必须给 --db（不写默认数据目录）") }
            return await runHistoryRecord(
                url: URL(fileURLWithPath: db), seconds: try options.double("--seconds", default: 180, range: 10...3600),
                menubar: options.flag("--menubar"), apps: !options.flag("--no-apps"))
        default:
            throw UsageError("未知的 history 动作：\(what)")
        }
    }

    static func describeMinute(_ minute: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(minute * 60)).formatted(date: .numeric, time: .shortened)
    }

    static func printStats(_ stats: HistoryStats) {
        print("历史库：\(stats.path)")
        print("  大小 \(stats.fileBytes / 1024) KiB（不含 WAL），指标 \(stats.metricCount) 个，应用 \(stats.appCount) 个")
        let minuteRange = stats.minuteRange.map { "\(describeMinute($0.lowerBound)) – \(describeMinute($0.upperBound))" } ?? "—"
        let hourRange = stats.hourRange.map { "\(describeMinute($0.lowerBound * 60)) – \(describeMinute($0.upperBound * 60))" } ?? "—"
        print("  分钟行 \(stats.minuteRows)（\(minuteRange)）")
        print("  小时行 \(stats.hourRows)（\(hourRange)）")
        print("  每应用分钟行 \(stats.appRows)")
        for epoch in stats.epochs {
            let topology = (try? JSONDecoder().decode(EpochTopology.self, from: Data(epoch.topologyJSON.utf8)))
                .map { t in t.levels.map { "\($0.name)×\($0.cpuCount)" }.joined(separator: " + ") } ?? "?"
            print("  epoch \(describeMinute(epoch.startMinute))：\(epoch.model) \(epoch.chip) \(epoch.osBuild) [\(topology)]")
        }
    }

    /// 本进程累计 CPU 时间，秒（getrusage）。
    static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// 经调度器跑记录器：`--menubar` 额外登记一个 1 s 的 cpu.load 前台需求（模拟菜单栏 item 开着）。
    static func runHistoryRecord(url: URL, seconds: Double, menubar: Bool, apps: Bool) async -> Int32 {
        print(machineLine())
        let collectors = StandardCollectors.make()
        let appSampler = collectors.compactMap { $0 as? AppSampler }.first
        let engine = SamplingEngine(collectors: collectors)
        _ = await engine.runSelfTests()
        let store: HistoryStore
        do {
            store = try HistoryStore(url: url)
        } catch {
            printError("打开历史库失败：\(error)")
            return 1
        }
        let recorder = HistoryRecorder(
            store: store, engine: engine, appSampler: appSampler,
            configuration: .init(recordSystem: true, recordApps: apps))
        let cpu0 = processCPUSeconds()
        let started = Date()
        await recorder.start()
        let menubarToken =
            menubar
            ? await engine.addDemand(Demand(collectors: [CPULoadCollector.collectorID], interval: 1, source: .menubarCPU))
            : nil
        print("记录 \(Int(seconds)) s\(menubar ? "（含 1 s 菜单栏需求）" : "（只有后台需求）") → \(url.path)")
        try? await Task.sleep(for: .seconds(seconds))
        menubarToken?.cancel()
        await recorder.stop()
        let elapsed = Date().timeIntervalSince(started)
        do {
            let cpu = processCPUSeconds() - cpu0
            print(String(format: "本进程 CPU %.3f s / 墙钟 %.0f s = %.3f%% 单核（含 CLI 自身）", cpu, elapsed, cpu / elapsed * 100))
        }
        let rows = await recorder.writtenRows
        let appRows = await recorder.writtenAppRows
        if let error = await recorder.lastError { printError("提交出错：\(error)") }
        print("本次写入：分钟行 \(rows)，每应用行 \(appRows)")
        do {
            let stats = try await recorder.stats()
            printStats(stats)
            let now = Date()
            for metric in [MetricID.cpuUsageTotal, .cpuTemperatureMax, .cpuPowerTotal, .cpuLoadAverage1] {
                let points = try await recorder.series(
                    metric, from: now.addingTimeInterval(-seconds - 120), to: now, granularity: .minute)
                let text = points.map { p in
                    let max = p.max.map { String(format: "%.3g", $0) } ?? "—"
                    return String(format: "%.3g", p.avg) + "/\(max)/n\(p.n)"
                }
                print("  \(metric)：\(text.joined(separator: "  "))")
            }
            let apps = try await recorder.topApps(from: now.addingTimeInterval(-seconds - 120), to: now, limit: 1000)
            for app in apps.prefix(5) {
                print(String(format: "  应用 %@：%.2f CPU·s", app.name, Double(app.cpuNanos) / 1e9))
            }
            // 合理性核对：每分钟前 10 个应用的合计不应超过按总占用积分出的整机 CPU 时间。
            let total = try await recorder.series(
                .cpuUsageTotal, from: now.addingTimeInterval(-seconds - 120), to: now, granularity: .minute)
            let cores = Double(SystemInfo.maxLogicalCPUCount ?? 0)
            let machine = total.reduce(0) { $0 + $1.avg * Double($1.n) } * cores
            let appSum = apps.reduce(0.0) { $0 + Double($1.cpuNanos) / 1e9 }
            print(String(format: "  核对：整机（按 cpu.usage.total）%.1f CPU·s，应用合计 %.1f CPU·s", machine, appSum))
        } catch {
            printError("读取失败：\(error)")
            return 1
        }
        return rows > 0 ? 0 : 1
    }
}
