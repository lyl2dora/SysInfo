// 电源设备的入库规则与 UPS 供电区间（电源设备设计 §5，D84 PD6）。

import Foundation
import SysCollectors
import SysModel
import Testing
@testable import SysStore

@Suite struct DeviceHistoryTests {
    @Test func primaryUPSMetricsAreRecorded() throws {
        let charge = try #require(HistoryCatalog.spec(for: .upsCharge))
        #expect(charge.module == .devices)
        #expect(charge.aggregation == .instant)
        #expect(charge.unit == "ratio")
        #expect(charge.collector == PowerSourceCollector.collectorID)
        #expect(HistoryCatalog.spec(for: .upsInputVoltage)?.unit == "V")
        #expect(HistoryCatalog.spec(for: .upsInputVoltage)?.collector == UPSTelemetryCollector.collectorID)
        #expect(HistoryCatalog.spec(for: .upsLoad)?.collector == UPSTelemetryCollector.collectorID)
    }

    @Test func derivedAndVolatileMetricsAreNotRecorded() {
        #expect(HistoryCatalog.spec(for: .upsLoadPower) == nil)
        #expect(HistoryCatalog.spec(for: .upsRuntime) == nil)
        #expect(HistoryCatalog.spec(for: .upsBatteryVoltage) == nil)
        #expect(HistoryCatalog.spec(for: .upsOnBattery) == nil)
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    @Test func spansOpenAndClose() throws {
        let store = try HistoryStore.inMemory()
        let id = try store.openUPSSpan(start: date(1000))
        #expect(try store.upsPowerSpans(from: date(0), to: date(2000)) == [UPSPowerSpan(start: date(1000), end: nil)])
        try store.closeUPSSpan(id: id, end: date(1045))
        // 重复收尾不改已有的结束时刻。
        try store.closeUPSSpan(id: id, end: date(1999))
        #expect(try store.upsPowerSpans(from: date(0), to: date(2000)) == [UPSPowerSpan(start: date(1000), end: date(1045))])
        // 不重叠的时段查不到。
        #expect(try store.upsPowerSpans(from: date(1100), to: date(2000)).isEmpty)
    }

    @Test func leftoverSpansAreClosedAsEstimated() throws {
        let store = try HistoryStore.inMemory()
        _ = try store.openUPSSpan(start: date(1000))
        try store.closeOpenUPSSpans(end: date(900))
        // 结束时刻不早于开始时刻。
        #expect(try store.upsPowerSpans(from: date(0), to: date(2000)) == [UPSPowerSpan(start: date(1000), end: date(1000), endEstimated: true)])
    }

    @Test func pruneDropsOldClosedSpans() throws {
        let store = try HistoryStore.inMemory()
        let old = try store.openUPSSpan(start: date(60))
        try store.closeUPSSpan(id: old, end: date(120))
        _ = try store.openUPSSpan(start: date(180))
        try store.prune(before: 10)
        let spans = try store.upsPowerSpans(from: .distantPast, to: .distantFuture)
        #expect(spans.map(\.start) == [date(180)])
    }
}
