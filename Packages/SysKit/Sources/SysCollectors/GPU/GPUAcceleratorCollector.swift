// ANE 电源状态与 GPU 内存采集器 `gpu.accelerators`（GPU 模块设计 §5，D57 G8、D58）。
//
// 只读 IORegistry（公开 IOKit，未文档化的属性），0.25–0.42 ms/次（GPU 边界稿 §1.6）：
// - `H11ANEIn` 的 `IOPowerManagement.CurrentPowerState`：>0 为上电。上电滞后 0.5–0.8 s，关断滞后 5–6 s（两台一致）；
//   找不到 ANE 节点的芯片不输出 `ane.powered`；
// - AGX（IOAccelerator）`PerformanceStatistics` 的「In use system memory」「Alloc system memory」。
//   同一个字典里的「Device Utilization %」不可靠（多读者互相污染、随提交模式乱跳，D57），这里不读，诊断页另读。

import Foundation
import IOKit
import Synchronization
import SysModel

public final class GPUAcceleratorCollector: Collector {
    public static let collectorID: CollectorID = "gpu.accelerators"
    public static let dataPath = "IORegistry H11ANEIn IOPowerManagement + IOAccelerator PerformanceStatistics"

    public var id: CollectorID { Self.collectorID }

    private struct State {
        var ane: io_service_t = 0
        var accelerator: io_service_t = 0
        var aneClass: String?
        var acceleratorClass: String?
        var exclave = false
    }

    private let state = Mutex(State())

    public init() {}

    deinit {
        state.withLock { s in
            if s.ane != 0 { IOObjectRelease(s.ane) }
            if s.accelerator != 0 { IOObjectRelease(s.accelerator) }
        }
    }

    /// 诊断页：ANE 节点与 AGX 类名；ANE 是否在 Exclave 后面（M5 有 `ANEExclaveProxy`）。
    public var nodes: (ane: String?, accelerator: String?, aneBehindExclave: Bool) {
        state.withLock { ($0.aneClass, $0.acceleratorClass, $0.exclave) }
    }

    public func selfTest() -> SelfTestResult {
        var checks: [SelfTestCheck] = []
        let ane = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("H11ANEIn"))
        let accelerator = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        let exclave = Self.exists("ANEExclaveProxy")
        let power = ane != 0 ? Self.powerState(ane) : nil
        checks.append(
            SelfTestCheck(
                name: "gpu.accelerators.ane", passed: power != nil,
                detail: ane == 0 ? "no H11ANEIn" : "CurrentPowerState \(power.map(String.init) ?? "unreadable")",
                severity: .advisory))
        let memory = accelerator != 0 ? Self.memory(accelerator) : nil
        checks.append(
            SelfTestCheck(
                name: "gpu.accelerators.memory", passed: memory != nil,
                detail: accelerator == 0 ? "no IOAccelerator" : memory == nil ? "PerformanceStatistics unreadable" : "ok",
                severity: .advisory))
        let usable = power != nil || memory != nil
        checks.append(SelfTestCheck(name: "gpu.accelerators.any", passed: usable, detail: usable ? "ok" : "nothing readable"))
        state.withLock { s in
            if s.ane != 0 { IOObjectRelease(s.ane) }
            if s.accelerator != 0 { IOObjectRelease(s.accelerator) }
            s.ane = power != nil ? ane : 0
            s.accelerator = memory != nil ? accelerator : 0
            if power == nil, ane != 0 { IOObjectRelease(ane) }
            if memory == nil, accelerator != 0 { IOObjectRelease(accelerator) }
            s.aneClass = s.ane != 0 ? Self.className(s.ane) : nil
            s.acceleratorClass = s.accelerator != 0 ? Self.className(s.accelerator) : nil
            s.exclave = exclave
        }
        return SelfTestResult(checks: checks, dataPath: Self.dataPath)
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        let (ane, accelerator) = state.withLock { ($0.ane, $0.accelerator) }
        guard ane != 0 || accelerator != 0 else {
            return CollectorOutput(samples: [], status: .unavailable, dataPath: Self.dataPath)
        }
        var samples: [Sample] = []
        var failed = false
        if ane != 0 {
            if let power = Self.powerState(ane) {
                samples.append(Sample(id: .anePowered, value: power > 0 ? 1 : 0, time: time))
            } else {
                samples.append(.unavailable(.anePowered, reason: .readFailed("IOPowerManagement"), at: time))
                failed = true
            }
        }
        if accelerator != 0 {
            if let memory = Self.memory(accelerator) {
                samples.append(Sample(id: .gpuMemoryInUse, value: memory.inUse, time: time))
                samples.append(Sample(id: .gpuMemoryAllocated, value: memory.allocated, time: time))
            } else {
                samples.append(.unavailable(.gpuMemoryInUse, reason: .readFailed("PerformanceStatistics"), at: time))
                samples.append(.unavailable(.gpuMemoryAllocated, reason: .readFailed("PerformanceStatistics"), at: time))
                failed = true
            }
        }
        return CollectorOutput(samples: samples, status: failed ? .degraded : .ok, dataPath: Self.dataPath)
    }

    public func resetBaseline() {}

    // MARK: - IORegistry

    static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func powerState(_ service: io_service_t) -> Int? {
        guard let pm = property(service, "IOPowerManagement") as? [String: Any] else { return nil }
        return (pm["CurrentPowerState"] as? NSNumber)?.intValue
    }

    static func memory(_ service: io_service_t) -> (inUse: Double, allocated: Double)? {
        guard let stats = property(service, "PerformanceStatistics") as? [String: Any],
            let inUse = stats["In use system memory"] as? NSNumber, let allocated = stats["Alloc system memory"] as? NSNumber
        else { return nil }
        return (inUse.doubleValue, allocated.doubleValue)
    }

    /// `PerformanceStatistics` 里的「Device Utilization %」原值（只给诊断页对照，不可靠）。
    static func deviceUtilization(_ service: io_service_t) -> Double? {
        guard let stats = property(service, "PerformanceStatistics") as? [String: Any] else { return nil }
        return (stats["Device Utilization %"] as? NSNumber)?.doubleValue
    }

    static func exists(_ className: String) -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    static func className(_ service: io_service_t) -> String? {
        var name = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(service, &name) == KERN_SUCCESS else { return nil }
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
