// 内存环形缓冲（M0 设计 §6）。

import Foundation
import Testing
import SysModel

@Suite struct TimeSeriesTests {
    private static let second: UInt64 = 1_000_000_000

    private func point(_ seconds: UInt64, _ value: Double?) -> TimeSeriesPoint {
        TimeSeriesPoint(
            continuousNanos: seconds * Self.second,
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
        #expect(series.points.map(\.continuousNanos) == [5, 10, 15].map { $0 * Self.second })
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
        #expect(missing.continuousNanos == 42)
    }

    /// 回归：保留期、「距今多久」要按包含睡眠的连续时钟算。不含睡眠的 uptime 在睡眠前后只差几秒，
    /// 睡了一小时后，睡眠前的点仍会被当成「刚才」留在保留期和窗口里。
    @Test func retentionAndWindowsCountSystemSleep() {
        var series = TimeSeries(retentionSeconds: 900)
        func sample(uptime: UInt64, continuous: UInt64, _ value: Double) -> Sample {
            Sample(
                id: .cpuUsageTotal, value: value,
                time: SampleTime(
                    monotonicNanos: uptime * Self.second, continuousNanos: continuous * Self.second,
                    wallClock: Date(timeIntervalSince1970: Double(continuous))))
        }
        series.append(sample(uptime: 100, continuous: 100, 0.9))
        series.append(sample(uptime: 101, continuous: 101, 0.9))
        // 睡了一小时：uptime 只多了 1 s，连续时钟多了 3600 s
        series.append(sample(uptime: 102, continuous: 3702, 0.1))
        #expect(series.count == 1, "睡眠前的点已超过 15 分钟保留期")
        #expect(series.mean(inLast: 60 * Self.second) == 0.1)
    }

    @Test func segmentsBreakAtUnavailablePointsAndLongGaps() {
        let points = [
            point(1, 0.1), point(2, 0.2),
            point(3, nil),  // 不可用：断开
            point(4, 0.4), point(5, 0.5),
            point(20, 0.6),  // 间隔 15 s > 3 s：断开
            point(22, 0.7),  // 间隔 2 s：连续
        ]
        let segmented = TimeSeries.segmented(points, maxGapNanos: 3 * Self.second)
        #expect(segmented.map(\.value) == [0.1, 0.2, 0.4, 0.5, 0.6, 0.7])
        #expect(segmented.map(\.segment) == [0, 0, 1, 1, 2, 2])
        // 开头的不可用点不产生空段
        let leading = TimeSeries.segmented([point(1, nil), point(2, 0.2)], maxGapNanos: Self.second)
        #expect(leading.map(\.segment) == [0])
    }
}
