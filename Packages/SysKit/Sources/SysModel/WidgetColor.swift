// 菜单栏 widget 的颜色（D43）：跟随系统，或用户选的一种固定颜色。纯值类型，AppKit 转换在 app 里。

import Foundation

public enum WidgetColor: Hashable, Sendable {
    /// 跟随系统（app 里对应 labelColor，随浅色 / 深色菜单栏切换）。
    case system
    /// 固定的 sRGB 颜色（0…1，不透明）。
    case custom(red: Double, green: Double, blue: Double)

    /// 持久化形式：「system」或「#RRGGBB」。
    public var storageValue: String {
        switch self {
        case .system: "system"
        case .custom(let r, let g, let b):
            String(format: "#%02X%02X%02X", Self.byte(r), Self.byte(g), Self.byte(b))
        }
    }

    public init?(storageValue: String) {
        if storageValue == "system" {
            self = .system
            return
        }
        guard storageValue.count == 7, storageValue.first == "#",
            storageValue.dropFirst().allSatisfy(\.isHexDigit),
            let rgb = UInt32(storageValue.dropFirst(), radix: 16)
        else { return nil }
        self = .custom(
            red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    private static func byte(_ component: Double) -> Int {
        guard component.isFinite else { return 0 }
        return Int((min(max(component, 0), 1) * 255).rounded())
    }
}
