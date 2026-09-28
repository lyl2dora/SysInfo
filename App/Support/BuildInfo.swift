// 版本信息（K30）：「关于」页显示版本号、build 号；Debug 版另显示 git 短哈希。

import Foundation

nonisolated enum BuildInfo {
    static var displayName: String {
        string(for: "CFBundleDisplayName") ?? string(for: "CFBundleName") ?? "SysInfo"
    }

    static var version: String { string(for: "CFBundleShortVersionString") ?? "?" }

    /// build 号 = `git rev-list --count HEAD`，由 Makefile 注入。
    static var build: String { string(for: "CFBundleVersion") ?? "?" }

    /// git 短哈希，由 Makefile 经 `SYSINFO_GIT_COMMIT` 注入 Info.plist；工作区有未提交改动时带 `-dirty`。
    static var gitCommit: String? {
        guard let value = string(for: "SysInfoGitCommit"), !value.isEmpty, value != "unknown" else { return nil }
        return value
    }

    static var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "?" }

    static var isDebug: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    private static func string(for key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
