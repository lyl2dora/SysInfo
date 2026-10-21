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
    /// 上一份快照写入时各曲线项的历史开关（`WidgetSlot.curved` 的顺序）。
    @ObservationIgnored private var writtenCurveHistory: [Bool] = []
    /// 上一份快照写入时的盘温与可用空间目标（跟随菜单栏 widget 的设置）。
    @ObservationIgnored private var writtenDiskTargets: [StorageTarget] = []

    /// 检查「想要数据」标记的间隔；写入周期是它的整数倍。
    static let pollSeconds: TimeInterval = 30

    static let collectors: Set<CollectorID> = [
        CPULoadCollector.collectorID, MemoryCollector.collectorID, PowerRailCollector.collectorID,
        PowerSensorCollector.collectorID, SMARTCollector.collectorID, NetworkIOCollector.collectorID,
        GPUPowerCollector.collectorID, StorageCapacityCollector.collectorID,
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
        // 启动时先查放置情况、登记需求，等每一项的第一个样本都到了再写（最多 10 s），
        // 免得把「还没采到」写成不可用。盘温来自 blocking 通道的 SMART，往往比 CPU 晚到；
        // 菜单栏没有绑定启动盘时，SMART 在登记需求之前也可能没人要。
        Task {
            await updatePlacement()
            for _ in 0..<50 where !placedFamilies.isEmpty && !firstSamplesArrived {
                try? await Task.sleep(for: .milliseconds(200))
            }
            await cycle(reason: "launch")
        }
    }

    private var firstSamplesArrived: Bool {
        // 风扇可能根本没有（不适用），不等它
        // 「所有盘最高温」时盘温不对应单个指标，也不等它
        WidgetSlot.allCases.filter { $0 != .fanSpeed && !($0 == .diskTemperature && hottest) }.allSatisfy { slot in
            metric(slot).map { store.latest[$0] != nil } ?? false
        }
    }

    /// 设置变了：节奏改了就跟着改需求；节奏、曲线所看的历史开关或盘的目标改了，立刻写一份。
    func settingsChanged() {
        guard available, appliedInterval != nil, !placedFamilies.isEmpty else { return }
        let curveSources = WidgetSlot.curved.map(historyEnabled)
        let intervalChanged = appliedInterval != interval
        guard intervalChanged || curveSources != writtenCurveHistory || diskTargets != writtenDiskTargets else { return }
        if intervalChanged { applyDemand() }
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
        let families = await updatePlacement()
        guard !families.isEmpty || reason == "wanted" else { return }
        await write(reason: reason)
    }

    /// 查放置情况，跟着登记或撤掉采样需求。
    @discardableResult
    private func updatePlacement() async -> [WidgetFamily] {
        let configs = (try? await WidgetCenter.shared.currentConfigurations()) ?? []
        let families = configs.filter { $0.kind == WidgetSnapshot.widgetKind }.map(\.family)
        let wasPlaced = !placedFamilies.isEmpty
        if families != placedFamilies { placedFamilies = families }
        if families.isEmpty != !wasPlaced {
            Log.widgets.info("已放置的组件：\(families.count, privacy: .public) 个")
        }
        applyDemand()
        return families
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
        writtenCurveHistory = WidgetSlot.curved.map(historyEnabled)
        writtenDiskTargets = diskTargets
        var items: [WidgetSnapshot.Item] = []
        var tempDisk = metric(.diskTemperature)?.storageDiskMetric?.key
        for slot in WidgetSlot.allCases {
            let (value, quality): (Double?, DataQuality)
            if slot == .fanSpeed {
                // 没有风扇的机器不写这一项（不适用，不是不可用）
                let fans = store.latest.filter { $0.key.fanSpeedIndex != nil }
                guard !fans.isEmpty else { continue }
                (value, quality) = current(fans.max { ($0.value.value ?? 0) < ($1.value.value ?? 0) }?.key, now: now)
            } else if slot == .diskTemperature, hottest {
                // 「所有盘最高温」：与菜单栏盘温 widget 相同，取各盘读数的最大值
                let temps = store.latest.filter { $0.key.storageDiskMetric?.metric == .temp && $0.value.value != nil }
                let hottestID = temps.max { $0.value.value! < $1.value.value! }?.key
                tempDisk = hottestID?.storageDiskMetric?.key
                (value, quality) = current(hottestID, now: now)
            } else {
                (value, quality) = current(metric(slot), now: now)
            }
            let curve = WidgetSlot.curved.contains(slot) ? await self.curve(slot, metric(slot), now: now) : nil
            items.append(.init(slot: slot, value: value, quality: quality, curve: curve?.points, curveSource: curve?.source))
        }
        // 只写显示名，不写盘与组的键（D22）
        let storage = StorageModel.shared
        let diskName = tempDisk.flatMap { storage.inventory.disk($0) }.map {
            StorageText.diskName($0, inventory: storage.inventory)
        }
        let groupKey = storage.resolveGroup(settings.diskFreeTarget)
        let snapshot = WidgetSnapshot(
            generatedAt: now, refreshInterval: interval, items: items, cpuLevels: cpuLevels(now: now),
            diskName: diskName, diskGroupName: storage.groups.first { $0.key == groupKey }?.name)
        do {
            try WidgetStorage.write(snapshot)
            lastWrite = now
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
        } catch {
            Log.widgets.error("写快照失败（\(reason, privacy: .public)）：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 盘温与可用空间跟随菜单栏 widget 的设置（与菜单栏、面板总览相同的解析）。
    private var diskTargets: [StorageTarget] { [settings.diskTemperatureTarget, settings.diskFreeTarget] }
    private var hottest: Bool { settings.diskTemperatureTarget == .hottest }

    private func metric(_ slot: WidgetSlot) -> MetricID? {
        let storage = StorageModel.shared
        return switch slot {
        case .cpuUsage: .cpuUsageTotal
        case .memoryUsage: .memoryUsage
        case .systemPower: .powerSystem
        case .socHotspot: .thermalSoCHotspot
        case .networkIn: .networkPrimaryIn
        case .networkOut: .networkPrimaryOut
        case .diskTemperature: storage.resolveDisk(settings.diskTemperatureTarget).map { .storageDisk($0, .temp) }
        case .gpuUsage: .gpuActive
        case .gpuPower: .powerGPU
        case .memoryUsed: .memoryUsed
        case .memoryTotal: .memoryPhysical
        case .memoryPressure: .memoryPressure
        case .swapUsed: .memorySwapUsed
        case .fanSpeed: nil  // 多个风扇取最高，见 write
        case .diskFree: storage.resolveGroup(settings.diskFreeTarget).map { .storageGroup($0, .available) }
        case .diskTotal: storage.resolveGroup(settings.diskFreeTarget).map { .storageGroup($0, .total) }
        }
    }

    /// CPU 各档占用：档数与档名运行时取（D20）；拓扑不成立时不写。
    private func cpuLevels(now: Date) -> [WidgetSnapshot.CPULevel] {
        guard let topology = CPUTopologyService.shared.current else { return [] }
        return topology.perfLevels.map { level in
            let (value, quality) = current(.cpuUsagePerfLevel(level.index), now: now)
            return .init(label: DisplayNames.perfLevel(level.name), name: level.name, value: value, quality: quality)
        }
    }

    /// 当前值：比一个写入周期还旧的样本按陈旧处理，写成不可用，不拿旧值冒充（规格 §4.2）。
    /// 功率类取与菜单栏相同的平滑值（K24）；只有小组件在采样时间隔远超时间常数，平滑值就等于原始值。
    private func current(_ metric: MetricID?, now: Date) -> (Double?, DataQuality) {
        guard let metric, let sample = store.latest[metric] else { return (nil, .unavailable(.readFailed("noSample"))) }
        if now.timeIntervalSince(sample.time.wallClock) > interval + 30 {
            return (nil, .unavailable(UnavailableReason(code: "stale")))
        }
        let value = MetricStore.smoothedIDs.contains(metric) ? store.smoothed[metric] ?? sample.value : sample.value
        return (value, sample.quality)
    }

    /// 这一项所属模块的历史记录开着没有（规格 §4.3：每项各看各的）。
    private func historyEnabled(_ slot: WidgetSlot) -> Bool {
        guard history != nil else { return false }
        return switch slot {
        case .cpuUsage: settings.historyCPUEnabled
        case .gpuUsage: settings.historyGPUEnabled
        case .systemPower, .socHotspot: settings.historyPowerEnabled
        case .memoryUsage: settings.historyMemoryEnabled
        default: false
        }
    }

    /// 24 h 曲线，每 5 分钟一个点；该模块的历史关着、或库里还没有数据时，用内存里最近 15 分钟（规格 §4.3）。
    /// 历史关着时不读库：库里留着关之前的数据，画出来会和「已关闭」的说明对不上。
    private func curve(_ slot: WidgetSlot, _ metric: MetricID?, now: Date) async
        -> (points: [WidgetSnapshot.CurvePoint], source: WidgetSnapshot.CurveSource)
    {
        let enabled = historyEnabled(slot)
        guard let metric else { return ([], enabled ? .history : .historyOff) }
        if enabled, let history,
            let points = try? await history.series(
                metric, from: now.addingTimeInterval(-86_400), to: now, granularity: .minute, bucketMinutes: 5),
            !points.isEmpty
        {
            let since = Int64(now.timeIntervalSince1970 / 60) - 24 * 60
            return (WidgetCurve.bucketed(points.map { ($0.minute, $0.avg) }, bucketMinutes: 5, since: since), .history)
        }
        let recent = store.recentPoints(metric, seconds: 900).compactMap { p in
            p.value.map { (minute: Int64(p.wallClock.timeIntervalSince1970 / 60), value: $0) }
        }
        let since = Int64(now.timeIntervalSince1970 / 60) - 15
        return (WidgetCurve.bucketed(recent, bucketMinutes: 1, since: since), enabled ? .recent : .historyOff)
    }
}
