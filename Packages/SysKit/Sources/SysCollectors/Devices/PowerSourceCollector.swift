// 电源设备采集器 `devices.sources`（电源设备设计 §4.2，D84）：inline 通道。
//
// - 不额外读 IOPS：取 `PowerSourceMonitor` 事件驱动维护的快照，输出主 UPS 的电量、剩余时间与供电状态；
//   输入电压由 `devices.ups`（HID）输出：IOPS 的电压由电池供电时是电池电压（2026-10-19 放电实测）；
// - 没有 UPS 时不输出样本（设备不存在，不是不可用）；
// - 自检：公开快照可读（必需）；私有按类型接口可用（提示：不可用时配件不显示）。复检时强制重建一次快照。

import Foundation
import IOKit.ps
internal import CSysPrivate
import SysModel

public final class PowerSourceCollector: Collector {
    public static let collectorID: CollectorID = "devices.sources"
    public static let dataPath = "IOPS（公开列表 + 私有 IOPSCopyPowerSourcesByType，事件驱动）"

    public var id: CollectorID { Self.collectorID }

    private let monitor: PowerSourceMonitor

    public init(monitor: PowerSourceMonitor = .shared) {
        self.monitor = monitor
    }

    public func selfTest() -> SelfTestResult {
        monitor.start()
        let publicReadable = IOPSCopyPowerSourcesInfo() != nil
        let snapshot = monitor.refresh()
        return SelfTestResult(
            checks: [
                SelfTestCheck(name: "devices.sources.public", passed: publicReadable, detail: "devices=\(snapshot.devices.count)"),
                SelfTestCheck(
                    name: "devices.sources.accessories", passed: snapshot.accessoriesAvailable,
                    detail: csp_ps_available() != 0 ? "IOPSCopyPowerSourcesByType" : "IOPSCopyPowerSourcesByType not resolved",
                    severity: .advisory),
            ], dataPath: Self.dataPath)
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        monitor.start()
        let snapshot = monitor.latest
        return CollectorOutput(
            samples: Self.samples(snapshot, at: time), status: snapshot.accessoriesAvailable ? .ok : .degraded,
            dataPath: Self.dataPath)
    }

    public func resetBaseline() {}

    /// 主 UPS 的样本；没有 UPS 时为空。
    static func samples(_ snapshot: PowerDeviceSnapshot, at time: SampleTime) -> [Sample] {
        guard let ups = snapshot.primaryUPS else { return [] }
        var samples: [Sample] = []
        samples.append(
            ups.level.map { Sample(id: .upsCharge, value: $0, time: time) }
                ?? .unavailable(.upsCharge, reason: .readFailed("no capacity"), at: time))
        samples.append(
            ups.timeToEmpty.map { Sample(id: .upsRuntime, value: $0, time: time) }
                ?? .unavailable(.upsRuntime, reason: .readFailed("no time to empty"), at: time))
        if ups.powerSourceState != .unknown {
            samples.append(Sample(id: .upsOnBattery, value: ups.isOnBattery ? 1 : 0, time: time))
        } else {
            samples.append(.unavailable(.upsOnBattery, reason: .readFailed("unknown power source state"), at: time))
        }
        return samples
    }
}
