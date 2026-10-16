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
// - menubar.power.<widget>.visible / .color   功耗与散热 widget（systemPower / socHotspot / socPower / gpuPower / fan，D44：只有 systemPower 默认开）
// - power.interval / power.panel.interval / power.panel.chartSpan / power.panel.overlaySoC   功耗与散热的常驻间隔覆盖与面板设置
// - history.power.enabled / history.energy.enabled   是否记录功耗与散热历史、是否记录能耗（D46）
// - menubar.memory.<widget>.visible / .color   内存 widget（memoryUsage / memoryPressure / swapUsed，D49、D51：只有 memoryUsage 默认开）
// - menubar.memory.usage.presentation   内存占用 widget 显示百分比（percent）或已用 GB（bytes）
// - memory.interval / memory.panel.topNInterval / .topNRows / .grouping / .chartSpan / .overlayPressure   内存的常驻间隔覆盖与面板设置
// - history.memory.enabled   是否记录内存历史（D49）
// - menubar.storage.<widget>.visible / .color   存储 widget（diskTemperature / diskThroughput / diskFree，D54：只有 diskTemperature 默认开）
// - storage.widget.temperature.target / .throughput.target / .free.target   widget 绑定的盘或组：primary、hottest、disk:<键>、group:<键>
// - storage.interval / storage.panel.smartInterval / .topNInterval / .topNRows / .grouping / .chartSpan / .collapsedRAIDs
//   存储的常驻间隔覆盖与面板设置（D55：面板 SMART 默认 2 s）
// - history.storage.enabled   是否记录存储历史
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
        static func widgetColor(_ widget: MenuWidget) -> String { "menubar.\(widget.module.rawValue).\(widget.rawValue).color" }
        /// 功耗与散热 widget 的显示开关（CPU 四项沿用上面的旧键）。
        static func widgetVisible(_ widget: MenuWidget) -> String { "menubar.\(widget.module.rawValue).\(widget.rawValue).visible" }
        static let powerInterval = "power.interval"
        static let powerPanelInterval = "power.panel.interval"
        static let powerChartSpan = "power.panel.chartSpan"
        static let powerChartOverlaySoC = "power.panel.overlaySoC"
        static let historyPower = "history.power.enabled"
        static let historyEnergy = "history.energy.enabled"
        static let memoryInterval = "memory.interval"
        static let memoryUsagePresentation = "menubar.memory.usage.presentation"
        static let memoryTopNInterval = "memory.panel.topNInterval"
        static let memoryTopNRows = "memory.panel.topNRows"
        static let memoryGrouping = "memory.panel.grouping"
        static let memoryChartSpan = "memory.panel.chartSpan"
        static let memoryChartOverlayPressure = "memory.panel.overlayPressure"
        static let historyMemory = "history.memory.enabled"
        static let storageInterval = "storage.interval"
        static let diskTemperatureTarget = "storage.widget.temperature.target"
        static let diskThroughputTarget = "storage.widget.throughput.target"
        static let diskFreeTarget = "storage.widget.free.target"
        static let storageSMARTInterval = "storage.panel.smartInterval"
        static let storageTopNInterval = "storage.panel.topNInterval"
        static let storageTopNRows = "storage.panel.topNRows"
        static let storageGrouping = "storage.panel.grouping"
        static let storageChartSpan = "storage.panel.chartSpan"
        static let storageCollapsedRAIDs = "storage.panel.collapsedRAIDs"
        static let historyStorage = "history.storage.enabled"
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

    /// CPU 以外各模块 widget 的显示开关（D44：功耗只开整机功率；D51：内存只开占用）。
    private(set) var powerWidgetsVisible: [MenuWidget: Bool]

    /// 当前显示的 widget（全部模块，D38）。
    var visibleWidgets: [MenuWidget] {
        MenuWidget.allCases.filter { isVisible($0) }
    }

    func isVisible(_ widget: MenuWidget) -> Bool {
        switch widget {
        case .usage: cpuItemVisible
        case .frequency: cpuFrequencyItemVisible
        case .temperature: cpuTemperatureItemVisible
        case .power: cpuPowerItemVisible
        default: powerWidgetsVisible[widget] ?? widget.visibleByDefault
        }
    }

    func setVisible(_ widget: MenuWidget, _ visible: Bool) {
        switch widget {
        case .usage: cpuItemVisible = visible
        case .frequency: cpuFrequencyItemVisible = visible
        case .temperature: cpuTemperatureItemVisible = visible
        case .power: cpuPowerItemVisible = visible
        default:
            guard powerWidgetsVisible[widget] != visible else { return }
            powerWidgetsVisible[widget] = visible
            persist(visible, Key.widgetVisible(widget))
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
    func renderStyle(for widget: MenuWidget) -> MenuBarCPUStyle {
        if widget == .usage, let graphic = cpuUsagePresentation.graphicStyle { return graphic }
        return menuBarLayout == .inline ? .inline : .stacked
    }

    /// 各 widget 的颜色（D43：默认跟随系统）。
    private(set) var widgetColors: [MenuWidget: WidgetColor]

    func color(for widget: MenuWidget) -> WidgetColor {
        widgetColors[widget] ?? .system
    }

    func setColor(_ color: WidgetColor, for widget: MenuWidget) {
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

    // MARK: 功耗与散热（D44–D46）

    /// 功耗与散热模块的常驻间隔覆盖；nil 表示跟随全局默认（D25）。
    var powerIntervalOverride: SamplingInterval? {
        didSet { persist(powerIntervalOverride?.rawValue ?? 0, Key.powerInterval) }
    }

    /// 功耗与散热模块实际使用的常驻间隔。
    var powerInterval: SamplingInterval { powerIntervalOverride ?? globalInterval }

    /// 面板「功耗与散热」tab 里 SoC/GPU/DRAM 功率、温度与风扇的间隔（默认 2 s）；整机功率固定每秒。
    var powerPanelInterval: Int {
        didSet { persist(powerPanelInterval, Key.powerPanelInterval) }
    }

    /// 功耗图的默认跨度。
    var powerChartSpan: ChartSpan {
        didSet { persist(powerChartSpan.rawValue, Key.powerChartSpan) }
    }

    /// 功耗图是否叠加 SoC 功率。
    var powerChartOverlaySoC: Bool {
        didSet { persist(powerChartOverlaySoC, Key.powerChartOverlaySoC) }
    }

    /// 是否记录功耗与散热历史（默认开）。
    var historyPowerEnabled: Bool {
        didSet { persist(historyPowerEnabled, Key.historyPower) }
    }

    /// 是否记录能耗（D46：后台每秒读一个 SMC 键，默认开）。
    var historyEnergyEnabled: Bool {
        didSet { persist(historyEnergyEnabled, Key.historyEnergy) }
    }

    // MARK: 内存（D49）

    /// 内存模块的常驻间隔覆盖；nil 表示跟随全局默认（D25）。
    var memoryIntervalOverride: SamplingInterval? {
        didSet { persist(memoryIntervalOverride?.rawValue ?? 0, Key.memoryInterval) }
    }

    /// 内存模块实际使用的常驻间隔。
    var memoryInterval: SamplingInterval { memoryIntervalOverride ?? globalInterval }

    /// 内存占用 widget 显示百分比还是已用 GB。
    var memoryUsagePresentation: MemoryUsagePresentation {
        didSet { persist(memoryUsagePresentation.rawValue, Key.memoryUsagePresentation) }
    }

    /// 面板内存 Top N 的间隔（默认 5 s：footprint 变化慢，coalition 全量扫描一次约 10–14 ms）。
    var memoryTopNInterval: Int {
        didSet { persist(memoryTopNInterval, Key.memoryTopNInterval) }
    }

    /// 内存 Top N 行数（0/3/5/8/10，默认 5）。
    var memoryTopNRows: Int {
        didSet { persist(memoryTopNRows, Key.memoryTopNRows) }
    }

    /// 内存 Top N 分组方式（默认按应用，D31）。
    var memoryGrouping: TopNGrouping {
        didSet { persist(memoryGrouping.rawValue, Key.memoryGrouping) }
    }

    /// 内存图的默认跨度。
    var memoryChartSpan: ChartSpan {
        didSet { persist(memoryChartSpan.rawValue, Key.memoryChartSpan) }
    }

    /// 内存图是否叠加压力。
    var memoryChartOverlayPressure: Bool {
        didSet { persist(memoryChartOverlayPressure, Key.memoryChartOverlayPressure) }
    }

    /// 是否记录内存历史（默认开）。
    var historyMemoryEnabled: Bool {
        didSet { persist(historyMemoryEnabled, Key.historyMemory) }
    }

    // MARK: 存储（D54、D55）

    /// 存储模块的常驻间隔覆盖；nil 表示跟随全局默认（D25）。
    var storageIntervalOverride: SamplingInterval? {
        didSet { persist(storageIntervalOverride?.rawValue ?? 0, Key.storageInterval) }
    }

    /// 存储模块实际使用的常驻间隔。
    var storageInterval: SamplingInterval { storageIntervalOverride ?? globalInterval }

    /// 盘温 widget 绑定的盘（默认内置盘，可选任意一块盘或所有盘最高温）。
    var diskTemperatureTarget: StorageTarget {
        didSet { persist(diskTemperatureTarget.storageValue, Key.diskTemperatureTarget) }
    }

    /// 读写 widget 绑定的盘（默认内置盘）。
    var diskThroughputTarget: StorageTarget {
        didSet { persist(diskThroughputTarget.storageValue, Key.diskThroughputTarget) }
    }

    /// 可用空间 widget 绑定的容量组（默认启动卷所在的组）。
    var diskFreeTarget: StorageTarget {
        didSet { persist(diskFreeTarget.storageValue, Key.diskFreeTarget) }
    }

    /// 面板存储 tab 的 SMART 间隔（D55：默认 2 s）。
    var storageSMARTInterval: Int {
        didSet { persist(storageSMARTInterval, Key.storageSMARTInterval) }
    }

    /// 面板磁盘 Top N 的间隔（默认 5 s：coalition 全量扫描一次约 10–14 ms；磁盘计数在 2 s 窗口里常常没有变化，存储模块设计 §11）。
    var storageTopNInterval: Int {
        didSet { persist(storageTopNInterval, Key.storageTopNInterval) }
    }

    /// 磁盘 Top N 行数（0/3/5/8/10，默认 5）。
    var storageTopNRows: Int {
        didSet { persist(storageTopNRows, Key.storageTopNRows) }
    }

    /// 磁盘 Top N 分组方式（默认按应用，D31）。
    var storageGrouping: TopNGrouping {
        didSet { persist(storageGrouping.rawValue, Key.storageGrouping) }
    }

    /// 单盘详情页读写图的默认跨度。
    var storageChartSpan: ChartSpan {
        didSet { persist(storageChartSpan.rawValue, Key.storageChartSpan) }
    }

    /// 面板里折叠起来的 RAID 组（D54：默认展开，状态记住）。
    var storageCollapsedRAIDs: Set<String> {
        didSet { persist(Array(storageCollapsedRAIDs).sorted(), Key.storageCollapsedRAIDs) }
    }

    /// 是否记录存储历史（默认开）。
    var historyStorageEnabled: Bool {
        didSet { persist(historyStorageEnabled, Key.historyStorage) }
    }

    /// 某个模块实际使用的常驻间隔。
    func interval(for module: MenuModule) -> SamplingInterval {
        switch module {
        case .cpu: cpuInterval
        case .power: powerInterval
        case .memory: memoryInterval
        case .storage: storageInterval
        }
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
            uniqueKeysWithValues: MenuWidget.allCases.map { widget in
                (widget, defaults?.string(forKey: Key.widgetColor(widget)).flatMap(WidgetColor.init(storageValue:)) ?? .system)
            })
        panelFreqInterval = Self.int(defaults, Key.panelFreqInterval, choices: Self.panelIntervals) ?? 5
        panelSensorInterval = Self.int(defaults, Key.panelSensorInterval, choices: Self.panelIntervals) ?? 2
        panelTopNInterval = Self.int(defaults, Key.panelTopNInterval, choices: Self.panelIntervals) ?? 2
        panelTopNRows = Self.int(defaults, Key.panelTopNRows, choices: Self.topNRowChoices) ?? 5
        panelGrouping = defaults?.string(forKey: Key.panelGrouping).flatMap(TopNGrouping.init(rawValue:)) ?? .byApp
        panelChartSpan = defaults?.string(forKey: Key.panelChartSpan).flatMap(ChartSpan.init(rawValue:)) ?? .twoMinutes
        panelSplitUserSystem = defaults?.object(forKey: Key.panelSplitUserSystem) as? Bool ?? true
        powerWidgetsVisible = Dictionary(
            uniqueKeysWithValues: MenuWidget.allCases.filter { $0.module != .cpu }.map { widget in
                (widget, defaults?.object(forKey: Key.widgetVisible(widget)) as? Bool ?? widget.visibleByDefault)
            })
        powerIntervalOverride = defaults.flatMap { SamplingInterval(rawValue: $0.integer(forKey: Key.powerInterval)) }
        powerPanelInterval = Self.int(defaults, Key.powerPanelInterval, choices: Self.panelIntervals) ?? 2
        powerChartSpan = defaults?.string(forKey: Key.powerChartSpan).flatMap(ChartSpan.init(rawValue:)) ?? .twoMinutes
        powerChartOverlaySoC = defaults?.object(forKey: Key.powerChartOverlaySoC) as? Bool ?? true
        historyPowerEnabled = defaults?.object(forKey: Key.historyPower) as? Bool ?? true
        historyEnergyEnabled = defaults?.object(forKey: Key.historyEnergy) as? Bool ?? true
        memoryIntervalOverride = defaults.flatMap { SamplingInterval(rawValue: $0.integer(forKey: Key.memoryInterval)) }
        memoryUsagePresentation =
            defaults?.string(forKey: Key.memoryUsagePresentation).flatMap(MemoryUsagePresentation.init(rawValue:)) ?? .percent
        memoryTopNInterval = Self.int(defaults, Key.memoryTopNInterval, choices: Self.panelIntervals) ?? 5
        memoryTopNRows = Self.int(defaults, Key.memoryTopNRows, choices: Self.topNRowChoices) ?? 5
        memoryGrouping = defaults?.string(forKey: Key.memoryGrouping).flatMap(TopNGrouping.init(rawValue:)) ?? .byApp
        memoryChartSpan = defaults?.string(forKey: Key.memoryChartSpan).flatMap(ChartSpan.init(rawValue:)) ?? .twoMinutes
        memoryChartOverlayPressure = defaults?.object(forKey: Key.memoryChartOverlayPressure) as? Bool ?? true
        historyMemoryEnabled = defaults?.object(forKey: Key.historyMemory) as? Bool ?? true
        storageIntervalOverride = defaults.flatMap { SamplingInterval(rawValue: $0.integer(forKey: Key.storageInterval)) }
        diskTemperatureTarget =
            defaults?.string(forKey: Key.diskTemperatureTarget).flatMap(StorageTarget.init(storageValue:)) ?? .primary
        diskThroughputTarget =
            defaults?.string(forKey: Key.diskThroughputTarget).flatMap(StorageTarget.init(storageValue:)) ?? .primary
        diskFreeTarget = defaults?.string(forKey: Key.diskFreeTarget).flatMap(StorageTarget.init(storageValue:)) ?? .primary
        storageSMARTInterval = Self.int(defaults, Key.storageSMARTInterval, choices: Self.panelIntervals) ?? 2
        storageTopNInterval = Self.int(defaults, Key.storageTopNInterval, choices: Self.panelIntervals) ?? 5
        storageTopNRows = Self.int(defaults, Key.storageTopNRows, choices: Self.topNRowChoices) ?? 5
        storageGrouping = defaults?.string(forKey: Key.storageGrouping).flatMap(TopNGrouping.init(rawValue:)) ?? .byApp
        storageChartSpan = defaults?.string(forKey: Key.storageChartSpan).flatMap(ChartSpan.init(rawValue:)) ?? .twoMinutes
        storageCollapsedRAIDs = Set(defaults?.stringArray(forKey: Key.storageCollapsedRAIDs) ?? [])
        historyStorageEnabled = defaults?.object(forKey: Key.historyStorage) as? Bool ?? true
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

/// 存储 widget 绑定的对象（存储模块设计 §6.1）。键是本地加盐哈希（D54），不含序列号。
enum StorageTarget: Hashable {
    /// 内置盘（盘温、读写）或启动卷所在的容量组（可用空间）。
    case primary
    /// 所有盘的最高温（只给盘温）。
    case hottest
    /// 一块物理盘。
    case disk(DiskKey)
    /// 一个容量组（只给可用空间）。
    case group(DiskKey)

    var storageValue: String {
        switch self {
        case .primary: "primary"
        case .hottest: "hottest"
        case .disk(let key): "disk:\(key.rawValue)"
        case .group(let key): "group:\(key.rawValue)"
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "primary": self = .primary
        case "hottest": self = .hottest
        default:
            let parts = storageValue.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let key = DiskKey(validating: parts[1]) else { return nil }
            switch parts[0] {
            case "disk": self = .disk(key)
            case "group": self = .group(key)
            default: return nil
            }
        }
    }
}

/// 内存占用 widget 的数值形式（D49 M2）。
enum MemoryUsagePresentation: String, CaseIterable, Identifiable {
    /// 占用率「64%」。
    case percent
    /// 已用「40.6G」。
    case bytes

    var id: String { rawValue }
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

/// 菜单栏 widget：一个 widget 只显示一项指标（D38），每个 widget 属于一个模块。
/// CPU 四项的 rawValue 沿用 CPU 模块的命名，设置键与 autosaveName 都不变。
enum MenuWidget: String, CaseIterable, Identifiable {
    case usage
    case frequency
    case temperature
    case power
    // 功耗与散热（D44）
    case systemPower
    case socHotspot
    case socPower
    case gpuPower
    case fan
    // 内存（D49）
    case memoryUsage
    case memoryPressure
    case swapUsed
    // 存储（D54）
    case diskTemperature
    case diskThroughput
    case diskFree

    var id: String { rawValue }

    var module: MenuModule {
        switch self {
        case .usage, .frequency, .temperature, .power: .cpu
        case .systemPower, .socHotspot, .socPower, .gpuPower, .fan: .power
        case .memoryUsage, .memoryPressure, .swapUsed: .memory
        case .diskTemperature, .diskThroughput, .diskFree: .storage
        }
    }

    static func widgets(of module: MenuModule) -> [MenuWidget] { allCases.filter { $0.module == module } }

    /// 出厂默认是否显示（D51：CPU 占用、整机功率、内存占用；D54 加盘温）。
    var visibleByDefault: Bool { self == .usage || self == .systemPower || self == .memoryUsage || self == .diskTemperature }
}

/// widget 所属的模块：决定常驻采集间隔、点击后预选的面板 tab、设置页的位置。
enum MenuModule: String, CaseIterable, Identifiable {
    case cpu
    case power
    case memory
    case storage

    var id: String { rawValue }
}
