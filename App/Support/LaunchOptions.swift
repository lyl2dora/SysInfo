// 启动参数（M0 设计 §6，D18）：用于截图自查和开销测量，Debug 与 Release 都支持（measure 脚本用 Release 构建）。

import Foundation

nonisolated struct LaunchOptions: Sendable, Equatable {
    /// `--open-panel`：不经 session 直接显示面板（截图、「面板打开」档的开销测量）。
    var openPanel = false
    /// `--open-settings`：启动后直接打开设置窗口；`--open-settings=<页面>`（如 `cpu`、`history`、`diagnostics`）打开指定页面。
    var openSettings = false
    var settingsPage: String?
    /// `--pin-panel`：与 `--open-panel` 一起用，显示后立即固定为浮窗（点别处不会关，开销测量用）。
    var pinPanel = false
    /// `--expand-details`：面板的「详情」与「中断来源」一开始就展开（开销测量的最重一档）。
    var expandDetails = false
    /// `--panel-tab=<tab>`：面板一开始显示的 tab（`cpu`、`power`、`memory`、`storage`、`gpu`、`network`），截图与开销测量用。
    var panelTab: String?
    /// `--storage-detail=<n>`：存储 tab 直接打开第 n 块盘（从 0 起，按面板顺序）的详情页，截图与开销测量用。
    var storageDetailIndex: Int?
    /// `--factory-defaults`：不读写持久化的设置，只用出厂默认值（开销测量用，不改动用户的偏好）。
    var factoryDefaults = false
    /// `--single-instance`：在 Debug 版上也按日用版的单实例规则执行（D48），截图自查与测试用。
    var singleInstance = false

    init(arguments: [String]) {
        openPanel = arguments.contains("--open-panel")
        let settingsArgument = arguments.first { $0 == "--open-settings" || $0.hasPrefix("--open-settings=") }
        openSettings = settingsArgument != nil
        settingsPage = settingsArgument?.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init)
        factoryDefaults = arguments.contains("--factory-defaults")
        singleInstance = arguments.contains("--single-instance")
        pinPanel = arguments.contains("--pin-panel")
        expandDetails = arguments.contains("--expand-details")
        panelTab = arguments.first { $0.hasPrefix("--panel-tab=") }?.split(separator: "=", maxSplits: 1).last.map(String.init)
        storageDetailIndex = arguments.first { $0.hasPrefix("--storage-detail=") }?.split(separator: "=", maxSplits: 1).last
            .flatMap { Int($0) }
    }

    static let current = LaunchOptions(arguments: CommandLine.arguments)
}
