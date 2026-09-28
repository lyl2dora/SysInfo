// 统一面板（D21，M0 设计 §6）。参考 research/probes/gap-menubar-runtime-27/mbprobe.swift 的 PopupCtl。
//
// - 打开与关闭由 `NSStatusItemExpandedInterfaceDelegate` 驱动：didBegin 时显示，didEnd 时隐藏；
// - 实测系统不会自动结束 session：点别处（全局鼠标监视器，鼠标事件不需要辅助功能权限）、按 Esc（本地键盘监视器）、
//   再次点击 item（点击交给系统处理，本进程只能从全局监视器看到）都由这里调用 `session.cancel()`；
// - 单个可复用的 `NSPanel` + `NSGlassEffectView`，内部放 `NSHostingView`；锚在 item 所在窗口下方，限制在屏幕 visibleFrame 内；
// - session 期间 item 的高亮由系统绘制（27 实测），这里不再自绘；
// - 「固定」：结束 session，把同一个面板改成可拖动的浮窗（level = .floating），显示关闭按钮；
// - 面板可见期间登记「面板」需求（cpu.load，1 s），隐藏时注销；隐藏时拆掉 SwiftUI 内容，关闭后不再随数据刷新。

import AppKit
import Observation
import SwiftUI
import SysCollectors
import SysModel
import OSLog

/// 面板里的模块。M0 只有 CPU，但按多 tab 的结构写（D21）。
enum PanelTab: String, CaseIterable, Identifiable {
    case cpu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: String(localized: "CPU")
        }
    }
}

/// 面板的界面状态，供 SwiftUI 读取。
@Observable
final class PanelState {
    var selectedTab: PanelTab = .cpu
    var isPinned = false
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

    static let width: CGFloat = 340
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
    private let demand: DemandSlot
    private var panel: PanelWindow?
    private var glass: NSGlassEffectView?
    /// 当前 session 所属的 item（锚定且有 session 时）。
    private weak var sessionItem: NSStatusItem?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// 面板显示的时刻（与 `NSEvent.timestamp` 同一时钟：开机以来的秒数）。
    /// 早于它的鼠标事件就是打开面板的那次点击，全局监视器要忽略它。
    private var shownAt: TimeInterval = 0

    init(store: MetricStore, engine: SamplingEngine) {
        self.store = store
        self.demand = DemandSlot(engine: engine)
    }

    // MARK: - NSStatusItemExpandedInterfaceDelegate

    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        Log.panel.info("expanded interface session 开始")
        sessionItem = statusItem
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
        demand.set(Demand(collectors: [CPULoadCollector.collectorID], interval: 1, source: .panel))
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
        demand.set(nil)
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
            openSettings: { [weak self] in
                self?.close()
                self?.onOpenSettings?()
            },
            quit: { NSApp.terminate(nil) })
        let hosting = NSHostingView(rootView: PanelRootView(store: store, state: state, actions: actions))
        let fitting = hosting.fittingSize
        let size = NSSize(width: Self.width, height: ceil(max(fitting.height, 200)))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        glass?.contentView = hosting
        return size
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
