// 整机能耗（功耗与散热模块设计 §5，D46）：
//
// - EnergyIntegrator：对 `power.system`（PDTR）做矩形积分。一个样本覆盖到上一个样本，单样本最多 1.05 s，
//   超出部分不外推；唤醒后第一个样本丢弃。按 UTC 分钟累加焦耳数与覆盖秒数；
// - EnergyGap：app 没运行的时段，用 `PowerTelemetryData` 累加器的差值补上（同一次开机比锚点；开机变了从开机算起），
//   按时长均摊进所跨的分钟（系统累计：累加器在满载时会漏记，可能偏低）；
// - 表：energy_minute（积分）与 energy_fill_minute（补数）随分钟级 30 天过期；整点后汇总进 energy_hour
//   （永久，source 0 为积分、1 为补数）；kv 存锚点与 PMGR 状态。

import Foundation
import SysCollectors
import SysModel

/// 一分钟的能耗积分。
public struct EnergyMinuteRow: Hashable, Sendable {
    public var minute: Int64
    public var joules: Double
    /// 有 PDTR 样本覆盖的秒数（≤60；不足说明这一分钟有缺口）。
    public var covered: Double
}

/// 能耗汇总（面板「能耗」卡片）。
public struct EnergySummary: Hashable, Sendable {
    /// PDTR 积分的焦耳数。
    public var integrated: Double
    /// 系统累计补数的焦耳数（app 没运行的时段）。
    public var filled: Double
    /// 积分覆盖的秒数。
    public var covered: Double

    public var total: Double { integrated + filled }
    public var kilowattHours: Double { total / 3.6e6 }
}

/// 能耗积分器（纯值类型，单测覆盖）。
public struct EnergyIntegrator: Sendable {
    /// 单样本最多覆盖的秒数（D46）。
    public static let maxSampleSpan: Double = 1.05

    private var buckets: [Int64: (joules: Double, covered: Double)] = [:]
    private var lastMonotonic: UInt64?
    private var dropNext = false

    public init() {}

    /// 吃一个整机功率样本。
    public mutating func ingest(watts: Double, at time: SampleTime) {
        defer { lastMonotonic = time.monotonicNanos }
        guard let last = lastMonotonic, time.monotonicNanos > last else { return }
        if dropNext {
            dropNext = false
            return
        }
        let span = min(Double(time.monotonicNanos - last) / 1e9, Self.maxSampleSpan)
        guard watts.isFinite, watts >= 0, span > 0 else { return }
        let minute = MinuteAggregator.minute(of: time.wallClock)
        var bucket = buckets[minute] ?? (0, 0)
        bucket.joules += watts * span
        bucket.covered += span
        buckets[minute] = bucket
    }

    /// 唤醒：下一个样本覆盖的区间不明（睡眠前的最后一个读数到唤醒），丢弃。
    public mutating func noteWake() {
        dropNext = true
    }

    /// 取出 `cutoff` 之前（不含）的分钟；cutoff 为 nil 时全部取出。
    public mutating func take(before cutoff: Int64?) -> [EnergyMinuteRow] {
        let keys = buckets.keys.filter { cutoff == nil || $0 < cutoff! }.sorted()
        defer { keys.forEach { buckets[$0] = nil } }
        return keys.map { EnergyMinuteRow(minute: $0, joules: buckets[$0]!.joules, covered: buckets[$0]!.covered) }
    }
}

/// 能耗锚点：上一次提交时的累加器读数（kv 表的 `energy.anchor`）。
public struct EnergyAnchor: Codable, Hashable, Sendable {
    public var telemetry: PowerTelemetryReading
    public var bootTime: Date
}

public enum EnergyGap {
    /// 短于这个时长的缺口不补（与积分重叠的风险大于收益）。
    public static let minimumSeconds: Double = 120

    /// 由锚点与当前读数算出要补的能量：返回缺口的起止与焦耳数；不需要补或无法补时为 nil。
    public static func fill(
        anchor: EnergyAnchor?, now: PowerTelemetryReading, bootTime: Date
    ) -> (start: Date, end: Date, joules: Double)? {
        if let anchor, abs(anchor.bootTime.timeIntervalSince(bootTime)) < 2 {
            // 同一次开机：累加器差值。倒退（不应发生）时不补。
            let delta = now.accumulatedSystemPowerIn - anchor.telemetry.accumulatedSystemPowerIn
            let seconds = now.wallClock.timeIntervalSince(anchor.telemetry.wallClock)
            guard delta >= 0, seconds >= minimumSeconds else { return nil }
            return (anchor.telemetry.wallClock, now.wallClock, Double(delta) / 1000)
        }
        // 开机变了（或第一次运行）：累加器从开机起算。第一次运行时也补上本次开机以来的能耗。
        let seconds = now.wallClock.timeIntervalSince(bootTime)
        guard seconds >= minimumSeconds, now.accumulatedSystemPowerIn >= 0 else { return nil }
        return (bootTime, now.wallClock, Double(now.accumulatedSystemPowerIn) / 1000)
    }

    /// 把一段能量按时长均摊进所跨的 UTC 分钟（`covered` 为该分钟里被缺口覆盖的秒数）。
    public static func perMinute(start: Date, end: Date, joules: Double) -> [EnergyMinuteRow] {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return [] }
        var rows: [EnergyMinuteRow] = []
        var minute = MinuteAggregator.minute(of: start)
        while Double(minute) * 60 < end.timeIntervalSince1970 {
            let lo = max(start.timeIntervalSince1970, Double(minute) * 60)
            let hi = min(end.timeIntervalSince1970, Double(minute + 1) * 60)
            if hi > lo { rows.append(EnergyMinuteRow(minute: minute, joules: joules * (hi - lo) / total, covered: hi - lo)) }
            minute += 1
        }
        return rows
    }
}

extension HistoryStore {
    /// 写入能耗分钟（UPSERT 累加：同一分钟的数据可能分两次提交）。
    public func writeEnergy(_ rows: [EnergyMinuteRow]) throws {
        guard !rows.isEmpty else { return }
        try db.transaction { () throws(SQLiteError) in
            let upsert = try db.statement(
                """
                INSERT INTO energy_minute(t, joules, covered_s) VALUES(?, ?, ?)
                ON CONFLICT(t) DO UPDATE SET joules = joules + excluded.joules, covered_s = covered_s + excluded.covered_s
                """)
            for row in rows { try upsert.run([.int(row.minute), .double(row.joules), .double(row.covered)]) }
        }
    }

    /// 写入补数分钟（UPSERT 累加）。
    public func writeEnergyFill(_ rows: [EnergyMinuteRow]) throws {
        guard !rows.isEmpty else { return }
        try db.transaction { () throws(SQLiteError) in
            let upsert = try db.statement(
                """
                INSERT INTO energy_fill_minute(t, joules, covered_s) VALUES(?, ?, ?)
                ON CONFLICT(t) DO UPDATE SET joules = joules + excluded.joules, covered_s = covered_s + excluded.covered_s
                """)
            for row in rows { try upsert.run([.int(row.minute), .double(row.joules), .double(row.covered)]) }
        }
    }

    static let energyTables: [(table: String, source: Int64)] = [("energy_minute", 0), ("energy_fill_minute", 1)]

    /// 把积分与补数的分钟汇总进小时表，直到 `throughHour`（含）。与分钟指标的汇总同一时机。
    /// 每张表从已汇总的最后一小时（含，补上迟到的分钟）开始，没有时从分钟表的第一小时开始。
    /// 补数总是从上一次运行的锚点到现在，不会早于上一次补数汇总到的小时。
    public func rollUpEnergyHours(through throughHour: Int64) throws {
        for (table, source) in Self.energyTables {
            let lastHour =
                try db.statement("SELECT MAX(t) FROM energy_hour WHERE source = ?").query([.int(source)]) { $0.optionalInt(0) }
                .first ?? nil
            let firstMinute = try db.statement("SELECT MIN(t) FROM \(table)").query { $0.optionalInt(0) }.first ?? nil
            guard let start = lastHour ?? firstMinute.map({ Self.floorDiv($0, 60) }), start <= throughHour else { continue }
            try db.statement(
                """
                INSERT OR REPLACE INTO energy_hour(t, source, joules, covered_s)
                SELECT t / 60, \(source), SUM(joules), SUM(covered_s) FROM \(table) WHERE t >= ? AND t < ? GROUP BY t / 60
                """
            ).run([.int(start * 60), .int((throughHour + 1) * 60)])
        }
    }

    /// 一段时间内的能耗（按分钟边界）：分钟级保留期内取分钟表，更早的部分取小时汇总（按小时边界）。
    public func energySummary(from: Date, to: Date) throws -> EnergySummary {
        let fromMinute = MinuteAggregator.minute(of: from)
        let toMinute = MinuteAggregator.minute(of: to) + 1
        var totals: [(joules: Double, covered: Double)] = []
        for (table, source) in Self.energyTables {
            let oldest = try db.statement("SELECT MIN(t) FROM \(table)").query { $0.optionalInt(0) }.first ?? nil
            let minuteStart = max(fromMinute, oldest ?? toMinute)
            var joules = 0.0
            var covered = 0.0
            if fromMinute < minuteStart {
                let rows = try db.statement(
                    "SELECT SUM(joules), SUM(covered_s) FROM energy_hour WHERE source = ? AND t >= ? AND t < ?"
                ).query([.int(source), .int(Self.floorDiv(fromMinute, 60)), .int(Self.floorDiv(minuteStart, 60))]) {
                    ($0.optionalDouble(0) ?? 0, $0.optionalDouble(1) ?? 0)
                }
                joules += rows.first?.0 ?? 0
                covered += rows.first?.1 ?? 0
            }
            let rows = try db.statement("SELECT SUM(joules), SUM(covered_s) FROM \(table) WHERE t >= ? AND t < ?")
                .query([.int(minuteStart), .int(toMinute)]) { ($0.optionalDouble(0) ?? 0, $0.optionalDouble(1) ?? 0) }
            joules += rows.first?.0 ?? 0
            covered += rows.first?.1 ?? 0
            totals.append((joules, covered))
        }
        return EnergySummary(integrated: totals[0].joules, filled: totals[1].joules, covered: totals[0].covered)
    }

    /// 按小时列出能耗（导出用）：小时、source、焦耳、覆盖秒数。
    func energyHours(from: Int64, to: Int64) throws -> [(hour: Int64, source: Int64, joules: Double, covered: Double)] {
        try db.statement(
            "SELECT t, source, joules, covered_s FROM energy_hour WHERE t >= ? AND t < ? ORDER BY t, source"
        ).query([.int(from), .int(to)]) { ($0.int(0), $0.int(1), $0.double(2), $0.double(3)) }
    }

    // MARK: - kv

    public func value(forKey key: String) throws -> String? {
        try db.statement("SELECT value FROM kv WHERE key = ?").query([.text(key)]) { $0.text(0) }.first
    }

    public func setValue(_ value: String, forKey key: String) throws {
        try db.statement("INSERT OR REPLACE INTO kv(key, value) VALUES(?, ?)").run([.text(key), .text(value)])
    }

    public func decoded<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T? {
        guard let text = try value(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: Data(text.utf8))
    }

    public func setEncoded<T: Encodable>(_ value: T, forKey key: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try setValue(String(decoding: try encoder.encode(value), as: UTF8.self), forKey: key)
    }
}
