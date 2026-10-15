// 内存里的分钟聚合（CPU 模块设计 §6 MinuteAggregator，D30）。纯值类型，便于单测；由 HistoryRecorder 持有。
//
// - 分钟按 UTC Unix 分钟计（墙钟秒数 / 60 向下取整）；
// - 样本覆盖的区间 = 距同一采集器上一次运行的单调时钟差。采集器刚建立基线时不出样本，但仍算一次运行，
//   所以下一个样本的区间就是它真正的差分区间。唤醒后不知道上一次运行在睡眠前多久，清空记录，丢弃第一个样本；
// - 区间量按墙钟拆到所跨的分钟，瞬时量整份记到所在分钟（见 HistoryCatalog）；
// - 不可用的样本不入库（空洞，图表断开）；
// - 每应用：窗口的增量整份记到窗口结束所在的分钟，按应用身份合并；写库时每分钟只取 CPU 前 10。

import Foundation
import SysCollectors
import SysModel

/// 一行分钟数据（写库前）。
public struct MinuteRow: Hashable, Sendable {
    public var minute: Int64
    public var metric: MetricID
    public var avg: Double
    /// 峰值；区间量混进了长区间样本时为 nil。
    public var max: Double?
    /// 覆盖秒数，至少为 1。
    public var n: Int64
    public var quality: HistoryQuality
}

/// 一个应用在一分钟里的用量（写库前）。
public struct AppMinuteRow: Hashable, Sendable {
    public var minute: Int64
    public var app: AppIdentity
    public var cpuNanos: UInt64
    /// 能耗；这一分钟里有窗口的能耗槽不可信时为 nil。
    public var energyNanojoules: UInt64?
}

public struct MinuteAggregator: Sendable {
    /// 每应用每分钟保留的行数（D30）。
    public static let appsPerMinute = 10
    /// 区间长于这个值的样本视为异常（漏掉了基线复位），丢弃，秒。
    static let maxIntervalSeconds: Double = 3600
    /// 瞬时量的覆盖秒数上限：它只记在一个分钟里。
    static let maxInstantWeight: Double = 60

    private struct Key: Hashable {
        var minute: Int64
        var metric: MetricID
    }

    private struct Bucket {
        var weightedSum = 0.0
        var weight = 0.0
        var max: Double?
        var peakValid = true
        var quality = HistoryQuality.measured
    }

    private struct AppBucket {
        var name: String
        var cpuNanos: UInt64 = 0
        var energyNanojoules: UInt64 = 0
        var energyValid = true
    }

    private var buckets: [Key: Bucket] = [:]
    private var apps: [Int64: [String: AppBucket]] = [:]
    private var lastRun: [CollectorID: SampleTime] = [:]

    public init() {}

    public var isEmpty: Bool { buckets.isEmpty && apps.isEmpty }

    static func minute(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / 60).rounded(.down))
    }

    // MARK: - 写入

    /// 吃一个 tick 结果：入库的样本按区间记账，并更新本结果里跑过的采集器的运行时刻。
    public mutating func ingest(_ result: TickResult, modules: Set<HistoryModule> = Set(HistoryModule.allCases)) {
        for sample in result.samples {
            guard let spec = HistoryCatalog.spec(for: sample.id), modules.contains(spec.module), let value = sample.value,
                let quality = HistoryQuality(sample.quality), value.isFinite,
                let previous = lastRun[spec.collector], result.time.monotonicNanos > previous.monotonicNanos
            else { continue }
            let seconds = Double(result.time.monotonicNanos - previous.monotonicNanos) / 1e9
            add(sample.id, value: value, quality: quality, seconds: seconds, end: result.time.wallClock, spec.aggregation)
        }
        for collector in result.collectors {
            lastRun[collector] = result.time
        }
    }

    /// 记一个样本：`seconds` 是它覆盖的区间长度，`end` 是区间结束的墙钟时刻。
    mutating func add(
        _ metric: MetricID, value: Double, quality: HistoryQuality, seconds: Double, end: Date,
        _ aggregation: HistoryAggregation
    ) {
        guard seconds > 0, seconds <= Self.maxIntervalSeconds else { return }
        switch aggregation {
        case .instant:
            let weight = min(seconds, Self.maxInstantWeight)
            update(Key(minute: Self.minute(of: end), metric: metric)) {
                $0.weightedSum += value * weight
                $0.weight += weight
                $0.max = Swift.max($0.max ?? value, value)
                $0.quality = Swift.max($0.quality, quality)
            }
        case .interval:
            let endSeconds = end.timeIntervalSince1970
            let startSeconds = endSeconds - seconds
            let hasPeak = seconds <= HistoryCatalog.peakWindowLimit
            var minute = Int64((startSeconds / 60).rounded(.down))
            while Double(minute) * 60 < endSeconds {
                let overlap = min(endSeconds, Double(minute + 1) * 60) - Swift.max(startSeconds, Double(minute) * 60)
                if overlap > 0 {
                    update(Key(minute: minute, metric: metric)) {
                        $0.weightedSum += value * overlap
                        $0.weight += overlap
                        if hasPeak {
                            $0.max = Swift.max($0.max ?? value, value)
                        } else {
                            $0.peakValid = false
                        }
                        $0.quality = Swift.max($0.quality, quality)
                    }
                }
                minute += 1
            }
        }
    }

    private mutating func update(_ key: Key, _ body: (inout Bucket) -> Void) {
        body(&buckets[key, default: Bucket()])
    }

    /// 吃一个应用活动窗口。`identities` 里没有的 coalition（已退出、解析不到）不记。
    public mutating func ingestApps(_ window: AppActivityWindow, identities: [UInt64: AppIdentity]) {
        let minute = Self.minute(of: window.time.wallClock)
        var perMinute = apps[minute, default: [:]]
        for delta in window.coalitions where delta.cpuNanos > 0 {
            guard let identity = identities[delta.id] else { continue }
            var bucket = perMinute[identity.key, default: AppBucket(name: identity.name)]
            bucket.name = identity.name
            bucket.cpuNanos &+= delta.cpuNanos
            if window.slotsTrusted {
                bucket.energyNanojoules &+= delta.energyNanojoules
            } else {
                bucket.energyValid = false
            }
            perMinute[identity.key] = bucket
        }
        apps[minute] = perMinute
    }

    /// 唤醒：不知道各采集器上一次运行离现在多久，下一个样本丢弃。
    public mutating func noteWake() {
        lastRun = [:]
    }

    /// 清除尚未写库的每应用数据（「一键清除每应用数据」）。
    public mutating func clearApps() {
        apps = [:]
    }

    // MARK: - 取出

    /// 取走分钟号小于 `cutoff` 的全部数据；`cutoff` 为 nil 时全部取走（睡眠、退出、导出前）。
    public mutating func take(before cutoff: Int64?) -> (rows: [MinuteRow], apps: [AppMinuteRow]) {
        var rows: [MinuteRow] = []
        for (key, bucket) in buckets where cutoff.map({ key.minute < $0 }) ?? true {
            buckets[key] = nil
            guard bucket.weight > 0 else { continue }
            rows.append(
                MinuteRow(
                    minute: key.minute, metric: key.metric, avg: bucket.weightedSum / bucket.weight,
                    max: bucket.peakValid ? bucket.max : nil, n: Swift.max(1, Int64(bucket.weight.rounded())),
                    quality: bucket.quality))
        }
        rows.sort { ($0.minute, $0.metric) < ($1.minute, $1.metric) }

        var appRows: [AppMinuteRow] = []
        for (minute, perMinute) in apps where cutoff.map({ minute < $0 }) ?? true {
            apps[minute] = nil
            let top = perMinute.sorted { $0.value.cpuNanos > $1.value.cpuNanos }.prefix(Self.appsPerMinute)
            for (key, bucket) in top {
                appRows.append(
                    AppMinuteRow(
                        minute: minute, app: AppIdentity(key: key, name: bucket.name), cpuNanos: bucket.cpuNanos,
                        energyNanojoules: bucket.energyValid ? bucket.energyNanojoules : nil))
            }
        }
        appRows.sort { ($0.minute, $1.cpuNanos) < ($1.minute, $0.cpuNanos) }
        return (rows, appRows)
    }
}
