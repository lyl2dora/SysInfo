// 用户设置（M0 设计 §6）：@Observable，底层是 UserDefaults.standard。
// Debug（zone.lyl.sysinfo.dev）与 Release（zone.lyl.sysinfo）的 Bundle ID 不同，存储天然隔离（D16）。
//
// 键名（也可以用 `defaults write zone.lyl.sysinfo.dev <键> …` 修改，重启 app 后生效）：
// - general.interval      全局默认采集间隔，秒：1 / 2 / 5
// - general.autoThrottle  是否自动降频（K20、D25：默认开）
// - cpu.interval          CPU 模块的间隔覆盖：0 表示跟随全局，否则 1 / 2 / 5
// - menubar.cpu.visible   CPU 占用 widget 是否显示
// - menubar.cpu.freq.visible / .temp.visible / .power.visible   频率、温度、功耗 widget 是否显示（D38，默认关）
// - menubar.layout / menubar.label   所有 widget 共用的排版（stacked / inline）与小标签开关（D41）
// - menubar.cpu.usage.presentation   占用 widget 的呈现形式（number / sparkline / barsTotal / barsLevels / barsCores，D41）
// - menubar.cpu.<widget>.color   各 widget 的颜色：system（跟随系统）或 #RRGGBB（D43）；<widget> 为 usage / frequency / temperature / power
// - 旧键 menubar.cpu.coloring / .warningPercent / .criticalPercent（D32 的着色，已由 D43 取消）不再读取
// - 旧键 menubar.cpu.style / menubar.cpu.label（D41 之前）只在新键缺失时读取，用来换算出上面三项
// - cpu.panel.freqInterval / .sensorInterval / .topNInterval   面板内各项的采样间隔，秒：1 / 2 / 5
// - cpu.panel.topNRows / .grouping / .chartSpan / .splitUserSystem   面板显示
// - history.cpu.enabled / history.apps.enabled / history.cpu.highPrecision   是否记录历史与后台高精度（D30、D19）

import Foundation
import Observation
import SysModel

/// 采集间隔，取基础 tick（1 s）的整数倍（D19、D25）。
enum SamplingInterval: Int, CaseIterable, Identifiable, Sendable {
    case oneSecond = 1
    case twoSeconds = 2
    case fiveSeconds = 5

    var id: Int { rawValue }
}

@Observable
final class AppSettings {
    enum Key {
        static let globalInterval = "general.interval"
        static let autoThrottle = "general.autoThrottle"
        static let cpuInterval = "cpu.interval"
        static let cpuItemVisible = "menubar.cpu.visible"
        static let cpuFrequencyItemVisible = "menubar.cpu.freq.visible"
        static let cpuTemperatureItemVisible = "menubar.cpu.temp.visible"
        static let cpuPowerItemVisible = "menubar.cpu.power.visible"
        static let historyCPU = "history.cpu.enabled"
        static let historyApps = "history.apps.enabled"
        static let historyHighPrecision = "history.cpu.highPrecision"
        static let menuBarLayout = "menubar.layout"
        static let menuBarLabel = "menubar.label"
        static let cpuUsagePresentation = "menubar.cpu.usage.presentation"
        /// D41 之前的键，只读不写。
        static let legacyCPUStyle = "menubar.cpu.style"
        static let legacyCPULabel = "menubar.cpu.label"
        static func widgetColor(_ widget: CPUMenuWidget) -> String { "menubar.cpu.\(widget.rawValue).color" }
        static let panelFreqInterval = "cpu.panel.freqInterval"
        static let panelSensorInterval = "cpu.panel.sensorInterval"
        static let panelTopNInterval = "cpu.panel.topNInterval"
        static let panelTopNRows = "cpu.panel.topNRows"
        static let panelGrouping = "cpu.panel.grouping"
        static let panelChartSpan = "cpu.panel.chartSpan"
        static let panelSplitUserSystem = "cpu.panel.splitUserSystem"
    }

    /// nil：不读写持久化存储，只用出厂默认值（`--factory-defaults`）。
    @ObservationIgnored private let defaults: UserDefaults?
    /// 任何一项设置被修改后调用（在 MainActor 上同步调用）。
    @ObservationIgnored var onChange: (() -> Void)?

    /// 全局默认采集间隔（D25）。
    var globalInterval: SamplingInterval {
        didSet { persist(globalInterval.rawValue, Key.globalInterval) }
    }

    /// CPU 模块的间隔覆盖；nil 表示跟随全局默认（D25）。
    var cpuIntervalOverride: SamplingInterval? {
        didSet { persist(cpuIntervalOverride?.rawValue ?? 0, Key.cpuInterval) }
    }

    /// CPU item 是否显示（K32：可见性以 app 设置为准）。
    var cpuItemVisible: Bool {
        didSet { persist(cpuItemVisible, Key.cpuItemVisible) }
    }

    /// 频率、温度、功耗 widget 是否显示（D38：出厂默认关）。
    var cpuFrequencyItemVisible: Bool {
        didSet { persist(cpuFrequencyItemVisible, Key.cpuFrequencyItemVisible) }
    }

    var cpuTemperatureItemVisible: Bool {
        didSet { persist(cpuTemperatureItemVisible, Key.cpuTemperatureItemVisible) }
    }

    var cpuPowerItemVisible: Bool {
        didSet { persist(cpuPowerItemVisible, Key.cpuPowerItemVisible) }
    }

    /// 当前显示的 CPU widget（D38）。
    var visibleCPUWidgets: [CPUMenuWidget] {
        CPUMenuWidget.allCases.filter { isVisible($0) }
    }

    func isVisible(_ widget: CPUMenuWidget) -> Bool {
        switch widget {
        case .usage: cpuItemVisible
        case .frequency: cpuFrequencyItemVisible
        case .temperature: cpuTemperatureItemVisible
        case .power: cpuPowerItemVisible
        }
    }

    func setVisible(_ widget: CPUMenuWidget, _ visible: Bool) {
        switch widget {
        case .usage: cpuItemVisible = visible
        case .frequency: cpuFrequencyItemVisible = visible
        case .temperature: cpuTemperatureItemVisible = visible
        case .power: cpuPowerItemVisible = visible
        }
    }

    /// 是否自动降频（K20、D25：默认开，可以关闭）。
    var autoThrottle: Bool {
        didSet { persist(autoThrottle, Key.autoThrottle) }
    }

    /// 是否记录 CPU 历史（D30：默认开）。
    var historyCPUEnabled: Bool {
        didSet { persist(historyCPUEnabled, Key.historyCPU) }
    }

    /// 是否记录每应用 CPU（D30：默认开）。
    var historyAppsEnabled: Bool {
        didSet { persist(historyAppsEnabled, Key.historyApps) }
    }

    /// 后台高精度历史：频率、温度与功耗每 5 秒（高开销项，默认关，D19）。
    var historyHighPrecision: Bool {
        didSet { persist(historyHighPrecision, Key.historyHighPrecision) }
    }

    /// 所有 widget 共用的排版（D32 默认上下；D41 改为全局）。
    var menuBarLayout: MenuBarLayout {
        didSet { persist(menuBarLayout.rawValue, Key.menuBarLayout) }
    }

    /// 所有 widget 是否显示小标签（D41：全局）。
    var menuBarShowsLabel: Bool {
        didSet { persist(menuBarShowsLabel, Key.menuBarLabel) }
    }

    /// 占用 widget 的呈现形式（D41：按 widget 设置）。
    var cpuUsagePresentation: CPUUsagePresentation {
        didSet { persist(cpuUsagePresentation.rawValue, Key.cpuUsagePresentation) }
    }

    /// widget 实际的绘制样式：占用 widget 选了图形时用图形，其余按全局排版。
    func renderStyle(for widget: CPUMenuWidget) -> MenuBarCPUStyle {
        if widget == .usage, let graphic = cpuUsagePresentation.graphicStyle { return graphic }
        return menuBarLayout == .inline ? .inline : .stacked
    }

    /// 各 widget 的颜色（D43：默认跟随系统）。
    private(set) var widgetColors: [CPUMenuWidget: WidgetColor]

    func color(for widget: CPUMenuWidget) -> WidgetColor {
        widgetColors[widget] ?? .system
    }

    func setColor(_ color: WidgetColor, for widget: CPUMenuWidget) {
        // 按持久化的精度（8 位）取整，内存里的值与重启后读回的一致。
        let stored = WidgetColor(storageValue: color.storageValue) ?? .system
        guard widgetColors[widget] != stored else { return }
        widgetColors[widget] = stored
        persist(stored.storageValue, Key.widgetColor(widget))
    }

    /// 面板 CPU tab 的频率采样间隔，秒（D29：默认 5 s，可选 1/2/5）。
    var panelFreqInterval: Int {
        didSet { persist(panelFreqInterval, Key.panelFreqInterval) }
    }

    /// 面板的温度与功耗间隔（默认 2 s）。
    var panelSensorInterval: Int {
        didSet { persist(panelSensorInterval, Key.panelSensorInterval) }
    }

    /// 面板 Top N 的间隔（默认 2 s）。
    var panelTopNInterval: Int {
        didSet { persist(panelTopNInterval, Key.panelTopNInterval) }
    }

    /// Top N 行数（0/3/5/8/10，默认 5）。
    var panelTopNRows: Int {
        didSet { persist(panelTopNRows, Key.panelTopNRows) }
    }

    /// Top N 分组方式（D31：默认按应用）。
    var panelGrouping: TopNGrouping {
        didSet { persist(panelGrouping.rawValue, Key.panelGrouping) }
    }

    /// 面板图表的默认跨度（默认 2 分钟）。
    var panelChartSpan: ChartSpan {
        didSet { persist(panelChartSpan.rawValue, Key.panelChartSpan) }
    }

    /// 概览里是否拆分用户/系统。
    var panelSplitUserSystem: Bool {
        didSet { persist(panelSplitUserSystem, Key.panelSplitUserSystem) }
    }

    /// 面板里可选的间隔，秒。
    static let panelIntervals = [1, 2, 5]
    static let topNRowChoices = [0, 3, 5, 8, 10]

    /// CPU 模块实际使用的间隔。
    var cpuInterval: SamplingInterval { cpuIntervalOverride ?? globalInterval }

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        globalInterval = defaults.flatMap { SamplingInterval(rawValue: $0.integer(forKey: Key.globalInterval)) } ?? .oneSecond
        cpuIntervalOverride = defaults.flatMap { SamplingInterval(rawValue: $0.integer(forKey: Key.cpuInterval)) }
        cpuItemVisible = defaults?.object(forKey: Key.cpuItemVisible) as? Bool ?? true
        cpuFrequencyItemVisible = defaults?.object(forKey: Key.cpuFrequencyItemVisible) as? Bool ?? false
        cpuTemperatureItemVisible = defaults?.object(forKey: Key.cpuTemperatureItemVisible) as? Bool ?? false
        cpuPowerItemVisible = defaults?.object(forKey: Key.cpuPowerItemVisible) as? Bool ?? false
        autoThrottle = defaults?.object(forKey: Key.autoThrottle) as? Bool ?? true
        historyCPUEnabled = defaults?.object(forKey: Key.historyCPU) as? Bool ?? true
        historyAppsEnabled = defaults?.object(forKey: Key.historyApps) as? Bool ?? true
        historyHighPrecision = defaults?.object(forKey: Key.historyHighPrecision) as? Bool ?? false
        // D41 之前只有一个样式键：上下 / 左右换算成排版，图形换算成占用的呈现形式。
        let legacyStyle = defaults?.string(forKey: Key.legacyCPUStyle).flatMap(MenuBarCPUStyle.init(rawValue:))
        menuBarLayout =
            defaults?.string(forKey: Key.menuBarLayout).flatMap(MenuBarLayout.init(rawValue:))
            ?? (legacyStyle == .inline ? .inline : .stacked)
        menuBarShowsLabel =
            defaults?.object(forKey: Key.menuBarLabel) as? Bool ?? defaults?.object(forKey: Key.legacyCPULabel) as? Bool ?? true
        cpuUsagePresentation =
            defaults?.string(forKey: Key.cpuUsagePresentation).flatMap(CPUUsagePresentation.init(rawValue:))
            ?? legacyStyle.flatMap(CPUUsagePresentation.init(graphicStyle:)) ?? .number
        widgetColors = Dictionary(
            uniqueKeysWithValues: CPUMenuWidget.allCases.map { widget in
                (widget, defaults?.string(forKey: Key.widgetColor(widget)).flatMap(WidgetColor.init(storageValue:)) ?? .system)
            })
        panelFreqInterval = Self.int(defaults, Key.panelFreqInterval, choices: Self.panelIntervals) ?? 5
        panelSensorInterval = Self.int(defaults, Key.panelSensorInterval, choices: Self.panelIntervals) ?? 2
        panelTopNInterval = Self.int(defaults, Key.panelTopNInterval, choices: Self.panelIntervals) ?? 2
        panelTopNRows = Self.int(defaults, Key.panelTopNRows, choices: Self.topNRowChoices) ?? 5
        panelGrouping = defaults?.string(forKey: Key.panelGrouping).flatMap(TopNGrouping.init(rawValue:)) ?? .byApp
        panelChartSpan = defaults?.string(forKey: Key.panelChartSpan).flatMap(ChartSpan.init(rawValue:)) ?? .twoMinutes
        panelSplitUserSystem = defaults?.object(forKey: Key.panelSplitUserSystem) as? Bool ?? true
    }

    private static func int(_ defaults: UserDefaults?, _ key: String, in range: ClosedRange<Int>) -> Int? {
        guard let value = defaults?.object(forKey: key) as? Int, range.contains(value) else { return nil }
        return value
    }

    private static func int(_ defaults: UserDefaults?, _ key: String, choices: [Int]) -> Int? {
        guard let value = defaults?.object(forKey: key) as? Int, choices.contains(value) else { return nil }
        return value
    }

    private func persist(_ value: Any, _ key: String) {
        defaults?.set(value, forKey: key)
        onChange?()
    }
}

/// 所有 widget 共用的排版（D41）。
enum MenuBarLayout: String, CaseIterable, Identifiable {
    /// 上行小标签，下行数值（D32 默认）。
    case stacked
    /// 左右布局「CPU 23%」。
    case inline

    var id: String { rawValue }
}

/// 占用 widget 的呈现形式（D41）：数字跟随全局排版，图形固定按上下布局画。
enum CPUUsagePresentation: String, CaseIterable, Identifiable {
    case number
    case sparkline
    case barsTotal
    case barsLevels
    case barsCores

    var id: String { rawValue }

    var graphicStyle: MenuBarCPUStyle? {
        switch self {
        case .number: nil
        case .sparkline: .sparkline
        case .barsTotal: .barsTotal
        case .barsLevels: .barsLevels
        case .barsCores: .barsCores
        }
    }

    init?(graphicStyle: MenuBarCPUStyle) {
        guard let match = Self.allCases.first(where: { $0.graphicStyle == graphicStyle }) else { return nil }
        self = match
    }
}

/// widget 的绘制样式（D32、边界稿 §5.1），由排版与呈现形式合成（`AppSettings.renderStyle(for:)`）。
enum MenuBarCPUStyle: String, CaseIterable, Identifiable {
    /// 上行小标签「CPU」，下行数值（默认）。
    case stacked
    /// 左右布局「CPU 23%」（M0 的样式）。
    case inline
    /// 最近 60 秒的迷你折线。
    case sparkline
    /// 一根总占用柱。
    case barsTotal
    /// 每档一根柱。
    case barsLevels
    /// 每核一根柱。
    case barsCores

    var id: String { rawValue }
}

/// 面板图表的跨度（K39：2 分、15 分、1 时、24 时、7 天）。
enum ChartSpan: String, CaseIterable, Identifiable {
    case twoMinutes
    case fifteenMinutes
    case oneHour
    case oneDay
    case sevenDays

    var id: String { rawValue }

    var seconds: Double {
        switch self {
        case .twoMinutes: 120
        case .fifteenMinutes: 900
        case .oneHour: 3600
        case .oneDay: 86_400
        case .sevenDays: 7 * 86_400
        }
    }

    /// 前两档读内存环形缓冲，其余读历史库（CPU 模块设计 §7.2）。
    var usesHistory: Bool { seconds > 900 }
}

/// CPU 模块的菜单栏 widget：一个 widget 只显示一项指标（D38）。
enum CPUMenuWidget: String, CaseIterable, Identifiable {
    case usage
    case frequency
    case temperature
    case power

    var id: String { rawValue }
}
