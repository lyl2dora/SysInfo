// CPU 杂项采集器 `cpu.misc`（CPU 模块设计 §5.6，D29）。
//
// - 负载均值：`getloadavg()`。不用 `HOST_LOAD_INFO`、processor_set 的 load_average（D29）；
// - 任务与线程数：`processor_set_statistics(PROCESSOR_SET_LOAD_INFO)`，只取这两项；
// - 中断：`host_processor_info(PROCESSOR_CPU_STAT64)` 全部核求和后差分，拆成 IPI、定时器、其余三项的每秒次数。
//   irq 计数包含 IPI 和定时器，「其余」是扣掉两者后的余量（边界稿 §8 C8）。计数器回退按复位处理，丢弃这一段；
// - 热状态：`ProcessInfo.thermalState`；热压力：notify `com.apple.system.thermalpressurelevel`
//   （`notify_register_check` 的共享内存读取，不经 IPC）。两者都是读缓存值，没有额外开销。
//
// 自检（K19）：必需项是三处读取都成功、中断布局为「核数 × 20 个 int」；提示项是中断计数两次读数单调不减。

import Darwin
import Foundation
import Synchronization
import SysModel
import notify

/// 全部核的中断计数之和。
struct InterruptCounts: Hashable, Sendable {
    var irq: UInt64
    var ipi: UInt64
    var timer: UInt64
}

/// 中断计数差分的结果（纯函数，便于单测）。
enum InterruptRates: Equatable, Sendable {
    case rates(ipi: Double, timer: Double, other: Double)
    /// 有计数器回退：按复位处理，丢弃这一段。
    case counterReset

    static func compute(previous: InterruptCounts, current: InterruptCounts, elapsedNanos: UInt64) -> InterruptRates? {
        guard elapsedNanos > 0 else { return nil }
        guard current.irq >= previous.irq, current.ipi >= previous.ipi, current.timer >= previous.timer else {
            return .counterReset
        }
        let seconds = Double(elapsedNanos) / 1e9
        let irq = current.irq - previous.irq
        let ipi = current.ipi - previous.ipi
        let timer = current.timer - previous.timer
        // irq 应包含 IPI 和定时器；余量为负说明口径变了，不硬算，丢弃这一段。
        guard irq >= ipi + timer else { return .counterReset }
        return .rates(
            ipi: Double(ipi) / seconds, timer: Double(timer) / seconds, other: Double(irq - ipi - timer) / seconds)
    }
}

public final class CPUMiscCollector: Collector {
    public static let collectorID: CollectorID = "cpu.misc"
    public static let dataPath =
        "getloadavg + processor_set_statistics(LOAD_INFO) + host_processor_info(CPU_STAT64) + thermalState"

    public var id: CollectorID { Self.collectorID }

    private struct State {
        var previous: (counts: InterruptCounts, nanos: UInt64)?
        var usable: Bool?
        var warnings = false
    }

    private let state = Mutex(State())
    /// notify 的 check token；注册失败时为 nil，热压力不可用。
    private let pressureToken: Int32?

    public init() {
        var token: Int32 = 0
        pressureToken =
            notify_register_check("com.apple.system.thermalpressurelevel", &token) == NOTIFY_STATUS_OK ? token : nil
    }

    deinit {
        if let pressureToken { notify_cancel(pressureToken) }
    }

    // MARK: - Collector

    public func selfTest() -> SelfTestResult {
        var checks: [SelfTestCheck] = []
        let load = Self.readLoadAverage()
        checks.append(
            SelfTestCheck(
                name: "cpu.misc.loadavg", passed: load != nil,
                detail: load.map { "1m=\(($0.0 * 100).rounded() / 100)" } ?? "getloadavg failed"))
        let counts = Self.readTaskCounts()
        checks.append(
            SelfTestCheck(
                name: "cpu.misc.tasks", passed: counts != nil && (counts?.tasks ?? 0) > 0,
                detail: counts.map { "tasks=\($0.tasks) threads=\($0.threads)" } ?? "processor_set_statistics failed"))
        let first = Self.readInterrupts()
        switch first {
        case .failure(let error):
            checks.append(SelfTestCheck(name: "cpu.misc.irq", passed: false, detail: error.description))
        case .success(let a):
            checks.append(SelfTestCheck(name: "cpu.misc.irq", passed: true, detail: "irq=\(a.irq) ipi=\(a.ipi) timer=\(a.timer)"))
            let again = try? Self.readInterrupts().get()
            let monotonic = again.map { $0.irq >= a.irq && $0.ipi >= a.ipi && $0.timer >= a.timer } ?? false
            checks.append(
                SelfTestCheck(
                    name: "cpu.misc.irq.monotonic", passed: monotonic, detail: monotonic ? "2 reads non-decreasing" : "regressed",
                    severity: .advisory))
        }
        checks.append(
            SelfTestCheck(
                name: "cpu.misc.thermalPressure", passed: pressureToken != nil,
                detail: pressureToken != nil ? "notify_register_check ok" : "notify_register_check failed",
                severity: .advisory))
        let result = SelfTestResult(checks: checks, dataPath: Self.dataPath)
        state.withLock {
            if $0.usable == false, result.isUsable { $0.previous = nil }
            $0.usable = result.isUsable
            $0.warnings = !result.warnings.isEmpty
        }
        return result
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        if state.withLock({ $0.usable }) == false {
            let reason = UnavailableReason.selfTestFailed()
            return CollectorOutput(
                samples: Self.allIDs.map { .unavailable($0, reason: reason, at: time) }, status: .unavailable,
                dataPath: Self.dataPath)
        }
        var samples: [Sample] = []
        var failed = false

        if let load = Self.readLoadAverage() {
            samples.append(Sample(id: .cpuLoadAverage1, value: load.0, time: time))
            samples.append(Sample(id: .cpuLoadAverage5, value: load.1, time: time))
            samples.append(Sample(id: .cpuLoadAverage15, value: load.2, time: time))
        } else {
            failed = true
            for id in [MetricID.cpuLoadAverage1, .cpuLoadAverage5, .cpuLoadAverage15] {
                samples.append(.unavailable(id, reason: .readFailed("getloadavg"), at: time))
            }
        }

        if let counts = Self.readTaskCounts() {
            samples.append(Sample(id: .cpuTaskCount, value: Double(counts.tasks), time: time))
            samples.append(Sample(id: .cpuThreadCount, value: Double(counts.threads), time: time))
        } else {
            failed = true
            samples.append(.unavailable(.cpuTaskCount, reason: .readFailed("processor_set_statistics"), at: time))
            samples.append(.unavailable(.cpuThreadCount, reason: .readFailed("processor_set_statistics"), at: time))
        }

        samples.append(Sample(id: .cpuThermalState, value: Double(ProcessInfo.processInfo.thermalState.rawValue), time: time))
        if let pressureToken {
            var value: UInt64 = 0
            if notify_get_state(pressureToken, &value) == NOTIFY_STATUS_OK {
                samples.append(Sample(id: .cpuThermalPressure, value: Double(value), time: time))
            } else {
                samples.append(.unavailable(.cpuThermalPressure, reason: .readFailed("notify_get_state"), at: time))
            }
        } else {
            samples.append(.unavailable(.cpuThermalPressure, reason: .readFailed("notify_register_check"), at: time))
        }

        let interrupts = Self.readInterrupts()
        let rateIDs: [MetricID] = [.cpuInterruptIPIRate, .cpuInterruptTimerRate, .cpuInterruptOtherRate]
        state.withLock { s in
            switch interrupts {
            case .failure(let error):
                failed = true
                s.previous = nil
                for id in rateIDs { samples.append(.unavailable(id, reason: .readFailed(error.description), at: time)) }
            case .success(let counts):
                defer { s.previous = (counts, time.monotonicNanos) }
                guard let previous = s.previous, time.monotonicNanos > previous.nanos else { return }  // 建立基线
                switch InterruptRates.compute(
                    previous: previous.counts, current: counts, elapsedNanos: time.monotonicNanos - previous.nanos)
                {
                case .rates(let ipi, let timer, let other):
                    samples.append(Sample(id: .cpuInterruptIPIRate, value: ipi, time: time))
                    samples.append(Sample(id: .cpuInterruptTimerRate, value: timer, time: time))
                    samples.append(Sample(id: .cpuInterruptOtherRate, value: other, time: time))
                case .counterReset:
                    for id in rateIDs { samples.append(.unavailable(id, reason: .counterReset(), at: time)) }
                case nil:
                    break
                }
            }
        }
        let warnings = state.withLock { $0.warnings }
        let status: CollectorStatus = failed ? .degraded : (warnings ? .degraded : .ok)
        return CollectorOutput(samples: samples, status: status, dataPath: Self.dataPath)
    }

    public func resetBaseline() {
        state.withLock { $0.previous = nil }
    }

    // MARK: - 读取

    static let allIDs: [MetricID] = [
        .cpuLoadAverage1, .cpuLoadAverage5, .cpuLoadAverage15, .cpuTaskCount, .cpuThreadCount,
        .cpuInterruptIPIRate, .cpuInterruptTimerRate, .cpuInterruptOtherRate, .cpuThermalState, .cpuThermalPressure,
    ]

    static func readLoadAverage() -> (Double, Double, Double)? {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, 3) == 3 else { return nil }
        return (values[0], values[1], values[2])
    }

    /// 默认处理器集的名字端口，只取一次（与 `CPULoadCollector.host` 同理，避免 urefs 累积）。
    private static let defaultProcessorSet: processor_set_name_t? = {
        var pset = processor_set_name_t()
        return processor_set_default(CPULoadCollector.host, &pset) == KERN_SUCCESS ? pset : nil
    }()

    static func readTaskCounts() -> (tasks: Int, threads: Int)? {
        guard let pset = defaultProcessorSet else { return nil }
        var info = processor_set_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<processor_set_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                processor_set_statistics(pset, PROCESSOR_SET_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return (Int(info.task_count), Int(info.thread_count))
    }

    /// `processor_cpu_stat64` 每核 20 个 int（10 个 64 位计数器，4 字节对齐）。
    static let stat64IntsPerCPU = 20

    static func readInterrupts() -> Result<InterruptCounts, CPULoadCollector.ReadError> {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(CPULoadCollector.host, PROCESSOR_CPU_STAT64, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else {
            return .failure(.init(description: "host_processor_info(CPU_STAT64) kr=\(kr)"))
        }
        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(bitPattern: info),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        guard cpuCount > 0, Int(infoCount) == Int(cpuCount) * stat64IntsPerCPU else {
            return .failure(.init(description: "unexpected layout: cpus=\(cpuCount), count=\(infoCount)"))
        }
        func u64(_ index: Int) -> UInt64 {
            UInt64(UInt32(bitPattern: info[index])) | (UInt64(UInt32(bitPattern: info[index + 1])) << 32)
        }
        var total = InterruptCounts(irq: 0, ipi: 0, timer: 0)
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * stat64IntsPerCPU
            total.irq &+= u64(base)
            total.ipi &+= u64(base + 2)
            total.timer &+= u64(base + 4)
        }
        return .success(total)
    }
}
