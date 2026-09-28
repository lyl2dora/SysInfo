// 菜单栏 CPU item（K32、D06，M0 设计 §6）。
//
// - 固定宽度的 `NSStatusItem`，自绘 `statusItem.view`；
// - autosaveName = "<bundle id>.cpu"；创建后显式设 isVisible = true，并启用 `.removalAllowed`；
//   KVO 观察 isVisible，用户把 item 拖走后同步关掉设置里的开关（可见性以 app 设置为准）；
// - item 可见时登记 `cpu.load` 需求，隐藏时注销（只在有消费者时采样）；
// - 点击由 `expandedInterfaceDelegate`（PanelController）驱动。

import AppKit
import SysCollectors
import SysModel
import OSLog

final class StatusItemController {
    private let store: MetricStore
    private let demand: DemandSlot
    private(set) var item: NSStatusItem?
    private var itemView: CPUStatusItemView?
    private var visibilityObservation: NSKeyValueObservation?

    /// 面板控制器，负责 expanded interface session。
    weak var expandedInterfaceDelegate: (any NSStatusItemExpandedInterfaceDelegate)? {
        didSet { item?.expandedInterfaceDelegate = expandedInterfaceDelegate }
    }

    /// 用户在菜单栏里把 item 移除（⌘ 拖走或在系统设置里关闭）后调用。
    var onUserRemoved: (() -> Void)?

    init(store: MetricStore, engine: SamplingEngine) {
        self.store = store
        self.demand = DemandSlot(engine: engine)
    }

    /// 按设置显示或移除 item，并同步采样需求。
    func update(visible: Bool, interval: SamplingInterval) {
        if visible {
            installIfNeeded()
            demand.set(
                Demand(collectors: [CPULoadCollector.collectorID], interval: interval.rawValue, source: .menubarCPU))
        } else {
            demand.set(nil)
            remove()
        }
    }

    /// 面板锚点：item 所在的菜单栏窗口。
    var anchorWindow: NSWindow? {
        item?.view?.window ?? item?.button?.window
    }

    // MARK: - 私有

    private func installIfNeeded() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: CPUStatusItemView.fixedWidth)
        item.autosaveName = "\(BuildInfo.bundleIdentifier).cpu"
        item.behavior = .removalAllowed
        // autosaveName 会持久化可见性；可见性以 app 设置为准（K32），创建后显式设为可见。
        item.isVisible = true

        let view = CPUStatusItemView(store: store, height: NSStatusBar.system.thickness)
        item.view = view
        item.expandedInterfaceDelegate = expandedInterfaceDelegate

        visibilityObservation = item.observe(\.isVisible, options: [.new]) { [weak self] _, change in
            guard change.newValue == false else { return }
            // KVO 在修改它的线程（主线程）上回调；移除 item 推迟到下一轮，避免在回调里改动 item 本身。
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.item != nil else { return }
                    Log.menubar.info("用户移除了 CPU item，同步关闭设置开关")
                    self.onUserRemoved?()
                }
            }
        }

        self.item = item
        itemView = view
        Log.menubar.info("CPU item 已创建，宽度 \(CPUStatusItemView.fixedWidth, format: .fixed(precision: 1)) pt")
    }

    private func remove() {
        guard let item else { return }
        visibilityObservation?.invalidate()
        visibilityObservation = nil
        item.expandedInterfaceDelegate = nil
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
        itemView = nil
        Log.menubar.info("CPU item 已移除")
    }
}
