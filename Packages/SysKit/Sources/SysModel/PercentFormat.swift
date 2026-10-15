// 百分比格式化（K24）。菜单栏、面板和 sysinfo-cli 共用，保证同一个比例在各处显示一致。

import Foundation

/// 把 0…1 的比例格式化成百分比字符串。
///
/// - 四舍五入（0.5 进位），不用 printf 的「银行家舍入」，与活动监视器的直觉一致；
/// - 负数（含 -0）显示为 0，大于 1 的值照常显示（本进程 CPU 按单核计，多线程时可以超过 100%）；
/// - 非有限值（NaN、∞）显示为占位符「—」。不可用的指标应当在上层就不走到这里。
/// - 输出不随地区变化（数字用 ASCII、百分号紧跟数字），菜单栏 item 的固定宽度按它计算。
public enum PercentFormat: Sendable {
    /// 非有限值的占位符。
    public static let placeholder = "—"

    public static func string(fromRatio ratio: Double, fractionDigits: Int = 0) -> String {
        guard let rounded = displayedPercent(fromRatio: ratio, fractionDigits: fractionDigits) else { return placeholder }
        return String(format: "%.\(min(max(fractionDigits, 0), 6))f%%", rounded)
    }

    /// 显示出来的百分数（已按上面的规则取整），非有限值为 nil。菜单栏着色按它判定（D42），保证颜色与数字一致。
    public static func displayedPercent(fromRatio ratio: Double, fractionDigits: Int = 0) -> Double? {
        guard ratio.isFinite else { return nil }
        let digits = min(max(fractionDigits, 0), 6)
        var percent = ratio * 100
        if !(percent > 0) { percent = 0 }  // 负数和 -0 都归零
        let scale = pow(10.0, Double(digits))
        return (percent * scale).rounded(.toNearestOrAwayFromZero) / scale
    }
}
