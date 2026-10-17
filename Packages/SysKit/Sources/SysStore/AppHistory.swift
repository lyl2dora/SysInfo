// 每应用历史的读取与电源断言区间（应用活动设计 §3.2，D68、D69）。
//
// - 按应用汇总一个时段：各列求和，footprint 取峰值；能耗只要有一分钟为空（槽位不可信）就整体为空；
// - 详情图表：一个应用按桶的 CPU（单核比例）与功率（W）；
// - 电源断言：开始时插入一行，结束时补上结束时刻；启动时把上次运行遗留的未结束行按上次提交时刻收尾（标「估计」）。

import Foundation
import SysCollectors
import SysModel

/// 一个应用在一个时段里的总量。
public struct AppTotal: Hashable, Sendable {
    public var key: String
    public var name: String
    public var cpuNanos: Int64
    /// CPU + GPU + ANE 能耗，nJ；时段内有分钟的 CPU 能耗不可信时为 nil。
    public var energyNanojoules: Int64?
    public var gpuNanos: Int64
    public var gpuEnergyNanojoules: Int64
    public var aneEnergyNanojoules: Int64
    public var diskReadBytes: Int64
    public var diskWrittenBytes: Int64
    public var wakeups: Int64
    /// footprint 峰值，字节（D68 之前的分钟没有，为 0）。
    public var footprintPeak: Int64
    /// 有记录的分钟数。
    public var minutes: Int
}

/// 详情图表的一个桶。
public struct AppSeriesPoint: Hashable, Sendable {
    /// 桶起点的 UTC Unix 分钟。
    public var minute: Int64
    /// 桶内平均 CPU，单核比例（按桶长计，应用没出现的分钟算 0）。
    public var cpu: Double
    /// 桶内平均功率，W；能耗不可信时为 nil。
    public var watts: Double?
}

/// 一段电源断言（D69）。
public struct PowerAssertionSpan: Hashable, Sendable {
    public var appKey: String
    public var appName: String
    public var type: String
    public var kind: PowerAssertionKind
    public var name: String
    public var holder: String
    public var start: Date
    /// 还没结束时为 nil。
    public var end: Date?
    /// 结束时刻是估计的（app 退出或崩溃时还没结束）。
    public var endEstimated: Bool

    /// 与 [from, to) 重叠的秒数；没结束的按 `now` 算。
    public func seconds(from: Date, to: Date, now: Date) -> TimeInterval {
        let a = max(start, from)
        let b = min(end ?? now, to)
        return max(b.timeIntervalSince(a), 0)
    }
}

extension HistoryStore {
    /// 时段 [from, to)（UTC Unix 分钟）内按应用汇总，按 CPU 时间降序。包括「其余合计」行（键 `__other__`）。
    public func appTotals(from: Int64, to: Int64) throws -> [AppTotal] {
        try db.statement(
            """
            SELECT p.key, p.name, SUM(a.cpu_ns),
                   CASE WHEN COUNT(a.energy_nj) = COUNT(*) THEN SUM(a.energy_nj) + SUM(COALESCE(a.gpu_nj, 0)) + SUM(COALESCE(a.ane_nj, 0)) END,
                   SUM(COALESCE(a.gpu_ns, 0)), SUM(COALESCE(a.gpu_nj, 0)), SUM(COALESCE(a.ane_nj, 0)),
                   SUM(COALESCE(a.disk_r, 0)), SUM(COALESCE(a.disk_w, 0)), SUM(COALESCE(a.wakeups, 0)),
                   MAX(COALESCE(a.footprint, 0)), COUNT(*)
            FROM app_minute a JOIN app p ON p.id = a.app
            WHERE a.t >= ? AND a.t < ? GROUP BY a.app ORDER BY 3 DESC
            """
        ).query([.int(from), .int(to)]) {
            AppTotal(
                key: $0.text(0), name: $0.text(1), cpuNanos: $0.int(2), energyNanojoules: $0.optionalInt(3), gpuNanos: $0.int(4),
                gpuEnergyNanojoules: $0.int(5), aneEnergyNanojoules: $0.int(6), diskReadBytes: $0.int(7),
                diskWrittenBytes: $0.int(8), wakeups: $0.int(9), footprintPeak: $0.int(10), minutes: Int($0.int(11)))
        }
    }

    /// 一个应用在 [from, to) 内按 `bucketMinutes` 分桶的 CPU 与功率。只出有记录的桶。
    public func appSeries(key: String, from: Int64, to: Int64, bucketMinutes: Int64) throws -> [AppSeriesPoint] {
        let bucket = max(1, bucketMinutes)
        let seconds = Double(bucket) * 60
        return try db.statement(
            """
            SELECT (a.t / ?) * ?, SUM(a.cpu_ns),
                   CASE WHEN COUNT(a.energy_nj) = COUNT(*) THEN SUM(a.energy_nj) + SUM(COALESCE(a.gpu_nj, 0)) + SUM(COALESCE(a.ane_nj, 0)) END
            FROM app_minute a JOIN app p ON p.id = a.app
            WHERE p.key = ? AND a.t >= ? AND a.t < ? GROUP BY a.t / ? ORDER BY 1
            """
        ).query([.int(bucket), .int(bucket), .text(key), .int(from), .int(to), .int(bucket)]) {
            AppSeriesPoint(
                minute: $0.int(0), cpu: Double($0.int(1)) / 1e9 / seconds,
                watts: $0.optionalInt(2).map { Double($0) / 1e9 / seconds })
        }
    }

    // MARK: - 电源断言

    /// 记一段断言的开始，返回行 id。同一应用、类型、名字、开始时刻（±1 s）的行已存在时（重启后同一条断言还在）
    /// 重新打开那一行，不重复插入。
    public func openAssertion(app: AppIdentity, type: String, name: String, holder: String, start: Date) throws -> Int64 {
        let appID = try appRowIDForAssertion(app)
        let existing = try db.statement(
            "SELECT id FROM power_assertion WHERE app = ? AND type = ? AND name = ? AND ABS(start_s - ?) < 1 ORDER BY id DESC LIMIT 1"
        ).query([.int(appID), .text(type), .text(name), .double(start.timeIntervalSince1970)]) { $0.int(0) }.first
        if let existing {
            try db.statement("UPDATE power_assertion SET end_s = NULL, end_estimated = 0 WHERE id = ?").run([.int(existing)])
            return existing
        }
        try db.statement("INSERT INTO power_assertion(app, type, name, holder, start_s) VALUES(?, ?, ?, ?, ?)")
            .run([.int(appID), .text(type), .text(name), .text(holder), .double(start.timeIntervalSince1970)])
        return db.lastInsertRowID
    }

    /// 记一段断言的结束。
    public func closeAssertion(id: Int64, end: Date, estimated: Bool = false) throws {
        try db.statement("UPDATE power_assertion SET end_s = ?, end_estimated = ? WHERE id = ? AND end_s IS NULL")
            .run([.double(end.timeIntervalSince1970), .int(estimated ? 1 : 0), .int(id)])
    }

    /// 把所有未结束的行按 `end` 收尾，标「估计」（启动时处理上次运行遗留的行、退出时处理还开着的行）。
    public func closeOpenAssertions(end: Date) throws {
        try db.statement(
            "UPDATE power_assertion SET end_s = MAX(start_s, ?), end_estimated = 1 WHERE end_s IS NULL"
        ).run([.double(end.timeIntervalSince1970)])
    }

    /// 与 [from, to) 重叠的断言，按开始时刻排序。
    public func assertionSpans(from: Date, to: Date) throws -> [PowerAssertionSpan] {
        try db.statement(
            """
            SELECT p.key, p.name, s.type, s.name, s.holder, s.start_s, s.end_s, s.end_estimated
            FROM power_assertion s JOIN app p ON p.id = s.app
            WHERE s.start_s < ? AND (s.end_s IS NULL OR s.end_s > ?) ORDER BY s.start_s
            """
        ).query([.double(to.timeIntervalSince1970), .double(from.timeIntervalSince1970)]) {
            PowerAssertionSpan(
                appKey: $0.text(0), appName: $0.text(1), type: $0.text(2), kind: PowerAssertionKind(trueType: $0.text(2)),
                name: $0.text(3), holder: $0.text(4), start: Date(timeIntervalSince1970: $0.double(5)),
                end: $0.optionalDouble(6).map(Date.init(timeIntervalSince1970:)), endEstimated: $0.int(7) != 0)
        }
    }
}
