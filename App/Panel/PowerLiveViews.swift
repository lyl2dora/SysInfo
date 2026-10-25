// 「功耗与散热」tab 里每秒都在变的部分（功耗与散热模块设计 §7.2），AppKit 自绘，做法同 LiveViews.swift：
// 在 draw(_:) 里直接读 MetricStore，数据变化时只重绘自己。

import AppKit
import SwiftUI
import SysModel

// MARK: - 概览

final class PowerOverviewDrawView: LiveDrawView {
    var hasFans = false {
        didSet { if hasFans != oldValue { needsDisplay = true } }
    }

    static let height: CGFloat = 94

    private static let big: NSFont = {
        let base = NSFont.monospacedDigitSystemFont(ofSize: PanelType.hero, weight: .semibold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: PanelType.hero) } ?? base
    }()
    private static let subheadline = NSFont.systemFont(ofSize: PanelType.title)
    private static let callout = NSFont.monospacedDigitSystemFont(ofSize: PanelType.title, weight: .medium)

    override func draw(_ dirtyRect: NSRect) {
        countDraw()
        let smoothed = store.smoothed  // 观察：平滑值变化时重绘
        let latest = store.latest
        Self.draw(Self.text(String(localized: "整机功率"), Self.subheadline, .secondaryLabelColor), x: 0, y: 0)
        let system = smoothed[.powerSystem].map(Formatting.watts) ?? "—"
        let w = Self.draw(Self.text(system, Self.big), x: 0, y: 17)
        if latest[.powerSystem]?.quality == .inferred {
            Self.draw(Self.text(String(localized: "推断"), Self.caption, .secondaryLabelColor), x: w + 6, y: 39)
        }
        // 墙插功率只是公式值（D46），放在次要位置并标「估算」。
        if let wall = latest[.powerWall]?.value {
            let text = String(localized: "墙插约 \(Formatting.watts(wall))（估算）")
            Self.draw(Self.text(text, Self.caption2Digits, .secondaryLabelColor), x: 0, y: 66)
        }

        let right = bounds.width
        var y: CGFloat = 0
        func item(_ title: String, _ value: String) {
            Self.drawRight(Self.text(title, Self.caption2, .secondaryLabelColor), right: right, y: y)
            Self.drawRight(Self.text(value, Self.callout), right: right, y: y + 14)
            y += 31
        }
        item(String(localized: "SoC"), smoothed[.powerSoC].map(Formatting.watts) ?? "—")
        item(String(localized: "最热点"), latest[.thermalSoCHotspot]?.value.map(Formatting.temperature) ?? "—")
        if hasFans {
            let rpm = latest.compactMap { id, s in id.fanSpeedIndex != nil ? s.value : nil }.max()
            item(String(localized: "风扇"), rpm.map(Formatting.rpm) ?? "—")
        }
        setAccessibilityLabel(String(localized: "整机功率 \(system)"))
    }
}

// MARK: - 功率分解（D44 PT4：各部件一行、SoC 合计单独一行，不相减）

final class PowerBreakdownDrawView: LiveDrawView {
    static let rowHeight: CGFloat = 18
    static let height: CGFloat = 17 + rowHeight * 4 + 6 + 16

    override func draw(_ dirtyRect: NSRect) {
        countDraw()
        let latest = store.latest
        let smoothed = store.smoothed
        Self.draw(Self.text(String(localized: "功率分解"), Self.captionBold), x: 0, y: 0)
        let soc = smoothed[.powerSoC]
        let rows: [(String, Double?, String?)] = [
            (String(localized: "CPU"), latest[.cpuPowerTotal]?.value, Self.reason(latest[.cpuPowerTotal])),
            (String(localized: "GPU"), smoothed[.powerGPU], Self.reason(latest[.powerGPU])),
            (String(localized: "DRAM"), latest[.powerDRAM]?.value, Self.reason(latest[.powerDRAM])),
        ]
        let scale = max(soc ?? 0, rows.compactMap(\.1).max() ?? 0, 1)
        var y: CGFloat = 17
        for (title, value, reason) in rows {
            drawRow(title, value: value, reason: reason, scale: scale, y: y, color: .controlAccentColor)
            y += Self.rowHeight
        }
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: y + 1, width: bounds.width, height: 0.5).fill()
        y += 4
        drawRow(String(localized: "SoC 合计"), value: soc, reason: Self.reason(latest[.powerSoC]), scale: scale, y: y, color: .systemOrange)
        y += Self.rowHeight + 2
        Self.draw(
            Self.text(String(localized: "CPU 为专用轨实测，其余为功耗模型口径，两者不相减。"), Self.caption2, .secondaryLabelColor), x: 0, y: y)
        setAccessibilityLabel(String(localized: "功率分解"))
    }

    private func drawRow(_ title: String, value: Double?, reason: String?, scale: Double, y: CGFloat, color: NSColor) {
        Self.draw(Self.text(title, Self.caption, .secondaryLabelColor), x: 0, y: y)
        let bar = NSRect(x: 80, y: y + 5.5, width: bounds.width - 80 - 76, height: 5)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        if let value {
            color.setFill()
            NSRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(min(max(value / scale, 0), 1)), height: bar.height).fill()
        }
        let text = value.map(Formatting.watts) ?? reason ?? "—"
        Self.drawRight(Self.text(text, Self.captionDigits, value == nil ? .secondaryLabelColor : .labelColor), right: bounds.width, y: y)
    }

    /// 不可用的简短原因（D29、D44：不估算，显示原因而不是 0）。
    static func reason(_ sample: Sample?) -> String? {
        guard case .unavailable(let reason)? = sample?.quality else { return nil }
        switch reason.code {
        case "noDedicatedRail": return String(localized: "无专用轨")
        case "selfTestFailed": return String(localized: "核对未通过")
        default: return "—"
        }
    }
}

// MARK: - 散热

final class ThermalDrawView: LiveDrawView {
    var fanCount = 0 {
        didSet { if fanCount != oldValue { needsDisplay = true } }
    }

    static let rowHeight: CGFloat = 18

    static func height(fans: Int) -> CGFloat {
        17 + rowHeight * CGFloat(1 + fans) + 23
    }

    override func draw(_ dirtyRect: NSRect) {
        countDraw()
        let latest = store.latest
        Self.draw(Self.text(String(localized: "散热"), Self.captionBold), x: 0, y: 0)
        var y: CGFloat = 17
        Self.draw(Self.text(String(localized: "SoC 最热点"), Self.caption, .secondaryLabelColor), x: 0, y: y)
        let hotspot = latest[.thermalSoCHotspot]
        let hotspotText: String
        if let value = hotspot?.value {
            hotspotText = Formatting.temperature(value)
        } else if case .unavailable(let reason)? = hotspot?.quality, reason.code == "learning" {
            hotspotText = String(localized: "学习中")
        } else {
            hotspotText = "—"
        }
        Self.drawRight(Self.text(hotspotText, Self.captionDigits), right: bounds.width, y: y)
        y += Self.rowHeight
        for index in 0..<fanCount {
            let title = fanCount > 1 ? String(localized: "风扇 \(index + 1)") : String(localized: "风扇")
            Self.draw(Self.text(title, Self.caption, .secondaryLabelColor), x: 0, y: y)
            let rpm = latest[.fanSpeed(index)]?.value
            let target = latest[.fanTarget(index)]?.value
            let low = latest[.fanMinimum(index)]?.value
            let high = latest[.fanMaximum(index)]?.value
            let mode = latest[.fanMode(index)]?.value
            // 占范围百分比：(实际 − 最低) / (最高 − 最低)。
            if let rpm, let low, let high, high > low {
                let bar = NSRect(x: 80, y: y + 5.5, width: bounds.width - 80 - 164, height: 5)
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
                NSColor.systemTeal.setFill()
                let ratio = min(max((rpm - low) / (high - low), 0), 1)
                NSRect(x: bar.minX, y: bar.minY, width: max(bar.width * CGFloat(ratio), 1), height: bar.height).fill()
            }
            var text = rpm.map(Formatting.rpm) ?? "—"
            if let target { text += String(localized: " · 目标 \(String(format: "%.0f", target))") }
            // 模式读不到时不显示，不当成「自动」。
            if let mode { text += mode != 0 ? String(localized: " · 强制") : String(localized: " · 自动") }
            Self.drawRight(Self.text(text, Self.caption2Digits, .secondaryLabelColor), right: bounds.width, y: y + 1)
            y += Self.rowHeight
        }
        // 徽标：热状态（正常也显示）、低功耗模式。
        var x: CGFloat = 0
        // 没有读数（首次采样前或采集器不可用）时显示灰色「热状态 —」，不显示成「正常」。
        let badge: (String, NSColor)
        if let state = latest[.cpuThermalState]?.value {
            badge = DisplayNames.thermalState(state).map { ($0.text, NSColor($0.color)) }
                ?? (String(localized: "热状态正常"), NSColor.systemGreen)
        } else {
            badge = (String(localized: "热状态 —"), NSColor.systemGray)
        }
        x += drawBadge(badge.0, color: badge.1, x: x, y: y + 2) + 6
        if latest[.powerLowPowerMode]?.value == 1 {
            _ = drawBadge(String(localized: "低功耗模式"), color: .systemYellow, x: x, y: y + 2)
        }
        setAccessibilityLabel(String(localized: "散热：最热点 \(hotspotText)"))
    }

    private func drawBadge(_ text: String, color: NSColor, x: CGFloat, y: CGFloat) -> CGFloat {
        let label = Self.text(text, Self.caption2)
        let size = label.size()
        let rect = NSRect(x: x, y: y, width: size.width + 12, height: size.height + 4)
        color.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        label.draw(at: NSPoint(x: rect.minX + 6, y: rect.minY + 2))
        return rect.width
    }
}
