// 历史库（CPU 模块设计 §6、§9）：UPSERT 合并、小时汇总、保留期清理、epoch、降采样读取、导出格式。

import Foundation
import Testing
import SysCollectors
import SysModel
@testable import SysStore

@Suite struct HistoryStoreTests {
    func row(_ minute: Int64, _ metric: MetricID = .cpuUsageTotal, avg: Double, max: Double?, n: Int64 = 60,
             q: HistoryQuality = .measured) -> MinuteRow {
        MinuteRow(minute: minute, metric: metric, avg: avg, max: max, n: n, quality: q)
    }

    func epoch(_ start: Int64, build: String = "26A1") -> HistoryEpoch {
        HistoryEpoch(startMinute: start, model: "Mac0,0", chip: "AppleT0000PMGR", osBuild: build, topologyJSON: "{}")
    }

    @Test func schemaIsCreatedWithVersion() throws {
        let store = try HistoryStore.inMemory()
        #expect(try store.db.pragmaInt("user_version") == HistoryStore.schemaVersion)
        #expect(try store.stats().minuteRows == 0)
    }

    @Test func upsertMergesByWeightAndKeepsNullPeak() throws {
        let store = try HistoryStore.inMemory()
        try store.write(rows: [row(100, avg: 0.2, max: 0.5, n: 30)], apps: [])
        try store.write(rows: [row(100, avg: 0.8, max: 0.9, n: 10, q: .estimated)], apps: [])
        var points = try store.series(.cpuUsageTotal, from: 100, to: 101, granularity: .minute)
        #expect(points.count == 1)
        #expect(abs(points[0].avg - (0.2 * 30 + 0.8 * 10) / 40) < 1e-12)
        #expect(points[0].max == 0.9)
        #expect(points[0].n == 40)
        #expect(points[0].quality == .estimated)
        // 混进没有峰值的部分后，峰值为空
        try store.write(rows: [row(100, avg: 0.5, max: nil, n: 20)], apps: [])
        points = try store.series(.cpuUsageTotal, from: 100, to: 101, granularity: .minute)
        #expect(points[0].max == nil)
        #expect(points[0].n == 60)
    }

    @Test func hourRollupIsWeightedAndIdempotent() throws {
        let store = try HistoryStore.inMemory()
        // 第 10 小时：两分钟，一分钟 n=60 avg 0.1，一分钟 n=30 avg 0.4
        try store.write(rows: [row(600, avg: 0.1, max: 0.2), row(601, avg: 0.4, max: 0.6, n: 30)], apps: [])
        try store.rollUpHours(through: 10)
        var hours = try store.series(.cpuUsageTotal, from: 600, to: 660, granularity: .hour)
        #expect(hours.count == 1)
        #expect(hours[0].minute == 600)
        #expect(abs(hours[0].avg - (0.1 * 60 + 0.4 * 30) / 90) < 1e-12)
        #expect(hours[0].max == 0.6)
        #expect(hours[0].n == 90)
        // 迟到的一分钟：重算最后一个小时，不重复累加
        try store.write(rows: [row(602, avg: 0.0, max: nil, n: 60)], apps: [])
        try store.rollUpHours(through: 10)
        hours = try store.series(.cpuUsageTotal, from: 600, to: 660, granularity: .hour)
        #expect(hours.count == 1)
        #expect(hours[0].n == 150)
        #expect(hours[0].max == nil)
    }

    @Test func pruneRemovesOldMinutesAndOrphanAppsButKeepsHours() throws {
        let store = try HistoryStore.inMemory()
        let app = AppIdentity(key: "com.example.a", name: "A")
        try store.write(
            rows: [row(60, avg: 0.1, max: nil), row(6000, avg: 0.2, max: nil)],
            apps: [AppMinuteRow(minute: 60, app: app, cpuNanos: 5, energyNanojoules: nil)])
        try store.rollUpHours(through: 100)
        try store.prune(before: 1000)
        let stats = try store.stats()
        #expect(stats.minuteRows == 1)
        #expect(stats.appRows == 0)
        #expect(stats.appCount == 0)
        #expect(stats.hourRows == 2)
        // 应用被清掉后再写，能重新登记
        try store.write(rows: [], apps: [AppMinuteRow(minute: 6000, app: app, cpuNanos: 7, energyNanojoules: 1)])
        #expect(try store.topApps(from: 0, to: 10_000, limit: 5).first?.cpuNanos == 7)
    }

    @Test func appUpsertSumsAndRenames() throws {
        let store = try HistoryStore.inMemory()
        try store.write(rows: [], apps: [AppMinuteRow(minute: 5, app: .init(key: "k", name: "Old"), cpuNanos: 10, energyNanojoules: 3)])
        try store.write(rows: [], apps: [AppMinuteRow(minute: 5, app: .init(key: "k", name: "New"), cpuNanos: 5, energyNanojoules: nil)])
        let rows = try store.appRows(from: 0, to: 10)
        #expect(rows.count == 1)
        #expect(rows[0].cpuNanos == 15)
        #expect(rows[0].energy == nil)
        #expect(rows[0].name == "New")
        try store.clearAppData()
        #expect(try store.appRows(from: 0, to: 10).isEmpty)
    }

    @Test func appTotalsSumColumnsAndTakePeakFootprint() throws {
        let store = try HistoryStore.inMemory()
        let a = AppIdentity(key: "a", name: "A")
        try store.write(
            rows: [],
            apps: [
                AppMinuteRow(
                    minute: 1, app: a, cpuNanos: 60_000_000_000, energyNanojoules: 1_000_000_000, gpuNanos: 5, gpuEnergyNanojoules: 2_000_000_000,
                    aneEnergyNanojoules: 0, diskReadBytes: 10, diskWrittenBytes: 20, wakeups: 3, footprintBytes: 100),
                AppMinuteRow(minute: 2, app: a, cpuNanos: 0, energyNanojoules: 0, wakeups: 4, footprintBytes: 300),
            ])
        let total = try #require(try store.appTotals(from: 0, to: 10).first)
        #expect(total.cpuNanos == 60_000_000_000)
        #expect(total.energyNanojoules == 3_000_000_000)
        #expect(total.wakeups == 7)
        #expect(total.footprintPeak == 300)
        #expect(total.minutes == 2)
        let series = try store.appSeries(key: "a", from: 0, to: 10, bucketMinutes: 1)
        #expect(series.first?.cpu == 1)
        #expect(abs((series.first?.watts ?? 0) - 0.05) < 1e-9)  // 3 J ÷ 60 s
    }

    @Test func unknownAuxiliaryColumnsStayUnknownAndMarkTotalsPartial() throws {
        let store = try HistoryStore.inMemory()
        let a = AppIdentity(key: "a", name: "A")
        let known = AppMinuteRow(
            minute: 1, app: a, cpuNanos: 60_000_000_000, energyNanojoules: 1_000_000_000, gpuNanos: 5,
            gpuEnergyNanojoules: 2_000_000_000, aneEnergyNanojoules: 1, diskReadBytes: 10, diskWrittenBytes: 20, wakeups: 3,
            footprintBytes: 100)
        // 第 2 分钟 S4 不过：CPU、GPU、ANE 能耗与 GPU 时间都为空（D96）
        let untrusted = AppMinuteRow(
            minute: 2, app: a, cpuNanos: 60_000_000_000, energyNanojoules: nil, gpuNanos: nil, gpuEnergyNanojoules: nil,
            aneEnergyNanojoules: nil, diskReadBytes: 1, diskWrittenBytes: 2, wakeups: 4, footprintBytes: 300)
        try store.write(rows: [], apps: [known, untrusted])
        // 同一分钟再合并一份已知的：空值不被当成 0 加回来（D98）
        try store.write(rows: [], apps: [AppMinuteRow(minute: 2, app: a, cpuNanos: 1, energyNanojoules: 1, gpuNanos: 7)])
        let total = try #require(try store.appTotals(from: 0, to: 10).first)
        #expect(total.gpuNanos == 5)
        #expect(total.aneEnergyNanojoules == 1)
        #expect(total.energyNanojoules == 3_000_000_001)
        #expect(!total.energyComplete)
        #expect(total.partial == [.gpuTime, .ane])
        #expect(total.wakeups == 7)
        let series = try store.appSeries(key: "a", from: 0, to: 10, bucketMinutes: 1)
        #expect(series.count == 2)
        #expect(series[0].watts != nil)
        #expect(series[1].watts == nil)
        // 只有空值的时段：显示「—」而不是 0
        let onlyUnknown = try #require(try store.appTotals(from: 2, to: 3).first)
        #expect(onlyUnknown.gpuNanos == nil)
        #expect(onlyUnknown.energyNanojoules == nil)
        #expect(onlyUnknown.partial.isEmpty)
        let row = total.row(appPath: nil, isApp: false)
        #expect(row.historyPartial == [.gpuTime, .ane])
        #expect(row.energyPartial)
    }

    @Test func assertionSpansOpenCloseAndReopen() throws {
        let store = try HistoryStore.inMemory()
        let app = AppIdentity(key: "com.example.vm", name: "VM")
        let start = Date(timeIntervalSince1970: 1_000_000)
        let id = try store.openAssertion(app: app, type: "PreventUserIdleSystemSleep", name: "VM running", holder: "", start: start)
        #expect(try store.assertionSpans(from: start, to: start.addingTimeInterval(10)).first?.end == nil)
        // 退出时还开着：按退出时刻收尾，标「估计」
        try store.closeOpenAssertions(end: start.addingTimeInterval(60))
        var span = try #require(try store.assertionSpans(from: start, to: start.addingTimeInterval(120)).first)
        #expect(span.endEstimated)
        // 重启后同一条断言还在：重新打开同一行
        let again = try store.openAssertion(app: app, type: "PreventUserIdleSystemSleep", name: "VM running", holder: "", start: start)
        #expect(again == id)
        try store.closeAssertion(id: again, end: start.addingTimeInterval(300))
        span = try #require(try store.assertionSpans(from: start, to: start.addingTimeInterval(400)).first)
        #expect(!span.endEstimated)
        #expect(span.seconds(from: start, to: start.addingTimeInterval(400), now: Date()) == 300)
        #expect(span.kind == .preventSleep)
        // 过期清理按结束时刻
        try store.prune(before: Int64(start.timeIntervalSince1970 / 60) + 10)
        #expect(try store.assertionSpans(from: start, to: start.addingTimeInterval(400)).isEmpty)
    }

    @Test func epochOpensOnlyWhenTheMachineChanges() throws {
        let store = try HistoryStore.inMemory()
        #expect(try store.recordEpoch(epoch(10)))
        #expect(try !store.recordEpoch(epoch(20)))
        #expect(try store.recordEpoch(epoch(30, build: "26A2")))
        #expect(try store.epochs().map(\.startMinute) == [10, 30])
    }

    @Test func seriesDownsamplesIntoBucketsAndLeavesGaps() throws {
        let store = try HistoryStore.inMemory()
        try store.write(
            rows: [row(0, avg: 0.1, max: 0.1), row(1, avg: 0.3, max: 0.5), row(10, avg: 0.9, max: 0.9)], apps: [])
        let points = try store.series(.cpuUsageTotal, from: 0, to: 20, granularity: .minute, bucketMinutes: 5)
        #expect(points.map(\.minute) == [0, 10])
        #expect(abs(points[0].avg - 0.2) < 1e-12)
        #expect(points[0].max == 0.5)
    }

    @Test func storeSurvivesReopenOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sysstore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("History.sqlite")
        do {
            let store = try HistoryStore(url: url)
            try store.write(rows: [row(1, avg: 0.5, max: 0.5)], apps: [])
            try store.recordEpoch(epoch(1))
        }
        let reopened = try HistoryStore(url: url)
        #expect(try reopened.series(.cpuUsageTotal, from: 0, to: 5, granularity: .minute).count == 1)
        #expect(try !reopened.recordEpoch(epoch(2)))
        #expect(try reopened.db.pragmaInt("auto_vacuum") == 2)  // INCREMENTAL
    }

    @Test func csvExportIsWideWithEmptyCellsForGaps() throws {
        let store = try HistoryStore.inMemory()
        try store.write(
            rows: [
                row(29_000_000, avg: 0.25, max: 0.5), row(29_000_000, .cpuTemperatureMax, avg: 60, max: 61),
                row(29_000_001, .cpuTemperatureMax, avg: 62, max: nil),
            ],
            apps: [AppMinuteRow(minute: 29_000_000, app: .init(key: "a,b", name: "A \"x\""), cpuNanos: 30_000_000_000, energyNanojoules: 2_000_000_000)])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sysexport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try HistoryExporter.export(
            store,
            options: HistoryExportOptions(
                from: Date(timeIntervalSince1970: 29_000_000 * 60), to: Date(timeIntervalSince1970: 29_000_001 * 60),
                appVersion: "test"),
            to: dir)
        #expect(files.map(\.lastPathComponent) == ["system.csv", "apps.csv", "metadata.json"])
        let system = try String(contentsOf: files[0], encoding: .utf8).split(separator: "\n")
        #expect(system[0] == "time,cpu.temp.max.avg,cpu.temp.max.max,cpu.usage.total.avg,cpu.usage.total.max")
        #expect(system[1].hasSuffix(",60,61,0.25,0.5"))
        #expect(system[2].hasSuffix(",62,,,"))
        let apps = try String(contentsOf: files[1], encoding: .utf8).split(separator: "\n")
        #expect(apps[1].contains("\"a,b\",\"A \"\"x\"\"\",30000000000,0.5,2"))
        let meta = try String(contentsOf: files[2], encoding: .utf8)
        #expect(meta.contains("\"appVersion\" : \"test\""))
    }

    @Test func jsonLinesStartWithMetadata() throws {
        let store = try HistoryStore.inMemory()
        try store.write(rows: [row(29_000_000, avg: 0.25, max: nil)], apps: [])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sysexport-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try HistoryExporter.export(
            store,
            options: HistoryExportOptions(
                from: Date(timeIntervalSince1970: 29_000_000 * 60), to: Date(timeIntervalSince1970: 29_000_000 * 60),
                format: .jsonLines, appVersion: "test"),
            to: file)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("\"type\":\"metadata\""))
        #expect(lines[1].contains("\"metric\":\"cpu.usage.total\""))
        #expect(!lines[1].contains("\"max\""))
    }

    @Test func failedWriteRollsBackEverythingIncludingIDCache() throws {
        let store = try HistoryStore.inMemory()
        try store.db.execute("DROP TABLE energy_minute")  // 让同一事务后半段的能耗写入失败
        #expect(throws: (any Error).self) {
            try store.write(
                rows: [row(10, .cpuUsageTotal, avg: 0.1, max: nil)], apps: [],
                energy: [EnergyMinuteRow(minute: 10, joules: 1, covered: 1)])
        }
        #expect(try store.stats().minuteRows == 0)  // 分钟数据随事务一起回滚
        // 回滚后 rowid 会被下一个新指标复用；缓存若没退回，两个指标会共用一行。
        try store.write(rows: [row(20, .cpuUsageUser, avg: 0.7, max: nil)], apps: [])
        try store.write(rows: [row(30, .cpuUsageTotal, avg: 0.3, max: nil)], apps: [])
        let total = try store.series(.cpuUsageTotal, from: 0, to: 100, granularity: .minute)
        let user = try store.series(.cpuUsageUser, from: 0, to: 100, granularity: .minute)
        #expect(total.map(\.avg) == [0.3])
        #expect(user.map(\.avg) == [0.7])
    }

    @Test func checkpointWorksAfterStatsOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sysstore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(url: dir.appendingPathComponent("History.sqlite"))
        try store.write(rows: [row(1, avg: 0.5, max: 0.5)], apps: [])
        _ = try store.stats()  // 读页数等 PRAGMA
        try store.checkpoint()  // 不能因为上面留着的读语句报 SQLITE_LOCKED
    }

    @Test func stepErrorResetsTheStatement() throws {
        // 第二行在 step 时出错（整数溢出）：语句要复位，不能留着读事务（A36）。
        let store = try HistoryStore.inMemory()
        try store.write(rows: [row(1, avg: 0.5, max: nil), row(2, avg: 0.5, max: nil)], apps: [])
        let sql = "SELECT CASE WHEN t = 2 THEN abs(-9223372036854775807 - 1) ELSE t END FROM sample_minute ORDER BY t"
        #expect(throws: SQLiteError.self) { try store.db.statement(sql).query { $0.int(0) } }
        #expect(!store.db.hasActiveStatement)
    }

    @Test func backdatedMinutesRecomputeTheirHour() throws {
        // 墙钟回拨：第 10 小时已汇总后，又写进第 9、10 小时的分钟（D103）。
        let store = try HistoryStore.inMemory()
        try store.write(rows: [row(540, avg: 0.1, max: nil), row(600, avg: 0.1, max: nil)], apps: [])
        try store.rollUpHours(through: 10)
        try store.write(rows: [row(541, avg: 0.5, max: nil), row(601, avg: 0.5, max: nil)], apps: [])
        try store.rollUpHours(through: 10)
        let hours = try store.series(.cpuUsageTotal, from: 540, to: 660, granularity: .hour)
        #expect(hours.map(\.n) == [120, 120])
        #expect(hours.allSatisfy { abs($0.avg - 0.3) < 1e-12 })
    }

    @Test func rollUpStartSkipsHoursOlderThanMinuteRetention() {
        let retentionHours = Int64(HistoryStore.minuteRetention / 3600)
        #expect(HistoryStore.rollUpStart(last: 100, dirty: nil, through: 100) == 100)
        #expect(HistoryStore.rollUpStart(last: 1000, dirty: 990, through: 1000) == 990)
        #expect(HistoryStore.rollUpStart(last: 1000, dirty: 1001, through: 1000) == 1000)
        // 太早的小时分钟已被清理：最早只到保留期内第一个完整小时
        #expect(HistoryStore.rollUpStart(last: 1000, dirty: 0, through: 1000) == 1000 + 2 - retentionHours)
        #expect(HistoryStore.rollUpStart(last: nil, dirty: 5, through: 10) == 5)
    }

    @Test func removeFutureDropsRowsAndClosesSpans() throws {
        // 墙钟曾跳到第 100 小时，现在回到第 10 小时（分钟 600–659）（D103）。
        let store = try HistoryStore.inMemory()
        let app = AppIdentity(key: "com.example.a", name: "A")
        try store.write(
            rows: [row(600, avg: 0.1, max: nil), row(6000, avg: 0.9, max: nil)],
            apps: [AppMinuteRow(minute: 6000, app: app, cpuNanos: 5, energyNanojoules: nil)],
            energy: [EnergyMinuteRow(minute: 6000, joules: 1, covered: 60)])
        try store.rollUpHours(through: 100)
        try store.rollUpEnergyHours(through: 100)
        let now = Date(timeIntervalSince1970: 610 * 60)
        let past = try store.openAssertion(app: app, type: "PreventUserIdleSystemSleep", name: "a", holder: "", start: Date(timeIntervalSince1970: 590 * 60))
        try store.closeAssertion(id: past, end: Date(timeIntervalSince1970: 6000 * 60))
        _ = try store.openAssertion(app: app, type: "PreventUserIdleSystemSleep", name: "b", holder: "", start: Date(timeIntervalSince1970: 6000 * 60))
        let spans = try store.removeFuture(afterMinute: 615, afterHour: 10, now: now)
        #expect(spans == 2)
        let stats = try store.stats()
        #expect(stats.minuteRows == 1)
        #expect(stats.appRows == 0)
        #expect(try store.series(.cpuUsageTotal, from: 0, to: 10_000, granularity: .hour).map(\.minute) == [600])
        #expect(try store.energyHours(from: 0, to: 1000).isEmpty)
        let left = try store.assertionSpans(from: .distantPast, to: .distantFuture)
        #expect(left.count == 1)
        #expect(left.first?.end == now)
        #expect(left.first?.endEstimated == true)
        // 汇总不再卡在未来的小时
        try store.write(rows: [row(660, avg: 0.2, max: nil)], apps: [])
        try store.rollUpHours(through: 11)
        #expect(try store.series(.cpuUsageTotal, from: 0, to: 10_000, granularity: .hour).map(\.minute) == [600, 660])
    }
}
