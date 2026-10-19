// 设置窗口（M0 设计 §6，D23、D25）。
//
// - 用 `NSHostingSceneRepresentation` 把 SwiftUI `Settings` 场景挂到 AppKit 生命周期上，
//   打开用它的 `environment.openSettings()`；
// - 窗口打开期间切换为 `.regular` 并激活（有 Dock 图标和主菜单，⌘, ⌘Q 可用），
//   关闭后切回 `.accessory`（与应用活动窗口共用计数，见 ForegroundWindows）；
// - 窗口关闭后把内容换成空视图：设置窗口不在屏幕上时不读 MetricStore，不随每个 tick 重算；
// - 诊断页可见期间登记「诊断页」需求（app.self，1 s），用于显示本进程开销。

import AppKit
import Observation
import SwiftUI
import SysCollectors
import SysModel
import OSLog

/// 设置侧栏的页面，顺序按 D25、D27；各页职责按 D41（模块页放本模块的一切，菜单栏与历史页只放容器级设置与只读总览）。
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case general
    case menuBar
    case cpu
    case power
    case memory
    case storage
    case gpu
    case network
    case devices
    case appActivity
    case widgets
    case history
    case privacy
    case diagnostics
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "通用")
        case .menuBar: String(localized: "菜单栏")
        case .cpu: String(localized: "CPU")
        case .power: String(localized: "功耗与散热")
        case .memory: String(localized: "内存")
        case .storage: String(localized: "存储")
        case .gpu: String(localized: "GPU 与加速器")
        case .network: String(localized: "网络")
        case .devices: String(localized: "电源设备")
        case .appActivity: String(localized: "应用活动")
        case .widgets: String(localized: "桌面小组件")
        case .history: String(localized: "历史与导出")
        case .privacy: String(localized: "隐私")
        case .diagnostics: String(localized: "诊断")
        case .about: String(localized: "关于")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .menuBar: "menubar.rectangle"
        case .cpu: "cpu"
        case .power: "bolt"
        case .memory: "memorychip"
        case .storage: "internaldrive"
        case .gpu: "cpu.fill"
        case .network: "network"
        case .devices: "minus.plus.batteryblock"
        case .appActivity: "list.bullet.rectangle"
        case .widgets: "widget.small"
        case .history: "clock.arrow.circlepath"
        case .privacy: "hand.raised"
        case .diagnostics: "stethoscope"
        case .about: "info.circle"
        }
    }
}

@Observable
final class SettingsState {
    var selection: SettingsPage? = .general
    /// 设置窗口是否在屏幕上。为 false 时窗口内容换成空视图。
    var isWindowOpen = false
    /// 侧栏收起为只显示图标的窄栏（不写偏好，重开 app 恢复展开）。
    var sidebarCompact = false
    /// 红绿灯在窗口里的位置（从窗口顶边、左边量起）：页头与它竖直居中对齐，收起时页头从它右边开始（D81）。
    var trafficLights = CGRect(x: 7, y: 9, width: 70, height: 16)
}

final class SettingsController {
    let state = SettingsState()

    private let settings: AppSettings
    private let store: MetricStore
    private let throttle: ThrottleMonitor
    private let engine: SamplingEngine
    private let services: AppServices
    private let diagnosticsDemand: DemandSlot
    /// 电源设备诊断读数（D84）：有 UPS 时 HID 每 2 s，同面板。
    private let devicesDemand: DemandSlot
    /// 诊断页的逐核频率（cpu.freq.cores，2 s，CPU 模块设计 §7.4）。
    private let coreFrequencyDemand: DemandSlot
    /// 诊断页的功耗数据（power.*，2 s）与展开的传感器目录（sensors.catalog，5 s）。
    private let powerDemand: DemandSlot
    private let catalogDemand: DemandSlot
    private let memoryDemand: DemandSlot
    private let bandwidthDemand: DemandSlot
    /// GPU 诊断读数（D57）：温度、ANE、媒体每 2 s；展开「GPU 细节」时另采 gpu.diagnostics。
    private let gpuDemand: DemandSlot
    private let gpuDetailsDemand: DemandSlot
    /// 诊断页的存储读数（读写 2 s、SMART 2 s 读全部盘、容量 10 s，存储模块设计 §6.4）。
    private let storageDemand: DemandSlot
    private let storageCapacityDemand: DemandSlot
    /// 诊断页的网络读数（原始计数每 2 s，网络模块设计 §7）。
    private let networkDemand: DemandSlot

    private var openSettingsAction: (() -> Void)?
    private weak var window: NSWindow?
    private var windowObservers: [any NSObjectProtocol] = []

    init(
        settings: AppSettings, store: MetricStore, throttle: ThrottleMonitor, engine: SamplingEngine, services: AppServices
    ) {
        self.settings = settings
        self.store = store
        self.throttle = throttle
        self.engine = engine
        self.services = services
        self.diagnosticsDemand = DemandSlot(engine: engine)
        self.devicesDemand = DemandSlot(engine: engine)
        self.coreFrequencyDemand = DemandSlot(engine: engine)
        self.powerDemand = DemandSlot(engine: engine)
        self.catalogDemand = DemandSlot(engine: engine)
        self.memoryDemand = DemandSlot(engine: engine)
        self.bandwidthDemand = DemandSlot(engine: engine)
        self.gpuDemand = DemandSlot(engine: engine)
        self.gpuDetailsDemand = DemandSlot(engine: engine)
        self.storageDemand = DemandSlot(engine: engine)
        self.storageCapacityDemand = DemandSlot(engine: engine)
        self.networkDemand = DemandSlot(engine: engine)
    }

    /// 把 Settings 场景挂到 NSApplication 上（启动时调用一次）。
    func install() {
        let context = SettingsContext(
            settings: settings, store: store, throttle: throttle, state: state, services: services, engine: engine,
            windowAttached: { [weak self] window in self?.attach(window) },
            diagnosticsVisibilityChanged: { [weak self] visible in self?.setDiagnosticsVisible(visible) },
            catalogVisibilityChanged: { [weak self] visible in self?.setCatalogVisible(visible) },
            bandwidthVisibilityChanged: { [weak self] visible in self?.setBandwidthVisible(visible) },
            gpuDetailsVisibilityChanged: { [weak self] visible in self?.setGPUDetailsVisible(visible) },
            runSelfTests: { [engine] in
                Task { await engine.runSelfTests() }
            })
        let scene = NSHostingSceneRepresentation {
            Settings {
                SettingsRootView(context: context)
            }
        }
        NSApp.addSceneRepresentation(scene)
        openSettingsAction = { scene.environment.openSettings() }
    }

    /// 打开设置窗口；可以指定页面。
    func open(page: SettingsPage? = nil) {
        if let page {
            state.selection = page
        }
        Log.settings.info("打开设置窗口（\(page?.rawValue ?? "上次的页面", privacy: .public)）")
        state.isWindowOpen = true
        ForegroundWindows.retain("settings")
        openSettingsAction?()
        NSApp.activate()
        bringWindowToFront()
    }

    // MARK: - 私有

    private func attach(_ window: NSWindow) {
        guard window !== self.window else { return }
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        self.window = window
        // Settings 场景默认是偏好设置式的高工具栏，侧栏按钮会落在标题下方一整行里。改成统一样式的透明标题栏（D81）：
        // 标题栏横贯整个窗口，只有红绿灯；侧栏开关和靠左的页名是内容栏顶部的页头，与红绿灯同一行。
        // 内容延伸到标题栏下，滚上去时由页面自绘的渐隐带保证页头可读：自排的侧栏布局拿不到系统的边缘效果
        // （不透明标题栏会出现色带和分隔线，隐藏工具栏背景则效果也没了，2026-10-18 实测）。
        window.toolbarStyle = .unified
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        updateTrafficLights(in: window)
        // SwiftUI 会在挂接之后再改一次工具栏，红绿灯随之移动：布局完成后再量一次。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak window] in
            MainActor.assumeIsolated {
                if let self, let window { self.updateTrafficLights(in: window) }
            }
        }
        windowObservers = [
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowWillClose() }
            }
        ]
        Log.settings.info("设置窗口已挂接")
        if state.isWindowOpen {
            bringWindowToFront()
        }
    }

    /// 读红绿灯三个按钮的并集（窗口坐标，换成从左上角量起）。
    private func updateTrafficLights(in window: NSWindow) {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let frames = buttons.compactMap { type -> CGRect? in
            guard let button = window.standardWindowButton(type), let superview = button.superview else { return nil }
            return superview.convert(button.frame, to: nil)
        }
        guard let union = frames.dropFirst().reduce(frames.first, { $0?.union($1) }) else {
            Log.settings.info("红绿灯：读不到按钮（\(frames.count)）")
            return
        }
        let height = window.frame.height
        state.trafficLights = CGRect(x: union.minX, y: height - union.maxY, width: union.width, height: union.height)
        Log.settings.info("红绿灯：\(NSStringFromRect(self.state.trafficLights), privacy: .public)")
    }

    /// 协作式激活（macOS 14 起）下，别的 app 在前台、又不是由用户在本 app 里的操作触发时（例如经命令行
    /// `--open-settings` 启动），`NSApp.activate()` 可能不生效。这时至少把窗口放到最前面，用户点一下即可激活。
    private func bringWindowToFront() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        // 激活是异步的，稍后再记录结果。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                Log.settings.info("设置窗口已在最前；app \(NSApp.isActive ? "已激活" : "未激活（别的 app 在前台，点一下窗口即可激活）", privacy: .public)")
            }
        }
    }

    private func windowWillClose() {
        Log.settings.info("设置窗口关闭，切回 accessory")
        state.isWindowOpen = false
        setDiagnosticsVisible(false)
        ForegroundWindows.release("settings")
    }

    private func setDiagnosticsVisible(_ visible: Bool) {
        let demand = visible && state.isWindowOpen
            ? Demand(collectors: [SelfUsageCollector.collectorID], interval: 1, source: .diagnostics)
            : nil
        diagnosticsDemand.set(demand)
        coreFrequencyDemand.set(
            visible && state.isWindowOpen
                ? Demand(collectors: [CoreFrequencyCollector.collectorID], interval: 2, source: .diagnostics) : nil)
        // 遥测对账要整机功率每秒一次；原始功率键、最热点、GPU 每 2 s。
        powerDemand.set(
            visible && state.isWindowOpen
                ? Demand(
                    collectors: [PowerRailCollector.collectorID, PowerSensorCollector.collectorID, GPUPowerCollector.collectorID],
                    interval: 1, source: .diagnostics) : nil)
        // 内存诊断读数每 2 s（D49）。
        memoryDemand.set(
            visible && state.isWindowOpen
                ? Demand(collectors: [MemoryCollector.collectorID], interval: 2, source: .diagnostics) : nil)
        let storageVisible = visible && state.isWindowOpen
        storageDemand.set(
            storageVisible
                ? Demand(collectors: [StorageIOCollector.collectorID, SMARTCollector.collectorID], interval: 2, source: .diagnostics)
                : nil)
        storageCapacityDemand.set(
            storageVisible ? Demand(collectors: [StorageCapacityCollector.collectorID], interval: 10, source: .diagnostics) : nil)
        services.storageModel.diagnosticsVisible = storageVisible
        networkDemand.set(
            storageVisible ? Demand(collectors: [NetworkIOCollector.collectorID], interval: 2, source: .diagnostics) : nil)
        let hasUPS = services.devicesModel.snapshot.primaryUPS != nil
        devicesDemand.set(
            storageVisible
                ? Demand(
                    collectors: hasUPS ? [PowerSourceCollector.collectorID, UPSTelemetryCollector.collectorID] : [PowerSourceCollector.collectorID],
                    interval: 2, source: .diagnostics) : nil)
        gpuDemand.set(
            storageVisible
                ? Demand(
                    collectors: [
                        GPUTemperatureCollector.collectorID, GPUAcceleratorCollector.collectorID, MediaEngineCollector.collectorID,
                    ], interval: 2, source: .diagnostics) : nil)
        if !visible {
            catalogDemand.set(nil)
            bandwidthDemand.set(nil)
            gpuDetailsDemand.set(nil)
        }
    }

    /// GPU 细节（PMP 带宽等）只在诊断页展开它时采（D57 G10），每 2 s。
    private func setGPUDetailsVisible(_ visible: Bool) {
        gpuDetailsDemand.set(
            visible && state.isWindowOpen
                ? Demand(collectors: [GPUDiagnosticsCollector.collectorID], interval: 2, source: .diagnostics) : nil)
    }

    /// DRAM 带宽只在诊断页展开它时采（D49 M3），每 2 s。
    private func setBandwidthVisible(_ visible: Bool) {
        bandwidthDemand.set(
            visible && state.isWindowOpen
                ? Demand(collectors: [DRAMBandwidthCollector.collectorID], interval: 2, source: .diagnostics) : nil)
    }

    private func setCatalogVisible(_ visible: Bool) {
        catalogDemand.set(
            visible && state.isWindowOpen
                ? Demand(collectors: [SensorCatalog.collectorID], interval: 5, source: .diagnostics) : nil)
    }
}

/// 设置窗口内容需要的依赖和回调。
struct SettingsContext {
    let settings: AppSettings
    let store: MetricStore
    let throttle: ThrottleMonitor
    let state: SettingsState
    let services: AppServices
    let engine: SamplingEngine
    let windowAttached: (NSWindow) -> Void
    let diagnosticsVisibilityChanged: (Bool) -> Void
    let catalogVisibilityChanged: (Bool) -> Void
    let bandwidthVisibilityChanged: (Bool) -> Void
    let gpuDetailsVisibilityChanged: (Bool) -> Void
    let runSelfTests: () -> Void
}
