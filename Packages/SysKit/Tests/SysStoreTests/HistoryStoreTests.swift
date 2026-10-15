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

    @Test func checkpointWorksAfterStatsOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sysstore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(url: dir.appendingPathComponent("History.sqlite"))
        try store.write(rows: [row(1, avg: 0.5, max: 0.5)], apps: [])
        _ = try store.stats()  // 读页数等 PRAGMA
        try store.checkpoint()  // 不能因为上面留着的读语句报 SQLITE_LOCKED
    }
}
