// 普通窗口打开期间切换为 `.regular`（有 Dock 图标和主菜单，⌘W ⌘Q 可用），全部关闭后切回 `.accessory`（D23）。
// 设置窗口与应用活动窗口（D67）共用，避免一个窗口关闭时把另一个窗口的 Dock 图标一起收掉。

import AppKit

enum ForegroundWindows {
    @MainActor private static var open: Set<String> = []

    /// 某个窗口打开：第一次打开时切换为 `.regular`。
    @MainActor static func retain(_ name: String) {
        open.insert(name)
        NSApp.setActivationPolicy(.regular)
    }

    /// 某个窗口关闭：全部关闭后切回 `.accessory`。
    @MainActor static func release(_ name: String) {
        open.remove(name)
        if open.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}
