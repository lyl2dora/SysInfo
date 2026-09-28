// SysInfo 入口（D23）：AppKit `@main` + LSUIElement，没有 Dock 图标。
//
// 脚手架阶段只负责正常启动和退出；菜单栏 item、面板、设置窗口、采样引擎在 M0 后续阶段接入（M0 设计 §6）。

import AppKit
import OSLog
import SysCollectors

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "zone.lyl.sysinfo",
        category: "app"
    )

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
        logger.info("启动完成，私有层版本 \(PrivateLayer.version, privacy: .public)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("即将退出")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
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
