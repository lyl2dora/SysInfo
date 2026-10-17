// sysinfo-cli apps / assertions（应用活动设计 §3.3，D67–D69）。
//
// - apps：「现在」档的全表（同应用活动窗口），按某一列排序，附应用合计功率与 SoC 功率；
//   --range hour|today|week|month 改读历史库（默认 Debug 版的库，--db 指定其他库）的按应用汇总；
// - assertions：当前电源断言（合并后）与自检结果（通知是否可用）；--watch 秒数内事件驱动地打印变化。

import Foundation
import SysCollectors
import SysModel
import SysStore

extension SysInfoCLI {
    enum AppSortKey: String, CaseIterable {
        case cpu, power, memory, gpu, ane, disk, wakeups
    }

    static func runApps(
        interval: Double, count: Int, rows: Int, sort: AppSortKey, range: AppActivityRange, db: String?, json: Bool
    ) -> Int32 {
        if range != .now { return runAppsHistory(range: range, rows: rows, sort: sort, db: db, json: json) }
        guard let sampler = prepareAppSampler() else { return 1 }
        let assertions = PowerAssertionCollector()
        let builder = AppActivityBuilder()
        let sensors = PowerSensorCollector(ledger: PowerLedger())
        _ = sensors.selfTest()
        _ = sensors.sample(at: .now())
        _ = sampler.sample(at: .now())
        var deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let encoder = makeEncoder()
        if !json { print("\(machineLine()) · 现在 · 按 \(sort.rawValue) · \(rows) 行") }
        for index in 1...count {
            deadline += UInt64(interval * 1e9)
            sleep(untilUptimeNanos: deadline)
            let cost0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            _ = sampler.sample(at: .now())
            guard let window = sampler.latestWindow else { continue }
            let snapshot = builder.build(window: window, assertions: PowerAssertionCollector.read())
            let costMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cost0) / 1e6
            let soc: Double? = sensors.sample(at: .now()).samples.first { $0.id == MetricID.powerSoC }?.value
            let sorted = sortRows(snapshot.rows, by: sort).prefix(rows)
            if json {
                struct Record: Encodable {
                    var index: Int
                    var totalWatts: Double?
                    var socWatts: Double?
                    var coalitions: Int
                    var rows: [Row]
                }
                struct Row: Encodable {
                    var name: String
                    var key: String
                    var cpu: Double?
                    var watts: Double?
                    var footprint: UInt64?
                    var gpu: Double?
                    var ane: Double?
                    var diskRead: Double?
                    var diskWrite: Double?
                    var wakeups: Double?
                    var preventsSleep: Bool
                }
                let record = Record(
                    index: index, totalWatts: snapshot.totalWatts, socWatts: soc, coalitions: snapshot.rows.count,
                    rows: sorted.map {
                        Row(
                            name: $0.name, key: $0.key, cpu: $0.cpu, watts: $0.watts, footprint: $0.footprint, gpu: $0.gpuShare,
                            ane: $0.aneWatts, diskRead: $0.diskRead, diskWrite: $0.diskWrite, wakeups: $0.wakeups,
                            preventsSleep: $0.preventsSleep)
                    })
                if let data = try? encoder.encode(record) { print(String(decoding: data, as: UTF8.self)) }
                continue
            }
            let total = snapshot.totalWatts.map { String(format: "%.2f W", $0) } ?? "—"
            let socText = soc.map { String(format: "%.2f W", $0) } ?? "—"
            print(
                "#\(index)  \(snapshot.rows.count) 个 coalition · 应用合计 \(total) · SoC \(socText) · 构建 \(String(format: "%.2f", costMs)) ms")
            print("   CPU      功率    内存       GPU   ANE      读/s      写/s    唤醒/s  名称")
            for row in sorted {
                let cells = [
                    String(format: "%5.1f%%", (row.cpu ?? 0) * 100),
                    row.watts.map { String(format: "%6.2fW", $0) } ?? "     —",
                    String(format: "%8.1fM", Double(row.footprint ?? 0) / 1_048_576),
                    String(format: "%5.1f%%", min(row.gpuShare ?? 0, 1) * 100),
                    String(format: "%5.2fW", row.aneWatts ?? 0),
                    String(format: "%9.0f", row.diskRead ?? 0), String(format: "%9.0f", row.diskWrite ?? 0),
                    String(format: "%7.1f", row.wakeups ?? 0),
                ]
                var line = "  " + cells.joined(separator: " ") + "  " + row.name
                if (row.memberCount ?? 0) > 1 { line += "（×\(row.memberCount ?? 0)）" }
                if row.preventsSleep { line += "  [阻止睡眠]" }
                print(line)
            }
            fflush(stdout)
        }
        _ = assertions
        return 0
    }

    static func sortRows(_ rows: [AppActivityRow], by key: AppSortKey) -> [AppActivityRow] {
        func value(_ row: AppActivityRow) -> Double {
            switch key {
            case .cpu: row.cpu ?? Double(row.cpuTimeNanos ?? 0)
            case .power: row.watts ?? row.energyJoules ?? 0
            case .memory: Double(row.footprint ?? 0)
            case .gpu: row.gpuShare ?? Double(row.gpuTimeNanos ?? 0)
            case .ane: row.aneWatts ?? row.aneJoules ?? 0
            case .disk: (row.diskRead ?? 0) + (row.diskWrite ?? 0)
            case .wakeups: row.wakeups ?? 0
            }
        }
        return rows.sorted { value($0) > value($1) }
    }

    static func runAppsHistory(range: AppActivityRange, rows: Int, sort: AppSortKey, db: String?, json: Bool) -> Int32 {
        do {
            let url = try historyURL(db)
            guard FileManager.default.fileExists(atPath: url.path) else {
                printError("历史库不存在：\(url.path)")
                return 1
            }
            let store = try HistoryStore(url: url)
            let now = Date()
            guard let start = range.start(now: now) else { return 1 }
            let totals = try store.appTotals(
                from: MinuteAggregator.minute(of: start), to: MinuteAggregator.minute(of: now) + 1)
            let spans = try store.assertionSpans(from: start, to: now)
            var sleepSeconds: [String: TimeInterval] = [:]
            for span in spans where span.kind.preventsSleep {
                sleepSeconds[span.appKey, default: 0] += span.seconds(from: start, to: now, now: now)
            }
            let converted = totals.map { $0.row(appPath: nil, isApp: false) }
            let sorted = sortRows(converted, by: sort).prefix(rows)
            if json {
                struct Row: Encodable {
                    var key: String
                    var name: String
                    var cpuSeconds: Double
                    var energyJoules: Double?
                    var footprintPeak: UInt64?
                    var diskBytes: Double
                    var wakeups: Double?
                    var minutes: Int?
                    var preventSleepSeconds: Double?
                }
                let encoder = makeEncoder()
                for row in sorted {
                    let record = Row(
                        key: row.key, name: row.name, cpuSeconds: Double(row.cpuTimeNanos ?? 0) / 1e9, energyJoules: row.energyJoules,
                        footprintPeak: row.footprint, diskBytes: (row.diskRead ?? 0) + (row.diskWrite ?? 0), wakeups: row.wakeups,
                        minutes: row.activeMinutes, preventSleepSeconds: sleepSeconds[row.key])
                    if let data = try? encoder.encode(record) { print(String(decoding: data, as: UTF8.self)) }
                }
                return 0
            }
            print("\(machineLine()) · \(range.rawValue)（\(start.formatted()) 起）· 按 \(sort.rawValue) · \(totals.count) 个应用")
            print("   CPU 时间      能耗   内存峰值     读写合计      唤醒  分钟  阻止睡眠  名称")
            for row in sorted {
                let cells = [
                    String(format: "%9.1fs", Double(row.cpuTimeNanos ?? 0) / 1e9),
                    row.energyJoules.map { String(format: "%8.1fJ", $0) } ?? "        —",
                    String(format: "%8.1fM", Double(row.footprint ?? 0) / 1_048_576),
                    String(format: "%11.0f", (row.diskRead ?? 0) + (row.diskWrite ?? 0)),
                    String(format: "%9.0f", row.wakeups ?? 0), String(format: "%5d", row.activeMinutes ?? 0),
                    sleepSeconds[row.key].map { String(format: "%7.0fs", $0) } ?? "        ",
                ]
                print("  " + cells.joined(separator: " ") + "  " + row.name)
            }
            if !spans.isEmpty {
                print("断言区间（阻止睡眠 / 显示器睡眠）：")
                for span in spans {
                    let end = span.end.map { $0.formatted(date: .omitted, time: .standard) } ?? "进行中"
                    print(
                        "  \(span.start.formatted(date: .abbreviated, time: .standard)) – \(end)\(span.endEstimated ? "（估计）" : "")  \(span.appName)  \(span.type)  \(span.name)\(span.holder.isEmpty ? "" : "  经 \(span.holder)")")
                }
            }
            return 0
        } catch {
            printError("读历史库失败：\(error)")
            return 1
        }
    }

    static func runAssertions(watchSeconds: Double?, json: Bool) -> Int32 {
        let collector = PowerAssertionCollector()
        let result = collector.selfTest()
        for check in result.checks {
            print("\(check.passed ? "✓" : check.severity == .advisory ? "!" : "✗") \(check.name)：\(check.detail)")
        }
        guard let snapshot = collector.latestSnapshot else { return 1 }
        printAssertions(snapshot)
        guard let watchSeconds else { return 0 }
        guard collector.isEventDriven else {
            printError("通知不可用，--watch 无法事件驱动")
            return 1
        }
        print("监视 \(Int(watchSeconds)) s（事件驱动）…")
        collector.setChangeHandler { snapshot in
            print("— 变化 \(snapshot.time.formatted(date: .omitted, time: .standard))")
            printAssertions(snapshot)
            fflush(stdout)
        }
        Thread.sleep(forTimeInterval: watchSeconds)
        collector.setChangeHandler(nil)
        _ = json
        return 0
    }

    private static func printAssertions(_ snapshot: PowerAssertionSnapshot) {
        let kinds: [PowerAssertionKind: String] = [.preventSleep: "阻止睡眠", .preventDisplaySleep: "阻止显示器睡眠", .other: "其他"]
        for assertion in snapshot.assertions.sorted(by: { ($0.kind.rawValue, $0.pid) < ($1.kind.rawValue, $1.pid) }) {
            var line = "  [\(kinds[assertion.kind] ?? "")] pid \(assertion.pid) \(assertion.type) “\(assertion.name)”"
            if assertion.count > 1 { line += " ×\(assertion.count)" }
            if assertion.isOnBehalf { line += " 经 \(assertion.holderName)（pid \(assertion.holderPID)）" } else {
                line += " \(assertion.holderName)"
            }
            line += assertion.coalitionID.map { " cid \($0)" } ?? " cid ?"
            if let since = assertion.since { line += " 自 \(since.formatted(date: .omitted, time: .standard))" }
            print(line)
        }
    }
}
