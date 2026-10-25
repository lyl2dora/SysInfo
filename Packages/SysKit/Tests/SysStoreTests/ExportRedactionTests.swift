// 导出脱敏：断言名里的扩展实例 UUID 替换为 <uuid>（K34、D71 全量验收发现）；路径里的用户名、卷名与 UUID（D101）。

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

    @Test func homeDirectoriesBecomeTilde() {
        #expect(HistoryExporter.redactingPaths("/Users/someone/bin/tool") == "~/bin/tool")
        #expect(HistoryExporter.redactingPaths("/System/Volumes/Data/Users/someone/x") == "~/x")
        #expect(HistoryExporter.redactingPaths("/Users/someone") == "~")
        #expect(HistoryExporter.redactingPaths("/Users/Shared/tool") == "/Users/Shared/tool")
        #expect(HistoryExporter.redactingPaths("Playing (/Users/someone/a.mp3)") == "Playing (~/a.mp3)")
        #expect(HistoryExporter.redactingPaths("/opt/Users/someone/x") == "/opt/Users/someone/x")
    }

    @Test func volumeNamesAreReplaced() {
        #expect(HistoryExporter.redactingPaths("/Volumes/External Disk/app/bin") == "/Volumes/<volume>/app/bin")
        #expect(HistoryExporter.redactingPaths("/Volumes/External") == "/Volumes/<volume>")
        #expect(HistoryExporter.redactingPaths("/System/Volumes/Preboot/x") == "/System/Volumes/Preboot/x")
        #expect(HistoryExporter.redactingPaths("/Volumes/<volume>/x") == "/Volumes/<volume>/x")
    }

    @Test func pathUUIDsAreReplaced() {
        let simulator =
            "/Users/someone/Library/Developer/CoreSimulator/Devices/0A1B2C3D-4E5F-4061-8728-394A5B6C7D8E/data/x"
        #expect(
            HistoryExporter.redactingPaths(simulator) == "~/Library/Developer/CoreSimulator/Devices/<uuid>/data/x")
        let translocated = "/private/var/folders/AppTranslocation/9f8e7d6c-5b4a-4938-8271-605f4e3d2c1b/d/Foo.app"
        #expect(HistoryExporter.redactingPaths(translocated) == "/private/var/folders/AppTranslocation/<uuid>/d/Foo.app")
        #expect(HistoryExporter.redactingPaths("com.example.app") == "com.example.app")
    }

    @Test func appsCSVRedactsKeys() {
        let row = ExportAppRow(
            minute: 0, key: "/Users/someone/bin/tool", name: "tool", cpuNanos: 0, energy: nil, gpuNanos: nil,
            gpuEnergy: nil, aneEnergy: nil, diskRead: nil, diskWrite: nil, wakeups: nil, footprint: nil)
        let csv = HistoryExporter.appsCSV([row])
        #expect(csv.contains(",~/bin/tool,"))
        #expect(!csv.contains("someone"))
    }
}
