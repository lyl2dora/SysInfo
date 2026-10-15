// 单实例锁（D48）：同一文件只有一个持有者；持有者释放后可再次获得；目录不存在时自动创建。

import Foundation
import Testing
@testable import SysStore

@Suite struct InstanceLockTests {
    func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("InstanceLockTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("instance.lock")
    }

    @Test func secondHolderIsRejectedUntilFirstReleases() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var first: InstanceLock? = InstanceLock(url: url)
        #expect(first?.tryLock() == .acquired)

        let second = InstanceLock(url: url)
        #expect(second.tryLock() == .heldByOther)

        first = nil  // 关闭文件描述符即释放锁（与进程退出、崩溃相同）
        #expect(second.tryLock() == .acquired)
        #expect(first == nil)
    }

    @Test func lockFileRecordsHolderPID() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let lock = InstanceLock(url: url)
        #expect(lock.tryLock() == .acquired)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == "\(getpid())\n")
    }

    @Test func unwritableLocationReportsFailure() {
        let lock = InstanceLock(url: URL(fileURLWithPath: "/System/SysInfoInstanceLockTest/instance.lock"))
        guard case .failed = lock.tryLock() else {
            Issue.record("系统只读卷上不应拿到锁")
            return
        }
    }
}
