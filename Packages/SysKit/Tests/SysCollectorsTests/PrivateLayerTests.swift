import Darwin
import Testing
import SysCollectors

@Suite struct PrivateLayerTests {
    @Test func placeholderLayerHasVersionZero() {
        // M0 的私有层只有占位，接口版本为 0。
        #expect(PrivateLayer.version == 0)
    }

    @Test(.tags(.hardware), .hardwareOnly)
    func logicalCPUCountIsPositive() {
        // 硬件测试框架的冒烟测试：能从真实机器读到逻辑核数。
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rc = sysctlbyname("hw.logicalcpu", &count, &size, nil, 0)
        #expect(rc == 0)
        #expect(count > 0)
    }
}
