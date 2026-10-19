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
// - menubar.gpu.<widget>.visible / .color   GPU 与加速器 widget（gpuActive / gpuTemperature，D57：默认关）；
//   GPU 功率 widget 从功耗模块移来（D57 G3），沿用旧键 menubar.power.gpuPower.visible / .color
// - gpu.interval / gpu.panel.interval / .topNInterval / .topNRows / .grouping / .chartSpan / .chartPower
//   GPU 与加速器的常驻间隔覆盖与面板设置
// - history.gpu.enabled   是否记录 GPU 与加速器历史（D57 G9）
// - menubar.network.<widget>.visible / .color   网络 widget（netThroughput / netLatency，D60：网速出厂开；延迟只在延迟开启时可选）
// - network.widget.throughput.target / .unit   网速 widget 绑定：primary、physical、if:<BSD 名>；单位 bytes / bits
// - network.widget.latency.target   延迟 widget 显示哪个目标：gateway / custom
// - network.interval / network.panel.chartSpan / .virtualActiveOnly / .totalsInterface   网络的常驻间隔覆盖与面板设置
//   （旧键 network.panel.showsVirtual 是 D64 之前虚拟接口就地展开的状态，已不再读取）
// - storage.panel.listActiveOnly   外置盘 / RAID 成员列表页只看活跃（D64，默认是）
// - menubar.merged / .merged.order / .merged.separator   合并为单个 item、合并顺序（widget 名数组）、分隔 line / space（D65）
// - network.latency.enabled / .gateway / .custom / .host / .interval   延迟（D61：默认关；间隔 2 / 5 / 10 s，默认 5）
// - network.publicIP.service   公网 IP 查询服务地址（D62：默认空，第一次点击时填写）
// - history.network.enabled   是否记录网络历史（D60 N7）
// - menubar.devices.deviceBattery.visible / .color   电源设备 widget（D84：出厂关）
// - devices.widget.battery.target   电源设备 widget 绑定：auto（UPS → 内置电池 → 电量最低的配件）/ ups / battery / accessoryLowest
// - history.devices.enabled   是否记录电源设备历史（D84 PD6：主 UPS 的电量、负载、输入电压，供电切换区间）
// - 旧键 menubar.cpu.coloring / .warningPercent / .criticalPercent（D32 的着色，已由 D43 取消）不再读取
// - 旧键 menubar.cpu.style / menubar.cpu.label（D41 之前）只在新键缺失时读取，用来换算出上面三项
// - cpu.panel.freqInterval / .sensorInterval / .topNInterval   面板内各项的采样间隔，秒：1 / 2 / 5
// - cpu.panel.topNRows / .grouping / .chartSpan / .splitUserSystem   面板显示
// - history.cpu.enabled / history.apps.enabled / history.cpu.highPrecision   是否记录历史与后台高精度（D30、D19）；
//   history.apps.enabled 同时管每应用数据（D68）与电源断言（D69），在「应用活动」页编辑
// - appActivity.interval   应用活动窗口「现在」档的采样间隔，秒：1 / 2 / 5（D67：默认 2）
// - update.frequency / update.autoInstall   检查更新的频率（off / daily / weekly，D76：默认 weekly）、发现新版本时是否自动安装（默认否）
//   （上次检查的时间 update.lastCheck 由 Updater 自己读写）

import Foundation
import Observation
import SysCollectors
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
        static let updateFrequency = "update.frequency"
        static let updateAutoInstall = "update.autoInstall"
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
        static func widgetColor(_ widget: MenuWidget) -> String { "menubar.\(widget.keyModule).\(widget.rawValue).color" }
        /// 功耗与散热等模块 widget 的显示开关（CPU 四项沿用上面的旧键）。
        static func widgetVisible(_ widget: MenuWidget) -> String { "menubar.\(widget.keyModule).\(widget.rawValue).visible" }
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
        static let gpuInterval = "gpu.interval"
        static let gpuPanelInterval = "gpu.panel.interval"
        static let gpuTopNInterval = "gpu.panel.topNInterval"
        static let gpuTopNRows = "gpu.panel.topNRows"
        static let gpuGrouping = "gpu.panel.grouping"
        static let gpuChartSpan = "gpu.panel.chartSpan"
        static let gpuChartShowsPower = "gpu.panel.chartPower"
        static let historyGPU = "history.gpu.enabled"
        static let networkInterval = "network.interval"
        static let networkThroughputTarget = "network.widget.throughput.target"
        static let networkThroughputUnit = "network.widget.throughput.unit"
        static let networkLatencyWidgetTarget = "network.widget.latency.target"
        static let networkChartSpan = "network.panel.chartSpan"
        static let networkVirtualActiveOnly = "network.panel.virtualActiveOnly"
        static let storageListActiveOnly = "storage.panel.listActiveOnly"
        static let menuBarMerged = "menubar.merged"
        static let menuBarMergedOrder = "menubar.merged.order"
        static let menuBarMergedSeparator = "menubar.merged.separator"
        static let networkTotalsInterface = "network.panel.totalsInterface"
        static let latencyEnabled = "network.latency.enabled"
        static let latencyGateway = "network.latency.gateway"
        static let latencyCustom = "network.latency.custom"
        static let latencyHost = "network.latency.host"
        static let latencyInterval = "network.latency.interval"
        static let publicIPService = "network.publicIP.service"
        static let historyNetwork = "history.network.enabled"
        static let deviceBatteryTarget = "devices.widget.battery.target"
        static let historyDevices = "history.devices.enabled"
        static let appActivityInterval = "appActivity.interval"
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

    /// 合并 item 里的段（D65 MG1）：开着的 widget，按合并顺序；不在顺序里的（新开的）按模块顺序排在后面。
    func mergedWidgets(from visible: [MenuWidget]) -> [MenuWidget] {
        let ordered = menuBarMergedOrder.filter(visible.contains)
        return ordered + visible.filter { !ordered.contains($0) }
    }

    func isVisible(_ widget: MenuWidget) -> Bool {
        switch widget {
        case .usage: cpuItemVisible
        case .frequency: cpuFrequencyItemVisible
        case .temperature: cpuTemperatureItemVisible
        case .power: cpuPowerItemVisible
        case .netLatency: latencyEnabled && (powerWidgetsVisible[widget] ?? widget.visibleByDefault)
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

    /// 检查更新的频率（D76：出厂每周）。
    var updateFrequency: UpdateCheckFrequency {
        didSet { persist(updateFrequency.rawValue, Key.updateFrequency) }
    }

    /// 发现新版本时自动下载并安装（D76：出厂只提示）。
    var updateAutoInstall: Bool {
        didSet { persist(updateAutoInstall, Key.updateAutoInstall) }
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

    /// 合并为单个 item（D65 MG1）。
    var menuBarMerged: Bool {
        didSet { persist(menuBarMerged, Key.menuBarMerged) }
    }

    /// 合并 item 里各 widget 的顺序（D65 MG1）。只记顺序；显示哪些仍由各 widget 的开关决定，
    /// 开着但不在这里的 widget 按模块顺序排在后面（见 `mergedWidgets`）。
    var menuBarMergedOrder: [MenuWidget] {
        didSet { persist(menuBarMergedOrder.map(\.rawValue), Key.menuBarMergedOrder) }
    }

    /// 合并 item 段与段之间的分隔（D65 MG6）。
    var menuBarMergedSeparator: MergedSeparator {
        didSet { persist(menuBarMergedSeparator.rawValue, Key.menuBarMergedSeparator) }
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

    // MARK: GPU 与加速器（D57、D58）

    /// GPU 模块的常驻间隔覆盖；nil 表示跟随全局默认（D25）。
    var gpuIntervalOverride: SamplingInterval? {
        didSet { persist(gpuIntervalOverride?.rawValue ?? 0, Key.gpuInterval) }
    }

    /// GPU 模块实际使用的常驻间隔。
    var gpuInterval: SamplingInterval { gpuIntervalOverride ?? globalInterval }

    /// 面板 GPU tab 里温度、ANE、媒体引擎与 GPU 内存的间隔（默认 2 s）；活跃、频率与功率固定每秒。
    var gpuPanelInterval: Int {
        didSet { persist(gpuPanelInterval, Key.gpuPanelInterval) }
    }

    /// 面板 GPU Top N 的间隔（默认 2 s；同时决定 ANE 估算的刷新）。
    var gpuTopNInterval: Int {
        didSet { persist(gpuTopNInterval, Key.gpuTopNInterval) }
    }

    /// GPU Top N 行数（0/3/5/8/10，默认 5）。
    var gpuTopNRows: Int {
        didSet { persist(gpuTopNRows, Key.gpuTopNRows) }
    }

    /// GPU Top N 分组方式（默认按应用，D31）。
    var gpuGrouping: TopNGrouping {
        didSet { persist(gpuGrouping.rawValue, Key.gpuGrouping) }
    }

    /// GPU 图的默认跨度。
    var gpuChartSpan: ChartSpan {
        didSet { persist(gpuChartSpan.rawValue, Key.gpuChartSpan) }
    }

    /// GPU 图画功率（W）而不是活跃（%）。两者纵轴不同，不叠加，二选一（默认活跃）。
    var gpuChartShowsPower: Bool {
        didSet { persist(gpuChartShowsPower, Key.gpuChartShowsPower) }
    }

    /// 是否记录 GPU 与加速器历史（默认开）。
    var historyGPUEnabled: Bool {
        didSet { persist(historyGPUEnabled, Key.historyGPU) }
    }

    // MARK: 网络（D60–D62）

    /// 网络模块的常驻间隔覆盖；nil 表示跟随全局默认（D25）。
    var networkIntervalOverride: SamplingInterval? {
        didSet { persist(networkIntervalOverride?.rawValue ?? 0, Key.networkInterval) }
    }

    /// 网络模块实际使用的常驻间隔。
    var networkInterval: SamplingInterval { networkIntervalOverride ?? globalInterval }

    /// 网速 widget 绑定的接口（默认主接口，自动跟随）。
    var networkThroughputTarget: NetworkTarget {
        didSet { persist(networkThroughputTarget.storageValue, Key.networkThroughputTarget) }
    }

    /// 网速 widget 用比特 / 秒（默认字节 / 秒，同活动监视器，K24）。
    var networkThroughputBits: Bool {
        didSet { persist(networkThroughputBits ? "bits" : "bytes", Key.networkThroughputUnit) }
    }

    /// 延迟 widget 显示哪个目标。
    var networkLatencyWidgetTarget: MetricID.LatencyTarget {
        didSet { persist(networkLatencyWidgetTarget.rawValue, Key.networkLatencyWidgetTarget) }
    }

    /// 网络图的默认跨度。
    var networkChartSpan: ChartSpan {
        didSet { persist(networkChartSpan.rawValue, Key.networkChartSpan) }
    }

    /// 虚拟接口列表页是否只看活跃（D64：默认只看活跃）。
    var networkVirtualActiveOnly: Bool {
        didSet { persist(networkVirtualActiveOnly, Key.networkVirtualActiveOnly) }
    }

    /// 外置盘 / RAID 成员列表页是否只看活跃（D64：默认只看活跃）。
    var storageListActiveOnly: Bool {
        didSet { persist(storageListActiveOnly, Key.storageListActiveOnly) }
    }

    /// 流量统计看哪个接口：nil 为主接口。
    var networkTotalsInterface: String? {
        didSet { persist(networkTotalsInterface ?? "", Key.networkTotalsInterface) }
    }

    /// 延迟（D61：默认关，开启才发 ICMP 包）。
    var latencyEnabled: Bool {
        didSet { persist(latencyEnabled, Key.latencyEnabled) }
    }

    /// 延迟测默认网关（无需本地网络授权）。
    var latencyGateway: Bool {
        didSet { persist(latencyGateway, Key.latencyGateway) }
    }

    /// 延迟测自定义地址。
    var latencyCustom: Bool {
        didSet { persist(latencyCustom, Key.latencyCustom) }
    }

    /// 自定义地址（IP 或主机名；默认 223.5.5.5，D61）。
    var latencyHost: String {
        didSet { persist(latencyHost, Key.latencyHost) }
    }

    /// 发包间隔，秒（2 / 5 / 10，默认 5）。
    var latencyInterval: Int {
        didSet { persist(latencyInterval, Key.latencyInterval) }
    }

    /// 实际要测的目标；延迟关闭时为 nil。
    var latencyTargets: LatencyCollector.Targets? {
        guard latencyEnabled else { return nil }
        let host = latencyHost.trimmingCharacters(in: .whitespaces)
        let targets = LatencyCollector.Targets(gateway: latencyGateway, custom: latencyCustom && !host.isEmpty ? host : nil)
        return targets.gateway || targets.custom != nil ? targets : nil
    }

    /// 公网 IP 查询服务地址（D62：默认空）。
    var publicIPService: String {
        didSet { persist(publicIPService, Key.publicIPService) }
    }

    /// 是否记录网络历史（默认开）。
    var historyNetworkEnabled: Bool {
        didSet { persist(historyNetworkEnabled, Key.historyNetwork) }
    }

    // MARK: 电源设备（D84）

    /// 电源设备 widget 绑定的设备（默认自动）。
    var deviceBatteryTarget: DeviceTarget {
        didSet { persist(deviceBatteryTarget.rawValue, Key.deviceBatteryTarget) }
    }

    /// 是否记录电源设备历史（默认开；没有 UPS 时什么也不写）。
    var historyDevicesEnabled: Bool {
        didSet { persist(historyDevicesEnabled, Key.historyDevices) }
    }

    /// 应用活动窗口「现在」档的采样间隔（D67：默认 2 s，可选 1 / 5）。
    var appActivityInterval: Int {
        didSet { persist(appActivityInterval, Key.appActivityInterval) }
    }


    static let latencyIntervals = [2, 5, 10]

    /// 某个模块实际使用的常驻间隔。
    func interval(for module: MenuModule) -> SamplingInterval {
        switch module {
        case .cpu: cpuInterval
        case .power: powerInterval
        case .memory: memoryInterval
        case .storage: storageInterval
        case .gpu: gpuInterval
        case .network: networkInterval
        // 电源设备的数值来自事件驱动的快照，采样只是取出：跟随全局，不单独覆盖（D84 PD3）。
        case .devices: globalInterval
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
        updateFrequency = defaults?.string(forKey: Key.updateFrequency).flatMap(UpdateCheckFrequency.init(rawValue:)) ?? .weekly
        updateAutoInstall = defaults?.object(forKey: Key.updateAutoInstall) as? Bool ?? false
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
        gpuIntervalOverride = defaults.flatMap { SamplingInterval(rawValue: $0.integer(forKey: Key.gpuInterval)) }
        gpuPanelInterval = Self.int(defaults, Key.gpuPanelInterval, choices: Self.panelIntervals) ?? 2
        gpuTopNInterval = Self.int(defaults, Key.gpuTopNInterval, choices: Self.panelIntervals) ?? 2
        gpuTopNRows = Self.int(defaults, Key.gpuTopNRows, choices: Self.topNRowChoices) ?? 5
        gpuGrouping = defaults?.string(forKey: Key.gpuGrouping).flatMap(TopNGrouping.init(rawValue:)) ?? .byApp
        gpuChartSpan = defaults?.string(forKey: Key.gpuChartSpan).flatMap(ChartSpan.init(rawValue:)) ?? .twoMinutes
        gpuChartShowsPower = defaults?.object(forKey: Key.gpuChartShowsPower) as? Bool ?? false
        historyGPUEnabled = defaults?.object(forKey: Key.historyGPU) as? Bool ?? true
        networkIntervalOverride = defaults.flatMap { SamplingInterval(rawValue: $0.integer(forKey: Key.networkInterval)) }
        networkThroughputTarget =
            defaults?.string(forKey: Key.networkThroughputTarget).flatMap(NetworkTarget.init(storageValue:)) ?? .primary
        networkThroughputBits = defaults?.string(forKey: Key.networkThroughputUnit) == "bits"
        networkLatencyWidgetTarget =
            defaults?.string(forKey: Key.networkLatencyWidgetTarget).flatMap(MetricID.LatencyTarget.init(rawValue:)) ?? .custom
        networkChartSpan = defaults?.string(forKey: Key.networkChartSpan).flatMap(ChartSpan.init(rawValue:)) ?? .twoMinutes
        networkVirtualActiveOnly = defaults?.object(forKey: Key.networkVirtualActiveOnly) as? Bool ?? true
        storageListActiveOnly = defaults?.object(forKey: Key.storageListActiveOnly) as? Bool ?? true
        menuBarMerged = defaults?.object(forKey: Key.menuBarMerged) as? Bool ?? false
        menuBarMergedOrder = (defaults?.stringArray(forKey: Key.menuBarMergedOrder) ?? []).compactMap(MenuWidget.init(rawValue:))
        menuBarMergedSeparator =
            defaults?.string(forKey: Key.menuBarMergedSeparator).flatMap(MergedSeparator.init(rawValue:)) ?? .line
        networkTotalsInterface = defaults?.string(forKey: Key.networkTotalsInterface).flatMap { $0.isEmpty ? nil : $0 }
        latencyEnabled = defaults?.object(forKey: Key.latencyEnabled) as? Bool ?? false
        latencyGateway = defaults?.object(forKey: Key.latencyGateway) as? Bool ?? true
        latencyCustom = defaults?.object(forKey: Key.latencyCustom) as? Bool ?? true
        latencyHost = defaults?.string(forKey: Key.latencyHost) ?? "223.5.5.5"
        latencyInterval = Self.int(defaults, Key.latencyInterval, choices: Self.latencyIntervals) ?? 5
        publicIPService = defaults?.string(forKey: Key.publicIPService) ?? ""
        historyNetworkEnabled = defaults?.object(forKey: Key.historyNetwork) as? Bool ?? true
        deviceBatteryTarget = defaults?.string(forKey: Key.deviceBatteryTarget).flatMap(DeviceTarget.init(rawValue:)) ?? .auto
        historyDevicesEnabled = defaults?.object(forKey: Key.historyDevices) as? Bool ?? true
        appActivityInterval = Self.int(defaults, Key.appActivityInterval, choices: Self.panelIntervals) ?? 2
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

/// 网速 widget 绑定的接口（网络模块设计 §7，D60）。
enum NetworkTarget: Hashable {
    /// 主接口，自动跟随（隧道时取下层物理接口）。
    case primary
    /// 活跃物理接口合计。
    case physical
    /// 指定接口（BSD 名）；不在了时显示「—」。
    case interface(String)

    var storageValue: String {
        switch self {
        case .primary: "primary"
        case .physical: "physical"
        case .interface(let name): "if:\(name)"
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "primary": self = .primary
        case "physical": self = .physical
        default:
            guard storageValue.hasPrefix("if:"), storageValue.count > 3 else { return nil }
            self = .interface(String(storageValue.dropFirst(3)))
        }
    }

    /// 入 / 出速率的指标。指定接口时按名字找物理前缀，没有再找虚拟前缀（由调用方按清单决定）。
    func metric(_ direction: MetricID.NetworkDirection, physical: Bool = true) -> MetricID {
        switch self {
        case .primary: .networkPrimary(direction)
        case .physical: .networkPhysical(direction)
        case .interface(let name):
            physical ? .networkInterface(name, direction) : .networkVirtualInterface(name, direction)
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
/// 合并 item 段与段之间的分隔（D65 MG6）。
enum MergedSeparator: String, CaseIterable, Identifiable {
    case line
    case space

    var id: String { rawValue }
}

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
    case fan
    // 内存（D49）
    case memoryUsage
    case memoryPressure
    case swapUsed
    // 存储（D54）
    case diskTemperature
    case diskThroughput
    case diskFree
    // GPU 与加速器（D57）：GPU 功率从功耗与散热移来（G3）
    case gpuActive
    case gpuPower
    case gpuTemperature
    // 网络（D60）
    case netThroughput
    case netLatency
    // 电源设备（D84）
    case deviceBattery

    var id: String { rawValue }

    var module: MenuModule {
        switch self {
        case .usage, .frequency, .temperature, .power: .cpu
        case .systemPower, .socHotspot, .socPower, .fan: .power
        case .memoryUsage, .memoryPressure, .swapUsed: .memory
        case .diskTemperature, .diskThroughput, .diskFree: .storage
        case .gpuActive, .gpuPower, .gpuTemperature: .gpu
        case .netThroughput, .netLatency: .network
        case .deviceBattery: .devices
        }
    }

    /// 偏好键里的模块段：GPU 功率移到 GPU 模块后沿用原来的 `menubar.power.gpuPower.*`，已有用户的开关与颜色不丢。
    var keyModule: String { self == .gpuPower ? MenuModule.power.rawValue : module.rawValue }

    static func widgets(of module: MenuModule) -> [MenuWidget] { allCases.filter { $0.module == module } }

    /// 出厂默认是否显示（D51：CPU 占用、整机功率、内存占用；D54 加盘温；D60 加网速）。
    var visibleByDefault: Bool {
        self == .usage || self == .systemPower || self == .memoryUsage || self == .diskTemperature || self == .netThroughput
    }
}

/// widget 所属的模块：决定常驻采集间隔、点击后预选的面板 tab、设置页的位置。
enum MenuModule: String, CaseIterable, Identifiable {
    case cpu
    case power
    case memory
    case storage
    case gpu
    case network
    case devices

    var id: String { rawValue }
}
