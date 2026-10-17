// 网络指标的入库规则与流量总量（网络模块设计 §6，D60 N7）。

import Foundation
import SysCollectors
import SysModel
import Testing
@testable import SysStore

@Suite struct NetworkHistoryTests {
    @Test func physicalAndPrimaryAreRecorded() throws {
        let en0 = try #require(HistoryCatalog.spec(for: .networkInterface("en0", .in)))
        #expect(en0.module == .network)
        #expect(en0.aggregation == .interval)
        #expect(en0.unit == "B/s")
        #expect(en0.collector == NetworkIOCollector.collectorID)
        #expect(HistoryCatalog.spec(for: .networkPrimaryOut)?.module == .network)
        let rtt = try #require(HistoryCatalog.spec(for: .networkLatencyRTT(.custom)))
        #expect(rtt.aggregation == .instant)
        #expect(rtt.unit == "s")
        #expect(HistoryCatalog.spec(for: .networkLatencyLoss(.gateway))?.unit == "ratio")
    }

    @Test func virtualPhysicalTotalAndWiFiAreNotRecorded() {
        #expect(HistoryCatalog.spec(for: .networkVirtualInterface("utun9", .in)) == nil)
        #expect(HistoryCatalog.spec(for: .networkPhysicalIn) == nil)
        #expect(HistoryCatalog.spec(for: .networkWiFiRSSI) == nil)
        #expect(HistoryCatalog.spec(for: .networkWiFiTxRate) == nil)
    }

    private func row(_ minute: Int64, _ metric: MetricID, avg: Double, n: Int64 = 60) -> MinuteRow {
        MinuteRow(minute: minute, metric: metric, avg: avg, max: nil, n: n, quality: .measured)
    }

    @Test func totalIsSumOfAverageTimesCoverage() throws {
        let store = try HistoryStore.inMemory()
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let nowMinute = MinuteAggregator.minute(of: now)
        // 两分钟：1000 B/s × 60 s、500 B/s × 30 s（另 30 s 睡眠留空）。
        try store.write(
            rows: [row(nowMinute - 10, .networkPrimaryIn, avg: 1000), row(nowMinute - 9, .networkPrimaryIn, avg: 500, n: 30)], apps: [])
        #expect(try store.total(.networkPrimaryIn, from: nowMinute - 60, to: nowMinute + 1, now: now) == 60_000 + 15_000)
        // 区间外的分钟不算。
        #expect(try store.total(.networkPrimaryIn, from: nowMinute - 9, to: nowMinute + 1, now: now) == 15_000)
        #expect(try store.total(.networkPrimaryOut, from: nowMinute - 60, to: nowMinute + 1, now: now) == 0)
    }

    @Test func olderThanMinuteRetentionReadsHourTable() throws {
        let store = try HistoryStore.inMemory()
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let nowMinute = MinuteAggregator.minute(of: now)
        // 31 天前的一小时：只在小时表里（分钟已清理）。
        let oldMinute = nowMinute - 31 * 24 * 60
        try store.write(rows: [row(oldMinute, .networkPrimaryIn, avg: 100), row(oldMinute + 1, .networkPrimaryIn, avg: 300)], apps: [])
        try store.rollUpHours(through: HistoryStore.floorDiv(oldMinute, 60))
        try store.prune(before: oldMinute + 60)
        // 最近的一分钟：在分钟表里。
        try store.write(rows: [row(nowMinute - 1, .networkPrimaryIn, avg: 10)], apps: [])
        let total = try store.total(.networkPrimaryIn, from: nowMinute - 40 * 24 * 60, to: nowMinute + 1, now: now)
        #expect(total == 100 * 60 + 300 * 60 + 10 * 60)
    }
}
