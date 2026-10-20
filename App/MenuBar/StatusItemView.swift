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
    /// 内存占用 widget 显示已用 GB 而不是百分比（D49）。
    var memoryShowsBytes = false
    /// 存储 widget 绑定的盘或容量组（D54）；绑定的盘不在了时仍保留键，显示「—」。
    var storageKey: DiskKey?
    /// 盘温 widget 显示所有盘的最高温。
    var storageHottest = false
    /// 网速 widget 的入 / 出指标（按绑定解析好，D60）。
    var networkIn: MetricID?
    var networkOut: MetricID?
    /// 网速用比特 / 秒。
    var networkBits = false
    /// 延迟 widget 的 RTT 指标。
    var latencyMetric: MetricID?
    /// 电源设备 widget 绑定的设备（D84）。
    var deviceTarget: DeviceTarget = .auto
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
        case .gpuPower: String(localized: "GPU", comment: "菜单栏小标签：GPU 模块的 widget，保持英文缩写")
        case .gpuActive: String(localized: "GPU", comment: "菜单栏小标签：GPU 模块的 widget，保持英文缩写")
        case .gpuTemperature: String(localized: "GPU", comment: "菜单栏小标签：GPU 模块的 widget，保持英文缩写")
        case .fan: String(localized: "FAN", comment: "菜单栏小标签：风扇转速，保持英文缩写")
        case .memoryUsage: String(localized: "RAM", comment: "菜单栏小标签：内存占用，保持英文缩写")
        case .memoryPressure: String(localized: "PRES", comment: "菜单栏小标签：内存压力，保持英文缩写")
        case .swapUsed: String(localized: "SWAP", comment: "菜单栏小标签：Swap 用量，保持英文缩写")
        case .diskTemperature: String(localized: "SSD", comment: "菜单栏小标签：盘温，保持英文缩写")
        case .diskThroughput: String(localized: "DISK", comment: "菜单栏小标签：磁盘读写（读写 widget 实际画 R/W 两行），保持英文缩写")
        case .diskFree: String(localized: "FREE", comment: "菜单栏小标签：可用空间，保持英文缩写")
        case .netThroughput: String(localized: "NET", comment: "菜单栏小标签：网速（实际画 ↑ / ↓ 两行），保持英文缩写")
        case .netLatency: String(localized: "PING", comment: "菜单栏小标签：网络延迟，保持英文缩写")
        case .deviceBattery: String(localized: "UPS", comment: "菜单栏小标签：UPS 电量，保持英文缩写")
        }
    }

    /// 电源设备 widget 的小标签按绑定到的设备种类换（定宽取几种里最宽的）。
    private static func deviceLabel(_ kind: PowerDeviceKind?) -> String {
        switch kind {
        case .ups, nil: String(localized: "UPS", comment: "菜单栏小标签：UPS 电量，保持英文缩写")
        case .internalBattery: String(localized: "BAT", comment: "菜单栏小标签：内置电池电量，保持英文缩写")
        case .accessory: String(localized: "ACC", comment: "菜单栏小标签：配件电量，保持英文缩写")
        }
    }

    private static var deviceLabels: [String] { [deviceLabel(.ups), deviceLabel(.internalBattery), deviceLabel(.accessory)] }

    /// 电池图形（D88）：iPhone 式，25 × 10 pt，圆角 3；数字与闪电镂空在里面。正极头在右侧，占 2.25 pt。
    static let batteryWidth: CGFloat = 25
    static let batteryHeight: CGFloat = 10
    static let batteryNub: CGFloat = 2.25
    private static let batteryFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold)
    private static let batteryTrack = NSColor.labelColor.withAlphaComponent(0.35)
    /// 设备没有自报低电量阈值时的默认值。
    private static let defaultLowLevel = 0.2

    /// 读写 widget 两行前面的字母（同 Stats 的 R / W）。
    private static let readSymbol = String(localized: "R", comment: "菜单栏读写 widget：读，保持英文字母")
    private static let writeSymbol = String(localized: "W", comment: "菜单栏读写 widget：写，保持英文字母")
    /// 网速 widget 两行前面的箭头：上行出（上传），下行入（下载）。
    private static let uploadSymbol = "↑"
    private static let downloadSymbol = "↓"

    /// 两行 widget（读写、网速）各行的符号。
    private static func rowSymbols(_ widget: MenuWidget) -> (String, String) {
        widget == .netThroughput ? (uploadSymbol, downloadSymbol) : (readSymbol, writeSymbol)
    }

    static func isTwoRow(_ widget: MenuWidget) -> Bool { widget == .diskThroughput || widget == .netThroughput }

    /// 各 widget 数值的最坏情况，用来定宽。
    private static func widestValue(_ c: StatusItemConfiguration) -> String {
        switch c.widget {
        case .usage, .memoryPressure: "100%"
        case .memoryUsage: c.memoryShowsBytes ? "99.9G" : "100%"
        case .frequency: "9.99G"
        case .temperature, .socHotspot: "125°"
        case .power, .systemPower, .socPower, .gpuPower: "99.9W"
        case .fan: "9999"
        case .swapUsed: "99.9G"
        case .diskTemperature, .gpuTemperature: "125°"
        case .gpuActive: "100%"
        case .diskThroughput: "999M"
        case .diskFree: "99.9T"
        case .netThroughput: c.networkBits ? "999Mb" : "999M"
        case .netLatency: "999ms"
        case .deviceBattery: "100%"
        }
    }

    /// 比特速率的短格式：字节 × 8，单位加 b（「96Mb」「1.2Gb」「800b」），与字节的「12M」区分开。
    static func bitsShort(_ bytesPerSecond: Double) -> String {
        let units = ["b", "Kb", "Mb", "Gb", "Tb"]
        var v = max(bytesPerSecond * 8, 0)
        var unit = 0
        while v >= 999.5, unit < units.count - 1 {
            v /= 1000
            unit += 1
        }
        if unit == 0 { return String(format: "%.0f%@", v, units[0]) }
        return String(format: v < 9.95 ? "%.1f%@" : "%.0f%@", v, units[unit])
    }

    /// 延迟：<10 ms 一位小数，否则取整，封顶 999ms。
    static func millisecondsShort(_ seconds: Double) -> String {
        let ms = seconds * 1000
        return ms < 9.95 ? String(format: "%.1fms", ms) : String(format: "%.0fms", min(ms, 999))
    }

    /// 十进制的短格式（K24：磁盘按 1000 换算）：<10 一位小数，否则取整；「812G」「1.2T」「340K」「12B」。
    static func decimalShort(_ value: Double) -> String {
        let units = ["B", "K", "M", "G", "T", "P"]
        var v = max(value, 0)
        var unit = 0
        while v >= 999.5, unit < units.count - 1 {
            v /= 1000
            unit += 1
        }
        if unit == 0 { return String(format: "%.0f%@", v, units[0]) }
        return String(format: v < 9.95 ? "%.1f%@" : "%.0f%@", v, units[unit])
    }

    /// 内存字节数的显示：按 1024 换算成 GB，<100 一位小数，否则取整（「99.9G」与「128G」同宽或更窄）。
    static func gigabytesText(_ bytes: Double) -> String {
        let gb = bytes / 1_073_741_824
        return String(format: gb < 99.95 ? "%.1fG" : "%.0fG", gb)
    }

    /// 功率的显示：<10 W 一位小数，否则取整（「99.9W」与「188W」同宽）。
    static func wattsText(_ watts: Double) -> String {
        String(format: watts < 10 ? "%.1fW" : "%.0fW", watts)
    }

    /// 实际生效的样式：非占用 widget 只有上下、左右两种；读写 widget 固定上下两行（同 Stats 的 twoRows）。
    static func effectiveStyle(_ c: StatusItemConfiguration) -> MenuBarCPUStyle {
        guard c.widget != .usage else { return c.style }
        if isTwoRow(c.widget) { return .stacked }
        return c.style == .inline ? .inline : .stacked
    }

    private static func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// 按样式的最坏情况算好的固定宽度。
    static func fixedWidth(for c: StatusItemConfiguration) -> CGFloat {
        if isTwoRow(c.widget) {
            let (top, bottom) = rowSymbols(c.widget)
            let symbol = c.showsLabel
                ? max(textWidth(top, stackedLabelFont), textWidth(bottom, stackedLabelFont)) + throughputGap : 0
            return ceil(padding + symbol + textWidth(widestValue(c), stackedValueFont) + padding)
        }
        let label = label(c.widget)
        let widestValue = widestValue(c)
        let labels = c.widget == .deviceBattery ? deviceLabels : [label]
        let stackedLabel = c.showsLabel ? labels.map { textWidth($0, stackedLabelFont) }.max() ?? 0 : 0
        let content: CGFloat
        if c.widget == .deviceBattery {
            // 电池本体居中，两侧各留出正极头的宽度，左右对称。
            let battery = batteryWidth + 2 * batteryNub
            if effectiveStyle(c) == .inline {
                let labelPart = c.showsLabel ? (labels.map { textWidth($0, inlineLabelFont) }.max() ?? 0) + inlineSpacing : 0
                return ceil(padding + labelPart + battery + padding)
            }
            return ceil(padding + max(stackedLabel, battery) + padding)
        }
        switch effectiveStyle(c) {
        case .stacked:
            content = max(stackedLabel, textWidth(widestValue, stackedValueFont))
        case .inline:
            let labelPart = c.showsLabel ? (labels.map { textWidth($0, inlineLabelFont) }.max() ?? 0) + inlineSpacing : 0
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
    /// 不在窗口里离屏绘制时（设置页的快照，D92）用的像素密度；在窗口里时取窗口的。
    var drawingScale: CGFloat?
    /// 离屏绘制时，AppKit 因 draw 里读到的数值变化而要求重绘就回调（设置页的快照据此重画，D92）。
    var onInvalidate: (() -> Void)?

    override var needsDisplay: Bool {
        didSet { if needsDisplay { onInvalidate?() } }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        onInvalidate?()
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
        case .gpuActive:
            return store.latest[.gpuActive]?.value.map { PercentFormat.string(fromRatio: $0) }
        case .gpuTemperature:
            return store.latest[.gpuTemperature]?.value.map { String(format: "%.0f°", $0) }
        case .socHotspot:
            return store.latest[.thermalSoCHotspot]?.value.map { String(format: "%.0f°", $0) }
        case .fan:
            // 多风扇时显示最快的一个。
            let rpm = store.latest.compactMap { id, sample in id.fanSpeedIndex != nil ? sample.value : nil }.max()
            return rpm.map { String(format: "%.0f", $0) }
        case .memoryUsage:
            if configuration.memoryShowsBytes { return store.latest[.memoryUsed]?.value.map(Self.gigabytesText) }
            return store.latest[.memoryUsage]?.value.map { PercentFormat.string(fromRatio: $0) }
        case .memoryPressure:
            return store.latest[.memoryPressure]?.value.map { PercentFormat.string(fromRatio: $0) }
        case .swapUsed:
            return store.latest[.memorySwapUsed]?.value.map(Self.gigabytesText)
        case .diskTemperature:
            if configuration.storageHottest {
                let temps = store.latest.compactMap { id, sample in id.storageDiskMetric?.metric == .temp ? sample.value : nil }
                return temps.max().map { String(format: "%.0f°", $0) }
            }
            guard let key = configuration.storageKey else { return nil }
            return store.latest[.storageDisk(key, .temp)]?.value.map { String(format: "%.0f°", $0) }
        case .diskThroughput, .netThroughput:
            return nil  // 两行，另画
        case .netLatency:
            return configuration.latencyMetric.flatMap { store.latest[$0]?.value }.map(Self.millisecondsShort)
        case .diskFree:
            guard let key = configuration.storageKey else { return nil }
            return store.latest[.storageGroup(key, .available)]?.value.map(Self.decimalShort)
        case .deviceBattery:
            return Self.deviceValue(PowerDevicesModel.shared.device(for: configuration.deviceTarget))
        }
    }

    /// 电源设备 widget 的数值：电量；UPS 由电池供电时改为剩余时间（D84 PD5）。
    static func deviceValue(_ device: PowerDevice?) -> String? {
        guard let device else { return nil }
        if device.kind == .ups, device.isOnBattery, let seconds = device.timeToEmpty { return DevicesText.durationShort(seconds) }
        return device.level.map { PercentFormat.string(fromRatio: $0) }
    }

    /// 读写 widget 两行字母与数值的间距。
    private static let throughputGap: CGFloat = 3

    /// 两行 widget：读写为上 R、下 W；网速为上 ↑（出）、下 ↓（入）。数值右对齐（同 Stats 的 twoRows），没有数据的一行画「—」。
    private func drawThroughput(color: NSColor) -> String {
        let read: Double?
        let write: Double?
        let format: (Double) -> String
        if configuration.widget == .netThroughput {
            read = configuration.networkOut.flatMap { store.latest[$0]?.value }
            write = configuration.networkIn.flatMap { store.latest[$0]?.value }
            format = configuration.networkBits ? Self.bitsShort : Self.decimalShort
        } else {
            let key = configuration.storageKey
            read = key.flatMap { store.latest[.storageDisk($0, .read)]?.value }
            write = key.flatMap { store.latest[.storageDisk($0, .write)]?.value }
            format = Self.decimalShort
        }
        let (topSymbol, bottomSymbol) = Self.rowSymbols(configuration.widget)
        let font = Self.stackedValueFont
        let cap = font.capHeight
        let gap: CGFloat = 2.5
        let bottomBaseline = floor((bounds.height - cap * 2 - gap) / 2)
        let rows: [(String, Double?, CGFloat)] = [
            (topSymbol, read, bottomBaseline + cap + gap), (bottomSymbol, write, bottomBaseline),
        ]
        for (symbol, value, baseline) in rows {
            if configuration.showsLabel {
                let label = NSAttributedString(
                    string: symbol, attributes: [.font: Self.stackedLabelFont, .foregroundColor: NSColor.labelColor])
                label.draw(at: NSPoint(x: Self.padding, y: baseline + Self.stackedLabelFont.descender))
            }
            let text = value.map(format) ?? PercentFormat.placeholder
            let attributed = NSAttributedString(
                string: text, attributes: [.font: font, .foregroundColor: value != nil ? color : NSColor.secondaryLabelColor])
            attributed.draw(
                at: NSPoint(x: pixelAligned(bounds.width - Self.padding - attributed.size().width), y: baseline + font.descender))
        }
        return "\(topSymbol) \(read.map(format) ?? "—") \(bottomSymbol) \(write.map(format) ?? "—")"
    }

    override func draw(_ dirtyRect: NSRect) {
        let widget = configuration.widget
        let label = Self.label(widget)
        let color = configuration.color.nsColor
        if Self.isTwoRow(widget) {
            setAccessibilityLabel(drawThroughput(color: color))
            return
        }
        if widget == .deviceBattery {
            setAccessibilityLabel(drawDeviceBattery(color: color))
            return
        }
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

    /// 电源设备 widget（D88，修订 D84 PD5）：iPhone 式电池，电量数字（不带 %）镂空在电池里；UPS 由电池供电时为剩余时间。
    /// 状态照 MacBook 菜单栏电池：接着电源时闪电与数字一起镂空在电池里；正在充电时填充为绿色；
    /// 不在充电且电量不高于低电量阈值（设备自报，没有时按 20%）时为红色；其余用 widget 颜色。
    private func drawDeviceBattery(color: NSColor) -> String {
        let model = PowerDevicesModel.shared
        let device = model.device(for: configuration.deviceTarget)  // 自动跟踪：快照变化时重绘
        let label = Self.deviceLabel(device?.kind)
        let text = Self.deviceValue(device)
        let valueText = text ?? PercentFormat.placeholder
        let charging = device?.isCharging == true
        let onPower = charging || device?.powerSourceState == .external
        var fill = color
        if charging {
            fill = .systemGreen
        } else if let level = device?.level, level <= (device?.lowWarnLevel ?? Self.defaultLowLevel) {
            fill = .systemRed
        }

        let body: NSRect
        if Self.effectiveStyle(configuration) == .inline {
            let x = bounds.width - Self.padding - Self.batteryNub - Self.batteryWidth
            body = NSRect(x: pixelAligned(x), y: floor((bounds.height - Self.batteryHeight) / 2), width: Self.batteryWidth, height: Self.batteryHeight)
            // 小标签对齐到电池本体的中线（原先沿用数字的基线，比电池低）。
            if configuration.showsLabel { drawInlineLabel(label, centeredOn: body.midY) }
        } else {
            let row = drawStackedLabel(label)
            // 电池本体与小标签同一条中线；电池比数字行高，底边放在数字行下方 2 pt，向上不压到小标签。
            body = NSRect(
                x: pixelAligned((bounds.width - Self.batteryWidth) / 2), y: max(row.minY - 2, 1), width: Self.batteryWidth,
                height: Self.batteryHeight)
        }
        drawBattery(body, level: device?.level, fill: fill, text: valueText.replacingOccurrences(of: "%", with: ""), bolt: onPower)
        let state = charging ? String(localized: "正在充电") : (onPower ? String(localized: "外接电源") : "")
        return [label, valueText, state].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// 底为半透明模板色，按电量填充。数字和闪电落在填充上的部分镂空，落在空白段的部分用实心模板色画，
    /// 两段在深浅色菜单栏上都看得清（只镂空的话，空白段透出壁纸，几乎看不见）。正极头画在右侧。
    private func drawBattery(_ body: NSRect, level: Double?, fill: NSColor, text: String, bolt: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let font = Self.batteryFont
        let number = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let boltWidth: CGFloat = bolt ? 4.5 : 0
        let boltGap: CGFloat = bolt ? 0.5 : 0
        let groupWidth = number.size().width + boltGap + boltWidth
        let startX = body.midX - groupWidth / 2
        let capBottom = body.midY - font.capHeight / 2
        let boltRect = NSRect(x: startX + number.size().width + boltGap, y: capBottom - 0.5, width: boltWidth, height: font.capHeight + 1)
        let drawGlyphs = { (color: NSColor) in
            number.draw(at: NSPoint(x: startX, y: capBottom + font.descender))
            if bolt {
                color.setFill()
                Self.boltPath(in: boltRect).fill()
            }
        }
        let fillWidth = level.map { body.width * CGFloat(min(max($0, 0), 1)) } ?? 0
        let filled = NSRect(x: body.minX, y: body.minY, width: fillWidth, height: body.height)
        let empty = NSRect(x: body.minX + fillWidth, y: body.minY, width: body.width - fillWidth, height: body.height)
        let shape = NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3)

        context.beginTransparencyLayer(auxiliaryInfo: nil)
        Self.batteryTrack.setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        fill.setFill()
        filled.fill()
        filled.clip()
        context.setBlendMode(.destinationOut)
        drawGlyphs(.black)
        NSGraphicsContext.restoreGraphicsState()
        context.endTransparencyLayer()

        NSGraphicsContext.saveGraphicsState()
        empty.clip()
        drawGlyphs(.labelColor)
        NSGraphicsContext.restoreGraphicsState()

        Self.batteryTrack.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: body.maxX + 0.75, y: body.midY - 2, width: Self.batteryNub - 0.75, height: 4), xRadius: 0.75,
            yRadius: 0.75
        ).fill()
    }

    /// 闪电的轮廓，撑满给定的矩形。
    private static func boltPath(in rect: NSRect) -> NSBezierPath {
        let (x, y, w, h) = (rect.minX, rect.minY, rect.width, rect.height)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x + w * 0.62, y: y + h))
        path.line(to: NSPoint(x: x, y: y + h * 0.42))
        path.line(to: NSPoint(x: x + w * 0.46, y: y + h * 0.42))
        path.line(to: NSPoint(x: x + w * 0.38, y: y))
        path.line(to: NSPoint(x: x + w, y: y + h * 0.58))
        path.line(to: NSPoint(x: x + w * 0.54, y: y + h * 0.58))
        path.close()
        return path
    }

    /// 文字起点的横坐标对齐到设备像素。居中算出的起点带小数（如 5.54 pt），在 1x 屏上字形会被抗锯齿摊到相邻像素，
    /// 低对比的颜色（systemRed）看起来尤其发虚（2026-10-15 验收发现）。纵向的基线已经取整，不用再处理。
    private func pixelAligned(_ x: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? drawingScale ?? 2
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
        // 数字的大写高度在 item 里垂直居中；小标签按自己的大写高度对齐到数字的中线。
        // 两种字号若共用一条基线，小标签的中线会比数字低约 1 pt（2026-10-20 用户反馈左右高度不一致）。
        let baseline = floor((bounds.height - Self.inlineValueFont.capHeight) / 2)
        if configuration.showsLabel {
            drawInlineLabel(labelText, centeredOn: baseline + Self.inlineValueFont.capHeight / 2)
        }
        let value = NSAttributedString(
            string: valueText, attributes: [.font: Self.inlineValueFont, .foregroundColor: valueColor])
        let valueWidth = value.size().width
        value.draw(at: NSPoint(x: pixelAligned(bounds.width - Self.padding - valueWidth), y: baseline + Self.inlineValueFont.descender))
    }

    /// 左右排版的小标签：大写高度的中线放在 `midY`，基线取整到设备像素。
    private func drawInlineLabel(_ text: String, centeredOn midY: CGFloat) {
        let font = Self.inlineLabelFont
        let scale = window?.backingScaleFactor ?? drawingScale ?? 2
        let baseline = ((midY - font.capHeight / 2) * scale).rounded() / scale
        let label = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        label.draw(at: NSPoint(x: Self.padding, y: baseline + font.descender))
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
