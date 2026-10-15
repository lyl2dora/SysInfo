// 菜单栏 CPU widget（K32、D38，M0 设计 §6）：一个 widget 只显示一项，每个 widget 是一个独立的 `NSStatusItem`。
//
// - 固定宽度，自绘 `statusItem.view`；
// - autosaveName = "<bundle id>.cpu"（占用，沿用 M0 的名字，保住用户拖好的位置）或 "<bundle id>.cpu.<项>"；
//   创建后显式设 isVisible = true，并启用 `.removalAllowed`；KVO 观察 isVisible，用户把 item 拖走后同步关掉设置里的开关
//   （可见性以 app 设置为准）；
// - 每个 widget 可见时登记它自己的需求，隐藏时注销（只在有消费者时采样）：
//   占用 → cpu.load，频率 → cpu.freq（D19 高开销项），温度与功耗 → cpu.sensors；
// - 点击由 `expandedInterfaceDelegate`（PanelController）驱动；面板锚在被点击的 widget 下方（`activeItem`）。

import AppKit
import SysCollectors
import SysModel
import OSLog

final class StatusItemController {
    private final class Entry {
        let item: NSStatusItem
        let view: CPUStatusItemView
        let demand: DemandSlot
        var observation: NSKeyValueObservation?

        init(item: NSStatusItem, view: CPUStatusItemView, demand: DemandSlot) {
            self.item = item
            self.view = view
            self.demand = demand
        }
    }

    private let store: MetricStore
    private let engine: SamplingEngine
    private var entries: [CPUMenuWidget: Entry] = [:]

    /// 最近一次被点击（开启 session）的 item；面板锚在它下方。
    weak var activeItem: NSStatusItem?

    /// 面板控制器，负责 expanded interface session。
    weak var expandedInterfaceDelegate: (any NSStatusItemExpandedInterfaceDelegate)? {
        didSet { entries.values.forEach { $0.item.expandedInterfaceDelegate = expandedInterfaceDelegate } }
    }

    /// 用户在菜单栏里把某个 widget 移除（⌘ 拖走或在系统设置里关闭）后调用。
    var onUserRemoved: ((CPUMenuWidget) -> Void)?

    init(store: MetricStore, engine: SamplingEngine) {
        self.store = store
        self.engine = engine
    }

    /// 按设置显示或移除各 widget，并同步采样需求与显示配置。`configurations` 里只有要显示的 widget。
    func update(_ configurations: [CPUStatusItemConfiguration], interval: SamplingInterval) {
        let wanted = Dictionary(uniqueKeysWithValues: configurations.map { ($0.widget, $0) })
        for widget in CPUMenuWidget.allCases {
            if let configuration = wanted[widget] {
                let entry = installIfNeeded(configuration)
                apply(configuration, to: entry)
                entry.demand.set(
                    Demand(collectors: [Self.collector(for: widget)], interval: interval.rawValue, source: Self.source(widget)))
            } else {
                remove(widget)
            }
        }
    }

    static func collector(for widget: CPUMenuWidget) -> CollectorID {
        switch widget {
        case .usage: CPULoadCollector.collectorID
        case .frequency: CPUFrequencyCollector.collectorID
        case .temperature, .power: SensorCollector.collectorID
        }
    }

    static func source(_ widget: CPUMenuWidget) -> DemandSource {
        widget == .usage ? .menubarCPU : DemandSource("menubar.cpu.\(widget.rawValue)")
    }

    /// 面板锚点：被点击的 widget 所在的菜单栏窗口；没有时取第一个显示的 widget。
    var anchorWindow: NSWindow? {
        let item = activeItem ?? CPUMenuWidget.allCases.lazy.compactMap { self.entries[$0]?.item }.first
        return item?.view?.window ?? item?.button?.window
    }

    // MARK: - 私有

    /// 样式或柱数变化时重新定宽（只在设置变化时发生，运行中宽度不变，K32）。
    private func apply(_ configuration: CPUStatusItemConfiguration, to entry: Entry) {
        guard entry.view.configuration != configuration else { return }
        let width = CPUStatusItemView.fixedWidth(for: configuration)
        entry.view.configuration = configuration
        if entry.item.length != width {
            entry.item.length = width
            entry.view.setFrameSize(NSSize(width: width, height: entry.view.frame.height))
            Log.menubar.info(
                "\(configuration.widget.rawValue, privacy: .public) widget 改为 \(configuration.style.rawValue, privacy: .public)，宽度 \(width, format: .fixed(precision: 1)) pt"
            )
        }
    }

    private func installIfNeeded(_ configuration: CPUStatusItemConfiguration) -> Entry {
        let widget = configuration.widget
        if let entry = entries[widget] { return entry }
        let width = CPUStatusItemView.fixedWidth(for: configuration)
        let item = NSStatusBar.system.statusItem(withLength: width)
        item.autosaveName =
            widget == .usage ? "\(BuildInfo.bundleIdentifier).cpu" : "\(BuildInfo.bundleIdentifier).cpu.\(widget.rawValue)"
        item.behavior = .removalAllowed
        // autosaveName 会持久化可见性；可见性以 app 设置为准（K32），创建后显式设为可见。
        item.isVisible = true

        let view = CPUStatusItemView(store: store, height: NSStatusBar.system.thickness, configuration: configuration)
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

    private func remove(_ widget: CPUMenuWidget) {
        guard let entry = entries.removeValue(forKey: widget) else { return }
        entry.demand.set(nil)
        entry.observation?.invalidate()
        entry.item.expandedInterfaceDelegate = nil
        if activeItem === entry.item { activeItem = nil }
        NSStatusBar.system.removeStatusItem(entry.item)
        Log.menubar.info("\(widget.rawValue, privacy: .public) widget 已移除")
    }
}

extension CPUStatusItemConfiguration {
    /// 按当前设置与拓扑生成某个 widget 的显示配置（菜单栏、设置页预览与总览共用）。
    init(widget: CPUMenuWidget, settings: AppSettings) {
        let topology = CPUTopologyService.shared.current
        self.init(
            widget: widget, style: settings.renderStyle(for: widget), showsLabel: settings.menuBarShowsLabel,
            color: settings.color(for: widget), levelCount: max(topology?.perfLevels.count ?? 2, 1),
            coreCount: topology?.logicalCPUCount ?? SystemInfo.maxLogicalCPUCount ?? 8)
    }
}
