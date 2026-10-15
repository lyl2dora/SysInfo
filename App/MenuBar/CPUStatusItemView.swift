// 菜单栏 CPU item 的自绘 view（K32、D06、D32，CPU 模块设计 §7.1）。
//
// - 宽度按样式的最坏情况算好，运行中不改（改宽会让 MenuBarAgent 多占 4–5% 的核）。只有用户改样式、
//   标签开关，或拓扑决定的柱数变化时才重新定宽；
// - 数字用 monospacedDigitSystemFont，文字用语义色（菜单栏在 27 上是透明的，颜色不能按深浅色写死）；
// - 着色（D32）：平时 labelColor；持续高占用时数值（或柱、折线）变 systemOrange / systemRed；
// - 在 draw(_:) 里直接读 MetricStore，AppKit 会自动跟踪 @Observable 并在数值变化时重绘。

import AppKit
import SysModel

/// 菜单栏 item 的显示配置。
struct CPUStatusItemConfiguration: Equatable {
    var style: MenuBarCPUStyle = .stacked
    var showsLabel = true
    var coloring = true
    /// 每档柱的个数（拓扑的档数）。
    var levelCount = 2
    /// 每核柱的个数（逻辑核数）。
    var coreCount = 8
}

final class CPUStatusItemView: NSView {
    // 上下布局（D32）：标签与数值同一字号、同一字重（2026-10-15 用户要求上下一致，偏离记录）。
    static let stackedFontSize: CGFloat = 10
    private static let stackedLabelFont = NSFont.systemFont(ofSize: stackedFontSize, weight: .medium)
    private static let stackedValueFont = NSFont.monospacedDigitSystemFont(ofSize: stackedFontSize, weight: .medium)
    // 左右布局（M0）。
    private static let inlineLabelFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private static let inlineValueFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private static let inlineSpacing: CGFloat = 3
    private static let padding: CGFloat = 2
    /// 最坏情况的数值字符串，用来定宽。
    private static let widestValue = "100%"
    private static let sparklineWidth: CGFloat = 36
    private static let sparklineSeconds: Double = 60
    private static let coreBarWidth: CGFloat = 3
    private static let levelBarWidth: CGFloat = 5
    private static let totalBarWidth: CGFloat = 6

    /// 菜单栏小标签用英文缩写（D23）。
    private static var label: String { String(localized: "CPU", comment: "菜单栏小标签，保持英文缩写") }

    private static func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// 按样式的最坏情况算好的固定宽度。
    static func fixedWidth(for c: CPUStatusItemConfiguration) -> CGFloat {
        let stackedLabel = c.showsLabel ? textWidth(label, stackedLabelFont) : 0
        let content: CGFloat
        switch c.style {
        case .stacked:
            content = max(stackedLabel, textWidth(widestValue, stackedValueFont))
        case .inline:
            let labelPart = c.showsLabel ? textWidth(label, inlineLabelFont) + inlineSpacing : 0
            content = labelPart + textWidth(widestValue, inlineValueFont)
        case .sparkline:
            content = max(stackedLabel, sparklineWidth)
        case .barsTotal:
            content = max(stackedLabel, totalBarWidth)
        case .barsLevels:
            content = max(stackedLabel, CGFloat(max(c.levelCount, 1)) * (levelBarWidth + 1) - 1)
        case .barsCores:
            content = max(stackedLabel, CGFloat(max(c.coreCount, 1)) * coreBarWidth)
        }
        return ceil(padding + content + padding)
    }

    private let store: MetricStore
    var configuration: CPUStatusItemConfiguration {
        didSet { needsDisplay = true }
    }

    init(store: MetricStore, height: CGFloat, configuration: CPUStatusItemConfiguration) {
        self.store = store
        self.configuration = configuration
        super.init(frame: NSRect(x: 0, y: 0, width: Self.fixedWidth(for: configuration), height: height))
        autoresizingMask = [.height]
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { false }

    /// 数值与图形的颜色：着色关闭或正常时用 labelColor（D32）。
    private func accentColor(_ level: UsageLevel) -> NSColor {
        guard configuration.coloring else { return .labelColor }
        switch level {
        case .normal: return .labelColor
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let reading = store.menuBarCPU  // 自动跟踪：数值变化时 AppKit 重绘
        let color = accentColor(store.menuBarLevel)

        let valueText: String
        let hasValue: Bool
        switch reading {
        case .value(let ratio, _):
            valueText = PercentFormat.string(fromRatio: ratio)
            hasValue = true
        case .noData, .unavailable:
            valueText = PercentFormat.placeholder
            hasValue = false
        }
        let valueColor = hasValue ? color : NSColor.secondaryLabelColor

        switch configuration.style {
        case .inline:
            drawInline(valueText, valueColor)
        case .stacked:
            let contentRect = drawStackedLabel()
            let value = NSAttributedString(
                string: valueText, attributes: [.font: Self.stackedValueFont, .foregroundColor: valueColor])
            let size = value.size()
            value.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: contentRect.minY + Self.stackedValueFont.descender))
        case .sparkline:
            drawSparkline(in: drawStackedLabel(), color: color)
        case .barsTotal:
            let ratio: Double? = if case .value(let r, _) = reading { r } else { nil }
            drawBars([ratio], width: Self.totalBarWidth, gap: 0, in: drawStackedLabel(), color: color)
        case .barsLevels:
            let levels = (0..<max(configuration.levelCount, 1)).map { store.latest[.cpuUsagePerfLevel($0)]?.value }
            drawBars(levels, width: Self.levelBarWidth, gap: 1, in: drawStackedLabel(), color: color)
        case .barsCores:
            let cores = store.cpuCores.map(\.value)
            drawBars(cores, width: Self.coreBarWidth - 1, gap: 1, in: drawStackedLabel(), color: color)
        }

        setAccessibilityLabel("\(Self.label) \(valueText)")
    }

    /// 上下布局里两行之间的间距（按大写高度算）。
    private static let stackedGap: CGFloat = 2.5

    /// 上下布局：按「数值大写高度 + 间距 + 标签大写高度」整组垂直居中。画出标签（关闭时不画），
    /// 返回下方内容区（数值的大写高度那一条；折线和柱也画在这里）。
    private func drawStackedLabel() -> NSRect {
        let valueCap = Self.stackedValueFont.capHeight
        let labelCap = configuration.showsLabel ? Self.stackedLabelFont.capHeight + Self.stackedGap : 0
        let valueBaseline = floor((bounds.height - valueCap - labelCap) / 2)
        if configuration.showsLabel {
            let label = NSAttributedString(
                string: Self.label, attributes: [.font: Self.stackedLabelFont, .foregroundColor: NSColor.labelColor])
            let labelBaseline = valueBaseline + valueCap + Self.stackedGap
            label.draw(at: NSPoint(x: (bounds.width - label.size().width) / 2, y: labelBaseline + Self.stackedLabelFont.descender))
        }
        return NSRect(x: Self.padding, y: valueBaseline, width: bounds.width - 2 * Self.padding, height: ceil(valueCap))
    }

    private func drawInline(_ valueText: String, _ valueColor: NSColor) {
        // 两种字号共用一条基线：让数字的大写高度在 item 里垂直居中。
        let baseline = floor((bounds.height - Self.inlineValueFont.capHeight) / 2)
        if configuration.showsLabel {
            let label = NSAttributedString(
                string: Self.label, attributes: [.font: Self.inlineLabelFont, .foregroundColor: NSColor.labelColor])
            label.draw(at: NSPoint(x: Self.padding, y: baseline + Self.inlineLabelFont.descender))
        }
        let value = NSAttributedString(
            string: valueText, attributes: [.font: Self.inlineValueFont, .foregroundColor: valueColor])
        let valueWidth = value.size().width
        value.draw(at: NSPoint(x: bounds.width - Self.padding - valueWidth, y: baseline + Self.inlineValueFont.descender))
    }

    private func drawSparkline(in rect: NSRect, color: NSColor) {
        let points = store.recentPoints(.cpuUsageTotal, seconds: Self.sparklineSeconds)
        NSColor.tertiaryLabelColor.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 0.5).fill()
        guard let newest = points.last?.continuousNanos else { return }
        let path = NSBezierPath()
        path.lineWidth = 1
        path.lineJoinStyle = .round
        var started = false
        for point in points {
            guard let value = point.value else {
                started = false
                continue
            }
            let age = Double(newest - point.continuousNanos) / 1e9
            let x = rect.maxX - CGFloat(age / Self.sparklineSeconds) * rect.width
            let y = rect.minY + CGFloat(min(max(value, 0), 1)) * rect.height
            if started { path.line(to: NSPoint(x: x, y: y)) } else { path.move(to: NSPoint(x: x, y: y)) }
            started = true
        }
        color.setStroke()
        path.stroke()
    }

    /// 柱：底是淡色槽，不可用时只画槽，不画成 0。
    private func drawBars(_ values: [Double?], width: CGFloat, gap: CGFloat, in rect: NSRect, color: NSColor) {
        let total = CGFloat(values.count) * (width + gap) - gap
        var x = rect.minX + (rect.width - total) / 2
        for value in values {
            let slot = NSRect(x: x, y: rect.minY, width: width, height: rect.height)
            NSColor.quaternaryLabelColor.setFill()
            slot.fill()
            if let value {
                color.setFill()
                NSRect(x: x, y: rect.minY, width: width, height: max(rect.height * CGFloat(min(max(value, 0), 1)), 1)).fill()
            }
            x += width + gap
        }
    }
}
