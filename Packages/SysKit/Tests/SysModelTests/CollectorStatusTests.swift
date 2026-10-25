// 采集器状态按读取成败判定：全部失败才算不可用（引擎据此做连续越界复检，K19）。

import Testing
import SysModel

@Suite struct CollectorStatusTests {
    @Test func readsMapToStatus() {
        #expect(CollectorStatus.reads(attempted: 4, failed: 0) == .ok)
        #expect(CollectorStatus.reads(attempted: 4, failed: 1) == .degraded)
        #expect(CollectorStatus.reads(attempted: 4, failed: 4) == .unavailable)
        #expect(CollectorStatus.reads(attempted: 0, failed: 0) == .ok)
    }
}
