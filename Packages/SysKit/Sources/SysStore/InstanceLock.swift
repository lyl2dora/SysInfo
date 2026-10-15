// 单实例锁（D48）：数据目录下的锁文件 + flock(LOCK_EX | LOCK_NB)。
//
// - 跨副本有效：/Applications 与 build/ 下的两份 app、`open -n`、直接执行二进制，都锁同一个文件；
//   LaunchServices 只按路径去重，拦不住这些情况。
// - 进程退出或崩溃时由内核释放，不会留下需要清理的陈旧锁。
// - flock 锁属于「打开的文件描述」，同一进程里再 open 一次也会冲突，单测可以直接在进程内验证。
// 文件描述符在进程生命周期内一直持有，不主动关闭；不随 exec 继承（O_CLOEXEC）。

import Darwin
import Foundation

public final class InstanceLock: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// 拿到了锁：本进程是主实例。
        case acquired
        /// 锁被其他实例持有。
        case heldByOther
        /// 打不开锁文件（目录不可写等），errno 附上；调用方按「无法判定」处理。
        case failed(Int32)
    }

    public let url: URL
    private let fd: Int32

    /// 尝试加锁。返回的实例持有文件描述符；`.acquired` 时必须保活到进程结束。
    public init(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    public func tryLock() -> Outcome {
        guard fd >= 0 else { return .failed(errno) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            // 写入 pid 只为排查方便；判定只看锁本身。
            let text = "\(getpid())\n"
            _ = ftruncate(fd, 0)
            _ = text.withCString { pwrite(fd, $0, strlen($0), 0) }
            return .acquired
        }
        let code = errno
        return code == EWOULDBLOCK ? .heldByOther : .failed(code)
    }

    /// `~/Library/Application Support/<bundle id>/instance.lock`，与历史库同一目录（D16 隔离 Debug 与 Release）。
    public static func defaultURL(bundleIdentifier: String) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("instance.lock")
    }
}
