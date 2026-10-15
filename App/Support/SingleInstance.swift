// 单实例（D48）：日用版全局只跑一个；Debug 版可以多开，但只有主实例写历史库。
//
// - 判定用数据目录下的 flock 锁（`InstanceLock`），跨副本、跨启动方式都有效，崩溃后自动释放。
// - 日用版（`zone.lyl.sysinfo`）的第二个实例：发分布式通知让主实例打开设置窗口（等同「重新打开 app」），
//   然后自己退出。
// - 其余（`.dev`，包括 measure 脚本用的 Release 配置 .dev 构建）：不退出，作为从实例运行，
//   历史库改用按 pid 区分的临时目录，避免两个实例同时写一个库。
// - `--single-instance`：在 Debug 版上按日用版的规则执行，供截图自查与测试，不必动日用版。
// - 打不开锁文件时无法判定，按主实例继续运行并记日志，不因此拒绝启动。

import AppKit
import OSLog
import SysStore

@MainActor
final class SingleInstance {
    enum Role: Equatable {
        case primary
        /// 允许多开时的从实例：照常运行，但不写共享的历史库。
        case secondary
    }

    private(set) var role: Role = .primary
    private var lock: InstanceLock?
    private var observer: NSObjectProtocol?

    /// 主实例收到「另一个实例想启动」时调用（打开设置窗口）。
    var onReopenRequest: (() -> Void)?

    private let enforce: Bool
    private let notificationName: Notification.Name

    init(bundleIdentifier: String, enforce: Bool) {
        self.enforce = enforce
        notificationName = Notification.Name("\(bundleIdentifier).reopen")
        guard let url = InstanceLock.defaultURL(bundleIdentifier: bundleIdentifier) else { return }
        let lock = InstanceLock(url: url)
        switch lock.tryLock() {
        case .acquired:
            self.lock = lock
            role = .primary
        case .heldByOther:
            role = .secondary
        case .failed(let code):
            Log.app.error("打不开单实例锁文件（errno \(code, privacy: .public)），按主实例继续")
            role = .primary
        }
    }

    /// 是否应该退出：强制单例且锁被别的实例持有。
    var shouldExit: Bool { enforce && role == .secondary }

    /// 通知主实例打开设置窗口。只在 `shouldExit` 时调用。
    func notifyPrimary() {
        DistributedNotificationCenter.default().postNotificationName(
            notificationName, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// 主实例监听重开请求。
    func startListening() {
        guard role == .primary, observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: notificationName, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.app.info("另一个实例请求启动，打开设置窗口")
                self?.onReopenRequest?()
            }
        }
    }

    /// 日用版的 Bundle ID（D16）。
    static let releaseBundleIdentifier = "zone.lyl.sysinfo"
}
