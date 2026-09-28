// 主菜单（M0 设计 §6）：设置窗口打开期间 app 是 .regular，菜单栏显示这份菜单，⌘, ⌘Q ⌘W 可用。
// accessory 状态下不显示，但一直挂在 NSApp 上。

import AppKit

enum MainMenu {
    /// - Parameters:
    ///   - target: 「关于」「设置…」的响应者（AppDelegate）。
    static func make(target: AnyObject, about: Selector, settings: Selector) -> NSMenu {
        let appName = BuildInfo.displayName
        let main = NSMenu()

        // 应用菜单
        let appMenu = NSMenu(title: appName)
        appMenu.addItem(item(String(localized: "关于 \(appName)"), about, target: target))
        appMenu.addItem(.separator())
        appMenu.addItem(item(String(localized: "设置…"), settings, key: ",", target: target))
        appMenu.addItem(.separator())
        appMenu.addItem(item(String(localized: "隐藏 \(appName)"), #selector(NSApplication.hide(_:)), key: "h"))
        let hideOthers = item(String(localized: "隐藏其他"), #selector(NSApplication.hideOtherApplications(_:)), key: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(item(String(localized: "全部显示"), #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item(String(localized: "退出 \(appName)"), #selector(NSApplication.terminate(_:)), key: "q"))
        addSubmenu(appMenu, to: main)

        // 编辑（设置里的文本控件需要标准的剪切、拷贝、粘贴）
        let editMenu = NSMenu(title: String(localized: "编辑"))
        editMenu.addItem(item(String(localized: "撤销"), Selector(("undo:")), key: "z"))
        let redo = item(String(localized: "重做"), Selector(("redo:")), key: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(item(String(localized: "剪切"), #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(item(String(localized: "拷贝"), #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(item(String(localized: "粘贴"), #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(item(String(localized: "全选"), #selector(NSText.selectAll(_:)), key: "a"))
        addSubmenu(editMenu, to: main)

        // 窗口
        let windowMenu = NSMenu(title: String(localized: "窗口"))
        windowMenu.addItem(item(String(localized: "最小化"), #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        windowMenu.addItem(item(String(localized: "关闭"), #selector(NSWindow.performClose(_:)), key: "w"))
        addSubmenu(windowMenu, to: main)
        NSApp.windowsMenu = windowMenu

        return main
    }

    private static func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil)
        -> NSMenuItem
    {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    private static func addSubmenu(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}
