// 统一面板（D21，M0 设计 §6）。参考 research/probes/gap-menubar-runtime-27/mbprobe.swift 的 PopupCtl。
//
// - 打开与关闭由 `NSStatusItemExpandedInterfaceDelegate` 驱动：didBegin 时显示，didEnd 时隐藏；
// - 实测系统不会自动结束 session：点别处（全局鼠标监视器，鼠标事件不需要辅助功能权限）、按 Esc（本地键盘监视器）、
//   再次点击 item（点击交给系统处理，本进程只能从全局监视器看到）都由这里调用 `session.cancel()`；
// - 单个可复用的 `NSPanel` + `NSGlassEffectView`，内部放 `NSHostingView`；锚在 item 所在窗口下方，限制在屏幕 visibleFrame 内；
// - session 期间 item 的高亮由系统绘制（27 实测），这里不再自绘；
// - 浮窗（D81）：锚定时用户拖动面板即转为浮窗——结束 session，同一个面板改为 level = .floating，显示关闭按钮；
//   不再有「固定」按钮。浮窗时再点菜单栏 item，面板换成该模块并重新锚到它下方（D47）；
// - 面板可见且在 CPU tab 时登记「面板」需求（D29，CPU 模块设计 §5.8）：占用与杂项 1 s，频率、温度与功耗、Top N
//   按设置的间隔；在「功耗与散热」tab 时（功耗与散热模块设计 §4.7）：整机功率与杂项（热状态）1 s，
//   SoC/GPU/DRAM 功率、最热点与风扇按设置的间隔，CPU 功耗按 CPU 面板的温度与功耗间隔，PMGR 批次 60 s；
//   在「内存」tab 时（内存模块设计 §7.2）：内存 1 s，内存 Top N 的 coalition 扫描按设置的间隔（默认 5 s）；
//   在「存储」tab 时（存储模块设计 §4.6）：读写 1 s，SMART 按设置（默认 2 s，读全部盘），容量 10 s，磁盘 Top N 按设置；
//   在「GPU 与加速器」tab 时（GPU 模块设计 §8）：活跃、频率与功率 1 s，温度、ANE、媒体引擎与 GPU 内存按设置（默认 2 s），
//   coalition 扫描按 Top N 的间隔（Top N 行数为 0 时也扫，ANE 估算要用，D58）；
//   在「网络」tab 时（网络模块设计 §7）：速率 1 s，Wi-Fi 卡片可见时 CoreWLAN 每 5 s（D60 N5），延迟开启时按延迟间隔（D61）；
//   隐藏时注销，并拆掉 SwiftUI 内容，关闭后不再随数据刷新；
// - 内容高度会变（展开详情、Top N 行数），面板跟着内容改高，锚定时保持顶边不动。

import AppKit
import Observation
import SwiftUI
import SysCollectors
import SysModel
import OSLog

/// 面板里的模块（D21、D47）：单 widget 模式下面板只显示被点击 widget 所属的模块；
/// 合并模式（D65）下多一个「总览」，并可以用切换器在模块之间切换。
enum PanelTab: String, CaseIterable, Identifiable {
    case overview
    case cpu
    case power
    case memory
    case storage
    case gpu
    case network
    case devices

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: String(localized: "总览")
        case .cpu: String(localized: "CPU")
        case .power: String(localized: "功耗与散热")
        case .memory: String(localized: "内存")
        case .storage: String(localized: "存储")
        case .gpu: String(localized: "GPU 与加速器")
        case .network: String(localized: "网络")
        case .devices: String(localized: "电源设备")
        }
    }

    /// 切换器上的两字标签（D65 MG4）。
    var shortTitle: String {
        switch self {
        case .overview: String(localized: "总览", comment: "面板切换器标签，两个字")
        case .cpu: String(localized: "CPU")
        case .power: String(localized: "功耗", comment: "面板切换器标签，两个字")
        case .memory: String(localized: "内存", comment: "面板切换器标签，两个字")
        case .storage: String(localized: "存储", comment: "面板切换器标签，两个字")
        case .gpu: String(localized: "GPU")
        case .network: String(localized: "网络", comment: "面板切换器标签，两个字")
        case .devices: String(localized: "电源", comment: "面板切换器标签，两个字：电源设备")
        }
    }

    /// 切换器的顺序（D65 MG3）：总览；合并 item 里出现的模块按出现顺序；其余按 D53 的模块顺序。
    /// 电源设备没有任何设备时不出现（D84 PD5）。
    static func switcherOrder(mergedModules: [MenuModule], hasPowerDevices: Bool = true) -> [PanelTab] {
        let modules = mergedModules + MenuModule.allCases.filter { !mergedModules.contains($0) }
        return [.overview] + modules.filter { $0 != .devices || hasPowerDevices }.map(PanelTab.init)
    }

    init(_ module: MenuModule) {
        switch module {
        case .cpu: self = .cpu
        case .power: self = .power
        case .memory: self = .memory
        case .storage: self = .storage
        case .gpu: self = .gpu
        case .network: self = .network
        case .devices: self = .devices
        }
    }
}

/// 面板的界面状态，供 SwiftUI 读取。
@Observable
final class PanelState {
    var selectedTab: PanelTab = .cpu
    var isPinned = false
    /// 合并模式（D65）：显示切换器与总览。
    var isMerged = false
    /// 切换器的顺序（合并模式下有效）。
    var switcherTabs: [PanelTab] = PanelTab.allCases
    /// 面板高度上限（D66）：锚定时从菜单栏下方到屏幕可用区域底边，浮窗时为可用区域高度；由 PanelController 维护。
    var maxPanelHeight: CGFloat = 900
    /// 「详情」与「中断来源」一开始是否展开（`--expand-details`）。
    var expandDetailsInitially = false
    /// 二级页（D64）：空为模块主页。换模块、关闭面板时清空。
    var path: [PanelRoute] = []
}

/// 面板顶栏按钮的动作。
struct PanelActions {
    var openActivityMonitor: () -> Void
    /// 打开应用活动窗口（D67）。
    var openAppActivity: () -> Void
    var close: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void
    /// 合并模式下换模块（切换器、总览卡片，D65）。
    var selectTab: (PanelTab) -> Void
    /// 推入二级页、返回一层（D64）。经 PanelController 走，量好高度后一次换完（D66）。
    var navigate: (PanelRoute) -> Void
    var back: () -> Void
}

/// 可以成为 key window 的无边框面板：Esc 等键盘事件要送到它这里（non-activating，不会激活 app）。
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PanelController: NSObject, NSStatusItemExpandedInterfaceDelegate {
    enum Presentation: Equatable {
        case hidden
        /// 锚在菜单栏 item 下方（有 session，或 `--open-panel` 时没有 session）。
        case anchored
        /// 固定为浮窗。
        case pinned
    }

    static let width: CGFloat = 360
    static let cornerRadius: CGFloat = 18
    /// 面板与菜单栏之间的间距。
    static let gap: CGFloat = 6
    /// 面板与屏幕边缘的最小距离。
    static let screenMargin: CGFloat = 8

    let state = PanelState()
    private(set) var presentation: Presentation = .hidden

    /// 打开设置窗口（由 AppDelegate 注入）。
    var onOpenSettings: (() -> Void)?
    /// 提供锚点和高亮的菜单栏 item。
    weak var statusItems: StatusItemController?

    private let store: MetricStore
    private let services: AppServices
    private let settings: AppSettings
    /// 面板的几条需求：间隔不同，各占一个槽。
    private let usageDemand: DemandSlot
    private let frequencyDemand: DemandSlot
    private let sensorDemand: DemandSlot
    private let topNDemand: DemandSlot
    private let powerDemand: DemandSlot
    private let powerSensorDemand: DemandSlot
    private let pmgrDemand: DemandSlot
    private let memoryDemand: DemandSlot
    private let memoryTopNDemand: DemandSlot
    private let storageDemand: DemandSlot
    private let storageSMARTDemand: DemandSlot
    private let storageCapacityDemand: DemandSlot
    private let storageTopNDemand: DemandSlot
    private let gpuDemand: DemandSlot
    private let gpuDetailDemand: DemandSlot
    private let gpuTopNDemand: DemandSlot
    private let networkDemand: DemandSlot
    private let wifiDemand: DemandSlot
    private let latencyDemand: DemandSlot
    private let appDetailDemand: DemandSlot
    private let overviewDemand: DemandSlot
    private let overviewSlowDemand: DemandSlot
    private let devicesDemand: DemandSlot
    private let upsDemand: DemandSlot
    /// 电源设备 tab 上一次是否可见：变为可见时让 UPS 采集器重读静态项。
    private var devicesWasVisible = false
    private var panel: PanelWindow?
    private var glass: NSGlassEffectView?
    /// 当前 session 所属的 item（锚定且有 session 时）。
    private weak var sessionItem: NSStatusItem?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// 面板显示的时刻（与 `NSEvent.timestamp` 同一时钟：开机以来的秒数）。
    /// 早于它的鼠标事件就是打开面板的那次点击，全局监视器要忽略它。
    private var shownAt: TimeInterval = 0
    /// 无 session 的锚定面板（`--open-panel`）被点击 item 关掉的时刻（同上的时钟）。
    /// 同一次点击随后还会让系统开启新 session，要把它取消，这次点击才等价于「关闭」。
    private var sessionlessClosedByItemClickAt: TimeInterval?
    /// 上面两件事之间允许的最大间隔，秒（实测约 20 ms）。
    static let itemClickSessionWindow: TimeInterval = 0.5
    /// 面板开着时点了本 app 的另一个 widget 的时刻（同上的时钟）：旧 session 结束时不隐藏面板，
    /// 等新 session 开始后原地换内容（D47）。原先先隐藏再显示，中间约 60 ms 空白，看起来是闪烁。
    private var switchRequestedAt: TimeInterval?

    init(store: MetricStore, engine: SamplingEngine, services: AppServices, settings: AppSettings) {
        self.store = store
        self.services = services
        self.settings = settings
        self.usageDemand = DemandSlot(engine: engine)
        self.frequencyDemand = DemandSlot(engine: engine)
        self.sensorDemand = DemandSlot(engine: engine)
        self.topNDemand = DemandSlot(engine: engine)
        self.powerDemand = DemandSlot(engine: engine)
        self.powerSensorDemand = DemandSlot(engine: engine)
        self.pmgrDemand = DemandSlot(engine: engine)
        self.memoryDemand = DemandSlot(engine: engine)
        self.memoryTopNDemand = DemandSlot(engine: engine)
        self.storageDemand = DemandSlot(engine: engine)
        self.storageSMARTDemand = DemandSlot(engine: engine)
        self.storageCapacityDemand = DemandSlot(engine: engine)
        self.storageTopNDemand = DemandSlot(engine: engine)
        self.gpuDemand = DemandSlot(engine: engine)
        self.gpuDetailDemand = DemandSlot(engine: engine)
        self.gpuTopNDemand = DemandSlot(engine: engine)
        self.networkDemand = DemandSlot(engine: engine)
        self.wifiDemand = DemandSlot(engine: engine)
        self.latencyDemand = DemandSlot(engine: engine)
        self.appDetailDemand = DemandSlot(engine: engine)
        self.overviewDemand = DemandSlot(engine: engine)
        self.overviewSlowDemand = DemandSlot(engine: engine)
        self.devicesDemand = DemandSlot(engine: engine)
        self.upsDemand = DemandSlot(engine: engine)
    }

    // MARK: - NSStatusItemExpandedInterfaceDelegate

    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        // `--open-panel` 显示的面板没有 session。这时点击 item，全局监视器和系统新开的 session 都会看到这次点击，
        // 先后顺序不定；两种顺序下都按「关闭」处理，与有 session 时「再次点击 item 关闭」一致。
        let clickClosedSessionlessPanel = sessionlessClosedByItemClickAt.map {
            ProcessInfo.processInfo.systemUptime - $0 < Self.itemClickSessionWindow
        } ?? false
        sessionlessClosedByItemClickAt = nil
        // 从一个 widget 点到另一个（D47）：系统先结束旧 session（sessionItem 已清空），再开新 session。
        // 这时面板还开着、没有 session，但不是「无 session 的面板被点了」，要先判断，原地换内容。
        let switching = switchRequestedAt.map { ProcessInfo.processInfo.systemUptime - $0 < Self.itemClickSessionWindow } ?? false
        switchRequestedAt = nil
        if presentation == .anchored, sessionItem == nil, !switching {
            Log.panel.info("无 session 的面板开着时点击 item：关闭面板，取消系统新开的 session")
            hide()
            session.cancel()
            return
        }
        if clickClosedSessionlessPanel {
            Log.panel.info("这次点击已经关闭了无 session 的面板：取消系统新开的 session")
            session.cancel()
            return
        }

        Log.panel.info("expanded interface session 开始")
        sessionItem = statusItem
        statusItems?.activeItem = statusItem
        if statusItems?.isMerged(statusItem) == true {
            // D65 MG2：按点击的 x 坐标打开那一段所属的模块；拿不到坐标时打开总览。
            let location = NSEvent.mouseLocation
            let widget = statusItems?.mergedWidget(at: location)
            Log.panel.info(
                "合并 item 被点击：\(NSStringFromPoint(location), privacy: .public) → \(widget?.rawValue ?? "（不在 item 上，打开总览）", privacy: .public)"
            )
            select(widget.map { PanelTab($0.module) } ?? .overview)
        } else if let widget = statusItems?.widget(for: statusItem) {
            select(PanelTab(widget.module))
        }
        if switching, presentation == .anchored {
            swapInPlace()
        } else {
            showAnchored()
        }
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        Log.panel.info("expanded interface session 结束（animated=\(animated)）")
        if sessionItem === statusItem {
            sessionItem = nil
        }
        // 固定为浮窗时 session 由我们主动结束，面板保留。
        guard presentation == .anchored else { return }
        // 点到了另一个 widget：面板先留着，等新 session 开始后原地换内容；新 session 没来就照常隐藏。
        if switchRequestedAt != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.itemClickSessionWindow) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.switchRequestedAt != nil, self.sessionItem == nil else { return }
                    self.switchRequestedAt = nil
                    self.hide()
                }
            }
            return
        }
        hide()
    }

    /// 选择面板显示的模块；换模块时回到主页（D64）。
    private func select(_ tab: PanelTab) {
        if tab != state.selectedTab { state.path = [] }
        state.selectedTab = tab
    }

    /// 合并模式下用切换器或 ⌘1–⌘7 换模块（D65 MG4）：面板保持锚定，原地换内容。
    func switchTab(_ tab: PanelTab) {
        guard tab != state.selectedTab || !state.path.isEmpty else { return }
        Log.panel.info("切换到 \(tab.rawValue, privacy: .public)")
        changePage {
            $0.path = []
            $0.selectedTab = tab
        }
    }

    /// 换页（D66）：改状态、量新内容的高度、改窗口大小，在同一次提交里完成，不加动画、不出现按旧高度绘制的一帧。
    func changePage(_ change: (PanelState) -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change(state)
        fitToContent()
        CATransaction.commit()
    }

    /// 合并模式的结构变了（开关合并、合并顺序）：同步切换器。单 widget 模式下不可能停在总览。
    func syncMergedState() {
        let merged = settings.menuBarMerged
        let tabs = PanelTab.switcherOrder(
            mergedModules: statusItems?.mergedModules ?? [], hasPowerDevices: services.devicesModel.hasDevices)
        if state.isMerged != merged { state.isMerged = merged }
        if state.switcherTabs != tabs { state.switcherTabs = tabs }
        if !merged, state.selectedTab == .overview { state.selectedTab = .cpu }
    }

    // MARK: - 打开与关闭

    /// `--open-panel`：不经 session，直接锚在 item 下方显示（截图和开销测量用）。
    /// 启动时菜单栏还没把 item 摆好（窗口还在原点），最多等 2 s，等锚点落到菜单栏上再显示。
    func showWithoutSession(attempt: Int = 0) {
        if statusItems?.anchorWindow != nil, validAnchorFrame() == nil, attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.showWithoutSession(attempt: attempt + 1)
            }
            return
        }
        Log.panel.info("--open-panel：不经 session 显示面板")
        sessionItem = nil
        showAnchored()
        if LaunchOptions.current.pinPanel {
            pin()
        }
    }

    /// 只关闭锚在 item 下方的面板（打开设置窗口前调用）；固定的浮窗保留。
    func dismissAnchored() {
        guard presentation == .anchored else { return }
        Log.panel.info("打开设置窗口，先关闭锚定面板")
        close()
    }

    /// 关闭面板：有 session 时取消 session（系统随后回调 didEnd），否则直接隐藏。
    func close() {
        guard presentation != .hidden else { return }
        if presentation == .anchored, let session = sessionItem?.expandedInterfaceSession {
            session.cancel()
        }
        hide()
    }

    /// 转为浮窗：结束 session，把同一个面板改为浮窗（D81：用户拖动时触发；`--pin-panel` 启动参数也走这里）。
    func pin() {
        guard presentation == .anchored, let panel else { return }
        presentation = .pinned
        state.isPinned = true
        removeGlobalMonitor()
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        if let session = sessionItem?.expandedInterfaceSession {
            session.cancel()
        }
        sessionItem = nil
        requestFit()  // 浮窗的高度上限与锚定时不同（D66）
        Log.panel.info("面板已固定为浮窗")
    }

    /// 按面板状态与设置登记或注销需求（设置变化、切换 tab 时也调用）。
    func updateDemands() {
        requestFit()  // Top N 行数等设置可能变了
        let visible = presentation != .hidden
        updateAppDetailDemand(visible: visible)
        updateOverviewDemands(visible: visible && state.selectedTab == .overview)
        let powerVisible = visible && state.selectedTab == .power
        if powerVisible {
            powerDemand.set(
                Demand(collectors: [PowerRailCollector.collectorID, CPUMiscCollector.collectorID], interval: 1, source: .panel))
            powerSensorDemand.set(
                Demand(
                    collectors: [PowerSensorCollector.collectorID, GPUPowerCollector.collectorID],
                    interval: settings.powerPanelInterval, source: .panel))
            pmgrDemand.set(Demand(collectors: [PMGRBatchCollector.collectorID], interval: 60, source: .panel))
            // 功率分解里的 CPU 行（专用轨）
            sensorDemand.set(
                Demand(collectors: [SensorCollector.collectorID], interval: settings.panelSensorInterval, source: .panel))
        } else {
            [powerDemand, powerSensorDemand, pmgrDemand].forEach { $0.set(nil) }
        }
        updateMemoryDemands(visible: visible && state.selectedTab == .memory)
        updateStorageDemands(visible: visible && state.selectedTab == .storage)
        updateGPUDemands(visible: visible && state.selectedTab == .gpu)
        updateNetworkDemands(visible: visible && state.selectedTab == .network)
        updateDevicesDemands(visible: visible && state.selectedTab == .devices)
        let cpuVisible = visible && state.selectedTab == .cpu
        guard cpuVisible else {
            [usageDemand, frequencyDemand, topNDemand].forEach { $0.set(nil) }
            if !powerVisible { sensorDemand.set(nil) }
            services.topN.setActive(false, coalitionUsable: true)
            return
        }
        usageDemand.set(
            Demand(collectors: [CPULoadCollector.collectorID, CPUMiscCollector.collectorID], interval: 1, source: .panel))
        frequencyDemand.set(
            Demand(collectors: [CPUFrequencyCollector.collectorID], interval: settings.panelFreqInterval, source: .panel))
        sensorDemand.set(
            Demand(collectors: [SensorCollector.collectorID], interval: settings.panelSensorInterval, source: .panel))
        let topN = services.topN
        topN.rowCount = state.path.isEmpty ? settings.panelTopNRows : 0
        topN.grouping = settings.panelGrouping
        topN.interval = settings.panelTopNInterval
        let topology = CPUTopologyService.shared.current
        topN.showsPerfLevel0 = topology?.quality.isOK == true && topology?.perfLevels.count == 2
        let coalitionUsable =
            store.engineStatus?.health.first { $0.id == AppSampler.collectorID }?.status != .unavailable
        if topN.rowCount > 0 {
            topNDemand.set(
                coalitionUsable
                    ? Demand(collectors: [AppSampler.collectorID], interval: settings.panelTopNInterval, source: .panel)
                    : nil)
            topN.setActive(true, coalitionUsable: coalitionUsable)
        } else {
            topNDemand.set(nil)
            topN.setActive(false, coalitionUsable: coalitionUsable)
        }
    }

    /// 内存 tab（D49）：内存 1 s；Top N 行数大于 0 时按设置的间隔扫描 coalition。
    private func updateMemoryDemands(visible: Bool) {
        let topN = services.memoryTopN
        guard visible else {
            memoryDemand.set(nil)
            memoryTopNDemand.set(nil)
            topN.setActive(false, coalitionUsable: true)
            return
        }
        memoryDemand.set(Demand(collectors: [MemoryCollector.collectorID], interval: 1, source: .panel))
        topN.rowCount = state.path.isEmpty ? settings.memoryTopNRows : 0
        topN.grouping = settings.memoryGrouping
        topN.interval = settings.memoryTopNInterval
        let coalitionUsable =
            store.engineStatus?.health.first { $0.id == AppSampler.collectorID }?.status != .unavailable
        if topN.rowCount > 0 {
            memoryTopNDemand.set(
                coalitionUsable
                    ? Demand(collectors: [AppSampler.collectorID], interval: settings.memoryTopNInterval, source: .panel)
                    : nil)
            topN.setActive(true, coalitionUsable: coalitionUsable)
        } else {
            memoryTopNDemand.set(nil)
            topN.setActive(false, coalitionUsable: coalitionUsable)
        }
    }

    /// 总览（D65 MG5）：只用各模块的常驻采集器，不扫 Top N、不读全部盘 SMART、不读 CoreWLAN。
    private func updateOverviewDemands(visible: Bool) {
        guard visible else {
            [overviewDemand, overviewSlowDemand].forEach { $0.set(nil) }
            return
        }
        overviewDemand.set(
            Demand(
                collectors: [
                    CPULoadCollector.collectorID, PowerRailCollector.collectorID, MemoryCollector.collectorID,
                    StorageIOCollector.collectorID, GPUPowerCollector.collectorID, NetworkIOCollector.collectorID,
                ], interval: 1, source: .panel))
        overviewSlowDemand.set(
            Demand(
                collectors: [PowerSensorCollector.collectorID, GPUTemperatureCollector.collectorID, StorageCapacityCollector.collectorID],
                interval: 5, source: .panel))
    }

    /// 应用详情页（D64）：可见时按所属模块 Top N 的间隔扫描 coalition，离开即停。
    private func updateAppDetailDemand(visible: Bool) {
        guard visible, case .app(let route) = state.path.last else {
            appDetailDemand.set(nil)
            services.appDetail.show(nil)
            return
        }
        let interval =
            switch route.metric {
            case .cpu: settings.panelTopNInterval
            case .memory: settings.memoryTopNInterval
            case .disk: settings.storageTopNInterval
            case .gpu: settings.gpuTopNInterval
            }
        appDetailDemand.set(Demand(collectors: [AppSampler.collectorID], interval: interval, source: .panel))
        services.appDetail.show(route.coalitionID)
    }

    /// GPU 与加速器 tab（D57、D58）。
    private func updateGPUDemands(visible: Bool) {
        let topN = services.gpuTopN
        guard visible else {
            [gpuDemand, gpuDetailDemand, gpuTopNDemand].forEach { $0.set(nil) }
            topN.setActive(false, coalitionUsable: true)
            return
        }
        gpuDemand.set(Demand(collectors: [GPUPowerCollector.collectorID], interval: 1, source: .panel))
        gpuDetailDemand.set(
            Demand(
                collectors: [
                    GPUTemperatureCollector.collectorID, GPUAcceleratorCollector.collectorID, MediaEngineCollector.collectorID,
                ], interval: settings.gpuPanelInterval, source: .panel))
        topN.rowCount = state.path.isEmpty ? settings.gpuTopNRows : 0
        topN.grouping = settings.gpuGrouping
        topN.interval = settings.gpuTopNInterval
        let coalitionUsable =
            store.engineStatus?.health.first { $0.id == AppSampler.collectorID }?.status != .unavailable
        // Top N 行数为 0 时也扫 coalition：ANE 估算功率来自同一次扫描（D58）。
        gpuTopNDemand.set(
            coalitionUsable
                ? Demand(collectors: [AppSampler.collectorID], interval: settings.gpuTopNInterval, source: .panel) : nil)
        topN.setActive(topN.rowCount > 0, coalitionUsable: coalitionUsable)
    }

    /// 网络 tab（网络模块设计 §7，D60、D61）。
    private func updateNetworkDemands(visible: Bool) {
        guard visible else {
            [networkDemand, wifiDemand, latencyDemand].forEach { $0.set(nil) }
            return
        }
        networkDemand.set(Demand(collectors: [NetworkIOCollector.collectorID], interval: 1, source: .panel))
        // Wi-Fi 卡片只在有活跃 Wi-Fi 接口时出现；CoreWLAN 只在这时读（D10）。
        let hasWiFi = services.networkModel.state.activeWiFi != nil || services.networkModel.state.interfaces.isEmpty
        wifiDemand.set(hasWiFi ? Demand(collectors: [WiFiCollector.collectorID], interval: 5, source: .panel) : nil)
        latencyDemand.set(
            settings.latencyTargets != nil
                ? Demand(collectors: [LatencyCollector.collectorID], interval: max(settings.latencyInterval, 2), source: .panel)
                : nil)
    }

    /// 电源设备 tab（D84 PD3）：IOPS 快照 1 s 取一次；有 UPS 时 HID 每 2 s 读一次，刚变为可见时重读静态项。
    private func updateDevicesDemands(visible: Bool) {
        defer { devicesWasVisible = visible }
        guard visible else {
            [devicesDemand, upsDemand].forEach { $0.set(nil) }
            return
        }
        devicesDemand.set(Demand(collectors: [PowerSourceCollector.collectorID], interval: 1, source: .panel))
        let hasUPS = services.devicesModel.snapshot.primaryUPS != nil
        upsDemand.set(hasUPS ? Demand(collectors: [UPSTelemetryCollector.collectorID], interval: 2, source: .panel) : nil)
        if !devicesWasVisible { services.devices.ups?.refreshStatic() }
    }

    /// 存储 tab（存储模块设计 §4.6）：读写 1 s、SMART 按设置（默认 2 s，读全部盘）、容量 10 s、
    /// 主页上 Top N 行数大于 0 时按设置的间隔扫描 coalition。
    private func updateStorageDemands(visible: Bool) {
        let topN = services.diskTopN
        services.storageModel.panelVisible = visible
        guard visible else {
            [storageDemand, storageSMARTDemand, storageCapacityDemand, storageTopNDemand].forEach { $0.set(nil) }
            topN.setActive(false, coalitionUsable: true)
            return
        }
        storageDemand.set(Demand(collectors: [StorageIOCollector.collectorID], interval: 1, source: .panel))
        storageSMARTDemand.set(
            Demand(collectors: [SMARTCollector.collectorID], interval: settings.storageSMARTInterval, source: .panel))
        storageCapacityDemand.set(Demand(collectors: [StorageCapacityCollector.collectorID], interval: 10, source: .panel))
        topN.rowCount = state.path.isEmpty ? settings.storageTopNRows : 0
        topN.grouping = settings.storageGrouping
        topN.interval = settings.storageTopNInterval
        let coalitionUsable =
            store.engineStatus?.health.first { $0.id == AppSampler.collectorID }?.status != .unavailable
        if topN.rowCount > 0 {
            storageTopNDemand.set(
                coalitionUsable
                    ? Demand(collectors: [AppSampler.collectorID], interval: settings.storageTopNInterval, source: .panel)
                    : nil)
            topN.setActive(true, coalitionUsable: coalitionUsable)
        } else {
            storageTopNDemand.set(nil)
            topN.setActive(false, coalitionUsable: coalitionUsable)
        }
    }

    // MARK: - 私有

    private func showAnchored() {
        let panel = preparePanel()
        let size = installContent(in: panel)

        panel.level = .popUpMenu
        panel.isMovableByWindowBackground = false
        panel.setFrame(anchoredFrame(for: size), display: false)
        panel.orderFrontRegardless()
        panel.makeKey()

        presentation = .anchored
        state.isPinned = false
        shownAt = ProcessInfo.processInfo.systemUptime
        installMonitors()
        updateDemands()
        Log.panel.info("面板已显示：\(NSStringFromRect(panel.frame), privacy: .public)")
    }

    /// 面板保持可见，换成新模块的内容并移到新 widget 下方，同一次提交里完成（不出现空白帧，D47）。
    private func swapInPlace() {
        guard let panel else { return showAnchored() }
        let size = installContent(in: panel)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(anchoredFrame(for: size), display: true)
        CATransaction.commit()
        panel.makeKey()
        shownAt = ProcessInfo.processInfo.systemUptime
        updateDemands()
        Log.panel.info("面板原地换为 \(self.state.selectedTab.rawValue, privacy: .public)：\(NSStringFromRect(panel.frame), privacy: .public)")
    }

    private func hide() {
        guard presentation != .hidden else { return }
        presentation = .hidden
        state.isPinned = false
        state.path = []
        removeGlobalMonitor()
        removeLocalMonitor()
        panel?.orderOut(nil)
        // 拆掉 SwiftUI 内容：面板关闭后不再随每个 tick 重算视图。
        glass?.contentView = nil
        updateDemands()
        Log.panel.info("面板已隐藏")
    }

    private func preparePanel() -> PanelWindow {
        if let panel { return panel }
        let panel = PanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow

        let glass = NSGlassEffectView(frame: panel.contentLayoutRect)
        glass.cornerRadius = Self.cornerRadius
        glass.autoresizingMask = [.width, .height]
        panel.contentView = glass

        self.panel = panel
        self.glass = glass
        // D81：用户拖动（WindowDragGesture）时系统发 willMove；程序里改 frame 不发。锚定时一拖就转为浮窗。
        NotificationCenter.default.addObserver(
            forName: NSWindow.willMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.presentation == .anchored else { return }
                Log.panel.info("用户拖动了锚定面板：转为浮窗")
                self.pin()
            }
        }
        return panel
    }

    /// 装上新的 SwiftUI 内容，返回面板应有的尺寸。
    private func installContent(in panel: PanelWindow) -> NSSize {
        let actions = PanelActions(
            openActivityMonitor: { [weak self] in self?.openActivityMonitor() },
            openAppActivity: { [services] in services.openAppActivity(nil, nil) },
            close: { [weak self] in self?.close() },
            // 关不关面板由打开设置的公共入口统一决定（锚定面板关闭，浮窗保留），见 AppDelegate.openSettings。
            openSettings: { [weak self] in self?.onOpenSettings?() },
            quit: { NSApp.terminate(nil) },
            selectTab: { [weak self] in self?.switchTab($0) },
            navigate: { [weak self] route in self?.changePage { $0.push(route) } },
            back: { [weak self] in self?.changePage { $0.pop() } })
        let hosting = NSHostingView(
            rootView: PanelRootView(
                store: store, state: state, actions: actions, services: services, settings: settings,
                onLayoutChange: { [weak self] in self?.requestFit() },
                onTabChange: { [weak self] in self?.updateDemands() }))
        // 面板尺寸由 fitToContent 控制，不让 hosting view 平时维护固有尺寸约束（省掉每次更新后的约束求解）。
        hosting.sizingOptions = []
        updateHeightCap(anchored: presentation != .pinned)
        let size = NSSize(width: Self.width, height: ceil(max(Self.idealHeight(of: hosting), 200)))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        glass?.contentView = hosting
        return size
    }

    private var fitScheduled = false

    /// 内容结构变了（展开或收起、Top N 行数变化）：下一轮量一次高度。平时的数值更新不量，
    /// 免得每个 tick 对整个面板做一次理想尺寸测量（2026-10-15 实测是面板开销的大头之一）。
    func requestFit() {
        guard !fitScheduled else { return }
        fitScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fitScheduled = false
                self.fitToContent()
            }
        }
    }

    /// 按内容的理想高度改面板高度（不加动画，D66）：锚定时顶边固定在菜单栏下方，浮窗时保持顶边（向下长）。
    /// 理想高度已被面板高度上限截住（PanelRootView 的 maxPanelHeight），超出部分由内容区滚动。
    private func fitToContent() {
        guard let panel, presentation != .hidden, let hosting = glass?.contentView as? NSHostingView<PanelRootView>
        else { return }
        updateHeightCap()
        let height = ceil(max(Self.idealHeight(of: hosting), 200))
        guard abs(panel.frame.height - height) >= 1 else { return }
        Log.panel.info("面板改高：\(panel.frame.height, format: .fixed(precision: 0)) → \(height, format: .fixed(precision: 0))（上限 \(self.state.maxPanelHeight, format: .fixed(precision: 0))）")
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        if presentation == .anchored {
            frame = anchoredFrame(for: frame.size)
        } else if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            // 浮窗向下长到屏幕可见区域以外（被程序坞挡住）时，整体往上挪，但顶边不超出可见区域。
            let margin = Self.screenMargin
            if frame.minY < visible.minY + margin {
                frame.origin.y = min(visible.minY + margin, visible.maxY - margin - frame.height)
            }
        }
        panel.setFrame(frame, display: true)
    }

    /// 量一次内容的理想高度：临时打开固有尺寸，量完关掉（平时不维护，见 installContent）。
    static func idealHeight(of hosting: NSHostingView<PanelRootView>) -> CGFloat {
        hosting.sizingOptions = [.intrinsicContentSize]
        defer { hosting.sizingOptions = [] }
        return hosting.fittingSize.height
    }

    /// item 所在菜单栏窗口的 frame；窗口还没摆到菜单栏上（启动初期在原点）时为 nil。
    private func validAnchorFrame() -> NSRect? {
        guard let anchor = statusItems?.anchorWindow, let screen = anchor.screen else { return nil }
        let frame = anchor.frame
        // 菜单栏窗口贴着屏幕顶边；不在顶边附近说明还没摆好。
        guard frame.width > 0, frame.maxY >= screen.frame.maxY - 1 else { return nil }
        return frame
    }

    /// 锚在 item 所在窗口下方，左边与 item 对齐，限制在屏幕 visibleFrame 内。没有可用的 item 时贴屏幕右上角。
    private func anchoredFrame(for size: NSSize) -> NSRect {
        let validAnchor = validAnchorFrame()
        let screen =
            (validAnchor != nil ? statusItems?.anchorWindow?.screen : nil) ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchorFrame = validAnchor ?? NSRect(x: visible.maxX - size.width, y: visible.maxY, width: 0, height: 0)

        var x = anchorFrame.minX
        x = min(x, visible.maxX - size.width - Self.screenMargin)
        x = max(x, visible.minX + Self.screenMargin)
        // D66：顶边固定在菜单栏下方，不再上推；高度已被上限截住，万一仍超出就只让底边越界，不盖菜单栏。
        let top = Self.anchoredTop(anchorFrame: anchorFrame, visible: visible)
        return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }

    /// 锚定时面板顶边的位置：item 窗口（或可用区域顶边）下方 `gap`。
    private static func anchoredTop(anchorFrame: NSRect, visible: NSRect) -> CGFloat {
        min(anchorFrame.minY, visible.maxY) - gap
    }

    /// 面板高度上限（D66）：锚定时从顶边到可用区域底边减边距；浮窗时为可用区域高度减上下边距。变了才写入状态。
    private func updateHeightCap(anchored: Bool? = nil) {
        let anchored = anchored ?? (presentation != .pinned)
        let cap: CGFloat
        if anchored {
            let validAnchor = validAnchorFrame()
            let screen =
                (validAnchor != nil ? statusItems?.anchorWindow?.screen : nil) ?? NSScreen.main ?? NSScreen.screens.first
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let anchorFrame = validAnchor ?? NSRect(x: visible.maxX, y: visible.maxY, width: 0, height: 0)
            cap = Self.anchoredTop(anchorFrame: anchorFrame, visible: visible) - (visible.minY + Self.screenMargin)
        } else {
            let visible = (panel?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            cap = visible.height - 2 * Self.screenMargin
        }
        let rounded = floor(max(cap, 300))
        if state.maxPanelHeight != rounded { state.maxPanelHeight = rounded }
    }

    // MARK: - 事件监视

    private func installMonitors() {
        if globalMonitor == nil {
            // 其他 app 的窗口和菜单栏（含本 app 的 item：点击由系统处理）上的鼠标按下 → 关闭。
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
                [weak self] event in
                let timestamp = event.timestamp
                MainActor.assumeIsolated {
                    self?.handleGlobalMouseDown(timestamp: timestamp)
                }
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) {
                [weak self] event in
                guard let self else { return event }
                return self.handleLocalEvent(event)
            }
        }
    }

    private func handleGlobalMouseDown(timestamp: TimeInterval) {
        guard presentation == .anchored, timestamp >= shownAt else { return }
        let location = NSEvent.mouseLocation
        if let widget = statusItems?.mergedWidget(at: location) {
            // D65 MG2：合并 item 上点另一段原地换模块；点同一段时在二级页回主页、在主页关闭。
            // 无 session 的面板（--open-panel）：系统随后为这次点击开的 session 要接管（换模块、回主页）或取消（关闭）。
            let now = ProcessInfo.processInfo.systemUptime
            let tab = PanelTab(widget.module)
            if tab != state.selectedTab || !state.path.isEmpty {
                Log.panel.info("合并 item：点到 \(widget.rawValue, privacy: .public)，原地换到该模块主页")
                switchTab(tab)
                if sessionItem == nil { switchRequestedAt = now }
                return
            }
            Log.panel.info("合并 item：再次点击同一段，关闭面板")
            if sessionItem == nil { sessionlessClosedByItemClickAt = now }
            close()
            return
        }
        if let anchor = statusItems?.anchorWindow?.frame, anchor.contains(location) {
            if !state.path.isEmpty {
                // D64：在二级页时再次点击同一个 widget 回到模块主页，不关闭。
                Log.panel.info("再次点击 item，回到模块主页")
                changePage { $0.path = [] }
                // 无 session 的面板：系统随后为这次点击开的 session 要接管，而不是被当成「关闭」。
                if sessionItem == nil { switchRequestedAt = ProcessInfo.processInfo.systemUptime }
                return
            }
            Log.panel.info("再次点击 item，关闭面板")
            if sessionItem == nil {
                // 无 session 的面板：系统随后会为这次点击开启新 session，didBegin 里把它取消。
                sessionlessClosedByItemClickAt = ProcessInfo.processInfo.systemUptime
            }
        } else if sessionItem != nil, statusItems?.isOtherItem(at: location, excluding: sessionItem) == true {
            Log.panel.info("点击另一个 widget：等新 session 开始后原地换内容")
            switchRequestedAt = ProcessInfo.processInfo.systemUptime
            return
        } else {
            Log.panel.info("点击面板以外的位置，关闭面板")
        }
        close()
    }

    private func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown
        where state.isMerged && event.window === panel && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command:
            // D65 MG4：⌘1–⌘7 按切换器顺序换模块。
            guard let digit = event.charactersIgnoringModifiers.flatMap(Int.init), digit >= 1,
                digit <= state.switcherTabs.count
            else { return event }
            switchTab(state.switcherTabs[digit - 1])
            return nil
        case .keyDown where event.keyCode == 53:  // Esc
            guard presentation != .hidden, event.window === panel else { return event }
            if !state.path.isEmpty {
                Log.panel.info("Esc，回退一层")
                changePage { $0.pop() }
            } else {
                Log.panel.info("Esc，关闭面板")
                close()
            }
            return nil
        case .leftMouseDown, .rightMouseDown:
            // 本 app 的其他窗口（如设置窗口）上的点击也算「点别处」。
            if presentation == .anchored, event.window !== panel {
                Log.panel.info("点击本 app 的其他窗口，关闭面板")
                close()
            }
            return event
        default:
            return event
        }
    }

    private func removeGlobalMonitor() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func removeLocalMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    // MARK: - 顶栏动作

    private func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else {
            Log.panel.error("找不到活动监视器")
            return
        }
        close()
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                Log.panel.error("打开活动监视器失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
