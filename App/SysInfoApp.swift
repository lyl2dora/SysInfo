// SysInfo 入口（D23，M0 设计 §6）：AppKit `@main` + LSUIElement，没有 Dock 图标。
//
// 负责创建 AppSettings、MetricStore、SamplingEngine、StatusItemController、PanelController、
// SettingsController、ThrottleMonitor，并把它们连起来：
// - 引擎事件在 MainActor 上写入 MetricStore（采样本身在引擎的私有串行队列上，D03、D23）；
// - 设置变化 → 菜单栏 item 显示与否、采样间隔、自动降频开关；
// - 重新打开 app（applicationShouldHandleReopen）、启动时没有任何启用的 item → 打开设置窗口；
// - 启动、唤醒时让引擎重新自检（K19）；
// - 单实例（D48）：日用版的第二个实例通知主实例打开设置窗口后退出；Debug 版的从实例不写共享历史库。

import AppKit
import SysCollectors
import SysModel
import SysStore
import OSLog

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options = LaunchOptions.current
    private let instance: SingleInstance

    private var settings: AppSettings!
    private var store: MetricStore!
    private var engine: SamplingEngine!
    private var throttle: ThrottleMonitor!
    private var statusItems: StatusItemController!
    private var panel: PanelController!
    private var settingsWindow: SettingsController!
    private var eventPump: Task<Void, Never>?
    /// 历史记录器（D30）；打开历史库失败时为 nil，app 照常运行。
    private var history: HistoryRecorder?
    /// 临时历史库所在目录（`--factory-defaults`、Debug 从实例）；退出时删除。
    private var temporaryHistoryDirectory: URL?
    private var services: AppServices!
    private var appActivity: AppActivityWindowController!

    /// 把 SIGTERM（`make stop`、登出、`kill`）转成正常的 `NSApp.terminate`，让 applicationWillTerminate 有机会收尾。
    private var terminateSignalSource: DispatchSourceSignal?

    override init() {
        let options = LaunchOptions.current
        instance = SingleInstance(
            bundleIdentifier: BuildInfo.bundleIdentifier,
            enforce: BuildInfo.bundleIdentifier == SingleInstance.releaseBundleIdentifier || options.singleInstance)
        super.init()
    }

    static func main() {
        let delegate = AppDelegate()
        // D48：在创建 NSApplication 之前判定，第二个日用版实例不出现任何菜单栏 item 或窗口。
        if delegate.instance.shouldExit {
            Log.app.info("已有实例在运行，请它打开设置窗口后退出")
            delegate.instance.notifyPrimary()
            exit(0)
        }
        let app = NSApplication.shared
        app.delegate = delegate  // delegate 是弱引用，由下面的 withExtendedLifetime 保活
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminateSignalHandler()
        NSApp.mainMenu = MainMenu.make(
            target: self, about: #selector(showAbout(_:)), settings: #selector(showSettings(_:)))

        let settings = AppSettings(defaults: options.factoryDefaults ? nil : .standard)
        // 盘的键（D54）：盐存在本 app 的 defaults 里，历史里同一块盘的键跨重启不变；
        // `--factory-defaults` 不读写偏好，用进程内随机盐（采集层的默认）。必须在创建采集器之前。
        if !options.factoryDefaults {
            DiskIdentity.configure(salt: DiskIdentity.loadOrCreateSalt(in: .standard))
        }
        let store = MetricStore()
        let collectors = StandardCollectors.make()
        let engine = SamplingEngine(collectors: collectors)
        self.settings = settings
        self.store = store
        self.engine = engine

        Task { [weak self] in
            await engine.runSelfTests()  // K19：启动时自检
            self?.applySettings()  // 自检刷新了拓扑：按档柱的个数随之确定
        }
        noteSystemBuild()

        let throttle = ThrottleMonitor(engine: engine, automatic: settings.autoThrottle)
        let power = PowerCollectors(collectors)
        if instance.role == .secondary {
            Log.app.info("另一个实例持有单实例锁：本实例作为从实例运行，历史库改用临时目录（D48）")
        }
        let temporaryName = options.factoryDefaults ? "factory" : instance.role == .secondary ? "secondary" : nil
        temporaryHistoryDirectory = temporaryName.map(Self.temporaryHistoryDirectory)
        let storage = StorageCollectors(collectors)
        let history = Self.makeHistory(
            engine: engine, appSampler: collectors.compactMap { $0 as? AppSampler }.first,
            assertions: collectors.compactMap { $0 as? PowerAssertionCollector }.first, power: power, storage: storage,
            powerSources: collectors.contains { $0 is PowerSourceCollector } ? PowerSourceMonitor.shared : nil,
            temporaryDirectory: temporaryHistoryDirectory, settings: settings)
        self.history = history
        let services = AppServices(
            collectors: CPUCollectors(collectors), power: power, memory: MemoryCollectors(collectors), storage: storage,
            gpu: GPUCollectors(collectors), network: NetworkCollectors(collectors), devices: DevicesCollectors(collectors),
            history: history, engine: engine)
        // 电源设备（D84）：事件驱动的快照，app 启动即跟随（面板切换器、widget 要知道有没有设备）。
        services.devicesModel.start()
        self.services = services
        services.diagnostics.requestSelfTests = { Task { await engine.runSelfTests() } }
        // 自动更新（D76）：只有日用版启用；到期才联网。
        let updater = Updater(settings: settings)
        services.updater = updater
        updater.start()
        // 应用活动窗口（D67）：模型挂在 services 上，引擎的 coalition 结果经 services.handle 转给它。
        let appActivityModel = AppActivityModel(services: services, settings: settings, engine: engine)
        services.appActivity = appActivityModel
        let appActivity = AppActivityWindowController(model: appActivityModel, store: store, services: services, settings: settings)
        self.appActivity = appActivity
        services.openAppActivity = { [weak self] sort, range in self?.openAppActivity(sort: sort, range: range) }
        eventPump = Task {
            for await event in await engine.events() {
                store.apply(event)
                services.handle(event)
            }
        }
        throttle.onWake = {
            Task { await engine.runSelfTests() }  // K19：唤醒时复检
            Task { await history?.noteWake() }
        }
        throttle.onSleep = {
            Task { await history?.flush() }  // D30：睡眠前立即提交
        }
        self.throttle = throttle

        let panel = PanelController(store: store, engine: engine, services: services, settings: settings)
        let statusItems = StatusItemController(store: store, engine: engine)
        statusItems.expandedInterfaceDelegate = panel
        statusItems.onUserRemoved = { [weak settings] widget in settings?.setVisible(widget, false) }
        statusItems.onUserRemovedMerged = { [weak settings] in settings?.menuBarMerged = false }
        panel.statusItems = statusItems
        self.panel = panel
        self.statusItems = statusItems

        let settingsWindow = SettingsController(
            settings: settings, store: store, throttle: throttle, engine: engine, services: services)
        settingsWindow.install()
        panel.onOpenSettings = { [weak self] in self?.openSettings() }
        services.openUpdateSettings = { [weak self] in self?.openSettings(page: .general) }
        self.settingsWindow = settingsWindow

        instance.onReopenRequest = { [weak self] in self?.openSettings() }
        instance.startListening()

        if options.merged { settings.menuBarMerged = true }
        settings.onChange = { [weak self] in self?.applySettings() }
        // 盘插拔、容量组变化：widget 的绑定（内置盘、启动组）要重新解析。
        services.storageModel.onStructureChange = { [weak self] in self?.applySettings() }
        // 接口增减、主接口切换：网速 widget 绑定的接口是物理还是虚拟，要重新解析。
        services.networkModel.onStructureChange = { [weak self] in self?.applySettings() }
        // 电源设备出现或全部消失：面板切换器里的「电源」tab 随之出现或隐藏（D84 PD5）；
        // UPS / 内置电池的有无（去抖后）决定电源设备 widget 的出厂开关（D89）。第一次布局前已经有值。
        settings.devicePresenceDefault = services.devicesModel.hasUPSOrBattery
        services.devicesModel.onPresenceChange = { [weak self] in
            guard let self else { return }
            self.settings.devicePresenceDefault = self.services.devicesModel.hasUPSOrBattery
            self.applySettings()
        }
        applySettings()
        // 桌面小组件（D90）：有组件放置时才采样、写快照。
        let widgets = WidgetSnapshotWriter(store: store, settings: settings, history: history, engine: engine)
        services.widgets = widgets
        widgets.start()
        throttle.start()

        Log.app.info(
            "启动完成：\(BuildInfo.displayName, privacy: .public) \(BuildInfo.version, privacy: .public) (\(BuildInfo.build, privacy: .public))，选项 \(String(describing: self.options), privacy: .public)"
        )

        panel.state.expandDetailsInitially = options.expandDetails
        if let tab = options.panelTab.flatMap(PanelTab.init(rawValue:)) { panel.state.selectedTab = tab }
        if options.openPanel {
            panel.showWithoutSession()
        }
        if let index = options.storageDetailIndex {
            openStorageDetail(index: index, attempt: 0)
        }
        if let route = options.panelRoute {
            openPanelRoute(route, attempt: 0)
        }
        if let range = options.appActivityRange {
            appActivity.open(range: AppActivityRange(rawValue: range) ?? .now)
            if let index = options.appActivitySelectIndex { selectAppActivityRow(index, attempt: 0) }
        }
        if options.openSettings || settings.visibleWidgets.isEmpty {
            settingsWindow.open(page: options.settingsPage.flatMap(SettingsPage.init(rawValue:)))
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Log.app.info("重新打开 app，打开设置窗口")
        openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        services?.widgets?.appWillTerminate()
        eventPump?.cancel()
        // D30：退出前立即提交。applicationWillTerminate 返回后进程就结束，所以同步等它完成（最多 2 s）。
        if let history {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await history.stop()
                done.signal()
            }
            _ = done.wait(timeout: .now() + 2)
        }
        if let temporaryHistoryDirectory { try? FileManager.default.removeItem(at: temporaryHistoryDirectory) }
        Log.app.info("即将退出")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// `--storage-detail=<n>`：等物理盘清单出来（启动自检之后），打开第 n 块盘的详情页。
    private func openStorageDetail(index: Int, attempt: Int) {
        let disks = services.storageModel.inventory.disks
        guard index < disks.count else {
            if attempt < 50 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.openStorageDetail(index: index, attempt: attempt + 1)
                }
            }
            return
        }
        panel.state.path = [.disk(disks[index].key)]
    }

    /// `--app-activity-select=<n>`：等表格有数据后选中第 n 行（截图用）。
    private func selectAppActivityRow(_ index: Int, attempt: Int) {
        let rows = appActivity.model.visibleRows
        guard index < rows.count else {
            if attempt < 100 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.selectAppActivityRow(index, attempt: attempt + 1)
                }
            }
            return
        }
        appActivity.model.selection = rows[index].id
    }

    /// `--panel-route=<页>`：等清单出来后推入二级页（D64，截图用）。
    private func openPanelRoute(_ name: String, attempt: Int) {
        let inventory = services.storageModel.inventory
        let route: PanelRoute? =
            switch name {
            case "virtual": services.networkModel.state.virtual.isEmpty ? nil : .virtualInterfaces
            case "external": inventory.disks.contains { $0.location == .external } ? .externalDisks : nil
            case "raid": inventory.raidSets.first.map { .raidMembers($0.key) }
            default: nil
            }
        guard let route else {
            if attempt < 50 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.openPanelRoute(name, attempt: attempt + 1)
                }
            }
            return
        }
        panel.state.path = [route]
    }

    // MARK: - 菜单动作

    @objc func showSettings(_ sender: Any?) {
        openSettings()
    }

    @objc func showAbout(_ sender: Any?) {
        openSettings(page: .about)
    }

    // MARK: - 私有

    /// 打开设置窗口的公共入口：⌘,、「关于」菜单、重新打开 app、面板顶栏的设置按钮都走这里。
    /// 锚在 item 下方的面板在 popUpMenu 层级，会盖住设置窗口，item 的 session 高亮也还在，所以先关掉它；
    /// 固定的浮窗是用户主动留下的，保留。
    private func openSettings(page: SettingsPage? = nil) {
        panel.dismissAnchored()
        settingsWindow.open(page: page)
    }

    /// 打开应用活动窗口（D67）。锚在 item 下方的面板会盖住窗口，先关掉它；固定的浮窗保留。
    private func openAppActivity(sort: AppActivityColumn?, range: AppActivityRange?) {
        panel.dismissAnchored()
        appActivity.open(sort: sort, range: range)
    }

    /// 设置变化后同步到各组件（幂等）。
    private func applySettings() {
        let settings: AppSettings = self.settings
        services?.widgets?.settingsChanged()
        // 没有风扇的机型不出现风扇 widget（风扇在自检时发现；启动自检结束后会再调一次这里）。
        let hasFans = services?.power.hasFans ?? false
        let widgets = settings.visibleWidgets.filter { $0 != .fan || hasFans }
        // D65 MG1：第一次切换到合并模式时，按各 item 当时在屏幕上的位置定初始顺序（赋值会再触发一次本函数，幂等）。
        if settings.menuBarMerged, settings.menuBarMergedOrder.isEmpty, !statusItems.screenOrder().isEmpty {
            settings.menuBarMergedOrder = statusItems.screenOrder()
            return
        }
        let ordered = settings.menuBarMerged ? settings.mergedWidgets(from: widgets) : widgets
        statusItems.update(
            ordered.map { StatusItemConfiguration(widget: $0, settings: settings) }, merged: settings.menuBarMerged,
            separator: settings.menuBarMergedSeparator, intervals: { settings.interval(for: $0) },
            latencyInterval: settings.latencyInterval)
        // 延迟目标（D61）：关闭时不发包。
        services?.network.latency?.setTargets(settings.latencyTargets ?? .none)
        // SMART 焦点盘（D55）：只每次读盘温 widget 绑定的盘；「所有盘最高温」时读全部。
        if let storageModel = services?.storageModel {
            if widgets.contains(.diskTemperature) {
                storageModel.widgetFocus =
                    settings.diskTemperatureTarget == .hottest
                    ? nil : Set([storageModel.resolveDisk(settings.diskTemperatureTarget)].compactMap { $0 })
            } else {
                storageModel.widgetFocus = []
            }
        }
        throttle.automatic = settings.autoThrottle
        let configuration = Self.historyConfiguration(settings)
        Task { [history] in await history?.setConfiguration(configuration) }
        panel?.syncMergedState()
        panel?.updateDemands()
        services?.appActivity?.settingsChanged()
    }

    private static func historyConfiguration(_ settings: AppSettings) -> HistoryRecorder.Configuration {
        HistoryRecorder.Configuration(
            recordSystem: settings.historyCPUEnabled, recordApps: settings.historyAppsEnabled,
            highPrecision: settings.historyHighPrecision, recordPower: settings.historyPowerEnabled,
            recordEnergy: settings.historyEnergyEnabled, recordMemory: settings.historyMemoryEnabled,
            recordStorage: settings.historyStorageEnabled, recordGPU: settings.historyGPUEnabled,
            recordNetwork: settings.historyNetworkEnabled, recordDevices: settings.historyDevicesEnabled)
    }

    /// 打开历史库并开始记录（D30）。`--factory-defaults` 时用临时目录，测量不污染日用数据（CPU 模块设计 §6）；
    /// Debug 版的从实例同样用临时目录（`SysInfo-secondary-<pid>`），不与主实例同写一个库（D48）。退出时删除临时目录。
    private static func makeHistory(
        engine: SamplingEngine, appSampler: AppSampler?, assertions: PowerAssertionCollector?, power: PowerCollectors,
        storage: StorageCollectors, powerSources: PowerSourceMonitor?, temporaryDirectory: URL?, settings: AppSettings
    ) -> HistoryRecorder? {
        let url: URL?
        if let temporaryDirectory {
            url = temporaryDirectory.appendingPathComponent("History.sqlite")
        } else {
            url = HistoryStore.defaultURL(bundleIdentifier: BuildInfo.bundleIdentifier)
        }
        guard let url else { return nil }
        do {
            let store = try HistoryStore(url: url)
            let recorder = HistoryRecorder(
                store: store, engine: engine, appSampler: appSampler, assertions: assertions, powerSources: powerSources,
                power: .init(ledger: power.ledger, pmgr: power.pmgr), storageCapacity: storage.capacity,
                configuration: historyConfiguration(settings))
            Task { await recorder.start() }
            return recorder
        } catch {
            Log.app.error("打开历史库失败，本次不记录历史：\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func temporaryHistoryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SysInfo-\(name)-\(getpid())", isDirectory: true)
    }

    /// K19：记录系统 build 号；与上次运行不同时写日志（启动自检已覆盖复检）。
    private func noteSystemBuild() {
        let key = "diagnostics.lastSystemBuild"
        let current = Self.systemBuild() ?? "?"
        guard !options.factoryDefaults else { return }
        let previous = UserDefaults.standard.string(forKey: key)
        if previous != current {
            Log.app.info("系统 build 号变化：\(previous ?? "（首次运行）", privacy: .public) → \(current, privacy: .public)")
            UserDefaults.standard.set(current, forKey: key)
        }
    }

    private static func systemBuild() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func installTerminateSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                NSApp.terminate(nil)
            }
        }
        source.resume()
        terminateSignalSource = source
    }
}
