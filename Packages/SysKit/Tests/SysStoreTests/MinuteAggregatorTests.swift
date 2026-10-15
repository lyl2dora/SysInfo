// 分钟聚合（CPU 模块设计 §6、§9）：区间拆分、峰值规则、瞬时量、唤醒丢弃、不可用不入库、每应用前 10。

import Foundation
import Testing
@testable import SysCollectors
import SysModel
@testable import SysStore

/// 测试用的 tick 结果：`wall` 为 Unix 秒，单调时钟与墙钟同步走。
func tick(_ wall: Double, _ collectors: [CollectorID], _ samples: [(MetricID, Double?)]) -> TickResult {
    let time = SampleTime(monotonicNanos: UInt64(wall * 1e9), wallClock: Date(timeIntervalSince1970: wall))
    let status = EngineStatus(
        tickCount: 0, lastTick: nil, nextTick: nil, demands: [], effectiveIntervals: [:], throttle: .normal,
        throttleReasons: [], health: [])
    return TickResult(
        tick: Int64(wall), time: time, collectors: collectors,
        samples: samples.map { id, value in
            value.map { Sample(id: id, value: $0, time: time) } ?? .unavailable(id, reason: .readFailed(), at: time)
        },
        cost: SampleCost(wallNanos: 0, cpuNanos: 0), status: status)
}

let load = CPULoadCollector.collectorID
let sensors = SensorCollector.collectorID

@Suite struct MinuteAggregatorTests {
    /// 基准时刻：某个整分钟（Unix 分钟 29_000_000）。
    let base = 29_000_000.0 * 60

    @Test func firstSampleAfterStartOnlySetsBaseline() {
        var agg = MinuteAggregator()
        agg.ingest(tick(base + 10, [load], [(.cpuUsageTotal, 0.5)]))
        #expect(agg.take(before: nil).rows.isEmpty)
    }

    @Test func intervalSampleIsSplitAcrossMinutesByOverlap() {
        var agg = MinuteAggregator()
        agg.ingest(tick(base + 30, [load], []))  // 建立基线
        // 60 s 窗口 [base+30, base+90]：前一分钟 30 s、后一分钟 30 s
        agg.ingest(tick(base + 90, [load], [(.cpuUsageTotal, 0.4)]))
        let rows = agg.take(before: nil).rows
        #expect(rows.count == 2)
        #expect(rows.map(\.minute) == [29_000_000, 29_000_001])
        #expect(rows.allSatisfy { $0.n == 30 && abs($0.avg - 0.4) < 1e-12 })
        // 60 s 差分没有峰值意义
        #expect(rows.allSatisfy { $0.max == nil })
    }

    @Test func shortWindowsKeepPeakAndWeightedAverage() {
        var agg = MinuteAggregator()
        agg.ingest(tick(base, [load], []))
        for s in 1...60 {
            agg.ingest(tick(base + Double(s), [load], [(.cpuUsageTotal, s == 30 ? 1.0 : 0.1)]))
        }
        let rows = agg.take(before: nil).rows
        #expect(rows.count == 1)
        #expect(rows[0].n == 60)
        #expect(rows[0].max == 1.0)
        #expect(abs(rows[0].avg - (59 * 0.1 + 1.0) / 60) < 1e-12)
    }

    @Test func mixingALongWindowDropsThePeak() {
        var agg = MinuteAggregator()
        agg.ingest(tick(base, [load], []))
        agg.ingest(tick(base + 1, [load], [(.cpuUsageTotal, 0.9)]))
        // 菜单栏关掉，下一次是后台 30 s 后的差分（仍在同一分钟）
        agg.ingest(tick(base + 31, [load], [(.cpuUsageTotal, 0.2)]))
        let rows = agg.take(before: nil).rows
        #expect(rows.count == 1)
        #expect(rows[0].max == nil)
        #expect(rows[0].n == 31)
    }

    @Test func instantMetricGoesToItsMinuteWithCappedWeight() {
        var agg = MinuteAggregator()
        agg.ingest(tick(base + 5, [sensors], []))
        agg.ingest(tick(base + 15, [sensors], [(.cpuTemperatureMax, 50)]))
        agg.ingest(tick(base + 25, [sensors], [(.cpuTemperatureMax, 70)]))
        let rows = agg.take(before: nil).rows
        #expect(rows.count == 1)
        #expect(rows[0].avg == 60)
        #expect(rows[0].max == 70)
        #expect(rows[0].n == 20)
    }

    @Test func unavailableAndUncataloguedSamplesAreSkipped() {
        var agg = MinuteAggregator()
        agg.ingest(tick(base, [load, sensors], []))
        agg.ingest(
            tick(
                base + 10, [load, sensors],
                [(.cpuTemperatureMax, nil), (.cpuUsageCore(0), 0.5), (.cpuUsageTotal, 0.3)]))
        let rows = agg.take(before: nil).rows
        #expect(rows.map(\.metric) == [.cpuUsageTotal])
    }

    @Test func wakeDropsTheFirstSample() {
        var agg = MinuteAggregator()
        agg.ingest(tick(base, [load], []))
        agg.noteWake()
        agg.ingest(tick(base + 3000, [load], [(.cpuUsageTotal, 0.3)]))
        #expect(agg.take(before: nil).rows.isEmpty)
        agg.ingest(tick(base + 3001, [load], [(.cpuUsageTotal, 0.3)]))
        #expect(agg.take(before: nil).rows.count == 1)
    }

    @Test func takeBeforeCutoffKeepsTheOpenMinute() {
        var agg = MinuteAggregator()
        agg.ingest(tick(base, [load], []))
        agg.ingest(tick(base + 50, [load], [(.cpuUsageTotal, 0.3)]))
        agg.ingest(tick(base + 70, [load], [(.cpuUsageTotal, 0.6)]))
        let first = agg.take(before: 29_000_001)
        #expect(first.rows.map(\.minute) == [29_000_000])
        let rest = agg.take(before: nil)
        #expect(rest.rows.map(\.minute) == [29_000_001])
        #expect(rest.rows[0].n == 10)
    }

    @Test func qualityIsTheWorstInTheMinute() {
        var agg = MinuteAggregator()
        agg.add(.cpuUsageTotal, value: 0.1, quality: .measured, seconds: 1, end: Date(timeIntervalSince1970: base + 1), .interval)
        agg.add(.cpuUsageTotal, value: 0.1, quality: .estimated, seconds: 1, end: Date(timeIntervalSince1970: base + 2), .interval)
        #expect(agg.take(before: nil).rows.first?.quality == .estimated)
    }

    @Test func appsMergeByIdentityAndKeepTopTen() {
        var agg = MinuteAggregator()
        let time = SampleTime(monotonicNanos: 1, wallClock: Date(timeIntervalSince1970: base + 20))
        func delta(_ id: UInt64, _ cpu: UInt64) -> CoalitionDelta {
            CoalitionDelta(
                id: id, tasks: 1, cpuNanos: cpu, perfLevel0Nanos: 0, cycles: 0, perfLevel0Cycles: 0,
                energyNanojoules: cpu / 10, membershipChanged: false, isNew: false)
        }
        var identities: [UInt64: AppIdentity] = [:]
        var deltas: [CoalitionDelta] = []
        for id in 1...12 {
            identities[UInt64(id)] = AppIdentity(key: "app\(id)", name: "App \(id)")
            deltas.append(delta(UInt64(id), UInt64(id) * 1_000_000))
        }
        // 第 13 号与 12 号是同一个应用（重启后换了 coalition）
        identities[13] = AppIdentity(key: "app12", name: "App 12")
        deltas.append(delta(13, 500_000))
        agg.ingestApps(AppActivityWindow(time: time, elapsedNanos: 10_000_000_000, coalitions: deltas), identities: identities)
        // 第二个窗口：能耗槽不可信
        agg.ingestApps(
            AppActivityWindow(time: time, elapsedNanos: 10_000_000_000, coalitions: [delta(1, 100)], slotsTrusted: false),
            identities: identities)
        let apps = agg.take(before: nil).apps
        #expect(apps.count == MinuteAggregator.appsPerMinute)
        #expect(apps.first?.app.key == "app12")
        #expect(apps.first?.cpuNanos == 12_500_000)
        #expect(!apps.contains { $0.app.key == "app1" || $0.app.key == "app2" })
        #expect(apps.allSatisfy { $0.energyNanojoules != nil })
    }

    @Test func appEnergyBecomesUnknownWhenAnyWindowIsUntrusted() {
        var agg = MinuteAggregator()
        let time = SampleTime(monotonicNanos: 1, wallClock: Date(timeIntervalSince1970: base + 20))
        let d = CoalitionDelta(
            id: 1, tasks: 1, cpuNanos: 100, perfLevel0Nanos: 0, cycles: 0, perfLevel0Cycles: 0, energyNanojoules: 5,
            membershipChanged: false, isNew: false)
        let id = [UInt64(1): AppIdentity(key: "a", name: "A")]
        agg.ingestApps(AppActivityWindow(time: time, elapsedNanos: 1, coalitions: [d]), identities: id)
        agg.ingestApps(AppActivityWindow(time: time, elapsedNanos: 1, coalitions: [d], slotsTrusted: false), identities: id)
        let apps = agg.take(before: nil).apps
        #expect(apps.count == 1)
        #expect(apps[0].cpuNanos == 200)
        #expect(apps[0].energyNanojoules == nil)
    }

    @Test func nextFlushIsOneMinuteAfterAFiveMinuteBoundary() {
        // base 是分钟 29_000_000（能被 5 整除），提交在 +62 s
        let next = HistoryRecorder.nextFlushDate(after: Date(timeIntervalSince1970: base + 10))
        #expect(next.timeIntervalSince1970 == base + 62)
        let after = HistoryRecorder.nextFlushDate(after: Date(timeIntervalSince1970: base + 62))
        #expect(after.timeIntervalSince1970 == base + 362)
    }
}
