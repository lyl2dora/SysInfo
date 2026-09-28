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
        let engine = SamplingEngine(collectors: StandardCollectors.make())
        self.settings = settings
        self.store = store
        self.engine = engine

        eventPump = Task {
            for await event in await engine.events() {
                store.apply(event)
            }
        }
        Task {
            await engine.runSelfTests()  // K19：启动时自检
        }
        noteSystemBuild()

        let throttle = ThrottleMonitor(engine: engine, automatic: settings.autoThrottle)
        throttle.onWake = {
            Task { await engine.runSelfTests() }  // K19：唤醒时复检
        }
        self.throttle = throttle

        let panel = PanelController(store: store, engine: engine)
        let statusItems = StatusItemController(store: store, engine: engine)
        statusItems.expandedInterfaceDelegate = panel
        statusItems.onUserRemoved = { [weak settings] in settings?.cpuItemVisible = false }
        panel.statusItems = statusItems
        self.panel = panel
        self.statusItems = statusItems

        let settingsWindow = SettingsController(settings: settings, store: store, throttle: throttle, engine: engine)
        settingsWindow.install()
        panel.onOpenSettings = { [weak settingsWindow] in settingsWindow?.open() }
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
            settingsWindow.open()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Log.app.info("重新打开 app，打开设置窗口")
        settingsWindow.open()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventPump?.cancel()
        Log.app.info("即将退出")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - 菜单动作

    @objc func showSettings(_ sender: Any?) {
        settingsWindow.open()
    }

    @objc func showAbout(_ sender: Any?) {
        settingsWindow.open(page: .about)
    }

    // MARK: - 私有

    /// 设置变化后同步到各组件（幂等）。
    private func applySettings() {
        statusItems.update(visible: settings.cpuItemVisible, interval: settings.cpuInterval)
        throttle.automatic = settings.autoThrottle
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
