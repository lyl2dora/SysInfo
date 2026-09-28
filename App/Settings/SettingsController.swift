// 设置窗口（M0 设计 §6，D23、D25）。
//
// - 用 `NSHostingSceneRepresentation` 把 SwiftUI `Settings` 场景挂到 AppKit 生命周期上，
//   打开用它的 `environment.openSettings()`；
// - 窗口打开期间 `NSApp.setActivationPolicy(.regular)` 并激活（有 Dock 图标和主菜单，⌘, ⌘Q 可用），
//   关闭后切回 `.accessory`；
// - 窗口关闭后把内容换成空视图：设置窗口不在屏幕上时不读 MetricStore，不随每个 tick 重算；
// - 诊断页可见期间登记「诊断页」需求（app.self，1 s），用于显示本进程开销。

import AppKit
import Observation
import SwiftUI
import SysCollectors
import OSLog

/// 设置侧栏的页面，顺序按 D25：通用、菜单栏、每个模块一页、历史与导出、诊断、关于。
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case general
    case menuBar
    case cpu
    case history
    case privacy
    case diagnostics
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "通用")
        case .menuBar: String(localized: "菜单栏")
        case .cpu: String(localized: "CPU")
        case .history: String(localized: "历史与导出")
        case .privacy: String(localized: "隐私")
        case .diagnostics: String(localized: "诊断")
        case .about: String(localized: "关于")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .menuBar: "menubar.rectangle"
        case .cpu: "cpu"
        case .history: "clock.arrow.circlepath"
        case .privacy: "hand.raised"
        case .diagnostics: "stethoscope"
        case .about: "info.circle"
        }
    }
}

@Observable
final class SettingsState {
    var selection: SettingsPage? = .general
    /// 设置窗口是否在屏幕上。为 false 时窗口内容换成空视图。
    var isWindowOpen = false
}

final class SettingsController {
    let state = SettingsState()

    private let settings: AppSettings
    private let store: MetricStore
    private let throttle: ThrottleMonitor
    private let engine: SamplingEngine
    private let diagnosticsDemand: DemandSlot

    private var openSettingsAction: (() -> Void)?
    private weak var window: NSWindow?
    private var windowObservers: [any NSObjectProtocol] = []

    init(settings: AppSettings, store: MetricStore, throttle: ThrottleMonitor, engine: SamplingEngine) {
        self.settings = settings
        self.store = store
        self.throttle = throttle
        self.engine = engine
        self.diagnosticsDemand = DemandSlot(engine: engine)
    }

    /// 把 Settings 场景挂到 NSApplication 上（启动时调用一次）。
    func install() {
        let context = SettingsContext(
            settings: settings, store: store, throttle: throttle, state: state,
            windowAttached: { [weak self] window in self?.attach(window) },
            diagnosticsVisibilityChanged: { [weak self] visible in self?.setDiagnosticsVisible(visible) },
            runSelfTests: { [engine] in
                Task { await engine.runSelfTests() }
            })
        let scene = NSHostingSceneRepresentation {
            Settings {
                SettingsRootView(context: context)
            }
        }
        NSApp.addSceneRepresentation(scene)
        openSettingsAction = { scene.environment.openSettings() }
    }

    /// 打开设置窗口；可以指定页面。
    func open(page: SettingsPage? = nil) {
        if let page {
            state.selection = page
        }
        Log.settings.info("打开设置窗口（\(page?.rawValue ?? "上次的页面", privacy: .public)）")
        state.isWindowOpen = true
        NSApp.setActivationPolicy(.regular)
        openSettingsAction?()
        NSApp.activate()
        bringWindowToFront()
    }

    // MARK: - 私有

    private func attach(_ window: NSWindow) {
        guard window !== self.window else { return }
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        self.window = window
        windowObservers = [
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowWillClose() }
            }
        ]
        Log.settings.info("设置窗口已挂接")
        if state.isWindowOpen {
            bringWindowToFront()
        }
    }

    /// 协作式激活（macOS 14 起）下，别的 app 在前台、又不是由用户在本 app 里的操作触发时（例如经命令行
    /// `--open-settings` 启动），`NSApp.activate()` 可能不生效。这时至少把窗口放到最前面，用户点一下即可激活。
    private func bringWindowToFront() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        // 激活是异步的，稍后再记录结果。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                Log.settings.info("设置窗口已在最前；app \(NSApp.isActive ? "已激活" : "未激活（别的 app 在前台，点一下窗口即可激活）", privacy: .public)")
            }
        }
    }

    private func windowWillClose() {
        Log.settings.info("设置窗口关闭，切回 accessory")
        state.isWindowOpen = false
        setDiagnosticsVisible(false)
        NSApp.setActivationPolicy(.accessory)
    }

    private func setDiagnosticsVisible(_ visible: Bool) {
        let demand = visible && state.isWindowOpen
            ? Demand(collectors: [SelfUsageCollector.collectorID], interval: 1, source: .diagnostics)
            : nil
        diagnosticsDemand.set(demand)
    }
}

/// 设置窗口内容需要的依赖和回调。
struct SettingsContext {
    let settings: AppSettings
    let store: MetricStore
    let throttle: ThrottleMonitor
    let state: SettingsState
    let windowAttached: (NSWindow) -> Void
    let diagnosticsVisibilityChanged: (Bool) -> Void
    let runSelfTests: () -> Void
}
