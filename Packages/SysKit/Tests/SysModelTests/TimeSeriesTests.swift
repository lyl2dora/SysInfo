// 内存环形缓冲（M0 设计 §6）。

import Foundation
import Testing
import SysModel

@Suite struct TimeSeriesTests {
    private static let second: UInt64 = 1_000_000_000

    private func point(_ seconds: UInt64, _ value: Double?) -> TimeSeriesPoint {
        TimeSeriesPoint(
            monotonicNanos: seconds * Self.second,
            wallClock: Date(timeIntervalSince1970: Double(seconds)),
            value: value)
    }

    @Test func keepsOnlyRetentionWindow() {
        var series = TimeSeries(retentionSeconds: 10)
        for t in UInt64(1)...30 {
            series.append(point(t, Double(t)))
        }
        // 最新是 30 s，保留 [20, 30]（含边界）
        #expect(series.count == 11)
        #expect(series.points.first?.value == 20)
        #expect(series.last?.value == 30)
    }

    @Test func irregularIntervalsUseTimestampsNotCounts() {
        var series = TimeSeries(retentionSeconds: 10)
        for t: UInt64 in [0, 1, 2, 5, 10, 15] {
            series.append(point(t, 1))
        }
        // 最新 15 s，保留期起点 5 s：5、10、15
        #expect(series.points.map(\.monotonicNanos) == [5, 10, 15].map { $0 * Self.second })
    }

    @Test func rejectsDuplicateAndOutOfOrderPoints() {
        var series = TimeSeries(retentionSeconds: 60)
        let first = series.append(point(5, 1))
        let duplicate = series.append(point(5, 2))
        let older = series.append(point(4, 3))
        #expect(first)
        #expect(!duplicate)
        #expect(!older)
        #expect(series.count == 1)
        #expect(series.last?.value == 1)
    }

    @Test func windowIsRelativeToNewestPoint() {
        var series = TimeSeries(retentionSeconds: 900)
        for t in UInt64(100)...200 {
            series.append(point(t, Double(t)))
        }
        let window = series.points(inLast: 10 * Self.second)
        #expect(window.count == 11)
        #expect(window.first?.value == 190)
        #expect(TimeSeries(retentionSeconds: 5).points(inLast: Self.second).isEmpty)
    }

    @Test func meanSkipsUnavailablePoints() {
        var series = TimeSeries(retentionSeconds: 900)
        series.append(point(1, 0.25))
        series.append(point(2, nil))
        series.append(point(3, 0.75))
        #expect(series.mean(inLast: 60 * Self.second) == 0.5)
        // 窗口只含最后一个点
        #expect(series.mean(inLast: 0) == 0.75)

        var empty = TimeSeries(retentionSeconds: 900)
        empty.append(point(1, nil))
        #expect(empty.mean(inLast: 60 * Self.second) == nil)
    }

    @Test func compactionKeepsContentsIntact() {
        var series = TimeSeries(retentionSeconds: 3)
        for t in UInt64(1)...1000 {
            series.append(point(t, Double(t)))
            #expect(series.count <= 4)
            #expect(series.last?.value == Double(t))
        }
        #expect(series.points.map { $0.value ?? -1 } == [997, 998, 999, 1000])
    }

    @Test func initFromSampleCarriesUnavailability() {
        let time = SampleTime(monotonicNanos: 42, wallClock: Date(timeIntervalSince1970: 1))
        let available = TimeSeriesPoint(Sample(id: .cpuUsageTotal, value: 0.5, time: time))
        let missing = TimeSeriesPoint(.unavailable(.cpuUsageTotal, reason: .readFailed(), at: time))
        #expect(available.value == 0.5)
        #expect(missing.value == nil)
        #expect(missing.monotonicNanos == 42)
    }
}
