// 菜单栏 widget（K32、D38，M0 设计 §6）：一个 widget 只显示一项，每个 widget 是一个独立的 `NSStatusItem`。
//
// - 固定宽度，自绘 `statusItem.view`；
// - autosaveName = "<bundle id>.cpu"（占用，沿用 M0 的名字，保住用户拖好的位置）、"<bundle id>.cpu.<项>"
//   或 "<bundle id>.<模块>.<项>"（GPU 功率移到 GPU 模块后仍用 "<bundle id>.power.gpuPower"，保住位置，D57）；
//   创建后显式设 isVisible = true，并启用 `.removalAllowed`；KVO 观察 isVisible，用户把 item 拖走后同步关掉设置里的开关
//   （可见性以 app 设置为准）；
// - 每个 widget 可见时登记它自己的需求，隐藏时注销（只在有消费者时采样）：
//   占用 → cpu.load，频率 → cpu.freq（D19 高开销项），温度与功耗 → cpu.sensors；
//   整机功率 → power.rail，SoC 功率、最热点、风扇 → power.sensors；
//   GPU 活跃与 GPU 功率 → power.gpu（同一个订阅，D57），GPU 温度 → gpu.temperature；
//   内存的三个 widget → memory.vm（D49）；
//   存储：盘温 → storage.smart（只读绑定的盘，D55），读写 → storage.io，可用空间 → storage.capacity（60 s）；
//   间隔取所属模块的常驻间隔（D25 的逐模块覆盖）；
// - 点击由 `expandedInterfaceDelegate`（PanelController）驱动；面板锚在被点击的 widget 下方（`activeItem`）。

import AppKit
import SysCollectors
import SysModel
import OSLog

final class StatusItemController {
    private final class Entry {
        let item: NSStatusItem
        let view: StatusItemView
        let demand: DemandSlot
        var observation: NSKeyValueObservation?

        init(item: NSStatusItem, view: StatusItemView, demand: DemandSlot) {
            self.item = item
            self.view = view
            self.demand = demand
        }
    }

    private let store: MetricStore
    private let engine: SamplingEngine
    private var entries: [MenuWidget: Entry] = [:]

    /// 最近一次被点击（开启 session）的 item；面板锚在它下方。
    weak var activeItem: NSStatusItem?

    /// 面板控制器，负责 expanded interface session。
    weak var expandedInterfaceDelegate: (any NSStatusItemExpandedInterfaceDelegate)? {
        didSet { entries.values.forEach { $0.item.expandedInterfaceDelegate = expandedInterfaceDelegate } }
    }

    /// 用户在菜单栏里把某个 widget 移除（⌘ 拖走或在系统设置里关闭）后调用。
    var onUserRemoved: ((MenuWidget) -> Void)?

    init(store: MetricStore, engine: SamplingEngine) {
        self.store = store
        self.engine = engine
    }

    /// 按设置显示或移除各 widget，并同步采样需求与显示配置。`configurations` 里只有要显示的 widget。
    func update(_ configurations: [StatusItemConfiguration], intervals: (MenuModule) -> SamplingInterval) {
        let wanted = Dictionary(uniqueKeysWithValues: configurations.map { ($0.widget, $0) })
        for widget in MenuWidget.allCases {
            if let configuration = wanted[widget] {
                let entry = installIfNeeded(configuration)
                apply(configuration, to: entry)
                entry.demand.set(
                    Demand(
                        collectors: [Self.collector(for: widget)], interval: Self.interval(for: widget, moduleInterval: intervals(widget.module)),
                        source: Self.source(widget)))
            } else {
                remove(widget)
            }
        }
    }

    static func collector(for widget: MenuWidget) -> CollectorID {
        switch widget {
        case .usage: CPULoadCollector.collectorID
        case .frequency: CPUFrequencyCollector.collectorID
        case .temperature, .power: SensorCollector.collectorID
        case .systemPower: PowerRailCollector.collectorID
        case .socHotspot, .socPower, .fan: PowerSensorCollector.collectorID
        case .gpuPower, .gpuActive: GPUPowerCollector.collectorID
        case .gpuTemperature: GPUTemperatureCollector.collectorID
        case .memoryUsage, .memoryPressure, .swapUsed: MemoryCollector.collectorID
        case .diskTemperature: SMARTCollector.collectorID
        case .diskThroughput: StorageIOCollector.collectorID
        case .diskFree: StorageCapacityCollector.collectorID
        }
    }

    /// 采样间隔：可用空间变化慢，固定 60 s（存储模块设计 §4.6）；其余按所属模块的常驻间隔。
    static func interval(for widget: MenuWidget, moduleInterval: SamplingInterval) -> Int {
        widget == .diskFree ? 60 : moduleInterval.rawValue
    }

    static func source(_ widget: MenuWidget) -> DemandSource {
        widget == .usage ? .menubarCPU : DemandSource("menubar.\(widget.module.rawValue).\(widget.rawValue)")
    }

    /// 屏幕上的这一点是否落在本 app 除 `excluded` 以外的某个 widget 上（从一个 widget 点到另一个时原地换面板，D47）。
    func isOtherItem(at point: NSPoint, excluding excluded: NSStatusItem?) -> Bool {
        entries.values.contains { entry in
            entry.item !== excluded && (entry.item.view?.window ?? entry.item.button?.window)?.frame.contains(point) == true
        }
    }

    /// 某个 item 是哪个 widget（点击后按模块选择面板内容，D47）。
    func widget(for item: NSStatusItem) -> MenuWidget? {
        entries.first { $0.value.item === item }?.key
    }

    /// 面板锚点：被点击的 widget 所在的菜单栏窗口；没有时取第一个显示的 widget。
    var anchorWindow: NSWindow? {
        let item = activeItem ?? MenuWidget.allCases.lazy.compactMap { self.entries[$0]?.item }.first
        return item?.view?.window ?? item?.button?.window
    }

    // MARK: - 私有

    /// 样式或柱数变化时重新定宽（只在设置变化时发生，运行中宽度不变，K32）。
    private func apply(_ configuration: StatusItemConfiguration, to entry: Entry) {
        guard entry.view.configuration != configuration else { return }
        let width = StatusItemView.fixedWidth(for: configuration)
        entry.view.configuration = configuration
        if entry.item.length != width {
            entry.item.length = width
            entry.view.setFrameSize(NSSize(width: width, height: entry.view.frame.height))
            Log.menubar.info(
                "\(configuration.widget.rawValue, privacy: .public) widget 改为 \(configuration.style.rawValue, privacy: .public)，宽度 \(width, format: .fixed(precision: 1)) pt"
            )
        }
    }

    private func installIfNeeded(_ configuration: StatusItemConfiguration) -> Entry {
        let widget = configuration.widget
        if let entry = entries[widget] { return entry }
        let width = StatusItemView.fixedWidth(for: configuration)
        let item = NSStatusBar.system.statusItem(withLength: width)
        item.autosaveName =
            widget == .usage
            ? "\(BuildInfo.bundleIdentifier).cpu" : "\(BuildInfo.bundleIdentifier).\(widget.keyModule).\(widget.rawValue)"
        item.behavior = .removalAllowed
        // autosaveName 会持久化可见性；可见性以 app 设置为准（K32），创建后显式设为可见。
        item.isVisible = true

        let view = StatusItemView(store: store, height: NSStatusBar.system.thickness, configuration: configuration)
        item.view = view
        item.expandedInterfaceDelegate = expandedInterfaceDelegate

        let entry = Entry(item: item, view: view, demand: DemandSlot(engine: engine))
        entry.observation = item.observe(\.isVisible, options: [.new]) { [weak self] _, change in
            guard change.newValue == false else { return }
            // KVO 在修改它的线程（主线程）上回调；移除 item 推迟到下一轮，避免在回调里改动 item 本身。
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.entries[widget] != nil else { return }
                    Log.menubar.info("用户移除了 \(widget.rawValue, privacy: .public) widget，同步关闭设置开关")
                    self.onUserRemoved?(widget)
                }
            }
        }
        entries[widget] = entry
        Log.menubar.info("\(widget.rawValue, privacy: .public) widget 已创建，宽度 \(width, format: .fixed(precision: 1)) pt")
        return entry
    }

    private func remove(_ widget: MenuWidget) {
        guard let entry = entries.removeValue(forKey: widget) else { return }
        entry.demand.set(nil)
        entry.observation?.invalidate()
        entry.item.expandedInterfaceDelegate = nil
        if activeItem === entry.item { activeItem = nil }
        NSStatusBar.system.removeStatusItem(entry.item)
        Log.menubar.info("\(widget.rawValue, privacy: .public) widget 已移除")
    }
}

extension StatusItemConfiguration {
    /// 按当前设置与拓扑生成某个 widget 的显示配置（菜单栏、设置页预览与总览共用）。
    init(widget: MenuWidget, settings: AppSettings) {
        let topology = CPUTopologyService.shared.current
        self.init(
            widget: widget, style: settings.renderStyle(for: widget), showsLabel: settings.menuBarShowsLabel,
            color: settings.color(for: widget), levelCount: max(topology?.perfLevels.count ?? 2, 1),
            coreCount: topology?.logicalCPUCount ?? SystemInfo.maxLogicalCPUCount ?? 8,
            memoryShowsBytes: settings.memoryUsagePresentation == .bytes,
            storageKey: Self.storageKey(widget: widget, settings: settings),
            storageHottest: widget == .diskTemperature && settings.diskTemperatureTarget == .hottest)
    }

    /// 存储 widget 绑定的盘或组（D54）：内置盘、启动组按当前清单解析；其余 widget 为 nil。
    private static func storageKey(widget: MenuWidget, settings: AppSettings) -> DiskKey? {
        let model = StorageModel.shared
        switch widget {
        case .diskTemperature: return model.resolveDisk(settings.diskTemperatureTarget)
        case .diskThroughput: return model.resolveDisk(settings.diskThroughputTarget)
        case .diskFree: return model.resolveGroup(settings.diskFreeTarget)
        default: return nil
        }
    }
}
