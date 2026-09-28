import Testing
import SysModel

@Suite struct MetricIDTests {
    @Test func literalAndRawValueAreEquivalent() {
        let literal: MetricID = "cpu.usage.total"
        #expect(literal == MetricID(rawValue: "cpu.usage.total"))
        #expect(literal.description == "cpu.usage.total")
    }

    @Test func knownMetricNamesAreStable() {
        // 这些名字会进入历史库、导出列名和小组件快照，改名要当作不兼容变更处理。
        #expect(MetricID.cpuUsageTotal.rawValue == "cpu.usage.total")
        #expect(MetricID.cpuUsageCore(0).rawValue == "cpu.usage.core.0")
        #expect(MetricID.cpuUsageCore(17).rawValue == "cpu.usage.core.17")
        #expect(MetricID.appSelfCPU.rawValue == "app.self.cpu")
        #expect(MetricID.appSelfFootprint.rawValue == "app.self.footprint")
    }

    @Test func collectorIDIsOrderedByRawValue() {
        let ids: [CollectorID] = ["cpu.load", "app.self"]
        #expect(ids.sorted() == ["app.self", "cpu.load"])
    }
}
