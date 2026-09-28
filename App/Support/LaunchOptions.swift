// 启动参数（M0 设计 §6，D18）：用于截图自查和开销测量，Debug 与 Release 都支持（measure 脚本用 Release 构建）。

import Foundation

nonisolated struct LaunchOptions: Sendable, Equatable {
    /// `--open-panel`：不经 session 直接显示面板（截图、「面板打开」档的开销测量）。
    var openPanel = false
    /// `--open-settings`：启动后直接打开设置窗口。
    var openSettings = false
    /// `--factory-defaults`：不读写持久化的设置，只用出厂默认值（开销测量用，不改动用户的偏好）。
    var factoryDefaults = false

    init(arguments: [String]) {
        openPanel = arguments.contains("--open-panel")
        openSettings = arguments.contains("--open-settings")
        factoryDefaults = arguments.contains("--factory-defaults")
    }

    static let current = LaunchOptions(arguments: CommandLine.arguments)
}
