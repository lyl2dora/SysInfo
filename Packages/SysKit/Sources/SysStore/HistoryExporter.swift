// 历史导出（CPU 模块设计 §6 Exporter，D30，边界稿 §5.5）。只在用户手动触发时运行。
//
// - CSV：一个文件夹，`system.csv` 是宽表（ISO 8601 UTC 时间，每个指标 avg、max 两列，空洞留空）、
//   `apps.csv` 是长表、`energy.csv` 是按小时的能耗（source：integrated 为 PDTR 积分，filled 为系统累计补数，D46）、
//   `metadata.json` 写机型、芯片、档名与核数、单位和 app 版本；
// - JSON Lines：长表，首行是元数据，能耗为 `energy` 记录；
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
    /// 存储指标里的加盐键 → 「型号 + 位置」（存储模块设计 §3.1）；没有存储指标时为空。
    var storageDevices: [String: String] = [:]
}

/// 导出用的一行每应用分钟数据（D68 之前的行新列为空）。
struct ExportAppRow: Hashable, Sendable {
    var minute: Int64
    var key: String
    var name: String
    var cpuNanos: Int64
    var energy: Int64?
    var gpuNanos: Int64? = nil
    var gpuEnergy: Int64? = nil
    var aneEnergy: Int64? = nil
    var diskRead: Int64? = nil
    var diskWrite: Int64? = nil
    var wakeups: Int64? = nil
    var footprint: Int64? = nil
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
        let assertions =
            options.includeApps
            ? try store.assertionSpans(
                from: Date(timeIntervalSince1970: TimeInterval(from * 60)), to: Date(timeIntervalSince1970: TimeInterval(to * 60)))
            : []
        let energy = try store.energyHours(from: HistoryStore.floorDiv(from, 60), to: HistoryStore.floorDiv(to - 1, 60) + 1)
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
            if !energy.isEmpty {
                let energyURL = destination.appendingPathComponent("energy.csv")
                try energyCSV(energy).write(to: energyURL, atomically: true, encoding: .utf8)
                out.insert(energyURL, at: 1)
            }
            if options.includeApps {
                let appsURL = destination.appendingPathComponent("apps.csv")
                try appsCSV(apps).write(to: appsURL, atomically: true, encoding: .utf8)
                out.insert(appsURL, at: 1)
                if !assertions.isEmpty {
                    let assertionsURL = destination.appendingPathComponent("assertions.csv")
                    try assertionsCSV(assertions).write(to: assertionsURL, atomically: true, encoding: .utf8)
                    out.insert(assertionsURL, at: 2)
                }
            }
            return out
        case .jsonLines:
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try jsonLines(metadata: metadata, rows: rows, apps: apps, energy: energy, assertions: assertions)
                .write(to: destination, atomically: true, encoding: .utf8)
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
        let storageDevices = (try? store.decoded([String: String].self, forKey: HistoryRecorder.storageLabelsKey)) ?? [:]
        let usedKeys = Set(metrics.compactMap { m -> String? in
            let id = MetricID(m.name)
            return id.storageDiskMetric?.key.rawValue ?? id.storageGroupMetric?.key.rawValue
        })
        return HistoryExportMetadata(
            appVersion: options.appVersion, exportedAt: iso(Date()), from: iso(options.from), to: iso(options.to),
            granularity: options.granularity.rawValue, metrics: metrics, epochs: epochs,
            qualityCodes: HistoryQuality.allCases.map(\.name),
            notes: [
                "avg/max are per-\(options.granularity.rawValue) aggregates in SI units; empty max means the samples covered windows too long to have a peak.",
                "apps: per minute, the union of the top \(MinuteAggregator.appsPerMinute) apps by each of CPU, energy, GPU, ANE, disk, wakeups and memory, plus one __other__ row with the rest (before schema 3 only the top \(MinuteAggregator.appsPerMinute) by CPU, without the extra columns); cpu_cores = cpu_ns / 60e9; energy_j is CPU energy, gpu_j and ane_j are separate; footprint is the peak in the minute.",
                "assertions: power assertions that prevented system or display sleep, recorded while SysInfo was running; end_estimated = the app quit or crashed before the assertion ended.",
                "energy: hourly joules; source integrated = 1 Hz PDTR integral, filled = PowerTelemetryData accumulator for periods when SysInfo was not running (may be low under heavy load).",
                "storage: disk and volume-group keys are locally salted hashes (no serial numbers); storageDevices maps them to model and position.",
            ], storageDevices: storageDevices.filter { usedKeys.contains($0.key) })
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

    static func appsCSV(_ apps: [ExportAppRow]) -> String {
        var lines = ["time,app_key,app_name,cpu_ns,cpu_cores,energy_j,gpu_ns,gpu_j,ane_j,disk_read_bytes,disk_write_bytes,wakeups,footprint_bytes"]
        func int(_ v: Int64?) -> String { v.map(String.init) ?? "" }
        func joules(_ v: Int64?) -> String { number(v.map { Double($0) / 1e9 }) }
        for a in apps {
            lines.append(
                [
                    iso(a.minute), csvField(a.key), csvField(a.name), String(a.cpuNanos), number(Double(a.cpuNanos) / 60e9),
                    joules(a.energy), int(a.gpuNanos), joules(a.gpuEnergy), joules(a.aneEnergy), int(a.diskRead), int(a.diskWrite),
                    int(a.wakeups), int(a.footprint),
                ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func assertionsCSV(_ spans: [PowerAssertionSpan]) -> String {
        var lines = ["start,end,end_estimated,app_key,app_name,type,name,holder"]
        for span in spans {
            lines.append(
                [
                    iso(span.start), span.end.map(iso) ?? "", span.endEstimated ? "1" : "0", csvField(span.appKey),
                    csvField(span.appName), csvField(span.type), csvField(redactingUUIDs(span.name)), csvField(span.holder),
                ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 断言名里可能带扩展实例的 UUID（如小组件的 `config:`、`uuid:`），导出时替换为 `<uuid>`。
    /// 它们不是设备标识，但导出承诺不带任何 UUID 形态的标识（K34）。
    static func redactingUUIDs(_ text: String) -> String {
        text.replacing(
            /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/, with: "<uuid>")
    }

    typealias EnergyHour = (hour: Int64, source: Int64, joules: Double, covered: Double)

    static func sourceName(_ source: Int64) -> String { source == 0 ? "integrated" : "filled" }

    static func energyCSV(_ hours: [EnergyHour]) -> String {
        var lines = ["time,source,joules,kwh,covered_s"]
        for h in hours {
            lines.append(
                [iso(h.hour * 60), sourceName(h.source), number(h.joules), number(h.joules / 3.6e6), number(h.covered)]
                    .joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func jsonLines(
        metadata: HistoryExportMetadata, rows: [(minute: Int64, metric: MetricID, point: HistoryPoint)],
        apps: [ExportAppRow], energy: [EnergyHour] = [], assertions: [PowerAssertionSpan] = []
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
            var gpu_ns: Int64?
            var gpu_nj: Int64?
            var ane_nj: Int64?
            var disk_read_bytes: Int64?
            var disk_write_bytes: Int64?
            var wakeups: Int64?
            var footprint_bytes: Int64?
        }
        var lines = [String(decoding: try encoder.encode(metadata), as: UTF8.self)]
        for r in rows {
            let line = SampleLine(
                t: iso(r.minute), metric: r.metric.rawValue, avg: r.point.avg, max: r.point.max, n: r.point.n,
                q: r.point.quality.name)
            lines.append(String(decoding: try encoder.encode(line), as: UTF8.self))
        }
        for a in apps {
            let line = AppLine(
                t: iso(a.minute), key: a.key, name: a.name, cpu_ns: a.cpuNanos, energy_nj: a.energy, gpu_ns: a.gpuNanos,
                gpu_nj: a.gpuEnergy, ane_nj: a.aneEnergy, disk_read_bytes: a.diskRead, disk_write_bytes: a.diskWrite,
                wakeups: a.wakeups, footprint_bytes: a.footprint)
            lines.append(String(decoding: try encoder.encode(line), as: UTF8.self))
        }
        struct EnergyLine: Encodable {
            var type = "energy"
            var t: String
            var source: String
            var joules: Double
            var covered_s: Double
        }
        for h in energy {
            let line = EnergyLine(t: iso(h.hour * 60), source: sourceName(h.source), joules: h.joules, covered_s: h.covered)
            lines.append(String(decoding: try encoder.encode(line), as: UTF8.self))
        }
        struct AssertionLine: Encodable {
            var type = "assertion"
            var start: String
            var end: String?
            var end_estimated: Bool
            var key: String
            var name: String
            var assertion_type: String
            var assertion_name: String
            var holder: String
        }
        for span in assertions {
            let line = AssertionLine(
                start: iso(span.start), end: span.end.map(iso), end_estimated: span.endEstimated, key: span.appKey,
                name: span.appName, assertion_type: span.type, assertion_name: redactingUUIDs(span.name), holder: span.holder)
            lines.append(String(decoding: try encoder.encode(line), as: UTF8.self))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
