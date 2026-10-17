// 导出脱敏：断言名里的扩展实例 UUID 替换为 <uuid>（K34、D71 全量验收发现）。

import Testing
@testable import SysStore

@Suite struct ExportRedactionTests {
    @Test func assertionNameUUIDsAreRedacted() {
        let name = "extension<com.apple.weather.widget[config:0A1B2C3D-4E5F-4061-8728-394A5B6C7D8E]>[uuid:9f8e7d6c-5b4a-4938-8271-605f4e3d2c1b]"
        #expect(HistoryExporter.redactingUUIDs(name) == "extension<com.apple.weather.widget[config:<uuid>]>[uuid:<uuid>]")
    }

    @Test func namesWithoutUUIDsAreUnchanged() {
        #expect(HistoryExporter.redactingUUIDs("Example VM Running") == "Example VM Running")
    }
}
