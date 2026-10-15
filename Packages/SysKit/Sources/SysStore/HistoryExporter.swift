// 历史导出（CPU 模块设计 §6 Exporter，D30，边界稿 §5.5）。只在用户手动触发时运行。
//
// - CSV：一个文件夹，`system.csv` 是宽表（ISO 8601 UTC 时间，每个指标 avg、max 两列，空洞留空）、
//   `apps.csv` 是长表、`metadata.json` 写机型、芯片、档名与核数、单位和 app 版本；
// - JSON Lines：长表，首行是元数据；
// - 不导出任何设备唯一标识：库里本来就没有序列号、UUID、MAC、IP；机型标识和芯片名不是唯一标识，照常包含。
// 调用方应先让 HistoryRecorder 提交内存里的数据（`flush()`）。

import Foundation
import SysModel

public struct HistoryExportOptions: Sendable, Hashable {
    public enum Format: String, Sendable, Hashable, CaseIterable {
        case csv
        case jsonLines
    }

    public var from: Date
    public var to: Date
    public var granularity: HistoryGranularity
    public var format: Format
    /// 只导出名字以这些前缀开头的指标（例如 `cpu.usage.`）；nil 为全部。
    public var metricPrefixes: [String]?
    /// 是否导出每应用数据（只有分钟粒度）。
    public var includeApps: Bool
    /// 写进元数据的 app 版本。
    public var appVersion: String

    public init(
        from: Date, to: Date, granularity: HistoryGranularity = .minute, format: Format = .csv,
        metricPrefixes: [String]? = nil, includeApps: Bool = true, appVersion: String
    ) {
        self.from = from
        self.to = to
        self.granularity = granularity
        self.format = format
        self.metricPrefixes = metricPrefixes
        self.includeApps = includeApps
        self.appVersion = appVersion
    }
}

/// 导出的元数据（`metadata.json`，或 JSON Lines 的首行）。
struct HistoryExportMetadata: Encodable {
    struct Metric: Encodable {
        var name: String
        var unit: String
    }

    struct Epoch: Encodable {
        var start: String
        var model: String
        var chip: String
        var osBuild: String
        var topology: EpochTopology?
    }

    var type = "metadata"
    var exporter = "SysInfo"
    var appVersion: String
    var exportedAt: String
    var from: String
    var to: String
    var granularity: String
    var timeZone = "UTC"
    var metrics: [Metric]
    var epochs: [Epoch]
    var qualityCodes: [String]
    var notes: [String]
}

public enum HistoryExporter {
    /// 导出到 `destination`：CSV 时是要新建的文件夹，JSON Lines 时是文件。返回写出的文件。
    @discardableResult
    public static func export(_ store: HistoryStore, options: HistoryExportOptions, to destination: URL) throws -> [URL] {
        let from = MinuteAggregator.minute(of: options.from)
        let to = MinuteAggregator.minute(of: options.to) + 1
        let filter: ((MetricID) -> Bool)? = options.metricPrefixes.map { prefixes in
            { id in prefixes.contains { id.rawValue.hasPrefix($0) } }
        }
        let rows = try store.rows(from: from, to: to, granularity: options.granularity, metrics: filter)
        let apps = options.includeApps ? try store.appRows(from: from, to: to) : []
        let units = Dictionary(try store.metrics().map { ($0.metric, $0.unit) }, uniquingKeysWith: { a, _ in a })
        let metricNames = Array(Set(rows.map(\.metric))).sorted()
        let metadata = makeMetadata(
            store: store, options: options, metrics: metricNames.map { .init(name: $0.rawValue, unit: units[$0] ?? "") })

        switch options.format {
        case .csv:
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let system = destination.appendingPathComponent("system.csv")
            try systemCSV(rows: rows, metrics: metricNames).write(to: system, atomically: true, encoding: .utf8)
            let meta = destination.appendingPathComponent("metadata.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(metadata).write(to: meta, options: .atomic)
            var out = [system, meta]
            if options.includeApps {
                let appsURL = destination.appendingPathComponent("apps.csv")
                try appsCSV(apps).write(to: appsURL, atomically: true, encoding: .utf8)
                out.insert(appsURL, at: 1)
            }
            return out
        case .jsonLines:
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try jsonLines(metadata: metadata, rows: rows, apps: apps).write(to: destination, atomically: true, encoding: .utf8)
            return [destination]
        }
    }

    static func iso(_ minute: Int64) -> String {
        iso(Date(timeIntervalSince1970: TimeInterval(minute * 60)))
    }

    static func iso(_ date: Date) -> String {
        date.formatted(.iso8601)  // 形如 2026-10-15T08:30:00Z
    }

    private static func makeMetadata(
        store: HistoryStore, options: HistoryExportOptions, metrics: [HistoryExportMetadata.Metric]
    ) -> HistoryExportMetadata {
        let decoder = JSONDecoder()
        let epochs = ((try? store.epochs()) ?? []).map { e in
            HistoryExportMetadata.Epoch(
                start: iso(e.startMinute), model: e.model, chip: e.chip, osBuild: e.osBuild,
                topology: try? decoder.decode(EpochTopology.self, from: Data(e.topologyJSON.utf8)))
        }
        return HistoryExportMetadata(
            appVersion: options.appVersion, exportedAt: iso(Date()), from: iso(options.from), to: iso(options.to),
            granularity: options.granularity.rawValue, metrics: metrics, epochs: epochs,
            qualityCodes: HistoryQuality.allCases.map(\.name),
            notes: [
                "avg/max are per-\(options.granularity.rawValue) aggregates in SI units; empty max means the samples covered windows too long to have a peak.",
                "apps: top \(MinuteAggregator.appsPerMinute) apps per minute by CPU; cpu_cores = cpu_ns / 60e9.",
            ])
    }

    static func csvField(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func number(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "" }
        return String(format: "%.6g", v)
    }

    static func systemCSV(rows: [(minute: Int64, metric: MetricID, point: HistoryPoint)], metrics: [MetricID]) -> String {
        let column = Dictionary(uniqueKeysWithValues: metrics.enumerated().map { ($1, $0) })
        var lines = ["time," + metrics.map { "\(csvField($0.rawValue + ".avg")),\(csvField($0.rawValue + ".max"))" }.joined(separator: ",")]
        var index = 0
        while index < rows.count {
            let minute = rows[index].minute
            var cells = [String](repeating: "", count: metrics.count * 2)
            while index < rows.count, rows[index].minute == minute {
                if let c = column[rows[index].metric] {
                    cells[c * 2] = number(rows[index].point.avg)
                    cells[c * 2 + 1] = number(rows[index].point.max)
                }
                index += 1
            }
            lines.append(iso(minute) + "," + cells.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func appsCSV(_ apps: [(minute: Int64, key: String, name: String, cpuNanos: Int64, energy: Int64?)]) -> String {
        var lines = ["time,app_key,app_name,cpu_ns,cpu_cores,energy_j"]
        for a in apps {
            lines.append(
                [
                    iso(a.minute), csvField(a.key), csvField(a.name), String(a.cpuNanos), number(Double(a.cpuNanos) / 60e9),
                    number(a.energy.map { Double($0) / 1e9 }),
                ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func jsonLines(
        metadata: HistoryExportMetadata, rows: [(minute: Int64, metric: MetricID, point: HistoryPoint)],
        apps: [(minute: Int64, key: String, name: String, cpuNanos: Int64, energy: Int64?)]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        struct SampleLine: Encodable {
            var type = "sample"
            var t: String
            var metric: String
            var avg: Double
            var max: Double?
            var n: Int64
            var q: String
        }
        struct AppLine: Encodable {
            var type = "app"
            var t: String
            var key: String
            var name: String
            var cpu_ns: Int64
            var energy_nj: Int64?
        }
        var lines = [String(decoding: try encoder.encode(metadata), as: UTF8.self)]
        for r in rows {
            let line = SampleLine(
                t: iso(r.minute), metric: r.metric.rawValue, avg: r.point.avg, max: r.point.max, n: r.point.n,
                q: r.point.quality.name)
            lines.append(String(decoding: try encoder.encode(line), as: UTF8.self))
        }
        for a in apps {
            let line = AppLine(t: iso(a.minute), key: a.key, name: a.name, cpu_ns: a.cpuNanos, energy_nj: a.energy)
            lines.append(String(decoding: try encoder.encode(line), as: UTF8.self))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
