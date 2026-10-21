// 桌面小组件快照 v3（D90、D91，规格 docs/design/widgets.md §3、widgets-rich.md §3）。

import Foundation
import Testing
import SysModel

@Suite struct WidgetSnapshotTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot(appRunning: Bool = true) -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: t0, appRunning: appRunning, refreshInterval: 300,
            items: [
                .init(slot: .cpuUsage, value: 0.25, quality: .measured, curve: [.init(minute: 10, value: 0.2)]),
                .init(slot: .socHotspot, value: nil, quality: .unavailable(.sensorPowerGated())),
                .init(slot: .systemPower, value: 3.4, quality: .estimated),
            ])
    }

    @Test func roundTripsAndRejectsOtherVersions() throws {
        let s = snapshot()
        #expect(WidgetSnapshot.decode(try s.encoded()) == s)
        var old = s
        old.version = 2
        #expect(WidgetSnapshot.decode(try old.encoded()) == nil)
        #expect(WidgetSnapshot.decode(Data("garbage".utf8)) == nil)
    }

    @Test func curveSourceIsPerItemAndOnlyWithACurve() throws {
        let off = WidgetSnapshot.Item(slot: .cpuUsage, value: 0.2, quality: .measured, curve: [], curveSource: .historyOff)
        #expect(off.curveSource == .historyOff && off.curveSource?.span == 900)
        // 带曲线没说来源：按历史库处理；不带曲线：没有来源
        #expect(WidgetSnapshot.Item(slot: .cpuUsage, value: 0.2, quality: .measured, curve: []).curveSource == .history)
        #expect(WidgetSnapshot.Item(slot: .networkIn, value: 1, quality: .measured, curveSource: .recent).curveSource == nil)
        var s = snapshot()
        s.items.append(off)
        #expect(WidgetSnapshot.decode(try s.encoded()) == s)
    }

    @Test func unavailableItemsCarryNoValue() {
        let s = snapshot()
        #expect(s.item(.socHotspot)?.value == nil)
        #expect(s.item(.socHotspot)?.quality.isAvailable == false)
        // 有质量却没有值：按不可用处理，不冒充实测
        let missing = WidgetSnapshot.Item(slot: .memoryUsage, value: nil, quality: .measured)
        #expect(!missing.quality.isAvailable)
        // 不可用却带了值：值被丢掉
        let contradictory = WidgetSnapshot.Item(slot: .memoryUsage, value: 0.5, quality: .unavailable(.readFailed()))
        #expect(contradictory.value == nil)
    }

    @Test func staleAfterThreeIntervalsOrWhenAppStopped() {
        let s = snapshot()
        #expect(!s.isStale(at: t0.addingTimeInterval(899)))
        #expect(s.isStale(at: t0.addingTimeInterval(901)))
        #expect(snapshot(appRunning: false).isStale(at: t0))
    }

    @Test func wantsRefreshAfterOneIntervalPlusGrace() {
        let s = snapshot()
        #expect(!s.wantsRefresh(at: t0.addingTimeInterval(359)))
        #expect(s.wantsRefresh(at: t0.addingTimeInterval(361)))
        #expect(snapshot(appRunning: false).wantsRefresh(at: t0))
    }

    @Test func curveBucketsAverageAndDropOldPoints() {
        let points: [(minute: Int64, value: Double)] = [(98, 9), (100, 1), (101, 3), (104, 5), (105, 7), (106, .nan)]
        let curve = WidgetCurve.bucketed(points, bucketMinutes: 5, since: 100)
        #expect(curve == [.init(minute: 100, value: 3), .init(minute: 105, value: 7)])
    }

    @Test func formatsLikeTheMenuBar() {
        #expect(WidgetFormat.string(.cpuUsage, 0.256) == "26%")
        #expect(WidgetFormat.string(.systemPower, 9.94) == "9.9 W")
        #expect(WidgetFormat.string(.systemPower, 18.4) == "18 W")
        #expect(WidgetFormat.string(.socHotspot, 54.6) == "55°")
        #expect(WidgetFormat.string(.networkIn, 1_234_000) == "1.2 MB/s")
        #expect(WidgetFormat.string(.networkOut, 812) == "812 B/s")
        #expect(WidgetFormat.string(.cpuUsage, nil) == PercentFormat.placeholder)
    }

    @Test func formatsMemoryAndDiskSizes() {
        #expect(WidgetFormat.string(.memoryTotal, 64 * 1_073_741_824) == "64 GB")
        #expect(WidgetFormat.string(.swapUsed, 1.25 * 1_073_741_824) == "1.2 GB")
        #expect(WidgetFormat.string(.bootDiskFree, 719_400_000_000) == "719 GB")
        #expect(WidgetFormat.string(.bootDiskFree, 1_520_000_000_000) == "1.52 TB")
        #expect(WidgetFormat.string(.fanSpeed, 1094.6) == "1095 rpm")
        #expect(WidgetFormat.string(.gpuUsage, 0.07) == "7%")
    }

    @Test func cpuLevelsRoundTripAndCarryNoValueWhenUnavailable() throws {
        var s = snapshot()
        s.cpuLevels = [
            .init(label: "超级核", name: "Super", value: 0.42, quality: .measured),
            .init(label: "性能核", name: "Performance", value: 0.3, quality: .unavailable(.readFailed())),
        ]
        #expect(s.cpuLevels[1].value == nil)
        #expect(WidgetSnapshot.decode(try s.encoded()) == s)
    }

    @Test func bootDiskUsedRatioNeedsBothValues() {
        var s = snapshot()
        #expect(s.bootDiskUsedRatio == nil)
        s.items.append(.init(slot: .bootDiskFree, value: 250, quality: .measured))
        #expect(s.bootDiskUsedRatio == nil)
        s.items.append(.init(slot: .bootDiskTotal, value: 1000, quality: .measured))
        #expect(s.bootDiskUsedRatio == 0.75)
    }
}
