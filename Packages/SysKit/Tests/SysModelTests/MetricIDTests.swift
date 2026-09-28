import Testing
import SysModel

@Suite struct MetricIDTests {
    @Test func literalAndRawValueAreEquivalent() {
        let literal: MetricID = "cpu.usage.total"
        #expect(literal == MetricID(rawValue: "cpu.usage.total"))
        #expect(literal.description == "cpu.usage.total")
    }
}
