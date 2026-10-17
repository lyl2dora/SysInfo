// 面板字号（D73）：SwiftUI 与 AppKit 自绘共用一套，改字号只改这里。
//
// 原来 SwiftUI 的 .caption / .caption2 在 macOS 上都是 10 pt，自绘卡片的行文字是 11 pt、注释 10 pt、摘要数值 13 pt。
// D73 整体加大 1 号并统一两边：行文字 12、注释 11、摘要标题与数值 14、顶栏标题 13；顶部大数字 34 不变。
// 自绘卡片的行高、偏移按这些字号的行高推算（见各 view 的常量），改字号后要一起核对。

import AppKit
import SwiftUI

enum PanelType {
    /// 行文字：列表行、卡片里的名称与数值（原 SwiftUI .caption 10 / 自绘 caption 11）。
    static let row: CGFloat = 12
    /// 注释与次要标签：说明文字、列标题、小标签（原 .caption2 / 自绘 caption2，10）。
    static let note: CGFloat = 11
    /// 摘要区的标题与右列数值（原 13）。
    static let title: CGFloat = 14
    /// 顶栏标题、应用详情的名称（原 .callout 12）。
    static let heading: CGFloat = 13
    /// 顶部大数字（不变）。
    static let hero: CGFloat = 34
}

extension Font {
    /// 面板行文字（D73，替代 .caption）。
    static let panelRow = Font.system(size: PanelType.row)
    /// 面板注释（D73，替代 .caption2）。
    static let panelNote = Font.system(size: PanelType.note)
    /// 面板顶栏标题（D73，替代 .callout）。
    static let panelTitle = Font.system(size: PanelType.heading)
}
