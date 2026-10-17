// 合并 item 的 view（D65 MG1）：各 widget 的 StatusItemView 横向并排，段间画细线或留空。
//
// - 每段沿用自己的宽度、颜色与排版（StatusItemView 不改），总宽 = 各段宽度 + 分隔，运行中不变（K32）；
// - 各段自己在 draw(_:) 里读 MetricStore，数值变化时只重绘变化的那一段；
// - 点击由系统交给 item 的 expandedInterfaceDelegate；落在哪一段由 `widget(atScreenPoint:)` 判断（D65 MG2）。

import AppKit

final class MergedStatusItemView: NSView {
    /// 细线分隔：线两边各留的空白、线宽、线高。
    static let lineGap: CGFloat = 3
    static let lineWidth: CGFloat = 1
    static let lineHeight: CGFloat = 14
    /// 留空分隔的宽度。
    static let spaceGap: CGFloat = 6

    private let store: MetricStore
    private(set) var segments: [StatusItemView] = []
    private(set) var separator: MergedSeparator = .line

    init(store: MetricStore, height: CGFloat) {
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: height))
        autoresizingMask = [.height]
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "SysInfo"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    static func gapWidth(_ separator: MergedSeparator) -> CGFloat {
        separator == .line ? lineGap * 2 + lineWidth : spaceGap
    }

    /// 合并 item 的固定宽度。
    static func fixedWidth(for configurations: [StatusItemConfiguration], separator: MergedSeparator) -> CGFloat {
        let segments = configurations.reduce(0) { $0 + StatusItemView.fixedWidth(for: $1) }
        return ceil(segments + CGFloat(max(configurations.count - 1, 0)) * gapWidth(separator))
    }

    /// 按配置重建或更新各段；段的种类与顺序不变时只更新配置（不重建 view）。返回新的总宽。
    @discardableResult
    func apply(_ configurations: [StatusItemConfiguration], separator: MergedSeparator) -> CGFloat {
        if segments.map(\.configuration.widget) != configurations.map(\.widget) {
            segments.forEach { $0.removeFromSuperview() }
            segments = configurations.map { StatusItemView(store: store, height: bounds.height, configuration: $0) }
            segments.forEach(addSubview)
        } else {
            for (view, configuration) in zip(segments, configurations) where view.configuration != configuration {
                view.configuration = configuration
            }
        }
        self.separator = separator
        var x: CGFloat = 0
        for view in segments {
            let width = StatusItemView.fixedWidth(for: view.configuration)
            view.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x += width + Self.gapWidth(separator)
        }
        let width = Self.fixedWidth(for: configurations, separator: separator)
        setFrameSize(NSSize(width: width, height: bounds.height))
        needsDisplay = true
        return width
    }

    override func draw(_ dirtyRect: NSRect) {
        guard separator == .line, segments.count > 1 else { return }
        // 模板色：菜单栏在 27 上是透明的，按 labelColor 的弱化色画线，不按深浅色写死。
        NSColor.labelColor.withAlphaComponent(0.3).setFill()
        let y = floor((bounds.height - Self.lineHeight) / 2)
        for view in segments.dropLast() {
            NSRect(x: view.frame.maxX + Self.lineGap, y: y, width: Self.lineWidth, height: Self.lineHeight).fill()
        }
    }

    /// 屏幕上的一点落在哪一段：在 item 窗口内时取最近的一段（分隔上归最近的一段）；不在窗口内时为 nil。
    func widget(atScreenPoint point: NSPoint) -> MenuWidget? {
        guard let window, window.frame.contains(point), !segments.isEmpty else { return nil }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        let nearest = segments.min { a, b in
            Self.distance(local.x, a.frame) < Self.distance(local.x, b.frame)
        }
        return nearest?.configuration.widget
    }

    private static func distance(_ x: CGFloat, _ frame: NSRect) -> CGFloat {
        x < frame.minX ? frame.minX - x : (x > frame.maxX ? x - frame.maxX : 0)
    }
}
