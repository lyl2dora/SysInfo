// 内存里的分钟聚合（CPU 模块设计 §6 MinuteAggregator，D30）。纯值类型，便于单测；由 HistoryRecorder 持有。
//
// - 分钟按 UTC Unix 分钟计（墙钟秒数 / 60 向下取整）；
// - 样本覆盖的区间 = 距同一采集器上一次运行的单调时钟差。采集器刚建立基线时不出样本，但仍算一次运行，
//   所以下一个样本的区间就是它真正的差分区间。唤醒后不知道上一次运行在睡眠前多久，清空记录，丢弃第一个样本；
// - 区间量按墙钟拆到所跨的分钟，瞬时量整份记到所在分钟（见 HistoryCatalog）；
// - 不可用的样本不入库（空洞，图表断开）；
// - 每应用：窗口的增量整份记到窗口结束所在的分钟，按应用身份合并；写库时每分钟取「各列前 10 的并集」，
//   另写一行「其余合计」（D68）。解析不到身份的 coalition（已退出、不在解析范围）直接记进「其余」，
//   所以各列的整机总量可以从表里还原。footprint 是存量：同一窗口里同一应用的几个 coalition 相加，跨窗口取最大。

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
    /// CPU 能耗（槽位 11）；这一分钟里有窗口的能耗槽不可信时为 nil。
    public var energyNanojoules: UInt64?
    /// GPU 时间（纳秒）、GPU 能耗、ANE 能耗（nJ）（D68）；与 CPU 能耗一样，辅助槽不可信时为 nil（D96、D98）。
    public var gpuNanos: UInt64? = 0
    public var gpuEnergyNanojoules: UInt64? = 0
    public var aneEnergyNanojoules: UInt64? = 0
    /// 磁盘读 / 写（字节）、唤醒次数、footprint 峰值（字节）（D68）。
    public var diskReadBytes: UInt64 = 0
    public var diskWrittenBytes: UInt64 = 0
    public var wakeups: UInt64 = 0
    public var footprintBytes: UInt64 = 0

    /// CPU + GPU + ANE 能耗，只算已知部分（选前 10 用）。
    var totalEnergy: UInt64 { (energyNanojoules ?? 0) &+ (gpuEnergyNanojoules ?? 0) &+ (aneEnergyNanojoules ?? 0) }
}

extension AppIdentity {
    /// 每分钟「其余合计」行的身份（D68）。界面按键显示本地化的「其余」。
    public static let other = AppIdentity(key: "__other__", name: "其余")
}

public struct MinuteAggregator: Sendable {
    /// 每应用每分钟按各列各取前几名（D68：各列前 10 的并集）。
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
        var gpuNanos: UInt64 = 0
        var gpuEnergyNanojoules: UInt64 = 0
        var aneEnergyNanojoules: UInt64 = 0
        var diskReadBytes: UInt64 = 0
        var diskWrittenBytes: UInt64 = 0
        var wakeups: UInt64 = 0
        var footprintMax: UInt64 = 0
        /// 当前窗口（按单调时钟区分）里已累加的 footprint。
        var footprintWindow: UInt64 = 0
        var footprintWindowTime: UInt64?

        mutating func add(_ delta: CoalitionDelta, trusted: Bool, window: UInt64) {
            cpuNanos &+= delta.cpuNanos
            if trusted { energyNanojoules &+= delta.energyNanojoules } else { energyValid = false }
            gpuNanos &+= delta.gpuNanos
            gpuEnergyNanojoules &+= delta.gpuEnergyNanojoules
            aneEnergyNanojoules &+= delta.aneEnergyNanojoules
            diskReadBytes &+= delta.diskReadBytes
            diskWrittenBytes &+= delta.diskWrittenBytes
            wakeups &+= delta.wakeups
            if footprintWindowTime != window {
                footprintWindowTime = window
                footprintWindow = 0
            }
            footprintWindow &+= delta.footprintBytes
            footprintMax = Swift.max(footprintMax, footprintWindow)
        }

        func row(minute: Int64, app: AppIdentity) -> AppMinuteRow {
            AppMinuteRow(
                minute: minute, app: app, cpuNanos: cpuNanos, energyNanojoules: energyValid ? energyNanojoules : nil,
                // S4 不过时 GPU、ANE 辅助槽与 CPU 能耗一起记为空（D96、D98）。
                gpuNanos: energyValid ? gpuNanos : nil, gpuEnergyNanojoules: energyValid ? gpuEnergyNanojoules : nil,
                aneEnergyNanojoules: energyValid ? aneEnergyNanojoules : nil,
                diskReadBytes: diskReadBytes, diskWrittenBytes: diskWrittenBytes, wakeups: wakeups, footprintBytes: footprintMax)
        }

    }

    private var buckets: [Key: Bucket] = [:]
    private var apps: [Int64: [String: AppBucket]] = [:]
    private var lastRun: [CollectorID: SampleTime] = [:]

    public init() {}

    public var isEmpty: Bool { buckets.isEmpty && apps.isEmpty }

    public static func minute(of date: Date) -> Int64 {
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

    /// 吃一个应用活动窗口。`identities` 里没有的 coalition（已退出、不在解析范围）记进「其余」。
    public mutating func ingestApps(_ window: AppActivityWindow, identities: [UInt64: AppIdentity]) {
        let minute = Self.minute(of: window.time.wallClock)
        var perMinute = apps[minute, default: [:]]
        let windowID = window.time.monotonicNanos
        for delta in window.coalitions {
            let identity = identities[delta.id] ?? .other
            var bucket = perMinute[identity.key, default: AppBucket(name: identity.name)]
            bucket.name = identity.name
            bucket.add(delta, trusted: window.slotsTrusted, window: windowID)
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
        defer { discard(before: cutoff) }
        return pending(before: cutoff)
    }

    /// 分钟号小于 `cutoff` 的数据（不取走）。写库成功后再 `discard(before:)`，失败时数据留在内存里，下次提交重试。
    public func pending(before cutoff: Int64?) -> (rows: [MinuteRow], apps: [AppMinuteRow]) {
        var rows: [MinuteRow] = []
        for (key, bucket) in buckets where cutoff.map({ key.minute < $0 }) ?? true {
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
            appRows.append(contentsOf: Self.selectRows(minute: minute, perMinute.map { $0.value.row(minute: minute, app: AppIdentity(key: $0.key, name: $0.value.name)) }))
        }
        appRows.sort { ($0.minute, $1.cpuNanos, $0.app.key) < ($1.minute, $0.cpuNanos, $1.app.key) }
        return (rows, appRows)
    }

    /// 丢掉分钟号小于 `cutoff` 的数据；`cutoff` 为 nil 时全部丢掉。
    public mutating func discard(before cutoff: Int64?) {
        guard let cutoff else {
            buckets = [:]
            apps = [:]
            return
        }
        buckets = buckets.filter { $0.key.minute >= cutoff }
        apps = apps.filter { $0.key >= cutoff }
    }

    /// 丢掉分钟号大于 `minute` 的数据（墙钟跳到未来时记下的分钟，D103）。
    public mutating func discard(after minute: Int64) {
        buckets = buckets.filter { $0.key.minute <= minute }
        apps = apps.filter { $0.key <= minute }
    }

    /// 各列前 `appsPerMinute` 名的并集，其余并成一行「其余合计」（D68）。全部为 0 的行不写。
    static func selectRows(minute: Int64, _ all: [AppMinuteRow]) -> [AppMinuteRow] {
        let candidates = all.filter { $0.app.key != AppIdentity.other.key }
        let columns: [(AppMinuteRow) -> UInt64] = [
            \.cpuNanos, \.totalEnergy, { $0.gpuNanos ?? 0 }, { $0.aneEnergyNanojoules ?? 0 },
            { $0.diskReadBytes &+ $0.diskWrittenBytes },
            \.wakeups, \.footprintBytes,
        ]
        var keep = Set<String>()
        for column in columns {
            let top = candidates.filter { column($0) > 0 }.sorted { column($0) > column($1) }.prefix(appsPerMinute)
            keep.formUnion(top.map(\.app.key))
        }
        var out = candidates.filter { keep.contains($0.app.key) }
        var other = all.first { $0.app.key == AppIdentity.other.key }
            ?? AppMinuteRow(minute: minute, app: .other, cpuNanos: 0, energyNanojoules: 0)
        for row in candidates where !keep.contains(row.app.key) {
            other.cpuNanos &+= row.cpuNanos
            other.energyNanojoules = Self.sum(other.energyNanojoules, row.energyNanojoules)
            other.gpuNanos = Self.sum(other.gpuNanos, row.gpuNanos)
            other.gpuEnergyNanojoules = Self.sum(other.gpuEnergyNanojoules, row.gpuEnergyNanojoules)
            other.aneEnergyNanojoules = Self.sum(other.aneEnergyNanojoules, row.aneEnergyNanojoules)
            other.diskReadBytes &+= row.diskReadBytes
            other.diskWrittenBytes &+= row.diskWrittenBytes
            other.wakeups &+= row.wakeups
            other.footprintBytes &+= row.footprintBytes
        }
        other.app = .other
        let otherIdle = other.cpuNanos == 0 && (other.gpuNanos ?? 0) == 0 && (other.aneEnergyNanojoules ?? 0) == 0
            && other.diskReadBytes == 0 && other.diskWrittenBytes == 0 && other.wakeups == 0 && other.footprintBytes == 0
        if !otherIdle { out.append(other) }
        return out
    }

    /// 两份都已知才相加，任一份为空结果就为空（D98）。
    static func sum(_ a: UInt64?, _ b: UInt64?) -> UInt64? { a.flatMap { a in b.map { a &+ $0 } } }
}
