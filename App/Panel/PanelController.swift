// 统一面板（D21，M0 设计 §6）。参考 research/probes/gap-menubar-runtime-27/mbprobe.swift 的 PopupCtl。
//
// - 打开与关闭由 `NSStatusItemExpandedInterfaceDelegate` 驱动：didBegin 时显示，didEnd 时隐藏；
// - 实测系统不会自动结束 session：点别处（全局鼠标监视器，鼠标事件不需要辅助功能权限）、按 Esc（本地键盘监视器）、
//   再次点击 item（点击交给系统处理，本进程只能从全局监视器看到）都由这里调用 `session.cancel()`；
// - 单个可复用的 `NSPanel` + `NSGlassEffectView`，内部放 `NSHostingView`；锚在 item 所在窗口下方，限制在屏幕 visibleFrame 内；
// - session 期间 item 的高亮由系统绘制（27 实测），这里不再自绘；
// - 「固定」：结束 session，把同一个面板改成可拖动的浮窗（level = .floating），显示关闭按钮；
// - 面板可见且在 CPU tab 时登记「面板」需求（D29，CPU 模块设计 §5.8）：占用与杂项 1 s，频率、温度与功耗、Top N
//   按设置的间隔；在「功耗与散热」tab 时（功耗与散热模块设计 §4.7）：整机功率与杂项（热状态）1 s，
//   SoC/GPU/DRAM 功率、最热点与风扇按设置的间隔，CPU 功耗按 CPU 面板的温度与功耗间隔，PMGR 批次 60 s；
//   隐藏时注销，并拆掉 SwiftUI 内容，关闭后不再随数据刷新；
// - 内容高度会变（展开详情、Top N 行数），面板跟着内容改高，锚定时保持顶边不动。

import AppKit
import Observation
import SwiftUI
import SysCollectors
import SysModel
import OSLog

/// 面板里的模块（D21）：点哪个模块的 widget 就预选对应的 tab。
enum PanelTab: String, CaseIterable, Identifiable {
    case cpu
    case power

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: String(localized: "CPU")
        case .power: String(localized: "功耗与散热")
        }
    }

    init(_ module: MenuModule) {
        switch module {
        case .cpu: self = .cpu
        case .power: self = .power
        }
    }
}

/// 面板的界面状态，供 SwiftUI 读取。
@Observable
final class PanelState {
    var selectedTab: PanelTab = .cpu
    var isPinned = false
    /// 「详情」与「中断来源」一开始是否展开（`--expand-details`）。
    var expandDetailsInitially = false
}

/// 面板顶栏按钮的动作。
struct PanelActions {
    var openActivityMonitor: () -> Void
    var pin: () -> Void
    var close: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void
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
    }

    // MARK: - NSStatusItemExpandedInterfaceDelegate

    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        // `--open-panel` 显示的面板没有 session。这时点击 item，全局监视器和系统新开的 session 都会看到这次点击，
        // 先后顺序不定；两种顺序下都按「关闭」处理，与有 session 时「再次点击 item 关闭」一致。
        let clickClosedSessionlessPanel = sessionlessClosedByItemClickAt.map {
            ProcessInfo.processInfo.systemUptime - $0 < Self.itemClickSessionWindow
        } ?? false
        sessionlessClosedByItemClickAt = nil
        if presentation == .anchored, sessionItem == nil {
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
        if let widget = statusItems?.widget(for: statusItem) {
            state.selectedTab = PanelTab(widget.module)
        }
        showAnchored()
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        Log.panel.info("expanded interface session 结束（animated=\(animated)）")
        if sessionItem === statusItem {
            sessionItem = nil
        }
        // 固定为浮窗时 session 由我们主动结束，面板保留。
        if presentation == .anchored {
            hide()
        }
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

    /// 「固定」：结束 session，把同一个面板改为可拖动的浮窗。
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
        Log.panel.info("面板已固定为浮窗")
    }

    /// 按面板状态与设置登记或注销需求（设置变化、切换 tab 时也调用）。
    func updateDemands() {
        requestFit()  // Top N 行数等设置可能变了
        let visible = presentation != .hidden
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
        topN.rowCount = settings.panelTopNRows
        topN.grouping = settings.panelGrouping
        topN.interval = settings.panelTopNInterval
        let topology = CPUTopologyService.shared.current
        topN.showsPerfLevel0 = topology?.quality.isOK == true && topology?.perfLevels.count == 2
        let coalitionUsable =
            store.engineStatus?.health.first { $0.id == AppSampler.collectorID }?.status != .unavailable
        if settings.panelTopNRows > 0 {
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

    private func hide() {
        guard presentation != .hidden else { return }
        presentation = .hidden
        state.isPinned = false
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
        return panel
    }

    /// 装上新的 SwiftUI 内容，返回面板应有的尺寸。
    private func installContent(in panel: PanelWindow) -> NSSize {
        let actions = PanelActions(
            openActivityMonitor: { [weak self] in self?.openActivityMonitor() },
            pin: { [weak self] in self?.pin() },
            close: { [weak self] in self?.close() },
            // 关不关面板由打开设置的公共入口统一决定（锚定面板关闭，浮窗保留），见 AppDelegate.openSettings。
            openSettings: { [weak self] in self?.onOpenSettings?() },
            quit: { NSApp.terminate(nil) })
        let hosting = NSHostingView(
            rootView: PanelRootView(
                store: store, state: state, actions: actions, services: services, settings: settings,
                onLayoutChange: { [weak self] in self?.requestFit() },
                onTabChange: { [weak self] in self?.updateDemands() }))
        // 面板尺寸由 fitToContent 控制，不让 hosting view 平时维护固有尺寸约束（省掉每次更新后的约束求解）。
        hosting.sizingOptions = []
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

    /// 按内容的理想高度改面板高度：锚定时保持顶边，浮窗时也保持顶边（向下长）。
    private func fitToContent() {
        guard let panel, presentation != .hidden, let hosting = glass?.contentView as? NSHostingView<PanelRootView>
        else { return }
        let height = ceil(max(Self.idealHeight(of: hosting), 200))
        guard abs(panel.frame.height - height) >= 1 else { return }
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
        var y = min(anchorFrame.minY, visible.maxY) - Self.gap - size.height
        y = max(y, visible.minY + Self.screenMargin)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
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
        if let anchor = statusItems?.anchorWindow?.frame, anchor.contains(location) {
            Log.panel.info("再次点击 item，关闭面板")
            if sessionItem == nil {
                // 无 session 的面板：系统随后会为这次点击开启新 session，didBegin 里把它取消。
                sessionlessClosedByItemClickAt = ProcessInfo.processInfo.systemUptime
            }
        } else {
            Log.panel.info("点击面板以外的位置，关闭面板")
        }
        close()
    }

    private func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown where event.keyCode == 53:  // Esc
            guard presentation != .hidden, event.window === panel else { return event }
            Log.panel.info("Esc，关闭面板")
            close()
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
