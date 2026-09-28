// 菜单栏 CPU item 的自绘 view（K32、D06，M0 设计 §6）。
//
// - 宽度按最坏情况「CPU 100%」算好，运行中不改（改宽会让 MenuBarAgent 多占 4–5% 的核）；
// - 数字用 monospacedDigitSystemFont，文字用语义色（菜单栏在 27 上是透明的，颜色不能按深浅色写死）；
// - 在 draw(_:) 里直接读 MetricStore，AppKit 会自动跟踪 @Observable 并在数值变化时重绘。

import AppKit
import SysModel

final class CPUStatusItemView: NSView {
    private static let labelFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private static let spacing: CGFloat = 3
    private static let padding: CGFloat = 1
    /// 最坏情况的数值字符串，用来定宽。
    private static let widestValue = "100%"

    /// 菜单栏小标签用英文缩写（D23）。
    private static var label: String { String(localized: "CPU", comment: "菜单栏小标签，保持英文缩写") }

    /// 按最坏情况算好的固定宽度。
    static var fixedWidth: CGFloat {
        let labelWidth = (label as NSString).size(withAttributes: [.font: labelFont]).width
        let valueWidth = (widestValue as NSString).size(withAttributes: [.font: valueFont]).width
        return ceil(padding + labelWidth + spacing + valueWidth + padding)
    }

    private let store: MetricStore

    init(store: MetricStore, height: CGFloat) {
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: Self.fixedWidth, height: height))
        autoresizingMask = [.height]
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let reading = store.menuBarCPU  // 自动跟踪：数值变化时 AppKit 重绘

        let valueText: String
        let valueColor: NSColor
        switch reading {
        case .value(let ratio, _):
            valueText = PercentFormat.string(fromRatio: ratio)
            valueColor = .labelColor
        case .noData, .unavailable:
            valueText = PercentFormat.placeholder
            valueColor = .secondaryLabelColor
        }

        // 两种字号共用一条基线：让数字的大写高度在 item 里垂直居中。
        let baseline = floor((bounds.height - Self.valueFont.capHeight) / 2)

        let label = NSAttributedString(
            string: Self.label,
            attributes: [.font: Self.labelFont, .foregroundColor: NSColor.labelColor])
        label.draw(at: NSPoint(x: Self.padding, y: baseline + Self.labelFont.descender))

        let value = NSAttributedString(
            string: valueText, attributes: [.font: Self.valueFont, .foregroundColor: valueColor])
        let valueWidth = value.size().width
        value.draw(at: NSPoint(x: bounds.width - Self.padding - valueWidth, y: baseline + Self.valueFont.descender))

        setAccessibilityLabel("\(Self.label) \(valueText)")
    }
}
