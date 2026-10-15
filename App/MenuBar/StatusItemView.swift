// 菜单栏 widget 的自绘 view（K32、D06、D32、D38，CPU 模块设计 §7.1，功耗与散热模块设计 §7.1）。
//
// - 宽度按样式的最坏情况算好，运行中不改（改宽会让 MenuBarAgent 多占 4–5% 的核）。只有用户改样式、
//   标签开关，或拓扑决定的柱数变化时才重新定宽；
// - 数字用 monospacedDigitSystemFont，文字用语义色（菜单栏在 27 上是透明的，颜色不能按深浅色写死）；
// - 颜色（D43）：数值和图形用该 widget 设置的颜色，默认 labelColor；小标签始终 labelColor。不按数值着色；
// - 在 draw(_:) 里直接读 MetricStore，AppKit 会自动跟踪 @Observable 并在数值变化时重绘。

import AppKit
import SysModel

/// 菜单栏 item 的显示配置。
struct StatusItemConfiguration: Equatable {
    /// 这个 widget 显示哪一项（D38：一个 widget 一项）。
    var widget: MenuWidget = .usage
    /// 占用 widget 的样式；其余 widget 只用上下或左右布局（图形样式按上下布局画）。
    var style: MenuBarCPUStyle = .stacked
    var showsLabel = true
    /// 数值与图形的颜色（D43）。
    var color: WidgetColor = .system
    /// 每档柱的个数（拓扑的档数）。
    var levelCount = 2
    /// 每核柱的个数（逻辑核数）。
    var coreCount = 8
}

final class StatusItemView: NSView {
    // 上下布局（D32）：标签与数值同一字号、同一字重（2026-10-15 用户要求上下一致，偏离记录）。
    static let stackedFontSize: CGFloat = 10
    private static let stackedLabelFont = NSFont.systemFont(ofSize: stackedFontSize, weight: .medium)
    private static let stackedValueFont = NSFont.monospacedDigitSystemFont(ofSize: stackedFontSize, weight: .medium)
    // 左右布局（M0）。
    private static let inlineLabelFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private static let inlineValueFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private static let inlineSpacing: CGFloat = 3
    private static let padding: CGFloat = 2
    private static let sparklineWidth: CGFloat = 36
    private static let sparklineSeconds: Double = 60
    private static let coreBarWidth: CGFloat = 3
    private static let levelBarWidth: CGFloat = 5
    private static let totalBarWidth: CGFloat = 6

    /// 菜单栏小标签用英文缩写（D23）。
    private static func label(_ widget: MenuWidget) -> String {
        switch widget {
        case .usage: String(localized: "CPU", comment: "菜单栏小标签，保持英文缩写")
        case .frequency: String(localized: "FREQ", comment: "菜单栏小标签：CPU 频率，保持英文缩写")
        case .temperature: String(localized: "TEMP", comment: "菜单栏小标签：CPU 温度，保持英文缩写")
        case .power: String(localized: "PWR", comment: "菜单栏小标签：CPU 功耗，保持英文缩写")
        case .systemPower: String(localized: "SYS", comment: "菜单栏小标签：整机功率，保持英文缩写")
        case .socHotspot: String(localized: "HOT", comment: "菜单栏小标签：SoC 最热点，保持英文缩写")
        case .socPower: String(localized: "SOC", comment: "菜单栏小标签：SoC 功率，保持英文缩写")
        case .gpuPower: String(localized: "GPU", comment: "菜单栏小标签：GPU 功率，保持英文缩写")
        case .fan: String(localized: "FAN", comment: "菜单栏小标签：风扇转速，保持英文缩写")
        }
    }

    /// 各 widget 数值的最坏情况，用来定宽。
    private static func widestValue(_ widget: MenuWidget) -> String {
        switch widget {
        case .usage: "100%"
        case .frequency: "9.99G"
        case .temperature, .socHotspot: "125°"
        case .power, .systemPower, .socPower, .gpuPower: "99.9W"
        case .fan: "9999"
        }
    }

    /// 功率的显示：<10 W 一位小数，否则取整（「99.9W」与「188W」同宽）。
    static func wattsText(_ watts: Double) -> String {
        String(format: watts < 10 ? "%.1fW" : "%.0fW", watts)
    }

    /// 实际生效的样式：非占用 widget 只有上下、左右两种。
    static func effectiveStyle(_ c: StatusItemConfiguration) -> MenuBarCPUStyle {
        guard c.widget != .usage else { return c.style }
        return c.style == .inline ? .inline : .stacked
    }

    private static func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// 按样式的最坏情况算好的固定宽度。
    static func fixedWidth(for c: StatusItemConfiguration) -> CGFloat {
        let label = label(c.widget)
        let widestValue = widestValue(c.widget)
        let stackedLabel = c.showsLabel ? textWidth(label, stackedLabelFont) : 0
        let content: CGFloat
        switch effectiveStyle(c) {
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
    var configuration: StatusItemConfiguration {
        didSet { needsDisplay = true }
    }

    init(store: MetricStore, height: CGFloat, configuration: StatusItemConfiguration) {
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

    /// widget 的数值文字；没有数据时为 nil。
    private func valueText(_ widget: MenuWidget) -> String? {
        switch widget {
        case .usage:
            if case .value(let ratio, _) = store.menuBarCPU { return PercentFormat.string(fromRatio: ratio) }
            return nil
        case .frequency:
            // 各簇实际频率的最大值（最忙的簇）；全部空闲时没有数值。
            let hz = store.latest.compactMap { id, sample in id.cpuFrequencyClusterKey != nil ? sample.value : nil }.max()
            return hz.map { String(format: "%.2fG", $0 / 1e9) }
        case .temperature:
            return store.latest[.cpuTemperatureMax]?.value.map { String(format: "%.0f°", $0) }
        case .power:
            return store.latest[.cpuPowerTotal]?.value.map(Self.wattsText)
        case .systemPower:
            return store.smoothed[.powerSystem].map(Self.wattsText)
        case .socPower:
            return store.smoothed[.powerSoC].map(Self.wattsText)
        case .gpuPower:
            return store.smoothed[.powerGPU].map(Self.wattsText)
        case .socHotspot:
            return store.latest[.thermalSoCHotspot]?.value.map { String(format: "%.0f°", $0) }
        case .fan:
            // 多风扇时显示最快的一个。
            let rpm = store.latest.compactMap { id, sample in id.fanSpeedIndex != nil ? sample.value : nil }.max()
            return rpm.map { String(format: "%.0f", $0) }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let widget = configuration.widget
        let label = Self.label(widget)
        let color = configuration.color.nsColor
        let text = valueText(widget)  // 自动跟踪：数值变化时 AppKit 重绘
        let valueText = text ?? PercentFormat.placeholder
        let valueColor = text != nil ? color : NSColor.secondaryLabelColor

        switch Self.effectiveStyle(configuration) {
        case .inline:
            drawInline(label, valueText, valueColor)
        case .stacked:
            let contentRect = drawStackedLabel(label)
            let value = NSAttributedString(
                string: valueText, attributes: [.font: Self.stackedValueFont, .foregroundColor: valueColor])
            let size = value.size()
            value.draw(at: NSPoint(x: pixelAligned((bounds.width - size.width) / 2), y: contentRect.minY + Self.stackedValueFont.descender))
        case .sparkline:
            drawSparkline(in: drawStackedLabel(label, graphic: true), color: color)
        case .barsTotal:
            let ratio: Double? = if case .value(let r, _) = store.menuBarCPU { r } else { nil }
            drawBars([ratio], width: Self.totalBarWidth, gap: 0, in: drawStackedLabel(label, graphic: true), color: color)
        case .barsLevels:
            let levels = (0..<max(configuration.levelCount, 1)).map { store.latest[.cpuUsagePerfLevel($0)]?.value }
            drawBars(levels, width: Self.levelBarWidth, gap: 1, in: drawStackedLabel(label, graphic: true), color: color)
        case .barsCores:
            let cores = store.cpuCores.map(\.value)
            drawBars(cores, width: Self.coreBarWidth - 1, gap: 1, in: drawStackedLabel(label, graphic: true), color: color)
        }

        setAccessibilityLabel("\(label) \(valueText)")
    }

    /// 文字起点的横坐标对齐到设备像素。居中算出的起点带小数（如 5.54 pt），在 1x 屏上字形会被抗锯齿摊到相邻像素，
    /// 低对比的颜色（systemRed）看起来尤其发虚（2026-10-15 验收发现）。纵向的基线已经取整，不用再处理。
    private func pixelAligned(_ x: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (x * scale).rounded() / scale
    }

    /// 上下布局里两行之间的间距（按大写高度算）。
    private static let stackedGap: CGFloat = 2.5

    /// 上下布局：按「数值大写高度 + 间距 + 标签大写高度」整组垂直居中。画出标签（关闭时不画），
    /// 返回下方内容区（数值的大写高度那一条；折线和柱也画在这里）。
    /// - Parameter graphic: 折线、柱状用：返回标签下方的全部空间（下边留 3 pt），而不只是数字大写高度那一条，
    ///   否则图形只有约 7 pt 高，低占用时几乎贴在底线上（2026-10-15 自查发现）。
    private func drawStackedLabel(_ text: String, graphic: Bool = false) -> NSRect {
        let valueCap = Self.stackedValueFont.capHeight
        let labelCap = configuration.showsLabel ? Self.stackedLabelFont.capHeight + Self.stackedGap : 0
        let valueBaseline = floor((bounds.height - valueCap - labelCap) / 2)
        if configuration.showsLabel {
            let label = NSAttributedString(
                string: text, attributes: [.font: Self.stackedLabelFont, .foregroundColor: NSColor.labelColor])
            let labelBaseline = valueBaseline + valueCap + Self.stackedGap
            label.draw(at: NSPoint(x: pixelAligned((bounds.width - label.size().width) / 2), y: labelBaseline + Self.stackedLabelFont.descender))
        }
        if graphic {
            let bottom: CGFloat = 3
            let top = configuration.showsLabel ? valueBaseline + valueCap + 1 : bounds.height - 3
            return NSRect(x: Self.padding, y: bottom, width: bounds.width - 2 * Self.padding, height: max(top - bottom, 4))
        }
        return NSRect(x: Self.padding, y: valueBaseline, width: bounds.width - 2 * Self.padding, height: ceil(valueCap))
    }

    private func drawInline(_ labelText: String, _ valueText: String, _ valueColor: NSColor) {
        // 两种字号共用一条基线：让数字的大写高度在 item 里垂直居中。
        let baseline = floor((bounds.height - Self.inlineValueFont.capHeight) / 2)
        if configuration.showsLabel {
            let label = NSAttributedString(
                string: labelText, attributes: [.font: Self.inlineLabelFont, .foregroundColor: NSColor.labelColor])
            label.draw(at: NSPoint(x: Self.padding, y: baseline + Self.inlineLabelFont.descender))
        }
        let value = NSAttributedString(
            string: valueText, attributes: [.font: Self.inlineValueFont, .foregroundColor: valueColor])
        let valueWidth = value.size().width
        value.draw(at: NSPoint(x: pixelAligned(bounds.width - Self.padding - valueWidth), y: baseline + Self.inlineValueFont.descender))
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
