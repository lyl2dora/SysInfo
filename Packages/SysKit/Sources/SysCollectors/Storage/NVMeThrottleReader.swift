// NVMe 节流计数（存储模块设计 §6.4，D54：只进诊断页）：私有 IOReport「NVMe」组（经 IOReportHub）。
//
// - `BW Limits` 子组的 `TierN BW Scale Factor`：绝对值，<100 疑为节流（调研报告 §1.4 标 ⚠️）；
// - `Time weighted throttle statistics` 子组：`Total time elapsed` 与 `TierN Throttle Time` 的增量；
//   外置 Intel 盘上 Throttle Time 等于总时长（2026-09-28 实测），含义未经验证，原样列出。
// - 驱动名里的 registry ID 对应到物理盘（`DiskInventory.diskKey(registryID:)`）。
// 只在诊断页展开时由调用方在后台定时读取，不经调度器。

import Foundation
import Synchronization
import SysModel

public struct NVMeThrottleReading: Hashable, Sendable {
    /// 对应的物理盘；对应不上时为 nil。
    public var disk: DiskKey?
    public var driver: String
    public var subgroup: String
    public var channel: String
    /// 当前绝对值。
    public var value: Int64
    /// 与上一次读取的差；第一次读取时为 nil。
    public var delta: Int64?
}

public final class NVMeThrottleReader: Sendable {
    private struct State {
        var subscription: IOReportSubscription?
        var previous: [String: Int64] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// 读一次。IOReport 不可用或没有 NVMe 组时返回 nil。
    public func read() -> [NVMeThrottleReading]? {
        state.withLock { s in
            if s.subscription == nil {
                s.subscription = IOReportHub.shared.makeSubscription(selecting: [
                    (group: "NVMe", include: { $0.key.subgroup == "BW Limits" || $0.key.subgroup == "Time weighted throttle statistics" })
                ])
            }
            guard let values = s.subscription?.snapshot() else { return nil }
            var out: [NVMeThrottleReading] = []
            var current: [String: Int64] = [:]
            for value in values {
                let driver = value.driverName ?? "?"
                let id = "\(driver)|\(value.key.subgroup)|\(value.key.name)"
                current[id] = value.integerValue
                out.append(
                    NVMeThrottleReading(
                        disk: Self.registryID(in: driver).flatMap { DiskInventory.shared.diskKey(registryID: $0) },
                        driver: Self.driverClass(driver), subgroup: value.key.subgroup, channel: value.key.name,
                        value: value.integerValue, delta: s.previous[id].map { value.integerValue - $0 }))
            }
            s.previous = current
            return out
        }
    }

    /// 驱动名里的 registry ID：「IONVMeBlockStorageDevice <id 0x100000ece>」→ 0x100000ece。
    static func registryID(in driver: String) -> UInt64? {
        guard let range = driver.range(of: "<id 0x") else { return nil }
        let hex = driver[range.upperBound...].prefix { $0.isHexDigit }
        return UInt64(hex, radix: 16)
    }

    /// 去掉 registry ID 的驱动名（诊断页显示用，不含设备标识）。
    static func driverClass(_ driver: String) -> String {
        driver.components(separatedBy: " <").first ?? driver
    }
}
