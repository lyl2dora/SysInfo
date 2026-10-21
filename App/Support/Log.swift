// 日志（K29）：subsystem 用 Bundle ID，按模块分 category；热路径只打 debug 级别并限速，
// 序列号、MAC、IP 这类标识一律 .private（M0 还没有这类数据）。

import Foundation
import OSLog

nonisolated enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "zone.lyl.sysinfo"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let menubar = Logger(subsystem: subsystem, category: "menubar")
    static let panel = Logger(subsystem: subsystem, category: "panel")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let throttle = Logger(subsystem: subsystem, category: "throttle")
    static let widgets = Logger(subsystem: subsystem, category: "widgets")
}
