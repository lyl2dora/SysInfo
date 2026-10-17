// 应用活动窗口（D64、D67）：标准、可缩放的 NSWindow + SwiftUI。
//
// - 入口：面板顶栏按钮、各模块 Top N 底部的「在应用活动中查看全部」（按该模块的列排序）、合并模式总览的「最耗能的应用」卡片
//   （按功率排序，D70）、启动参数 `--open-app-activity[=<时间段>]`；
// - 窗口打开期间与设置窗口共用 `.regular` 计数（ForegroundWindows）；
// - 采样只在窗口可见时：关闭、最小化、被完全遮住（occlusionState 不含 visible）时注销需求（D67）；
// - 位置与大小按 autosave 名记住（`--factory-defaults` 时不记）；关闭后保留窗口对象，再次打开不重新冷解析身份（构建器缓存在模型里）。

import AppKit
import OSLog
import SwiftUI
import SysCollectors
import SysModel

final class AppActivityWindowController: NSObject, NSWindowDelegate {
    let model: AppActivityModel
    private let store: MetricStore
    private let services: AppServices
    private let settings: AppSettings
    private var window: NSWindow?

    init(model: AppActivityModel, store: MetricStore, services: AppServices, settings: AppSettings) {
        self.model = model
        self.store = store
        self.services = services
        self.settings = settings
    }

    /// 打开（或带到最前）。`sort` 为按哪一列排序，`range` 为时间段。
    func open(sort: AppActivityColumn? = nil, range: AppActivityRange? = nil) {
        if let range { model.range = range }
        if let sort { model.sort(by: sort) }
        let window = window ?? makeWindow()
        self.window = window
        ForegroundWindows.retain("appActivity")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.orderFrontRegardless()
        updateVisibility()
        Log.panel.info("打开应用活动窗口（\(self.model.range.rawValue, privacy: .public)）")
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(
            rootView: AppActivityView(model: model, store: store, services: services, settings: settings))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = String(localized: "应用活动")
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1280, height: 720))
        window.contentMinSize = NSSize(width: 760, height: 400)
        window.toolbarStyle = .unified
        window.delegate = self
        // `--factory-defaults` 不读写偏好（测量、对照机截图，D39）：不用 autosave。
        if LaunchOptions.current.factoryDefaults {
            window.center()
        } else {
            if !window.setFrameUsingName("AppActivity") { window.center() }
            window.setFrameAutosaveName("AppActivity")
        }
        return window
    }

    private func updateVisibility() {
        guard let window else { return }
        model.setVisible(window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        model.setVisible(false)
        ForegroundWindows.release("appActivity")
        Log.panel.info("应用活动窗口关闭")
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        updateVisibility()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        updateVisibility()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        updateVisibility()
    }
}
