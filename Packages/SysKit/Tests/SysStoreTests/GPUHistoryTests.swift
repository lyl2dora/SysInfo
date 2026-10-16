// GPU 与加速器指标的入库规则（GPU 模块设计 §7，D57 G9）。

import SysCollectors
import SysModel
import Testing
@testable import SysStore

@Suite struct GPUHistoryTests {
    @Test func gpuMetricsBelongToGPUModule() throws {
        let active = try #require(HistoryCatalog.spec(for: .gpuActive))
        #expect(active.module == .gpu && active.aggregation == .interval && active.unit == "ratio")
        #expect(active.collector == GPUPowerCollector.collectorID)
        let temperature = try #require(HistoryCatalog.spec(for: .gpuTemperature))
        #expect(temperature.module == .gpu && temperature.unit == "degC")
        #expect(temperature.collector == GPUTemperatureCollector.collectorID)
        let ane = try #require(HistoryCatalog.spec(for: .anePowered))
        #expect(ane.module == .gpu && ane.aggregation == .instant)
        // GPU 功率仍由功耗模块记录
        #expect(HistoryCatalog.spec(for: .powerGPU)?.module == .power)
    }

    @Test func panelOnlyMetricsAreNotRecorded() {
        for id in [MetricID.gpuFrequency, .gpuMemoryInUse, .gpuMemoryAllocated, .anePowerEstimated, .mediaEncodeRate,
            .mediaDecodeRate, .mediaProResRate]
        {
            #expect(HistoryCatalog.spec(for: id) == nil)
        }
    }
}
