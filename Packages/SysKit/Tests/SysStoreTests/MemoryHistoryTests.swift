// 内存指标的入库规则（内存模块设计 §6，D49）。

import SysCollectors
import SysModel
import Testing
@testable import SysStore

@Suite struct MemoryHistoryTests {
    @Test func memoryMetricsBelongToMemoryModule() throws {
        for id in [MetricID.memoryUsed, .memoryApp, .memoryWired, .memoryCompressed, .memoryCached, .memorySwapUsed] {
            let spec = try #require(HistoryCatalog.spec(for: id))
            #expect(spec.module == .memory)
            #expect(spec.unit == "B")
            #expect(spec.aggregation == .instant)
            #expect(spec.collector == MemoryCollector.collectorID)
        }
        #expect(HistoryCatalog.spec(for: .memoryPressureLevel)?.unit == "level")
        #expect(HistoryCatalog.spec(for: .memoryUsage)?.unit == "ratio")
        #expect(HistoryCatalog.spec(for: .memorySwapOutRate)?.aggregation == .interval)
    }

    @Test func diagnosticOnlyMetricsAreNotRecorded() {
        for id in [MetricID.memoryPhysical, .memoryFree, .memorySwapTotal, .memoryCompressionRatio, .memoryCompressionRate,
            .memoryBandwidthRead]
        {
            #expect(HistoryCatalog.spec(for: id) == nil)
        }
    }
}
