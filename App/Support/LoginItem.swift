// 登录项（D75）：用 SMAppService.mainApp 注册开机自启。出厂不注册，由用户在设置「通用」页手动打开。
// 状态以系统为准（每次读 SMAppService），不另存偏好；用户在系统设置里关掉，这里也随之显示关闭。
// 只有从 /Applications 运行的 Release 版可以注册：Debug 版不注册登录项（D16），其他位置的副本注册后路径不稳定。

import AppKit
import Observation
import os
import ServiceManagement

@Observable
final class LoginItemModel {
    enum Availability: Equatable {
        case available
        /// Debug 版（D16）。
        case debugBuild
        /// 不在 /Applications 下运行。
        case notInApplications
        /// 系统从隔离位置运行（App Translocation）：带 quarantine 的 app 没用访达移动过（例如直接在「下载」里打开，
        /// 或用命令行移进「应用程序」），实际路径在 /private/var/folders/…/AppTranslocation/ 下。
        case translocated
    }

    private(set) var status: SMAppService.Status = .notRegistered
    /// 最近一次注册或取消失败的说明；成功后清空。
    private(set) var lastError: String?

    let availability: Availability

    init(bundleURL: URL = Bundle.main.bundleURL) {
        availability = Self.availability(isDebug: BuildInfo.isDebug, bundlePath: bundleURL.resolvingSymlinksInPath().path)
        refresh()
    }

    nonisolated static func availability(isDebug: Bool, bundlePath: String) -> Availability {
        if isDebug { return .debugBuild }
        if isTranslocated(bundlePath) { return .translocated }
        return bundlePath.hasPrefix("/Applications/") ? .available : .notInApplications
    }

    nonisolated static func isTranslocated(_ bundlePath: String) -> Bool {
        bundlePath.contains("/AppTranslocation/")
    }

    /// 开关显示为「开」：已启用，或已注册但还在等用户批准。
    var isOn: Bool { status == .enabled || status == .requiresApproval }

    var requiresApproval: Bool { status == .requiresApproval }

    /// 设置页出现时、app 重新激活时调用：用户可能在系统设置里批准或关掉了。
    func refresh() {
        guard availability == .available else { return }
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        guard availability == .available else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
            Log.settings.info("登录项已\(enabled ? "注册" : "取消", privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            Log.settings.error("登录项\(enabled ? "注册" : "取消", privacy: .public)失败：\(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
