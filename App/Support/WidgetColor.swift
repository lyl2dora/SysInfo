// 菜单栏 widget 颜色（D43）与 AppKit 颜色之间的转换。

import AppKit
import SysModel

extension WidgetColor {
    var nsColor: NSColor {
        switch self {
        case .system: .labelColor
        case .custom(let r, let g, let b): NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
    }

    /// 从任意 NSColor 取 sRGB 分量（丢掉透明度）；转换不了时为 nil。
    init?(_ color: NSColor) {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        self = .custom(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
    }
}
