// 登录会话与显示器的当前状态：降频信号（K20，M0 设计 §5.3）的初始值。
//
// 锁屏、显示器睡眠的通知只报告变化；app 在锁屏或显示器已睡眠时启动（经 ssh、make run 远程启动，
// 将来作为登录项在会话切换时启动）就收不到「已锁屏」这一次，所以启动时要主动读一次。

import CoreGraphics

public enum SessionState: Sendable {
    /// 未公开的会话字典键（D05）：没有公开 API 能读锁屏状态。它出现在公开函数 `CGSessionCopyCurrentDictionary`
    /// 的返回值里：锁屏时为 1，未锁屏时不存在（macOS 27 实测未锁屏时没有这个键）。只在这里读，读不到按未锁屏处理。
    static let screenIsLockedKey = "CGSSessionScreenIsLocked"

    /// 当前 GUI 会话是否锁屏；拿不到会话字典（例如进程不在 GUI 会话里，如 ssh 下的 sysinfo-cli）时为 nil。
    public static func isScreenLocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return screenLocked(inSessionDictionary: session)
    }

    /// 按会话字典判断是否锁屏（纯函数，便于单测）。键不存在或值不是真值时视为未锁屏。
    static func screenLocked(inSessionDictionary session: [String: Any]) -> Bool {
        switch session[screenIsLockedKey] {
        case let value as Bool: value
        case let value as Int: value != 0
        default: false
        }
    }

    /// 所有在线显示器（含镜像、睡眠中的）是否都在睡眠；没有在线显示器或读取失败时为 nil。
    public static func areDisplaysAsleep() -> Bool? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success, count > 0 else { return nil }
        return displays.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
    }
}
