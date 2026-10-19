// 桌面小组件的快照写入（D90、D91，规格 docs/design/widgets.md §4–§6.4）。
//
// - 只在有组件放置时工作：每 30 s 看一眼扩展留下的「想要数据」标记（只是一次文件读取），
//   每个写入周期查一次 `currentConfigurations`（D90 W2）；没有组件时撤掉采样需求、不写文件（D12）。
// - 有组件时登记一条后台需求（锁屏 / 显示器睡眠时保留），按节奏从 MetricStore 取当前值、
//   从历史库取 24 h 曲线，写进组容器，再刷新组件（probe B：主进程主动刷新会被照做）。
// - 点击刷新（RefreshWidgetIntent，在主进程执行）：临时加 1 s 的需求，等新样本到了再写。
// - 正常退出时写一份 appRunning = false，组件马上显示「未运行」。

import Foundation
import SysCollectors
import SysModel
import SysStore
import WidgetKit
import os

@Observable
final class WidgetSnapshotWriter {
    /// 已放置的组件（尺寸），设置页显示。
    private(set) var placedFamilies: [WidgetFamily] = []
    private(set) var lastWrite: Date?
    /// 没有 App Group（ad-hoc 签名的构建）时整个功能不可用，设置页注明。
    let available = WidgetStorage.containerURL != nil

    @ObservationIgnored private let store: MetricStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let history: HistoryRecorder?
    @ObservationIgnored private let demand: DemandSlot
    @ObservationIgnored private let burst: DemandSlot
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var writing = false
    @ObservationIgnored private var appliedInterval: TimeInterval?

    /// 检查「想要数据」标记的间隔；写入周期是它的整数倍。
    static let pollSeconds: TimeInterval = 30

    static let collectors: Set<CollectorID> = [
        CPULoadCollector.collectorID, MemoryCollector.collectorID, PowerRailCollector.collectorID,
        PowerSensorCollector.collectorID, SMARTCollector.collectorID, NetworkIOCollector.collectorID,
    ]

    init(store: MetricStore, settings: AppSettings, history: HistoryRecorder?, engine: SamplingEngine) {
        self.store = store
        self.settings = settings
        self.history = history
        demand = DemandSlot(engine: engine)
        burst = DemandSlot(engine: engine)
    }

    var interval: TimeInterval { settings.widgetRefreshInterval.seconds }

    func start() {
        guard available, timer == nil else { return }
        RefreshWidgetIntent.handler = { [weak self] in await self?.refreshNow() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        Task { await cycle(reason: "launch") }
    }

    /// 设置变了：只有节奏改了才跟着改需求、立刻写一份。
    func settingsChanged() {
        guard available, appliedInterval != nil, appliedInterval != interval, !placedFamilies.isEmpty else { return }
        applyDemand()
        Task { await write(reason: "settings") }
    }

    /// 设置页打开时：立刻查一次放置情况（有组件就顺便写一份）。
    func refreshPlacement() async {
        guard available else { return }
        await cycle(reason: "settings")
    }

    private func poll() {
        ticks += 1
        if WidgetStorage.takeWanted() != nil {
            Task { await cycle(reason: "wanted") }
        } else if ticks % max(Int(interval / Self.pollSeconds), 1) == 0 {
            Task { await cycle(reason: "timer") }
        }
    }

    /// 查放置情况；有组件就写。
    private func cycle(reason: String) async {
        let configs = (try? await WidgetCenter.shared.currentConfigurations()) ?? []
        let families = configs.filter { $0.kind == WidgetSnapshot.widgetKind }.map(\.family)
        let wasPlaced = !placedFamilies.isEmpty
        if families != placedFamilies { placedFamilies = families }
        if families.isEmpty != !wasPlaced {
            Log.widgets.info("已放置的组件：\(families.count, privacy: .public) 个")
        }
        applyDemand()
        guard !families.isEmpty || reason == "wanted" else { return }
        await write(reason: reason)
    }

    private func applyDemand() {
        appliedInterval = interval
        demand.set(
            placedFamilies.isEmpty
                ? nil
                : Demand(
                    collectors: Self.collectors, interval: Int(interval), source: DemandSource("widgets"), tier: .background))
    }

    /// 点击刷新：临时 1 s 的需求，等 CPU 占用出现比点击更新的样本（最多 2 s）再写。
    func refreshNow() async {
        let started = Date()
        burst.set(Demand(collectors: Self.collectors, interval: 1, source: DemandSource("widgets.refresh")))
        for _ in 0..<20 {
            if let t = store.latest[.cpuUsageTotal]?.time.wallClock, t > started { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        burst.set(nil)
        await write(reason: "refresh")
    }

    /// 正常退出：写一份「未运行」并刷新（规格 §6.4）。
    func appWillTerminate() {
        guard available, var snapshot = WidgetStorage.readSnapshot() else { return }
        snapshot.appRunning = false
        try? WidgetStorage.write(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
    }

    private func write(reason: String) async {
        guard !writing else { return }
        writing = true
        defer { writing = false }
        let now = Date()
        var items: [WidgetSnapshot.Item] = []
        for slot in WidgetSlot.allCases {
            let metric = Self.metric(slot)
            let (value, quality) = current(metric, now: now)
            let curve = WidgetSlot.curved.contains(slot) ? await self.curve(metric, now: now) : nil
            items.append(.init(slot: slot, value: value, quality: quality, curve: curve))
        }
        let snapshot = WidgetSnapshot(
            generatedAt: now, refreshInterval: interval, historyEnabled: historyEnabled, items: items)
        do {
            try WidgetStorage.write(snapshot)
            lastWrite = now
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
        } catch {
            Log.widgets.error("写快照失败（\(reason, privacy: .public)）：\(error.localizedDescription, privacy: .public)")
        }
    }

    private static func metric(_ slot: WidgetSlot) -> MetricID? {
        switch slot {
        case .cpuUsage: .cpuUsageTotal
        case .memoryUsage: .memoryUsage
        case .systemPower: .powerSystem
        case .socHotspot: .thermalSoCHotspot
        case .networkIn: .networkPrimaryIn
        case .networkOut: .networkPrimaryOut
        case .bootDiskTemperature: StorageModel.shared.resolveDisk(.primary).map { .storageDisk($0, .temp) }
        }
    }

    /// 当前值：比一个写入周期还旧的样本按陈旧处理，写成不可用，不拿旧值冒充（规格 §4.2）。
    private func current(_ metric: MetricID?, now: Date) -> (Double?, DataQuality) {
        guard let metric, let sample = store.latest[metric] else { return (nil, .unavailable(.readFailed("noSample"))) }
        if now.timeIntervalSince(sample.time.wallClock) > interval + 30 {
            return (nil, .unavailable(UnavailableReason(code: "stale")))
        }
        return (sample.value, sample.quality)
    }

    private var historyEnabled: Bool {
        history != nil && settings.historyCPUEnabled && settings.historyPowerEnabled && settings.historyMemoryEnabled
    }

    /// 24 h 曲线，每 5 分钟一个点；历史库没有数据时退回内存里最近 15 分钟（规格 §4.3）。
    private func curve(_ metric: MetricID?, now: Date) async -> [WidgetSnapshot.CurvePoint] {
        guard let metric else { return [] }
        let since = Int64(now.timeIntervalSince1970 / 60) - 24 * 60
        if let history,
            let points = try? await history.series(
                metric, from: now.addingTimeInterval(-86_400), to: now, granularity: .minute, bucketMinutes: 5),
            !points.isEmpty
        {
            return WidgetCurve.bucketed(points.map { ($0.minute, $0.avg) }, bucketMinutes: 5, since: since)
        }
        let recent = store.recentPoints(metric, seconds: 900).compactMap { p in
            p.value.map { (minute: Int64(p.wallClock.timeIntervalSince1970 / 60), value: $0) }
        }
        return WidgetCurve.bucketed(recent, bucketMinutes: 1, since: since)
    }
}
