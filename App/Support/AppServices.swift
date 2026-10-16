// app 层共用的对象（CPU 模块设计 §7、功耗与散热模块设计 §7）：采集器实例、Top N 模型、历史记录器。
// 面板、设置页、诊断页从这里取，不各自持有采集器。

import AppKit
import Observation
import SysCollectors
import SysModel
import SysStore
import OSLog

/// 引擎里的 CPU 采集器实例（诊断读数要直接读它们的最新细节）。
struct CPUCollectors {
    var frequency: CPUFrequencyCollector?
    var sensors: SensorCollector?
    var apps: AppSampler?
    var interrupts: InterruptDeviceCollector?
    var cores: CoreFrequencyCollector?

    init(_ collectors: [any Collector]) {
        cores = collectors.compactMap { $0 as? CoreFrequencyCollector }.first
        interrupts = collectors.compactMap { $0 as? InterruptDeviceCollector }.first
        frequency = collectors.compactMap { $0 as? CPUFrequencyCollector }.first
        sensors = collectors.compactMap { $0 as? SensorCollector }.first
        apps = collectors.compactMap { $0 as? AppSampler }.first
    }
}

/// 引擎里的功耗与散热采集器实例（诊断页、面板的 30 分钟卡片要直接读它们的状态）。
struct PowerCollectors {
    var rail: PowerRailCollector?
    var sensors: PowerSensorCollector?
    var gpu: GPUPowerCollector?
    var pmgr: PMGRBatchCollector?
    var catalog: SensorCatalog?

    init(_ collectors: [any Collector]) {
        rail = collectors.compactMap { $0 as? PowerRailCollector }.first
        sensors = collectors.compactMap { $0 as? PowerSensorCollector }.first
        gpu = collectors.compactMap { $0 as? GPUPowerCollector }.first
        pmgr = collectors.compactMap { $0 as? PMGRBatchCollector }.first
        catalog = collectors.compactMap { $0 as? SensorCatalog }.first
    }

    /// 跨采集器的核对账本（几个功耗采集器共用同一个）。
    var ledger: PowerLedger? { rail?.ledger }

    /// 有风扇（风扇 widget 与面板风扇行只在有风扇时出现）。
    var hasFans: Bool { !(sensors?.fans.isEmpty ?? true) }
}

/// 引擎里的内存采集器实例（诊断页读状态，D49）。
struct MemoryCollectors {
    var vm: MemoryCollector?
    var bandwidth: DRAMBandwidthCollector?

    init(_ collectors: [any Collector]) {
        vm = collectors.compactMap { $0 as? MemoryCollector }.first
        bandwidth = collectors.compactMap { $0 as? DRAMBandwidthCollector }.first
    }
}

/// 引擎里的存储采集器实例（面板读清单、SMART 全字段与累计错误，诊断页读连接状态，D54）。
struct StorageCollectors {
    var io: StorageIOCollector?
    var smart: SMARTCollector?
    var capacity: StorageCapacityCollector?

    init(_ collectors: [any Collector]) {
        io = collectors.compactMap { $0 as? StorageIOCollector }.first
        smart = collectors.compactMap { $0 as? SMARTCollector }.first
        capacity = collectors.compactMap { $0 as? StorageCapacityCollector }.first
    }

    static let ids: Set<CollectorID> = [
        StorageIOCollector.collectorID, SMARTCollector.collectorID, StorageCapacityCollector.collectorID,
    ]
}

/// 引擎里的 GPU 与加速器采集器实例（诊断页读档位表、温度键、媒体底数与细节读数，D57）。
/// GPU 活跃、频率与功率由 `PowerCollectors.gpu`（`power.gpu`）一并输出。
struct GPUCollectors {
    var temperature: GPUTemperatureCollector?
    var accelerators: GPUAcceleratorCollector?
    var media: MediaEngineCollector?
    var details: GPUDiagnosticsCollector?

    init(_ collectors: [any Collector]) {
        temperature = collectors.compactMap { $0 as? GPUTemperatureCollector }.first
        accelerators = collectors.compactMap { $0 as? GPUAcceleratorCollector }.first
        media = collectors.compactMap { $0 as? MediaEngineCollector }.first
        details = collectors.compactMap { $0 as? GPUDiagnosticsCollector }.first
    }
}

/// 存储的结构状态（存储模块设计 §6）：物理盘清单与容量组变化时才更新，面板据此决定有几行；
/// 另负责 widget 绑定的解析与 SMART 焦点盘（D55）。
@Observable
final class StorageModel {
    /// 菜单栏 widget 的显示配置要在没有 AppServices 的地方（设置页预览）解析绑定，所以有一个共享实例。
    static let shared = StorageModel()

    private(set) var inventory: StorageInventory = .empty
    private(set) var groups: [CapacityGroup] = []

    /// 面板存储 tab 可见、诊断页打开：这两种情况下每次读全部盘的 SMART。
    @ObservationIgnored var panelVisible = false { didSet { applyFocus() } }
    @ObservationIgnored var diagnosticsVisible = false { didSet { applyFocus() } }
    /// 菜单栏 widget 需要的盘：nil 表示要全部盘（「所有盘最高温」），空集表示没有 widget 要 SMART。
    @ObservationIgnored var widgetFocus: Set<DiskKey>? = [] { didSet { applyFocus() } }
    @ObservationIgnored weak var smart: SMARTCollector?
    /// 清单或容量组变了（盘插拔、RAID 状态变化）：菜单栏 widget 的绑定要重新解析。
    @ObservationIgnored var onStructureChange: (() -> Void)?

    func refresh(inventory: StorageInventory, groups: [CapacityGroup]?) {
        var changed = false
        if inventory != self.inventory {
            self.inventory = inventory
            changed = true
        }
        if let groups, groups.map(Self.structure) != self.groups.map(Self.structure) || groups.count != self.groups.count {
            self.groups = groups
            changed = true
        } else if let groups {
            self.groups = groups  // 只有数值变化：不触发结构变化回调
        }
        if changed { onStructureChange?() }
    }

    /// 结构比较只看组的身份与卷，不看数值。
    private static func structure(_ group: CapacityGroup) -> [String] {
        [group.key.rawValue, group.name, group.isAuxiliary ? "a" : "p"] + group.volumes.map { $0.bsdName ?? $0.name }
    }

    /// 盘温 / 读写 widget 实际绑定的盘：内置盘、指定的盘（不在了也保留键，显示「—」）。
    func resolveDisk(_ target: StorageTarget) -> DiskKey? {
        switch target {
        case .primary, .hottest, .group: inventory.primaryDisk?.key
        case .disk(let key): key
        }
    }

    /// 可用空间 widget 实际绑定的容量组：启动组、指定的组。
    func resolveGroup(_ target: StorageTarget) -> DiskKey? {
        switch target {
        case .group(let key): key
        default: (groups.first { $0.isBoot && !$0.isAuxiliary } ?? groups.first { !$0.isAuxiliary })?.key
        }
    }

    private func applyFocus() {
        let focus: Set<DiskKey>? = panelVisible || diagnosticsVisible ? nil : widgetFocus
        smart?.setFocus(focus)
    }
}

/// Top N（D31，CPU 模块设计 §5.7、§7.2）：只在所属 tab 可见且行数大于 0 时工作。
/// CPU 与内存（D49）各用一个实例，共用同一次 coalition 扫描；内存按 footprint 排序，不需要差分。
/// 组装（libproc 查询、名称解析）在后台执行，不占 MainActor（D03、D23）。
@Observable
final class TopNModel {
    private(set) var rows: [TopNRow] = []
    /// coalition 不可用、改用同 uid 回退（D31）。
    private(set) var isFallback = false
    /// 回退时读不到的进程数（root 与其他用户）。
    private(set) var hiddenCount = 0
    /// 「刷新全部」（setuid ps，D31）正在运行。
    private(set) var isRefreshingAll = false
    /// 鼠标悬停在列表上时冻结排序（CPU 模块设计 §5.7）。
    var isFrozen = false

    /// 按 CPU 还是按内存排序。
    let metric: TopNMetric
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private let builder = TopNBuilder()
    @ObservationIgnored private let fallbackSampler = SameUIDSampler()
    @ObservationIgnored private let sampler: AppSampler?
    @ObservationIgnored private var building = false
    @ObservationIgnored private var fallbackTimer: Timer?
    @ObservationIgnored var rowCount = 5
    @ObservationIgnored var grouping: TopNGrouping = .byApp
    @ObservationIgnored var interval = 2
    /// 两档芯片、拓扑成立、槽位可信时显示 perflevel0 占比（D29）。
    @ObservationIgnored var showsPerfLevel0 = false

    init(sampler: AppSampler?, metric: TopNMetric = .cpu) {
        self.sampler = sampler
        self.metric = metric
    }

    /// 面板里所属的 tab 显示或隐藏。
    func setActive(_ active: Bool, coalitionUsable: Bool) {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        isActive = active
        isFallback = active && (!coalitionUsable || sampler == nil)
        guard active else {
            rows = []
            return
        }
        // 后台历史每 10 s 扫一次 coalition，`latestWindow` 里通常已有不超过 10 s 的窗口：
        // 立即用它组装第一版，不必等面板自己的两次扫描（约 2–3 s 的「等待数据」）。
        if !isFallback { coalitionTick(maxAgeSeconds: Self.firstWindowMaxAge) }
        if isFallback {
            switch metric {
            case .memory: refreshFallback()  // footprint 是当前值，不需要基线
            case .disk: _ = fallbackSampler.sampleDisk(rows: rowCount)  // 建立基线
            case .cpu: _ = fallbackSampler.sample(rows: rowCount)  // 建立基线
            case .gpu:
                // 没有按进程的公开 GPU 计数，不回退（D57 G7）：列表留空，由界面提示。
                rows = []
                return
            }
            let timer = Timer(timeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshFallback() }
            }
            RunLoop.main.add(timer, forMode: .common)
            fallbackTimer = timer
        }
    }

    /// 面板打开时可以直接采用的窗口的最大年龄，秒（后台历史 10 s 扫一次，留一点余量）。
    static let firstWindowMaxAge: Double = 15

    /// 引擎交付了一个 `app.coalition` 结果；或面板刚打开，用已有的窗口（不超过 `maxAgeSeconds`）。
    func coalitionTick(maxAgeSeconds: Double? = nil) {
        guard isActive, !isFallback, !building, !isFrozen, rowCount > 0, let sampler else { return }
        if metric == .memory {
            memoryTick(sampler, maxAgeSeconds: maxAgeSeconds)
            return
        }
        guard let window = sampler.latestWindow else { return }
        if let maxAgeSeconds {
            let age = Double(SampleTime.now().continuousNanos &- window.time.continuousNanos) / 1e9
            guard age <= maxAgeSeconds else { return }
        }
        if metric == .disk {
            diskTick(window)
            return
        }
        if metric == .gpu {
            gpuTick(window)
            return
        }
        building = true
        let builder = builder
        let rows = rowCount
        let grouping = grouping
        let perfLevel0 = showsPerfLevel0 && sampler.auxiliarySlotsTrusted
        let trusted = sampler.auxiliarySlotsTrusted
        Task.detached(priority: .utility) { [weak self] in
            let built = builder.build(
                window: window, rows: rows, grouping: grouping, showPerfLevel0: perfLevel0, slotsTrusted: trusted)
            await MainActor.run {
                guard let self else { return }
                self.building = false
                if !self.isFrozen, self.isActive { self.rows = built }
            }
        }
    }

    /// 内存：用最近一次扫描的 footprint 组装（D49）。
    private func memoryTick(_ sampler: AppSampler, maxAgeSeconds: Double?) {
        guard let footprints = sampler.latestFootprints else { return }
        if let maxAgeSeconds {
            let age = Double(SampleTime.now().continuousNanos &- footprints.time.continuousNanos) / 1e9
            guard age <= maxAgeSeconds else { return }
        }
        building = true
        let builder = builder
        let rows = rowCount
        let grouping = grouping
        Task.detached(priority: .utility) { [weak self] in
            let built = builder.buildMemory(footprints: footprints, rows: rows, grouping: grouping)
            await MainActor.run {
                guard let self else { return }
                self.building = false
                if !self.isFrozen, self.isActive { self.rows = built }
            }
        }
    }

    /// 磁盘：用最近一个窗口的 6/7 号槽差分组装（存储模块设计 §4.5）。
    private func diskTick(_ window: AppActivityWindow) {
        building = true
        let builder = builder
        let rows = rowCount
        let grouping = grouping
        Task.detached(priority: .utility) { [weak self] in
            let built = builder.buildDisk(window: window, rows: rows, grouping: grouping)
            await MainActor.run {
                guard let self else { return }
                self.building = false
                if !self.isFrozen, self.isActive { self.rows = built }
            }
        }
    }

    /// GPU：用最近一个窗口的槽位 8 / 41 / 39 差分组装（D57 G7）。
    private func gpuTick(_ window: AppActivityWindow) {
        building = true
        let builder = builder
        let rows = rowCount
        let grouping = grouping
        Task.detached(priority: .utility) { [weak self] in
            let built = builder.buildGPU(window: window, rows: rows, grouping: grouping)
            await MainActor.run {
                guard let self else { return }
                self.building = false
                if !self.isFrozen, self.isActive { self.rows = built }
            }
        }
    }

    private func refreshFallback() {
        guard !building, !isFrozen else { return }
        building = true
        let sampler = fallbackSampler
        let rows = rowCount
        let metric = metric
        Task.detached(priority: .utility) { [weak self] in
            let result =
                switch metric {
                case .memory: sampler.sampleMemory(rows: rows)
                case .disk: sampler.sampleDisk(rows: rows)
                case .cpu, .gpu: sampler.sample(rows: rows)
                }
            await MainActor.run {
                guard let self else { return }
                self.building = false
                self.rows = result.rows
                self.hiddenCount = result.hiddenCount
            }
        }
    }

    /// 回退时的「刷新全部」：间隔 2 s 运行两次 setuid `/bin/ps`，只在点击时运行（D31，CLAUDE.md）。
    /// 只有 CPU 有：`ps` 没有 footprint 列（D49）。
    var supportsRefreshAll: Bool { metric == .cpu }

    func refreshAll() {
        guard isFallback, supportsRefreshAll, !isRefreshingAll else { return }
        isRefreshingAll = true
        let rows = rowCount
        Task.detached(priority: .utility) { [weak self] in
            let result = try? PSSnapshot.refreshAll(rows: rows)
            await MainActor.run {
                guard let self else { return }
                self.isRefreshingAll = false
                if let result {
                    self.rows = result
                    self.hiddenCount = 0
                }
            }
        }
    }

    /// 结束进程（D31）：先确认，按住 ⌥ 时默认强制。GUI app 用 NSRunningApplication，其余用信号。
    func terminate(pid: pid_t, name: String) {
        // 先看触发这次操作的事件上的修饰键（合成点击也带在事件上），再看全局键盘状态。
        let optionHeld = (NSApp.currentEvent?.modifierFlags ?? []).contains(.option)
            || NSEvent.modifierFlags.contains(.option)
        let alert = NSAlert()
        alert.messageText = String(localized: "结束「\(name)」？")
        alert.informativeText = String(localized: "未存储的更改可能会丢失。强制结束不会给进程清理的机会。")
        let quit = alert.addButton(withTitle: String(localized: "结束"))
        let force = alert.addButton(withTitle: String(localized: "强制结束"))
        alert.addButton(withTitle: String(localized: "取消"))
        if optionHeld {
            quit.keyEquivalent = ""
            force.keyEquivalent = "\r"
        }
        NSApp.activate()
        let response = alert.runModal()
        let forced: Bool
        switch response {
        case .alertFirstButtonReturn: forced = false
        case .alertSecondButtonReturn: forced = true
        default: return
        }
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy != .prohibited {
            _ = forced ? app.forceTerminate() : app.terminate()
            return
        }
        do {
            try ProcessControl.terminate(pid: pid, force: forced)
        } catch {
            Log.panel.error("结束进程失败：\(String(describing: error), privacy: .public)")
        }
    }
}

/// app 层的共用对象。
final class AppServices {
    let collectors: CPUCollectors
    let power: PowerCollectors
    let topN: TopNModel
    /// 内存面板的 Top N（D49）。
    let memoryTopN: TopNModel
    let memory: MemoryCollectors
    /// 存储（D54）：采集器、结构状态与按磁盘 IO 的 Top N。
    let storage: StorageCollectors
    let storageModel = StorageModel.shared
    let diskTopN: TopNModel
    /// GPU 与加速器（D57）：采集器与按 GPU 时间的 Top N。
    let gpu: GPUCollectors
    let gpuTopN: TopNModel
    let history: HistoryRecorder?
    let diagnostics = CPUDiagnosticsModel()
    /// 「中断来源」展开时的需求（D29 C8：每 5 s，收起即停）。
    private let interruptDemand: DemandSlot

    init(
        collectors: CPUCollectors, power: PowerCollectors, memory: MemoryCollectors, storage: StorageCollectors,
        gpu: GPUCollectors, history: HistoryRecorder?, engine: SamplingEngine
    ) {
        self.gpu = gpu
        self.gpuTopN = TopNModel(sampler: collectors.apps, metric: .gpu)
        self.collectors = collectors
        self.power = power
        self.memory = memory
        self.storage = storage
        self.diskTopN = TopNModel(sampler: collectors.apps, metric: .disk)
        storageModel.smart = storage.smart
        self.topN = TopNModel(sampler: collectors.apps)
        self.memoryTopN = TopNModel(sampler: collectors.apps, metric: .memory)
        self.history = history
        self.interruptDemand = DemandSlot(engine: engine)
    }

    func setInterruptSourcesVisible(_ visible: Bool) {
        interruptDemand.set(
            visible ? Demand(collectors: [InterruptDeviceCollector.collectorID], interval: 5, source: .panel) : nil)
    }

    /// 引擎事件（在 MainActor 上，由 AppDelegate 的事件泵转来）。
    func handle(_ event: EngineEvent) {
        guard case .tick(let result) = event else { return }
        diagnostics.ingest(result)
        if result.collectors.contains(AppSampler.collectorID) {
            topN.coalitionTick()
            memoryTopN.coalitionTick()
            diskTopN.coalitionTick()
            gpuTopN.coalitionTick()
        }
        if !StorageCollectors.ids.isDisjoint(with: result.collectors) {
            storageModel.refresh(
                inventory: DiskInventory.shared.inventory,
                groups: result.collectors.contains(StorageCapacityCollector.collectorID) ? storage.capacity?.latestGroups : nil)
        }
    }
}
