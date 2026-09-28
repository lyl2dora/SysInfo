import Testing
import SysCollectors

@Suite struct PrivateLayerTests {
    @Test func placeholderLayerHasVersionZero() {
        // M0 的私有层只有占位，接口版本为 0。
        #expect(PrivateLayer.version == 0)
    }
}
