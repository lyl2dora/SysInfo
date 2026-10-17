// 面板的「内存」tab（内存模块设计 §7.2，D49）。
//
// 分区：概览 → 历史图（占用率，可叠加压力）→ 构成 → 活动与压力 → Top N（按内存）。
// 每秒都在变的部分用 AppKit 自绘（做法同 LiveViews.swift：在 draw(_:) 里直接读 MetricStore，数据变化时只重绘自己），
// SwiftUI 只放外框。需求由 PanelController 按 tab 可见性登记。

import AppKit
import SwiftUI
import SysCollectors
import SysModel

struct MemoryPanelView: View {
    let store: MetricStore
    let services: AppServices
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelCard {
                LiveView(make: { MemoryOverviewDrawView(store: store) })
                    .frame(height: MemoryOverviewDrawView.height)
            }
            PanelCard {
                HistoryChart(
                    store: store, history: services.history, defaultSpan: settings.memoryChartSpan,
                    series: ChartSeries(
                        metric: .memoryUsage, overlay: settings.memoryChartOverlayPressure ? .memoryPressure : nil,
                        collector: MemoryCollector.collectorID, scale: .unit))
            }
            PanelCard {
                LiveView(make: { MemoryCompositionDrawView(store: store) })
                    .frame(height: MemoryCompositionDrawView.height)
            }
            PanelCard {
                LiveView(make: { MemoryActivityDrawView(store: store) })
                    .frame(height: MemoryActivityDrawView.height)
            }
            if settings.memoryTopNRows > 0 {
                PanelCard {
                    TopNSection(model: services.memoryTopN, grouping: settings.memoryGrouping, slots: settings.memoryTopNRows)
                }
            }
        }
    }
}

// MARK: - 概览

final class MemoryOverviewDrawView: LiveDrawView {
    static let height: CGFloat = 94

    private static let big: NSFont = {
        let base = NSFont.monospacedDigitSystemFont(ofSize: PanelType.hero, weight: .semibold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: PanelType.hero) } ?? base
    }()
    private static let subheadline = NSFont.systemFont(ofSize: PanelType.title)
    private static let callout = NSFont.monospacedDigitSystemFont(ofSize: PanelType.title, weight: .medium)

    override func draw(_ dirtyRect: NSRect) {
        countDraw()
        let latest = store.latest
        Self.draw(Self.text(String(localized: "已用内存"), Self.subheadline, .secondaryLabelColor), x: 0, y: 0)
        let used = latest[.memoryUsed]
        let usedText = used?.value.map(Formatting.memory) ?? "—"
        let w = Self.draw(Self.text(usedText, Self.big), x: 0, y: 17)
        if used?.quality == .estimated {
            Self.draw(Self.text(String(localized: "估算"), Self.caption, .secondaryLabelColor), x: w + 6, y: 39)
        }
        if let physical = latest[.memoryPhysical]?.value {
            let usage = latest[.memoryUsage]?.value.map { PercentFormat.string(fromRatio: $0) } ?? "—"
            Self.draw(
                Self.text(String(localized: "共 \(Formatting.memory(physical)) · 占用 \(usage)"), Self.caption2Digits, .secondaryLabelColor),
                x: 0, y: 66)
        }

        let right = bounds.width
        var y: CGFloat = 0
        func item(_ title: String, _ value: String) {
            Self.drawRight(Self.text(title, Self.caption2, .secondaryLabelColor), right: right, y: y)
            Self.drawRight(Self.text(value, Self.callout), right: right, y: y + 14)
            y += 31
        }
        let level = MemoryPressureLevel(sampleValue: latest[.memoryPressureLevel]?.value)
        let pressure = latest[.memoryPressure]?.value.map { PercentFormat.string(fromRatio: $0) } ?? "—"
        item(String(localized: "压力"), level.map { "\(DisplayNames.memoryPressure($0)) · \(pressure)" } ?? pressure)
        item(String(localized: "Swap"), latest[.memorySwapUsed]?.value.map(Formatting.memory) ?? "—")
        item(String(localized: "被压缩"), latest[.memoryCompressed]?.value.map(Formatting.memory) ?? "—")
        setAccessibilityLabel(String(localized: "已用内存 \(usedText)，压力 \(pressure)"))
    }
}

// MARK: - 构成

/// 物理内存的构成：App、联动、被压缩、已缓存文件、空闲，一根横向堆叠条加逐项数值（按物理内存的比例）。
final class MemoryCompositionDrawView: LiveDrawView {
    static let rowHeight: CGFloat = 17
    static let parts: [(MetricID, NSColor)] = [
        (.memoryApp, .systemBlue), (.memoryWired, .systemOrange), (.memoryCompressed, .systemPurple),
        (.memoryCached, .systemTeal), (.memoryFree, .quaternaryLabelColor),
    ]
    static let height: CGFloat = 17 + 10 + 8 + rowHeight * CGFloat(parts.count) + 4 + 15

    static func title(_ id: MetricID) -> String {
        switch id {
        case .memoryApp: String(localized: "App 内存")
        case .memoryWired: String(localized: "联动内存")
        case .memoryCompressed: String(localized: "被压缩")
        case .memoryCached: String(localized: "已缓存文件")
        default: String(localized: "空闲")
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        countDraw()
        let latest = store.latest
        Self.draw(Self.text(String(localized: "构成"), Self.captionBold), x: 0, y: 0)
        let physical = latest[.memoryPhysical]?.value ?? 0
        // 堆叠条：按物理内存的比例；其余（引导保留等，约 1%）留成槽色。
        let bar = NSRect(x: 0, y: 17, width: bounds.width, height: 10)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.4).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
        if physical > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).addClip()
            var x = bar.minX
            for (id, color) in Self.parts {
                guard let value = latest[id]?.value, value > 0 else { continue }
                let width = bar.width * CGFloat(min(value / physical, 1))
                color.setFill()
                NSRect(x: x, y: bar.minY, width: width, height: bar.height).fill()
                x += width
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        var y = bar.maxY + 8
        for (id, color) in Self.parts {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: y + 4.5, width: 7, height: 7)).fill()
            Self.draw(Self.text(Self.title(id), Self.caption, .secondaryLabelColor), x: 12, y: y)
            let sample = latest[id]
            var text = sample?.value.map(Formatting.memory) ?? "—"
            if let value = sample?.value, physical > 0 {
                text += "  " + PercentFormat.string(fromRatio: value / physical)
            }
            if sample?.quality == .estimated { text += String(localized: "（估算）") }
            Self.drawRight(Self.text(text, Self.captionDigits), right: bounds.width, y: y)
            y += Self.rowHeight
        }
        y += 4
        Self.draw(
            Self.text(String(localized: "已用 = App + 联动 + 被压缩（同活动监视器）；缓存可随时回收。"), Self.caption2, .secondaryLabelColor),
            x: 0, y: y)
        setAccessibilityLabel(String(localized: "内存构成"))
    }
}

// MARK: - 活动与压力

final class MemoryActivityDrawView: LiveDrawView {
    static let rowHeight: CGFloat = 18
    static let height: CGFloat = 17 + rowHeight * 4 + 25

    override func draw(_ dirtyRect: NSRect) {
        countDraw()
        let latest = store.latest
        Self.draw(Self.text(String(localized: "活动"), Self.captionBold), x: 0, y: 0)
        func rate(_ id: MetricID) -> String { latest[id]?.value.map(Formatting.rate) ?? "—" }
        var y: CGFloat = 17
        func row(_ title: String, _ value: String) {
            Self.draw(Self.text(title, Self.caption, .secondaryLabelColor), x: 0, y: y)
            Self.drawRight(Self.text(value, Self.captionDigits), right: bounds.width, y: y)
            y += Self.rowHeight
        }
        row(String(localized: "页入 / 页出"), "\(rate(.memoryPageInRate)) / \(rate(.memoryPageOutRate))")
        row(String(localized: "换入 / 换出"), "\(rate(.memorySwapInRate)) / \(rate(.memorySwapOutRate))")
        row(String(localized: "压缩 / 解压"), "\(rate(.memoryCompressionRate)) / \(rate(.memoryDecompressionRate))")
        let ratio = latest[.memoryCompressionRatio]
        let ratioText: String
        if let value = ratio?.value {
            ratioText = String(format: "%.1f : 1", value)
        } else if case .unavailable(let reason)? = ratio?.quality, reason.code == "nothingCompressed" {
            ratioText = String(localized: "没有被压缩的页")
        } else {
            ratioText = "—"
        }
        row(String(localized: "压缩比"), ratioText)

        // 徽标：当前压力等级；另给最近 15 分钟出现过的最差等级（变化记录，D49）。
        var x: CGFloat = 0
        let current = MemoryPressureLevel(sampleValue: latest[.memoryPressureLevel]?.value)
        let worst = store.recentPoints(.memoryPressureLevel, seconds: 900)
            .compactMap { MemoryPressureLevel(sampleValue: $0.value) }.max()
        if let current {
            x += drawBadge(String(localized: "压力\(DisplayNames.memoryPressure(current))"), color: Self.color(current), x: x, y: y + 4) + 6
        }
        if let worst, let current, worst > current {
            _ = drawBadge(String(localized: "15 分钟内最高：\(DisplayNames.memoryPressure(worst))"), color: Self.color(worst), x: x, y: y + 4)
        }
        setAccessibilityLabel(String(localized: "内存活动"))
    }

    static func color(_ level: MemoryPressureLevel) -> NSColor {
        switch level {
        case .normal: .systemGreen
        case .warning: .systemYellow
        case .critical: .systemRed
        }
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
