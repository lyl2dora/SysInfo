// 应用活动窗口（D64、D67）：标准、可缩放的 NSWindow + SwiftUI。
//
// - 入口：面板顶栏按钮、各模块 Top N 底部的「在应用活动中查看全部」（按该模块的列排序）、合并模式总览的「最耗能的应用」卡片
//   （按功率排序，D70）、启动参数 `--open-app-activity[=<时间段>]`；
// - 窗口打开期间与设置窗口共用 `.regular` 计数（ForegroundWindows）；
// - 采样只在窗口可见时：关闭、最小化、被完全遮住（occlusionState 不含 visible）时注销需求（D67）；
// - 位置与大小按 autosave 名记住（`--factory-defaults` 时不记）；关闭后保留窗口对象，再次打开不重新冷解析身份（构建器缓存在模型里）；
// - 详情栏外伸（D81）：打开时窗口向右加宽一个详情栏的宽度，关闭时收回同样宽度，表格与列宽不变；不检查是否超出屏幕
//   （有多屏）。全屏或平铺（含缩放到占满）时窗口尺寸由系统决定，退回挤占表格。

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
    /// 当前打开的详情栏是否是靠加宽窗口得来的（关闭时要收回）。窗口初始尺寸已经包含详情栏。
    private var grewForInspector = true

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
            rootView: AppActivityView(
                model: model, store: store, services: services, settings: settings,
                toggleInspector: { [weak self] in self?.toggleInspector() }))
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

    /// 开关详情栏（D81）。打开：能加宽时先把窗口向右加宽，再显示；关闭：先隐藏，再收回加宽的部分。
    private func toggleInspector() {
        let width = AppActivityView.inspectorWidth
        guard let window else {
            model.showsInspector.toggle()
            return
        }
        if model.showsInspector {
            model.showsInspector = false
            if grewForInspector {
                var frame = window.frame
                frame.size.width = max(frame.width - width, window.minSize.width)
                window.setFrame(frame, display: true)
            }
            grewForInspector = false
        } else {
            grewForInspector = Self.canGrow(window)
            if grewForInspector {
                var frame = window.frame
                frame.size.width += width
                window.setFrame(frame, display: true)
            }
            model.showsInspector = true
        }
        Log.panel.info("应用活动详情栏：\(self.model.showsInspector ? "打开" : "关闭", privacy: .public)（\(self.grewForInspector ? "外伸" : "内伸", privacy: .public)）")
    }

    /// 全屏、平铺（占满可用区域或左右各半）时不能加宽。
    static func canGrow(_ window: NSWindow) -> Bool {
        if window.styleMask.contains(.fullScreen) { return false }
        guard let visible = window.screen?.visibleFrame else { return true }
        let frame = window.frame
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 2 }
        let fullHeight = near(frame.minY, visible.minY) && near(frame.height, visible.height)
        guard fullHeight else { return true }
        let full = near(frame.minX, visible.minX) && near(frame.width, visible.width)
        let leftHalf = near(frame.minX, visible.minX) && near(frame.width, visible.width / 2)
        let rightHalf = near(frame.maxX, visible.maxX) && near(frame.width, visible.width / 2)
        return !(full || leftHalf || rightHalf)
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
