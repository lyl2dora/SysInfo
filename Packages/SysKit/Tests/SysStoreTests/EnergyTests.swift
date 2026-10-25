// 能耗（功耗与散热模块设计 §5、§9，D46）：积分的 1.05 s 上限与唤醒丢弃、补数（同一开机 / 重启 / 太短）、
// 小时均摊、写库与汇总、kv、schema 1 → 2 迁移、导出 energy.csv。

import Foundation
import Testing
import SysModel
@testable import SysStore
import SysCollectors

private func t(_ seconds: Double, wall: Double) -> SampleTime {
    SampleTime(monotonicNanos: UInt64(seconds * 1e9), wallClock: Date(timeIntervalSince1970: wall))
}

private func reading(_ milliJ: Int64, at seconds: Double) -> PowerTelemetryReading {
    PowerTelemetryReading(
        accumulatedSystemPowerIn: milliJ, accumulatorCount: 0, accumulatedWallEnergy: 0,
        wallClock: Date(timeIntervalSince1970: seconds))
}

@Suite struct EnergyIntegratorTests {
    @Test func integratesWithSpanCapAndWakeDrop() {
        var integrator = EnergyIntegrator()
        integrator.ingest(watts: 10, at: t(100, wall: 6000))  // 基线
        integrator.ingest(watts: 10, at: t(101, wall: 6001))  // 1 s → 10 J
        integrator.ingest(watts: 20, at: t(111, wall: 6011))  // 间隔 10 s：只算 1.05 s → 21 J
        integrator.noteWake()
        integrator.ingest(watts: 50, at: t(400, wall: 6050))  // 唤醒后第一个样本丢弃
        integrator.ingest(watts: 50, at: t(401, wall: 6051))  // 50 J
        let rows = integrator.take(before: nil)
        #expect(rows.count == 1)
        #expect(rows[0].minute == 100)
        #expect(abs(rows[0].joules - 81) < 1e-9)
        #expect(abs(rows[0].covered - 3.05) < 1e-9)
        #expect(integrator.take(before: nil).isEmpty)
    }

    @Test func takeKeepsCurrentMinute() {
        var integrator = EnergyIntegrator()
        integrator.ingest(watts: 5, at: t(0, wall: 6000))
        integrator.ingest(watts: 5, at: t(1, wall: 6001))  // 分钟 100
        integrator.ingest(watts: 5, at: t(2, wall: 6062))  // 分钟 101（墙钟跳过，单调只走 1 s）
        #expect(integrator.take(before: 101).map(\.minute) == [100])
        #expect(integrator.take(before: nil).map(\.minute) == [101])
    }

    @Test func pendingKeepsRowsUntilDiscarded() {
        var integrator = EnergyIntegrator()
        integrator.ingest(watts: 5, at: t(0, wall: 6000))
        integrator.ingest(watts: 5, at: t(1, wall: 6001))  // 分钟 100
        integrator.ingest(watts: 5, at: t(2, wall: 6062))  // 分钟 101
        #expect(integrator.pending(before: nil).map(\.minute) == [100, 101])
        #expect(integrator.pending(before: nil).map(\.minute) == [100, 101])
        integrator.discard(before: 101)
        #expect(integrator.pending(before: nil).map(\.minute) == [101])
    }
}

@Suite struct EnergyGapTests {
    let boot = Date(timeIntervalSince1970: 1_000_000)

    @Test func sameBootUsesAccumulatorDelta() throws {
        let anchor = EnergyAnchor(telemetry: reading(5_000_000, at: 1_010_000), bootTime: boot)
        let gap = try #require(EnergyGap.fill(anchor: anchor, now: reading(5_720_000, at: 1_010_100 + 3500), bootTime: boot))
        #expect(gap.joules == 720)
        #expect(gap.start == anchor.telemetry.wallClock)
    }

    @Test func rebootCountsFromBoot() throws {
        let anchor = EnergyAnchor(telemetry: reading(9_000_000, at: 900_000), bootTime: Date(timeIntervalSince1970: 800_000))
        let gap = try #require(EnergyGap.fill(anchor: anchor, now: reading(36_000, at: 1_000_600), bootTime: boot))
        #expect(gap.start == boot)
        #expect(gap.joules == 36)
    }

    @Test func shortOrBackwardGapsAreSkipped() {
        let anchor = EnergyAnchor(telemetry: reading(5_000_000, at: 1_010_000), bootTime: boot)
        #expect(EnergyGap.fill(anchor: anchor, now: reading(5_100_000, at: 1_010_060), bootTime: boot) == nil)
        #expect(EnergyGap.fill(anchor: anchor, now: reading(4_000_000, at: 1_020_000), bootTime: boot) == nil)
    }

    @Test func perMinuteSplitIsProportional() {
        let rows = EnergyGap.perMinute(
            start: Date(timeIntervalSince1970: 600 + 30), end: Date(timeIntervalSince1970: 720 + 15), joules: 105)
        #expect(rows.map(\.minute) == [10, 11, 12])
        #expect(rows.map(\.covered) == [30, 60, 15])
        #expect(abs(rows.map(\.joules).reduce(0, +) - 105) < 1e-9)
        #expect(abs(rows[1].joules - 60) < 1e-9)
    }
}

@Suite struct EnergyStoreTests {
    @Test func writeRollUpAndSummarize() throws {
        let store = try HistoryStore.inMemory()
        // 小时 10 的 60 分钟各 600 J（10 W），再写一次同一分钟（UPSERT 累加）
        try store.writeEnergy((600..<660).map { EnergyMinuteRow(minute: $0, joules: 600, covered: 60) })
        try store.writeEnergy([EnergyMinuteRow(minute: 600, joules: 6, covered: 0.6)])
        try store.rollUpEnergyHours(through: 10)
        let hours = try store.energyHours(from: 10, to: 11)
        #expect(hours.count == 1)
        #expect(abs(hours[0].joules - 36_006) < 1e-9)
        // 补数：小时 11 整小时 7200 J（每分钟 120 J）
        try store.writeEnergyFill(
            EnergyGap.perMinute(start: Date(timeIntervalSince1970: 39_600), end: Date(timeIntervalSince1970: 43_200), joules: 7200))
        let summary = try store.energySummary(
            from: Date(timeIntervalSince1970: 36_000), to: Date(timeIntervalSince1970: 36_000 + 7199))
        #expect(abs(summary.integrated - 36_006) < 1e-9)
        #expect(abs(summary.filled - 7200) < 1e-9)
        #expect(abs(summary.kilowattHours - (36_006 + 7200) / 3.6e6) < 1e-12)
        // 半小时的区间只算一半补数
        let half = try store.energySummary(
            from: Date(timeIntervalSince1970: 39_600), to: Date(timeIntervalSince1970: 39_600 + 1799))
        #expect(abs(half.filled - 3600) < 1e-9)
        // 汇总后补数进小时表 source 1，清理分钟表后仍能查到
        try store.rollUpEnergyHours(through: 11)
        try store.prune(before: 10_000)
        let old = try store.energySummary(from: Date(timeIntervalSince1970: 36_000), to: Date(timeIntervalSince1970: 43_199))
        #expect(abs(old.filled - 7200) < 1e-9)
        #expect(abs(old.integrated - 36_006) < 1e-9)
    }

    @Test func pruneKeepsHourlyEnergy() throws {
        let store = try HistoryStore.inMemory()
        try store.writeEnergy([EnergyMinuteRow(minute: 600, joules: 100, covered: 10)])
        try store.rollUpEnergyHours(through: 10)
        try store.prune(before: 700)
        let summary = try store.energySummary(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 50_000))
        #expect(summary.integrated == 100)  // 分钟表已清理，改从小时汇总取
    }

    @Test func keyValueRoundTrip() throws {
        let store = try HistoryStore.inMemory()
        let anchor = EnergyAnchor(telemetry: reading(123, at: 1000.5), bootTime: Date(timeIntervalSince1970: 10))
        try store.setEncoded(anchor, forKey: "energy.anchor")
        #expect(try store.decoded(EnergyAnchor.self, forKey: "energy.anchor") == anchor)
        #expect(try store.decoded(EnergyAnchor.self, forKey: "missing") == nil)
    }

    @Test func migratesVersionOneDatabase() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("energy-migrate-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            // 手工建一个 schema 1 的库
            let db = try SQLiteDatabase(path: path)
            try db.execute(
                """
                CREATE TABLE metric(id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, unit TEXT NOT NULL, aggregation TEXT NOT NULL);
                CREATE TABLE epoch(start_t INTEGER PRIMARY KEY, model TEXT NOT NULL, chip TEXT NOT NULL, os_build TEXT NOT NULL,
                    topology_json TEXT NOT NULL);
                CREATE TABLE sample_minute(t INTEGER NOT NULL, metric INTEGER NOT NULL, avg REAL NOT NULL, max REAL, n INTEGER NOT NULL,
                    q INTEGER NOT NULL, PRIMARY KEY(t, metric)) WITHOUT ROWID;
                CREATE TABLE sample_hour(t INTEGER NOT NULL, metric INTEGER NOT NULL, avg REAL NOT NULL, max REAL, n INTEGER NOT NULL,
                    q INTEGER NOT NULL, PRIMARY KEY(t, metric)) WITHOUT ROWID;
                CREATE TABLE app(id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, name TEXT NOT NULL);
                CREATE TABLE app_minute(t INTEGER NOT NULL, app INTEGER NOT NULL, cpu_ns INTEGER NOT NULL, energy_nj INTEGER,
                    PRIMARY KEY(t, app)) WITHOUT ROWID;
                PRAGMA user_version = 1;
                """)
            db.close()
        }
        let store = try HistoryStore(path: path)
        #expect(try store.db.pragmaInt("user_version") == HistoryStore.schemaVersion)
        // schema 3（D68）：旧库补上新列，旧行新列为空
        try store.write(rows: [], apps: [AppMinuteRow(minute: 1, app: .init(key: "k", name: "K"), cpuNanos: 1, energyNanojoules: 1, gpuNanos: 2)])
        #expect(try store.appTotals(from: 0, to: 10).first?.gpuNanos == 2)
        try store.writeEnergy([EnergyMinuteRow(minute: 1, joules: 1, covered: 1)])
        try store.setValue("x", forKey: "k")
        #expect(try store.value(forKey: "k") == "x")
        // schema 4（D84）：UPS 供电区间表
        _ = try store.openUPSSpan(start: Date(timeIntervalSince1970: 60))
        #expect(try store.upsPowerSpans(from: .distantPast, to: .distantFuture).count == 1)
    }

    @Test func exportsEnergyCSV() throws {
        let csv = HistoryExporter.energyCSV([(hour: 10, source: 0, joules: 36_000, covered: 3600), (hour: 11, source: 1, joules: 7200, covered: 3600)])
        let lines = csv.split(separator: "\n")
        #expect(lines.first == "time,source,joules,kwh,covered_s")
        #expect(lines[1].hasPrefix("1970-01-01T10:00:00Z,integrated,36000,0.01,3600"))
        #expect(lines[2].contains(",filled,"))
    }
}
