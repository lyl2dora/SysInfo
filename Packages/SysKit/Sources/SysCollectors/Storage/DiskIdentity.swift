// 盘与组的稳定键（存储模块设计 §3.1）：本地加盐 SHA-256 的前 6 字节。
//
// - 序列号、阵列 UUID、容器 UUID 只在本进程里参与哈希，不出进程、不进日志与历史库（CLAUDE.md）；
// - 盐由调用方配置（app 存在自己的 defaults，CLI 存在自己的 defaults）；没配置时用进程内随机盐，
//   键只在本次运行内稳定（`--factory-defaults`、测试）。采集层本身不读写任何偏好。

import CryptoKit
import Foundation
import Synchronization
import SysModel

public enum DiskIdentity {
    private static let configuredSalt = Mutex<Data?>(nil)
    private static let ephemeralSalt = DiskIdentity.randomSalt()

    /// 盐的长度，字节。
    public static let saltLength = 16

    /// 配置盐。要在创建采集器之前调用；之后再改会让同一块盘换一个键（历史里变成另一块盘）。
    public static func configure(salt: Data) {
        configuredSalt.withLock { $0 = salt }
    }

    /// 生成一份新盐（交给调用方持久化）。
    public static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: saltLength)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        return Data(bytes)
    }

    /// 从 defaults 读盐，没有就生成一份写回（app 与 CLI 共用的小工具；采集层自己不调用）。
    public static func loadOrCreateSalt(in defaults: UserDefaults, key: String = "storage.identitySalt") -> Data {
        if let data = defaults.data(forKey: key), data.count == saltLength { return data }
        let salt = randomSalt()
        defaults.set(salt, forKey: key)
        return salt
    }

    static var salt: Data { configuredSalt.withLock { $0 } ?? ephemeralSalt }

    /// 由若干组成部分算键（组成部分之间用 0x1F 分隔，避免拼接歧义）。
    public static func key(_ components: [String], salt: Data? = nil) -> DiskKey {
        var hasher = SHA256()
        hasher.update(data: salt ?? Self.salt)
        for component in components {
            hasher.update(data: Data([0x1F]))
            hasher.update(data: Data(component.utf8))
        }
        let digest = hasher.finalize()
        let hex = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return DiskKey(rawValue: hex)
    }
}
