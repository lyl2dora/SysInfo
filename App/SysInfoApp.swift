// SysInfo 入口（D23，M0 设计 §6）：AppKit `@main` + LSUIElement，没有 Dock 图标。
//
// 负责创建 AppSettings、MetricStore、SamplingEngine、StatusItemController、PanelController、
// SettingsController、ThrottleMonitor，并把它们连起来：
// - 引擎事件在 MainActor 上写入 MetricStore（采样本身在引擎的私有串行队列上，D03、D23）；
// - 设置变化 → 菜单栏 item 显示与否、采样间隔、自动降频开关；
// - 重新打开 app（applicationShouldHandleReopen）、启动时没有任何启用的 item → 打开设置窗口；
// - 启动、唤醒时让引擎重新自检（K19）。

import AppKit
import SysCollectors
import SysModel
import SysStore
import OSLog

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options = LaunchOptions.current

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
    private var services: CPUServices!

    /// 把 SIGTERM（`make stop`、登出、`kill`）转成正常的 `NSApp.terminate`，让 applicationWillTerminate 有机会收尾。
    private var terminateSignalSource: DispatchSourceSignal?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
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
        let history = Self.makeHistory(
            engine: engine, appSampler: collectors.compactMap { $0 as? AppSampler }.first,
            factoryDefaults: options.factoryDefaults, settings: settings)
        self.history = history
        let services = CPUServices(collectors: CPUCollectors(collectors), history: history, engine: engine)
        self.services = services
        services.diagnostics.requestSelfTests = { Task { await engine.runSelfTests() } }
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
        statusItems.onUserRemoved = { [weak settings] in settings?.cpuItemVisible = false }
        panel.statusItems = statusItems
        self.panel = panel
        self.statusItems = statusItems

        let settingsWindow = SettingsController(
            settings: settings, store: store, throttle: throttle, engine: engine, services: services)
        settingsWindow.install()
        panel.onOpenSettings = { [weak self] in self?.openSettings() }
        self.settingsWindow = settingsWindow

        settings.onChange = { [weak self] in self?.applySettings() }
        applySettings()
        throttle.start()

        Log.app.info(
            "启动完成：\(BuildInfo.displayName, privacy: .public) \(BuildInfo.version, privacy: .public) (\(BuildInfo.build, privacy: .public))，选项 \(String(describing: self.options), privacy: .public)"
        )

        if options.openPanel {
            panel.showWithoutSession()
        }
        if options.openSettings || !settings.cpuItemVisible {
            settingsWindow.open(page: options.settingsPage.flatMap(SettingsPage.init(rawValue:)))
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Log.app.info("重新打开 app，打开设置窗口")
        openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        Log.app.info("即将退出")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
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

    /// 设置变化后同步到各组件（幂等）。
    private func applySettings() {
        store.colorThresholds = settings.cpuColorThresholds
        let topology = CPUTopologyService.shared.current
        statusItems.update(
            visible: settings.cpuItemVisible, interval: settings.cpuInterval,
            configuration: CPUStatusItemConfiguration(
                style: settings.menuBarCPUStyle, showsLabel: settings.menuBarCPULabel,
                coloring: settings.menuBarCPUColoring, levelCount: max(topology?.perfLevels.count ?? 2, 1),
                coreCount: topology?.logicalCPUCount ?? SystemInfo.maxLogicalCPUCount ?? 8))
        throttle.automatic = settings.autoThrottle
        let configuration = HistoryRecorder.Configuration(
            recordSystem: settings.historyCPUEnabled, recordApps: settings.historyAppsEnabled,
            highPrecision: settings.historyHighPrecision)
        Task { [history] in await history?.setConfiguration(configuration) }
        panel?.updateDemands()
    }

    /// 打开历史库并开始记录（D30）。`--factory-defaults` 时用临时目录，测量不污染日用数据（CPU 模块设计 §6）。
    private static func makeHistory(
        engine: SamplingEngine, appSampler: AppSampler?, factoryDefaults: Bool, settings: AppSettings
    ) -> HistoryRecorder? {
        let url: URL?
        if factoryDefaults {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("SysInfo-factory-\(getpid())", isDirectory: true)
                .appendingPathComponent("History.sqlite")
        } else {
            url = HistoryStore.defaultURL(bundleIdentifier: BuildInfo.bundleIdentifier)
        }
        guard let url else { return nil }
        do {
            let store = try HistoryStore(url: url)
            let recorder = HistoryRecorder(
                store: store, engine: engine, appSampler: appSampler,
                configuration: .init(
                    recordSystem: settings.historyCPUEnabled, recordApps: settings.historyAppsEnabled,
                    highPrecision: settings.historyHighPrecision))
            Task { await recorder.start() }
            return recorder
        } catch {
            Log.app.error("打开历史库失败，本次不记录历史：\(String(describing: error), privacy: .public)")
            return nil
        }
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
