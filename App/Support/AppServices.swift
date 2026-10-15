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

/// Top N（D31，CPU 模块设计 §5.7、§7.2）：只在 CPU tab 可见且行数大于 0 时工作。
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

    init(sampler: AppSampler?) {
        self.sampler = sampler
    }

    /// 面板的 CPU tab 显示或隐藏。
    func setActive(_ active: Bool, coalitionUsable: Bool) {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        isFallback = active && (!coalitionUsable || sampler == nil)
        guard active else {
            rows = []
            return
        }
        if isFallback {
            _ = fallbackSampler.sample(rows: rowCount)  // 建立基线
            let timer = Timer(timeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshFallback() }
            }
            RunLoop.main.add(timer, forMode: .common)
            fallbackTimer = timer
        }
    }

    /// 引擎交付了一个 `app.coalition` 结果。
    func coalitionTick() {
        guard !isFallback, !building, !isFrozen, rowCount > 0, let sampler, let window = sampler.latestWindow else { return }
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
                if !self.isFrozen { self.rows = built }
            }
        }
    }

    private func refreshFallback() {
        guard !building, !isFrozen else { return }
        building = true
        let sampler = fallbackSampler
        let rows = rowCount
        Task.detached(priority: .utility) { [weak self] in
            let result = sampler.sample(rows: rows)
            await MainActor.run {
                guard let self else { return }
                self.building = false
                self.rows = result.rows
                self.hiddenCount = result.hiddenCount
            }
        }
    }

    /// 回退时的「刷新全部」：间隔 2 s 运行两次 setuid `/bin/ps`，只在点击时运行（D31，CLAUDE.md）。
    func refreshAll() {
        guard isFallback, !isRefreshingAll else { return }
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
    let history: HistoryRecorder?
    let diagnostics = CPUDiagnosticsModel()
    /// 「中断来源」展开时的需求（D29 C8：每 5 s，收起即停）。
    private let interruptDemand: DemandSlot

    init(collectors: CPUCollectors, power: PowerCollectors, history: HistoryRecorder?, engine: SamplingEngine) {
        self.collectors = collectors
        self.power = power
        self.topN = TopNModel(sampler: collectors.apps)
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
        if result.collectors.contains(AppSampler.collectorID) { topN.coalitionTick() }
    }
}
