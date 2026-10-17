// 历史库的数据库层（CPU 模块设计 §6，D30，边界稿 §5.5）。
//
// - WAL + `synchronous=NORMAL` + `auto_vacuum=INCREMENTAL`；`user_version` 做迁移；
// - 主键时间在前、`WITHOUT ROWID`（边界稿实测：写入量是指标在前的 1/12，小时汇总不随表变大而变慢）；
// - 与芯片相关的信息只记在 `epoch` 表里，变化时新开一段；
// - 写入一律 UPSERT：墙钟回拨、分钟分批写入时按 n 加权合并；峰值任一侧为空则为空；
// - 小时汇总从分钟表重算（幂等），只存整机指标；保留期：分钟级与每应用 30 天，小时级永久。
//
// 不是线程安全的：由 HistoryRecorder（actor）或 CLI 串行使用。

import Foundation
import SysCollectors
import SysModel

/// 一段「同一台机器、同一拓扑、同一系统 build」的记录。
public struct HistoryEpoch: Hashable, Sendable, Codable {
    /// 起始的 UTC Unix 分钟。
    public var startMinute: Int64
    /// 机型标识，例如 `Mac17,16`。不是设备唯一标识（CLAUDE.md）。
    public var model: String
    /// SoC 标识，例如 `AppleT6050PMGR`。
    public var chip: String
    public var osBuild: String
    /// 拓扑（`EpochTopology` 的 JSON，键排序，便于比较）。
    public var topologyJSON: String

    public init(startMinute: Int64, model: String, chip: String, osBuild: String, topologyJSON: String) {
        self.startMinute = startMinute
        self.model = model
        self.chip = chip
        self.osBuild = osBuild
        self.topologyJSON = topologyJSON
    }

    /// 除起始时刻外是否相同。
    func sameMachine(as other: HistoryEpoch) -> Bool {
        model == other.model && chip == other.chip && osBuild == other.osBuild && topologyJSON == other.topologyJSON
    }
}

/// 写进 epoch 的拓扑摘要：档名、核数、簇。不含判定依据的说明文字（会随版本变化）。
public struct EpochTopology: Hashable, Sendable, Codable {
    public struct Level: Hashable, Sendable, Codable {
        public var index: Int
        public var name: String
        public var cpuCount: Int
        public var clusters: [String]
    }

    public struct Cluster: Hashable, Sendable, Codable {
        public var key: String
        public var cpus: [Int]
        public var perfLevel: Int?
    }

    public var logicalCPUCount: Int
    public var levels: [Level]
    public var clusters: [Cluster]
    public var quality: String

    public init(_ topology: CPUTopology) {
        logicalCPUCount = topology.logicalCPUCount
        levels = topology.perfLevels.map {
            Level(index: $0.index, name: $0.name, cpuCount: $0.cpuCount, clusters: $0.clusters.map(\.description))
        }
        clusters = topology.clusters.map { Cluster(key: $0.key.description, cpus: $0.cpus, perfLevel: $0.perfLevel) }
        switch topology.quality {
        case .ok: quality = "ok"
        case .clustersOnly: quality = "clustersOnly"
        case .coresOnly: quality = "coresOnly"
        }
    }

    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// 读出来的一个点。
public struct HistoryPoint: Hashable, Sendable {
    /// 桶起点的 UTC Unix 分钟。
    public var minute: Int64
    public var avg: Double
    public var max: Double?
    /// 覆盖秒数。
    public var n: Int64
    public var quality: HistoryQuality
}

/// 读历史时的粒度。
public enum HistoryGranularity: String, Sendable, Hashable, Codable, CaseIterable {
    case minute
    case hour
}

/// 历史库的概况（CLI `history stats`、设置页）。
public struct HistoryStats: Hashable, Sendable {
    public var path: String
    public var fileBytes: Int64
    public var metricCount: Int
    public var minuteRows: Int
    public var hourRows: Int
    public var appRows: Int
    public var appCount: Int
    /// 分钟表的首尾分钟。
    public var minuteRange: ClosedRange<Int64>?
    public var hourRange: ClosedRange<Int64>?
    public var epochs: [HistoryEpoch]
}

public final class HistoryStore {
    /// 当前表结构版本。
    /// 1：CPU 模块（D30）；2：能耗与 kv 表（功耗与散热模块设计 §6，D46）；
    /// 3：每应用扩列与电源断言（应用活动设计 §3.2，D68、D69）。
    public static let schemaVersion: Int64 = 3
    /// 分钟级与每应用数据的保留期（D30）。
    public static let minuteRetention: TimeInterval = 30 * 86_400

    let db: SQLiteDatabase
    private var metricIDs: [MetricID: Int64] = [:]
    private var appIDs: [String: (id: Int64, name: String)] = [:]
    private var latestEpoch: HistoryEpoch?

    public var path: String { db.path }

    /// 打开（必要时创建并迁移）历史库。父目录不存在时创建。
    public convenience init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(path: url.path)
    }

    /// `path` 为 `:memory:` 时是内存库（测试用）。
    init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try configure()
        try migrate()
        try loadCaches()
    }

    /// 内存库（测试用）。
    public static func inMemory() throws -> HistoryStore {
        try HistoryStore(path: ":memory:")
    }

    /// 默认位置：`~/Library/Application Support/<bundle id>/History.sqlite`（Debug 与 Release 天然隔离，D16）。
    public static func defaultURL(bundleIdentifier: String) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("History.sqlite")
    }

    private func configure() throws {
        // auto_vacuum 必须在建第一张表之前设置，对已有的库不起作用（也不需要）。
        try db.execute("PRAGMA auto_vacuum = INCREMENTAL")
        if db.path != ":memory:" { try db.execute("PRAGMA journal_mode = WAL") }
        try db.execute("PRAGMA synchronous = NORMAL")
    }

    private func migrate() throws {
        let version = try db.pragmaInt("user_version")
        guard version < Self.schemaVersion else { return }
        try db.transaction { () throws(SQLiteError) in
            if version < 1 {
                try db.execute(
                    """
                    CREATE TABLE metric(
                        id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, unit TEXT NOT NULL, aggregation TEXT NOT NULL);
                    CREATE TABLE epoch(
                        start_t INTEGER PRIMARY KEY, model TEXT NOT NULL, chip TEXT NOT NULL, os_build TEXT NOT NULL,
                        topology_json TEXT NOT NULL);
                    CREATE TABLE sample_minute(
                        t INTEGER NOT NULL, metric INTEGER NOT NULL, avg REAL NOT NULL, max REAL, n INTEGER NOT NULL,
                        q INTEGER NOT NULL, PRIMARY KEY(t, metric)) WITHOUT ROWID;
                    CREATE TABLE sample_hour(
                        t INTEGER NOT NULL, metric INTEGER NOT NULL, avg REAL NOT NULL, max REAL, n INTEGER NOT NULL,
                        q INTEGER NOT NULL, PRIMARY KEY(t, metric)) WITHOUT ROWID;
                    CREATE TABLE app(id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, name TEXT NOT NULL);
                    CREATE TABLE app_minute(
                        t INTEGER NOT NULL, app INTEGER NOT NULL, cpu_ns INTEGER NOT NULL, energy_nj INTEGER,
                        PRIMARY KEY(t, app)) WITHOUT ROWID;
                    """)
            }
            if version < 2 {
                try db.execute(
                    """
                    CREATE TABLE energy_minute(t INTEGER PRIMARY KEY, joules REAL NOT NULL, covered_s REAL NOT NULL);
                    CREATE TABLE energy_fill_minute(t INTEGER PRIMARY KEY, joules REAL NOT NULL, covered_s REAL NOT NULL);
                    CREATE TABLE energy_hour(
                        t INTEGER NOT NULL, source INTEGER NOT NULL, joules REAL NOT NULL, covered_s REAL NOT NULL,
                        PRIMARY KEY(t, source)) WITHOUT ROWID;
                    CREATE TABLE kv(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
                    """)
            }
            if version < 3 {
                // 旧行的新列为空（D68 之前只记 CPU 时间与能耗）。
                try db.execute(
                    """
                    ALTER TABLE app_minute ADD COLUMN gpu_ns INTEGER;
                    ALTER TABLE app_minute ADD COLUMN gpu_nj INTEGER;
                    ALTER TABLE app_minute ADD COLUMN ane_nj INTEGER;
                    ALTER TABLE app_minute ADD COLUMN disk_r INTEGER;
                    ALTER TABLE app_minute ADD COLUMN disk_w INTEGER;
                    ALTER TABLE app_minute ADD COLUMN wakeups INTEGER;
                    ALTER TABLE app_minute ADD COLUMN footprint INTEGER;
                    CREATE TABLE power_assertion(
                        id INTEGER PRIMARY KEY, app INTEGER NOT NULL, type TEXT NOT NULL, name TEXT NOT NULL,
                        holder TEXT NOT NULL, start_s REAL NOT NULL, end_s REAL, end_estimated INTEGER NOT NULL DEFAULT 0);
                    CREATE INDEX power_assertion_start ON power_assertion(start_s);
                    """)
            }
            try db.execute("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    private func loadCaches() throws {
        for (name, id) in try (db.statement("SELECT name, id FROM metric").query { ($0.text(0), $0.int(1)) }) {
            metricIDs[MetricID(name)] = id
        }
        for (key, id, name) in try (db.statement("SELECT key, id, name FROM app").query { ($0.text(0), $0.int(1), $0.text(2)) }) {
            appIDs[key] = (id, name)
        }
        latestEpoch = try epochs().last
    }

    // MARK: - 写入

    private func metricRowID(_ metric: MetricID) throws(SQLiteError) -> Int64 {
        if let id = metricIDs[metric] { return id }
        let spec = HistoryCatalog.spec(for: metric)
        try db.statement("INSERT INTO metric(name, unit, aggregation) VALUES(?, ?, ?)")
            .run([.text(metric.rawValue), .text(spec?.unit ?? ""), .text(spec?.aggregation.rawValue ?? "")])
        let id = db.lastInsertRowID
        metricIDs[metric] = id
        return id
    }

    private func appRowID(_ app: AppIdentity) throws(SQLiteError) -> Int64 {
        if let hit = appIDs[app.key] {
            if hit.name != app.name {
                try db.statement("UPDATE app SET name = ? WHERE id = ?").run([.text(app.name), .int(hit.id)])
                appIDs[app.key] = (hit.id, app.name)
            }
            return hit.id
        }
        try db.statement("INSERT INTO app(key, name) VALUES(?, ?)").run([.text(app.key), .text(app.name)])
        let id = db.lastInsertRowID
        appIDs[app.key] = (id, app.name)
        return id
    }

    /// 断言表用的应用行 id（与分钟数据共用 app 表）。
    func appRowIDForAssertion(_ app: AppIdentity) throws -> Int64 {
        try appRowID(app)
    }

    /// 在一个事务里写入分钟数据与每应用数据。
    public func write(rows: [MinuteRow], apps: [AppMinuteRow]) throws {
        guard !rows.isEmpty || !apps.isEmpty else { return }
        try db.transaction { () throws(SQLiteError) in
            let upsert = try db.statement(
                """
                INSERT INTO sample_minute(t, metric, avg, max, n, q) VALUES(?, ?, ?, ?, ?, ?)
                ON CONFLICT(t, metric) DO UPDATE SET
                    avg = (avg * n + excluded.avg * excluded.n) / (n + excluded.n),
                    max = CASE WHEN max IS NULL OR excluded.max IS NULL THEN NULL ELSE MAX(max, excluded.max) END,
                    n = n + excluded.n,
                    q = MAX(q, excluded.q)
                """)
            for row in rows {
                let metric = try metricRowID(row.metric)
                try upsert.run([
                    .int(row.minute), .int(metric), .double(row.avg), .optional(row.max), .int(row.n),
                    .int(row.quality.rawValue),
                ])
            }
            let upsertApp = try db.statement(
                """
                INSERT INTO app_minute(t, app, cpu_ns, energy_nj, gpu_ns, gpu_nj, ane_nj, disk_r, disk_w, wakeups, footprint)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(t, app) DO UPDATE SET
                    cpu_ns = cpu_ns + excluded.cpu_ns,
                    energy_nj = CASE WHEN energy_nj IS NULL OR excluded.energy_nj IS NULL THEN NULL
                                     ELSE energy_nj + excluded.energy_nj END,
                    gpu_ns = COALESCE(gpu_ns, 0) + excluded.gpu_ns,
                    gpu_nj = COALESCE(gpu_nj, 0) + excluded.gpu_nj,
                    ane_nj = COALESCE(ane_nj, 0) + excluded.ane_nj,
                    disk_r = COALESCE(disk_r, 0) + excluded.disk_r,
                    disk_w = COALESCE(disk_w, 0) + excluded.disk_w,
                    wakeups = COALESCE(wakeups, 0) + excluded.wakeups,
                    footprint = MAX(COALESCE(footprint, 0), excluded.footprint)
                """)
            for row in apps {
                let app = try appRowID(row.app)
                func v(_ x: UInt64) -> SQLiteValue { .int(Int64(clamping: x)) }
                try upsertApp.run([
                    .int(row.minute), .int(app), v(row.cpuNanos), .optional(row.energyNanojoules.map { Int64(clamping: $0) }),
                    v(row.gpuNanos), v(row.gpuEnergyNanojoules), v(row.aneEnergyNanojoules), v(row.diskReadBytes),
                    v(row.diskWrittenBytes), v(row.wakeups), v(row.footprintBytes),
                ])
            }
        }
    }

    /// 与最近一段不同时新开一段 epoch（拓扑、机型、芯片或系统 build 变化，包括用迁移助理把库带到另一台 Mac）。
    /// 返回是否新开了一段。
    @discardableResult
    public func recordEpoch(_ epoch: HistoryEpoch) throws -> Bool {
        if let latestEpoch, latestEpoch.sameMachine(as: epoch) { return false }
        try db.statement(
            "INSERT OR REPLACE INTO epoch(start_t, model, chip, os_build, topology_json) VALUES(?, ?, ?, ?, ?)"
        ).run([.int(epoch.startMinute), .text(epoch.model), .text(epoch.chip), .text(epoch.osBuild), .text(epoch.topologyJSON)])
        latestEpoch = epoch
        return true
    }

    /// 从分钟表重算小时汇总，直到 `throughHour`（含）。从已有的最后一个小时（含，补上迟到的分钟）开始，
    /// 没有小时数据时从分钟表的第一个小时开始。按 n 加权；峰值只在这一小时每行都有峰值时给出。
    public func rollUpHours(through throughHour: Int64) throws {
        let lastHour = try db.statement("SELECT MAX(t) FROM sample_hour").query { $0.optionalInt(0) }.first ?? nil
        let firstMinute = try db.statement("SELECT MIN(t) FROM sample_minute").query { $0.optionalInt(0) }.first ?? nil
        guard let start = lastHour ?? firstMinute.map({ Self.floorDiv($0, 60) }), start <= throughHour else { return }
        try db.statement(
            """
            INSERT OR REPLACE INTO sample_hour(t, metric, avg, max, n, q)
            SELECT t / 60, metric, SUM(avg * n) / SUM(n),
                   CASE WHEN COUNT(max) = COUNT(*) THEN MAX(max) END, SUM(n), MAX(q)
            FROM sample_minute WHERE t >= ? AND t < ? GROUP BY t / 60, metric
            """
        ).run([.int(start * 60), .int((throughHour + 1) * 60)])
    }

    /// 删掉早于 `minute` 的分钟数据与每应用数据，清掉不再被引用的应用，并归还空闲页。
    public func prune(before minute: Int64) throws {
        try db.transaction { () throws(SQLiteError) in
            try db.statement("DELETE FROM sample_minute WHERE t < ?").run([.int(minute)])
            try db.statement("DELETE FROM app_minute WHERE t < ?").run([.int(minute)])
            try db.statement("DELETE FROM energy_minute WHERE t < ?").run([.int(minute)])
            try db.statement("DELETE FROM energy_fill_minute WHERE t < ?").run([.int(minute)])
            try db.statement("DELETE FROM power_assertion WHERE end_s IS NOT NULL AND end_s < ?").run([.double(Double(minute) * 60)])
            try db.execute(
                """
                DELETE FROM app WHERE id NOT IN (SELECT DISTINCT app FROM app_minute)
                    AND id NOT IN (SELECT DISTINCT app FROM power_assertion)
                """)
        }
        try reloadApps()
        try db.execute("PRAGMA incremental_vacuum")
    }

    /// 一键清除每应用数据（D30）。
    public func clearAppData() throws {
        try db.transaction { () throws(SQLiteError) in
            try db.execute("DELETE FROM app_minute; DELETE FROM power_assertion; DELETE FROM app;")
        }
        appIDs = [:]
        try db.execute("PRAGMA incremental_vacuum")
    }

    private func reloadApps() throws {
        appIDs = [:]
        for (key, id, name) in try (db.statement("SELECT key, id, name FROM app").query { ($0.text(0), $0.int(1), $0.text(2)) }) {
            appIDs[key] = (id, name)
        }
    }

    /// 把 WAL 合并回主文件（导出前、退出时）。
    public func checkpoint() throws {
        guard db.path != ":memory:" else { return }
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    // MARK: - 读取

    public func epochs() throws -> [HistoryEpoch] {
        try db.statement("SELECT start_t, model, chip, os_build, topology_json FROM epoch ORDER BY start_t").query {
            HistoryEpoch(startMinute: $0.int(0), model: $0.text(1), chip: $0.text(2), osBuild: $0.text(3), topologyJSON: $0.text(4))
        }
    }

    /// 库里出现过的指标名与单位。
    public func metrics() throws -> [(metric: MetricID, unit: String)] {
        try db.statement("SELECT name, unit FROM metric ORDER BY name").query { (MetricID($0.text(0)), $0.text(1)) }
    }

    /// 读一个指标在 [from, to)（UTC Unix 分钟）内的点。`bucketMinutes` 大于 1 时按桶降采样（按 n 加权），
    /// 小时粒度下桶以分钟计也必须是 60 的倍数。没有数据的桶不出点（图表在这里断开）。
    public func series(
        _ metric: MetricID, from: Int64, to: Int64, granularity: HistoryGranularity, bucketMinutes: Int64 = 1
    ) throws -> [HistoryPoint] {
        guard let id = metricIDs[metric] else { return [] }
        let table = granularity == .minute ? "sample_minute" : "sample_hour"
        let unit: Int64 = granularity == .minute ? 1 : 60
        let bucket = Swift.max(1, bucketMinutes / unit)
        let lower = granularity == .minute ? from : Self.floorDiv(from, 60)
        let upper = granularity == .minute ? to : Self.floorDiv(to + 59, 60)
        return try db.statement(
            """
            SELECT (t / ?) * ?, SUM(avg * n) / SUM(n), CASE WHEN COUNT(max) = COUNT(*) THEN MAX(max) END, SUM(n), MAX(q)
            FROM \(table) WHERE metric = ? AND t >= ? AND t < ? GROUP BY t / ? ORDER BY 1
            """
        ).query([.int(bucket), .int(bucket), .int(id), .int(lower), .int(upper), .int(bucket)]) {
            HistoryPoint(
                minute: $0.int(0) * unit, avg: $0.double(1), max: $0.optionalDouble(2), n: $0.int(3),
                quality: HistoryQuality(rawValue: Int($0.int(4))) ?? .measured)
        }
    }

    /// 速率指标在 [from, to) 分钟内的总量：Σ(avg × n)。分钟表只保留 `minuteRetention`，更早的部分读小时表
    /// （小时表的 avg、n 是同样口径的汇总，Σ(avg × n) 不变）。
    public func total(_ metric: MetricID, from: Int64, to: Int64, now: Date = Date()) throws -> Double {
        guard let id = metricIDs[metric], to > from else { return 0 }
        // 留一天余量：清理按天进行，分钟表里最老的一天可能已被删掉一部分。对齐到整小时，和小时表无缝衔接
        // （from 不在整小时上时，第一个小时按整小时计；本地时区切日、切月一般都在整小时上）。
        let minuteFloor = (Self.floorDiv(MinuteAggregator.minute(of: now) - Int64(Self.minuteRetention / 60), 60) + 25) * 60
        var total = 0.0
        let minuteStart = Swift.max(from, minuteFloor)
        if minuteStart < to {
            total += try db.statement("SELECT COALESCE(SUM(avg * n), 0) FROM sample_minute WHERE metric = ? AND t >= ? AND t < ?")
                .query([.int(id), .int(minuteStart), .int(to)]) { $0.double(0) }.first ?? 0
        }
        if from < minuteFloor {
            // 小时表按整小时：[from, minuteFloor) 覆盖到的小时。
            let hourFrom = Self.floorDiv(from, 60)
            let hourTo = Self.floorDiv(Swift.min(minuteFloor, to), 60)
            if hourFrom < hourTo {
                total += try db.statement("SELECT COALESCE(SUM(avg * n), 0) FROM sample_hour WHERE metric = ? AND t >= ? AND t < ?")
                    .query([.int(id), .int(hourFrom), .int(hourTo)]) { $0.double(0) }.first ?? 0
            }
        }
        return total
    }

    /// 导出用：全部指标在 [from, to) 内的行，按时间、指标排序。
    func rows(
        from: Int64, to: Int64, granularity: HistoryGranularity, metrics filter: ((MetricID) -> Bool)?
    ) throws -> [(minute: Int64, metric: MetricID, point: HistoryPoint)] {
        let table = granularity == .minute ? "sample_minute" : "sample_hour"
        let unit: Int64 = granularity == .minute ? 1 : 60
        let lower = granularity == .minute ? from : Self.floorDiv(from, 60)
        let upper = granularity == .minute ? to : Self.floorDiv(to + 59, 60)
        let rows = try db.statement(
            """
            SELECT s.t, m.name, s.avg, s.max, s.n, s.q FROM \(table) s JOIN metric m ON m.id = s.metric
            WHERE s.t >= ? AND s.t < ? ORDER BY s.t, m.name
            """
        ).query([.int(lower), .int(upper)]) { s -> (Int64, MetricID, HistoryPoint) in
            let minute = s.int(0) * unit
            return (
                minute, MetricID(s.text(1)),
                HistoryPoint(
                    minute: minute, avg: s.double(2), max: s.optionalDouble(3), n: s.int(4),
                    quality: HistoryQuality(rawValue: Int(s.int(5))) ?? .measured)
            )
        }
        guard let filter else { return rows.map { ($0.0, $0.1, $0.2) } }
        return rows.filter { filter($0.1) }.map { ($0.0, $0.1, $0.2) }
    }

    /// 导出用：每应用的分钟数据（只有分钟粒度）。
    func appRows(from: Int64, to: Int64) throws -> [ExportAppRow] {
        try db.statement(
            """
            SELECT a.t, p.key, p.name, a.cpu_ns, a.energy_nj, a.gpu_ns, a.gpu_nj, a.ane_nj, a.disk_r, a.disk_w, a.wakeups,
                   a.footprint
            FROM app_minute a JOIN app p ON p.id = a.app
            WHERE a.t >= ? AND a.t < ? ORDER BY a.t, a.cpu_ns DESC
            """
        ).query([.int(from), .int(to)]) {
            ExportAppRow(
                minute: $0.int(0), key: $0.text(1), name: $0.text(2), cpuNanos: $0.int(3), energy: $0.optionalInt(4),
                gpuNanos: $0.optionalInt(5), gpuEnergy: $0.optionalInt(6), aneEnergy: $0.optionalInt(7),
                diskRead: $0.optionalInt(8), diskWrite: $0.optionalInt(9), wakeups: $0.optionalInt(10),
                footprint: $0.optionalInt(11))
        }
    }

    /// 某一段时间里 CPU 用量最多的应用（面板「按应用浏览较长时段」将来用；CLI 也用）。
    public func topApps(from: Int64, to: Int64, limit: Int) throws -> [(key: String, name: String, cpuNanos: Int64)] {
        try db.statement(
            """
            SELECT p.key, p.name, SUM(a.cpu_ns) AS c FROM app_minute a JOIN app p ON p.id = a.app
            WHERE a.t >= ? AND a.t < ? GROUP BY a.app ORDER BY c DESC LIMIT ?
            """
        ).query([.int(from), .int(to), .int(limit)]) { ($0.text(0), $0.text(1), $0.int(2)) }
    }

    public func stats() throws -> HistoryStats {
        func count(_ sql: String) throws -> Int {
            Int(try db.statement(sql).query { $0.int(0) }.first ?? 0)
        }
        func range(_ table: String) throws -> ClosedRange<Int64>? {
            let r = try db.statement("SELECT MIN(t), MAX(t) FROM \(table)").query { ($0.optionalInt(0), $0.optionalInt(1)) }.first
            guard let lo = r?.0, let hi = r?.1 else { return nil }
            return lo...hi
        }
        let pages = try db.pragmaInt("page_count")
        let pageSize = try db.pragmaInt("page_size")
        return HistoryStats(
            path: db.path, fileBytes: pages * pageSize, metricCount: try count("SELECT COUNT(*) FROM metric"),
            minuteRows: try count("SELECT COUNT(*) FROM sample_minute"), hourRows: try count("SELECT COUNT(*) FROM sample_hour"),
            appRows: try count("SELECT COUNT(*) FROM app_minute"), appCount: try count("SELECT COUNT(*) FROM app"),
            minuteRange: try range("sample_minute"), hourRange: try range("sample_hour"), epochs: try epochs())
    }
}
