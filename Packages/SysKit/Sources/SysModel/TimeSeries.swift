// 内存时间序列（M0 设计 §6 MetricStore）：面板图表和诊断页的「1 分钟均值」都从这里读。

import Foundation

/// 时间序列中的一个点。
public struct TimeSeriesPoint: Sendable, Hashable {
    /// 单调时钟，纳秒（与 `SampleTime.monotonicNanos` 同源），用于保留期和图表的相对时间轴。
    public var monotonicNanos: UInt64
    /// 墙钟时间。
    public var wallClock: Date
    /// 取值；nil 表示这一刻不可用（图表上画成断点，不画成 0）。
    public var value: Double?

    public init(monotonicNanos: UInt64, wallClock: Date, value: Double?) {
        self.monotonicNanos = monotonicNanos
        self.wallClock = wallClock
        self.value = value
    }

    public init(_ sample: Sample) {
        self.init(monotonicNanos: sample.time.monotonicNanos, wallClock: sample.time.wallClock, value: sample.value)
    }
}

/// 一个指标的内存环形缓冲。
///
/// - 按「时间戳 + 值」逐条追加，不假设采样间隔固定（间隔会随设置和降频变化）；
/// - 只保留最近 `retentionNanos` 内的点，按单调时钟计算，不受改系统时间影响；
/// - 追加是均摊 O(1)：过期的点先只移动起点，过期部分超过一半时再整体压缩。
public struct TimeSeries: Sendable {
    public let retentionNanos: UInt64

    private var storage: [TimeSeriesPoint] = []
    /// 第一个仍在保留期内的点在 `storage` 中的下标。
    private var start = 0

    public init(retentionNanos: UInt64) {
        self.retentionNanos = retentionNanos
    }

    /// - Parameter seconds: 保留时长，秒。
    public init(retentionSeconds seconds: Double) {
        self.init(retentionNanos: UInt64(max(seconds, 0) * 1e9))
    }

    public var count: Int { storage.count - start }
    public var isEmpty: Bool { count == 0 }

    /// 最新的点。
    public var last: TimeSeriesPoint? { isEmpty ? nil : storage.last }

    /// 保留期内的全部点，按时间先后。
    public var points: ArraySlice<TimeSeriesPoint> { storage[start...] }

    /// 追加一个点。时间不晚于上一个点的（重复或乱序）会被忽略，返回 false。
    @discardableResult
    public mutating func append(_ point: TimeSeriesPoint) -> Bool {
        if let last, point.monotonicNanos <= last.monotonicNanos { return false }
        storage.append(point)
        prune(now: point.monotonicNanos)
        return true
    }

    @discardableResult
    public mutating func append(_ sample: Sample) -> Bool {
        append(TimeSeriesPoint(sample))
    }

    /// 以最新的点为「现在」，最近 `windowNanos` 内（含边界）的点。
    public func points(inLast windowNanos: UInt64) -> ArraySlice<TimeSeriesPoint> {
        guard let last else { return storage[storage.count...] }
        let cutoff = last.monotonicNanos >= windowNanos ? last.monotonicNanos - windowNanos : 0
        return storage[firstIndex(atOrAfter: cutoff)...]
    }

    /// 最近 `windowNanos` 内可用值的算术平均；没有可用值时为 nil（不当成 0）。
    public func mean(inLast windowNanos: UInt64) -> Double? {
        var sum = 0.0
        var n = 0
        for point in points(inLast: windowNanos) {
            guard let value = point.value else { continue }
            sum += value
            n += 1
        }
        return n > 0 ? sum / Double(n) : nil
    }

    private mutating func prune(now: UInt64) {
        let cutoff = now >= retentionNanos ? now - retentionNanos : 0
        start = firstIndex(atOrAfter: cutoff)
        if start > 0, start * 2 >= storage.count {
            storage.removeFirst(start)
            start = 0
        }
    }

    /// `storage[start...]` 中第一个时间不早于 `time` 的下标（二分查找）；都更早时返回 `storage.count`。
    private func firstIndex(atOrAfter time: UInt64) -> Int {
        var low = start
        var high = storage.count
        while low < high {
            let mid = (low + high) / 2
            if storage[mid].monotonicNanos < time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
