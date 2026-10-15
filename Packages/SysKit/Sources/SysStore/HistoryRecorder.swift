// 历史记录器（CPU 模块设计 §6，D30）：订阅引擎事件，按分钟聚合，定时写库。
//
// - 登记 background 层需求（锁屏、显示器睡眠时继续采，不受降频影响）：
//   CPU tick、频率、杂项每 60 s；温度与功耗每 10 s；coalition 每 10 s（记录每应用时）。
//   用户开启「后台高精度」时，频率、温度与功耗改为每 5 s（D19 的高开销项）。
//   菜单栏、面板的前台需求更密时，引擎按较短的间隔采样，记录器直接用这些样本，峰值随之更准；
// - 每 5 分钟（整 5 分之后 1 分钟，即 :01、:06…）提交一次事务：写入已结束的分钟、新开 epoch、小时汇总、
//   每天一次的过期清理。睡眠、退出、导出前由调用方 `flush()` 立即提交（含当前这一分钟，之后的数据按 UPSERT 合并）；
// - 唤醒后调用 `noteWake()`：丢弃各采集器唤醒后的第一个样本（不知道它覆盖了多长的区间）；
// - 只在 actor 自己的执行器上运行，不碰 MainActor（D03、D23）。

import Foundation
import SysCollectors
import SysModel
import os

extension DemandSource {
    /// 历史记录的后台需求。
    public static let history: DemandSource = "history"
}

public actor HistoryRecorder {
    public struct Configuration: Sendable, Hashable {
        /// 记录整机 CPU 指标（设置「是否记录 CPU 历史」）。
        public var recordSystem: Bool
        /// 记录每应用 CPU（设置「是否记录每应用 CPU」）。
        public var recordApps: Bool
        /// 后台高精度：频率、温度与功耗改为每 5 s（用户开启的高开销项，D19、CPU 模块设计 §7.3）。
        public var highPrecision: Bool
        /// 记录功耗与散热指标（设置「记录功耗与散热历史」）：SoC/GPU 功率、最热点、风扇每 10 s，PMGR 批次每 60 s。
        public var recordPower: Bool
        /// 记录能耗（D46）：PDTR 每 1 s 积分。
        public var recordEnergy: Bool

        public init(
            recordSystem: Bool = true, recordApps: Bool = true, highPrecision: Bool = false, recordPower: Bool = true,
            recordEnergy: Bool = true
        ) {
            self.recordSystem = recordSystem
            self.recordApps = recordApps
            self.highPrecision = highPrecision
            self.recordPower = recordPower
            self.recordEnergy = recordEnergy
        }
    }

    /// 功耗与散热的状态来源：能耗补数要读遥测，PMGR 批次状态要持久化（功耗与散热模块设计 §5、§6）。
    public struct PowerSources: Sendable {
        public var ledger: PowerLedger?
        public var pmgr: PMGRBatchCollector?

        public init(ledger: PowerLedger?, pmgr: PMGRBatchCollector?) {
            self.ledger = ledger
            self.pmgr = pmgr
        }
    }

    /// PDTR 积分的间隔（D46：1 s）、PMGR 批次检查的间隔。
    public static let energyInterval = 1
    public static let pmgrInterval = 60
    static let anchorKey = "energy.anchor"
    static let pmgrKey = "pmgr.state"

    /// 后台采样间隔（D30），基础 tick 数。
    public static let slowInterval = 60
    public static let sensorInterval = 10
    public static let appInterval = 10
    /// 高精度时频率、温度与功耗的间隔。
    public static let highPrecisionInterval = 5
    /// 提交周期，分钟；在周期边界之后这么多秒提交（让上一分钟最后一个 1 s 样本先到）。
    static let flushPeriodMinutes: Int64 = 5
    static let flushOffsetSeconds: Int64 = 62
    /// 每个窗口为前多少个 coalition 解析应用身份。每分钟的前 10 几乎总在各窗口的前列里；
    /// coalition 退出后就解析不到，所以要在窗口到达时就解析。
    static let identitiesPerWindow = 16

    private let store: HistoryStore
    private let engine: SamplingEngine
    private let appSampler: AppSampler?
    private let power: PowerSources
    private var energy = EnergyIntegrator()
    /// 本次运行是否已经处理过「app 没运行的时段」的补数。
    private var gapHandled = false
    private var savedPMGR: PMGRState?
    private let resolver = AppIdentityResolver()
    /// 当前机器的 epoch 信息（起始分钟由记录器填）。
    private let epoch: @Sendable (Int64) -> HistoryEpoch?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "sysinfo-cli", category: "history")

    private var configuration: Configuration
    private var aggregator = MinuteAggregator()
    private var tokens: [DemandToken] = []
    private var pump: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var lastPrune: Date?

    /// 最近一次提交的时刻与错误（诊断页、设置页显示）。
    public private(set) var lastFlush: Date?
    public private(set) var lastError: String?
    /// 至今写入的分钟行数与每应用行数。
    public private(set) var writtenRows = 0
    public private(set) var writtenAppRows = 0

    /// - Parameters:
    ///   - store: 历史库；交给记录器后由它独占。
    ///   - appSampler: 引擎里的 `app.coalition` 实例（每应用数据从它取窗口）；nil 时不记每应用。
    ///   - epoch: 返回当前机器的 epoch（参数是起始分钟）；默认按 `HistoryRecorder.currentEpoch` 读取。
    public init(
        store: sending HistoryStore, engine: SamplingEngine, appSampler: AppSampler?,
        power: PowerSources = PowerSources(ledger: nil, pmgr: nil), configuration: Configuration = Configuration(),
        epoch: @escaping @Sendable (Int64) -> HistoryEpoch? = { HistoryRecorder.currentEpoch(startMinute: $0) }
    ) {
        self.store = store
        self.engine = engine
        self.appSampler = appSampler
        self.power = power
        self.configuration = configuration
        self.epoch = epoch
    }

    /// SoC 标识要遍历 IORegistry，只读一次（一次运行期间不会变）。
    private static let socID = ChipIdentity.socID()

    /// 当前机器：机型、SoC、系统 build 与拓扑（D20：全部运行时读取）。拓扑还没发现时为 nil，等下一次提交。
    public static func currentEpoch(startMinute: Int64) -> HistoryEpoch? {
        guard let topology = CPUTopologyService.shared.current else { return nil }
        return HistoryEpoch(
            startMinute: startMinute, model: SystemInfo.modelIdentifier ?? "unknown",
            chip: socID ?? "unknown", osBuild: SystemInfo.osBuild ?? "unknown",
            topologyJSON: EpochTopology(topology).json())
    }

    // MARK: - 生命周期

    /// 开始记录：订阅引擎事件、登记后台需求、排定提交。重复调用没有副作用。
    public func start() async {
        guard pump == nil else { return }
        // PMGR：恢复上一次运行的批次状态，重启后能立即显示上一批（功耗与散热模块设计 §4.4）。
        if let pmgr = power.pmgr, let saved = try? store.decoded(PMGRState.self, forKey: Self.pmgrKey) {
            pmgr.restore(saved)
            savedPMGR = saved
        }
        let stream = await engine.events()
        pump = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
        await applyDemands()
        scheduleFlush()
        logger.info("历史记录开始：\(self.store.path, privacy: .private)")
    }

    /// 停止记录：注销需求、提交剩余数据。
    public func stop() async {
        tokens.forEach { $0.cancel() }
        tokens = []
        appSampler?.setRetainsWindows(false)
        pump?.cancel()
        pump = nil
        timer?.cancel()
        timer = nil
        flush()
        try? store.checkpoint()
    }

    public func setConfiguration(_ configuration: Configuration) async {
        guard configuration != self.configuration else { return }
        self.configuration = configuration
        if !configuration.recordApps { aggregator.clearApps() }
        if pump != nil { await applyDemands() }
    }

    private func applyDemands() async {
        tokens.forEach { $0.cancel() }
        tokens = []
        var demands: [Demand] = []
        let recordApps = configuration.recordApps && appSampler != nil
        if configuration.recordSystem {
            let precise = configuration.highPrecision
            demands.append(
                Demand(
                    collectors: [CPULoadCollector.collectorID, CPUMiscCollector.collectorID], interval: Self.slowInterval,
                    source: .history, tier: .background))
            demands.append(
                Demand(
                    collectors: [CPUFrequencyCollector.collectorID],
                    interval: precise ? Self.highPrecisionInterval : Self.slowInterval, source: .history, tier: .background))
            demands.append(
                Demand(
                    collectors: [SensorCollector.collectorID],
                    interval: precise ? Self.highPrecisionInterval : Self.sensorInterval, source: .history, tier: .background))
        }
        if recordApps {
            demands.append(
                Demand(collectors: [AppSampler.collectorID], interval: Self.appInterval, source: .history, tier: .background))
        }
        if configuration.recordPower {
            demands.append(
                Demand(
                    collectors: [PowerSensorCollector.collectorID, GPUPowerCollector.collectorID], interval: Self.sensorInterval,
                    source: .history, tier: .background))
            if power.pmgr != nil {
                demands.append(
                    Demand(
                        collectors: [PMGRBatchCollector.collectorID], interval: Self.pmgrInterval, source: .history,
                        tier: .background))
            }
        }
        if configuration.recordEnergy {
            demands.append(
                Demand(
                    collectors: [PowerRailCollector.collectorID], interval: Self.energyInterval, source: .history,
                    tier: .background))
        }
        appSampler?.setRetainsWindows(recordApps)
        for demand in demands {
            tokens.append(await engine.addDemand(demand))
        }
    }

    /// 唤醒：各采集器唤醒后的第一个样本丢弃。
    public func noteWake() {
        aggregator.noteWake()
        energy.noteWake()
        scheduleFlush()
    }

    // MARK: - 事件

    private func handle(_ event: EngineEvent) {
        guard case .tick(let result) = event else { return }
        var modules: Set<HistoryModule> = []
        if configuration.recordSystem { modules.insert(.cpu) }
        if configuration.recordPower { modules.insert(.power) }
        if !modules.isEmpty { aggregator.ingest(result, modules: modules) }
        if configuration.recordEnergy, let sample = result.samples.first(where: { $0.id == .powerSystem }), let watts = sample.value {
            energy.ingest(watts: watts, at: sample.time)
            fillGapIfNeeded()
        }
        if result.collectors.contains(AppSampler.collectorID), configuration.recordApps, let appSampler {
            for window in appSampler.drainRetainedWindows() {
                let top = window.coalitions.prefix(Self.identitiesPerWindow).filter { $0.cpuNanos > 0 }
                let identities = resolver.resolve(top.map { ($0.id, $0.tasks) })
                aggregator.ingestApps(window, identities: identities)
            }
        }
    }

    // MARK: - 提交

    /// 下一次定时提交的时刻：分钟号 ≡ 0 (mod 5) 的整分之后 `flushOffsetSeconds` 秒。
    static func nextFlushDate(after now: Date) -> Date {
        let seconds = Int64(now.timeIntervalSince1970.rounded(.down))
        let period = flushPeriodMinutes * 60
        var next = (HistoryStore.floorDiv(seconds - flushOffsetSeconds, period) + 1) * period + flushOffsetSeconds
        if next <= seconds { next += period }
        return Date(timeIntervalSince1970: TimeInterval(next))
    }

    private func scheduleFlush() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                let delay = HistoryRecorder.nextFlushDate(after: Date()).timeIntervalSinceNow
                try? await Task.sleep(for: .seconds(max(delay, 1)))
                guard !Task.isCancelled, let self else { return }
                await self.commit(includeCurrent: false)
            }
        }
    }

    /// 立即提交，包括还没结束的当前分钟（睡眠、退出、导出前，D30）。
    public func flush() {
        commit(includeCurrent: true)
    }

    private func commit(includeCurrent: Bool) {
        let now = Date()
        let current = MinuteAggregator.minute(of: now)
        let taken = aggregator.take(before: includeCurrent ? nil : current)
        do {
            let start = min(taken.rows.first?.minute ?? current, taken.apps.first?.minute ?? current)
            if let epoch = epoch(start) {
                if try store.recordEpoch(epoch) {
                    logger.info("新开一段 epoch：\(epoch.model, privacy: .public) \(epoch.chip, privacy: .public) \(epoch.osBuild, privacy: .public)")
                }
            }
            try store.write(rows: taken.rows, apps: taken.apps)
            try store.writeEnergy(energy.take(before: includeCurrent ? nil : current))
            try store.rollUpHours(through: HistoryStore.floorDiv(current, 60) - 1)
            try store.rollUpEnergyHours(through: HistoryStore.floorDiv(current, 60) - 1)
            try saveAnchorAndPMGR()
            if lastPrune.map({ now.timeIntervalSince($0) >= 86_400 }) ?? true {
                try store.prune(before: current - Int64(HistoryStore.minuteRetention / 60))
                lastPrune = now
            }
            writtenRows += taken.rows.count
            writtenAppRows += taken.apps.count
            lastFlush = now
            lastError = nil
        } catch {
            lastError = "\(error)"
            logger.error("历史提交失败：\(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - 能耗与 PMGR（功耗与散热模块设计 §5）

    /// app 没运行的时段用累加器补上（D46）。只在本次运行拿到第一个遥测读数后做一次。
    private func fillGapIfNeeded() {
        guard !gapHandled, let reading = power.ledger?.latestTelemetry, let boot = SystemInfo.bootTime else { return }
        gapHandled = true
        let anchor = try? store.decoded(EnergyAnchor.self, forKey: Self.anchorKey)
        guard let gap = EnergyGap.fill(anchor: anchor, now: reading, bootTime: boot) else { return }
        do {
            try store.writeEnergyFill(EnergyGap.perMinute(start: gap.start, end: gap.end, joules: gap.joules))
            logger.info(
                "能耗补数：\(Int(gap.end.timeIntervalSince(gap.start))) s，\(String(format: "%.1f", gap.joules / 3600)) Wh（系统累计）")
        } catch {
            logger.error("能耗补数失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// 提交时更新能耗锚点与 PMGR 批次状态。
    private func saveAnchorAndPMGR() throws {
        if configuration.recordEnergy, gapHandled, let reading = power.ledger?.latestTelemetry, let boot = SystemInfo.bootTime {
            try store.setEncoded(EnergyAnchor(telemetry: reading, bootTime: boot), forKey: Self.anchorKey)
        }
        if let state = power.pmgr?.persistentState, state != savedPMGR {
            try store.setEncoded(state, forKey: Self.pmgrKey)
            savedPMGR = state
        }
    }

    /// 一段时间内的能耗（先提交内存里的数据）。
    public func energySummary(from: Date, to: Date) throws -> EnergySummary {
        flush()
        return try store.energySummary(from: from, to: to)
    }

    // MARK: - 读取与维护

    /// 一键清除每应用数据（D30）。
    public func clearAppData() throws {
        aggregator.clearApps()
        try store.clearAppData()
    }

    /// 读一个指标（先提交内存里的数据，让图表包含最近几分钟）。
    public func series(
        _ metric: MetricID, from: Date, to: Date, granularity: HistoryGranularity, bucketMinutes: Int64 = 1
    ) throws -> [HistoryPoint] {
        flush()
        return try store.series(
            metric, from: MinuteAggregator.minute(of: from), to: MinuteAggregator.minute(of: to) + 1,
            granularity: granularity, bucketMinutes: bucketMinutes)
    }

    public func stats() throws -> HistoryStats {
        try store.stats()
    }

    public func topApps(from: Date, to: Date, limit: Int) throws -> [(key: String, name: String, cpuNanos: Int64)] {
        flush()
        return try store.topApps(
            from: MinuteAggregator.minute(of: from), to: MinuteAggregator.minute(of: to) + 1, limit: limit)
    }

    /// 导出（先提交、合并 WAL）。
    @discardableResult
    public func export(_ options: HistoryExportOptions, to destination: URL) throws -> [URL] {
        flush()
        // 合并 WAL 只是让主文件更完整；失败（例如有读事务未结束）不影响从同一连接读出的导出内容。
        do {
            try store.checkpoint()
        } catch {
            logger.notice("导出前合并 WAL 失败，照常导出：\(String(describing: error), privacy: .public)")
        }
        return try HistoryExporter.export(store, options: options, to: destination)
    }
}
