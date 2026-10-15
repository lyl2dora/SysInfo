// sysctl 读取的小封装（公开 API）。

import Darwin
import Foundation

/// 硬件与系统信息，全部在运行时读取，不写死任何机型的值（D20）。
public enum SystemInfo: Sendable {
    /// 当前电源管理模式下可用的逻辑核数（`hw.logicalcpu`）；读取失败时为 nil。
    public static var logicalCPUCount: Int? {
        sysctlInt32("hw.logicalcpu").map(Int.init)
    }

    /// 本次开机最多可能可用的逻辑核数（`hw.logicalcpu_max`）；读取失败时为 nil。
    /// `host_processor_info` 返回的是全部已注册的处理器，核数对照要用它，而不是 `hw.logicalcpu`。
    public static var maxLogicalCPUCount: Int? {
        sysctlInt32("hw.logicalcpu_max").map(Int.init)
    }

    /// 机型标识，例如 `Mac17,16`（`hw.model`）。它标识机型而不是某台设备，可以写进对照记录。
    public static var modelIdentifier: String? {
        sysctlString("hw.model")
    }

    /// 系统 build 号，例如 `26A428`（`kern.osversion`）。K19 的复检时机之一是它发生变化。
    public static var osBuild: String? {
        sysctlString("kern.osversion")
    }

    /// 本次开机的时刻（`kern.boottime`）：PMGR 计数与遥测累加器都从开机起算，开机变了就要作废旧的基线。
    public static var bootTime: Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(boot.tv_sec) + Double(boot.tv_usec) / 1e6)
    }

    static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size else {
            return nil
        }
        return value
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
