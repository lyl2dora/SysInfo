// CPU 负载采集器 `cpu.load`（M0 设计 §5.1）。
//
// 数据源：`host_processor_info(PROCESSOR_CPU_LOAD_INFO)`，读每核 tick 并差分；总占用取所有核之和。
// 不用 `HOST_CPU_LOAD_INFO`：它受全系统节流，其他监控 app 在跑时会拿到无标记的缓存值（调研报告 §0-7）。
// M0 只输出总占用和每核占用，不做 perflevel 或簇的映射（那是 CPU 模块的能力边界）。

import Darwin
import Synchronization
import SysModel

public final class CPULoadCollector: Collector {
    public static let collectorID: CollectorID = "cpu.load"
    public static let dataPath = "host_processor_info(PROCESSOR_CPU_LOAD_INFO)"

    /// 连续读到陈旧数据达到这个次数时，状态降为 degraded。
    static let degradedAfterConsecutiveStale = 3

    public var id: CollectorID { Self.collectorID }

    private struct State {
        var baseline: [CoreTicks]?
        var staleCount: UInt64 = 0
        var consecutiveStale = 0
        /// nil 表示还没自检过；此时照常采样。
        var selfTestPassed: Bool?
        /// 按核数缓存的每核 MetricID，避免每个 tick 重新拼字符串。
        var coreMetricIDs: [MetricID] = []
    }

    private let state = Mutex(State())

    public init() {}

    // MARK: - Collector

    public func selfTest() -> SelfTestResult {
        var checks: [SelfTestCheck] = []
        let first = Self.readTicks()
        switch first {
        case .failure(let error):
            checks.append(SelfTestCheck(name: "cpu.load.read", passed: false, detail: error.description))
        case .success(let ticks):
            checks.append(SelfTestCheck(name: "cpu.load.read", passed: true, detail: "\(ticks.count) CPU"))

            let logical = SystemInfo.logicalCPUCount
            checks.append(
                SelfTestCheck(
                    name: "cpu.load.coreCount",
                    passed: logical == ticks.count,
                    detail: "host_processor_info=\(ticks.count), hw.logicalcpu=\(logical.map(String.init) ?? "?")"))

            let zeroCores = ticks.indices.filter { ticks[$0].total == 0 }
            checks.append(
                SelfTestCheck(
                    name: "cpu.load.nonzero",
                    passed: zeroCores.isEmpty,
                    detail: zeroCores.isEmpty ? "all cores > 0" : "zero ticks: cpu\(zeroCores)"))

            switch Self.readTicks() {
            case .failure(let error):
                checks.append(SelfTestCheck(name: "cpu.load.monotonic", passed: false, detail: error.description))
            case .success(let again):
                let regressed = zip(ticks, again).enumerated().filter { !$0.element.1.isMonotonic(since: $0.element.0) }
                let passed = again.count == ticks.count && regressed.isEmpty
                checks.append(
                    SelfTestCheck(
                        name: "cpu.load.monotonic",
                        passed: passed,
                        detail: passed
                            ? "2 reads non-decreasing"
                            : "count \(ticks.count)->\(again.count), regressed cpu\(regressed.map(\.offset))"))
            }
        }

        let result = SelfTestResult(checks: checks, dataPath: Self.dataPath)
        state.withLock {
            // 从失败恢复：失败期间没有更新基线，旧基线不可用
            if $0.selfTestPassed == false, result.passed {
                $0.baseline = nil
                $0.consecutiveStale = 0
            }
            $0.selfTestPassed = result.passed
        }
        return result
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        let reading = Self.readTicks()
        return state.withLock { state in
            switch reading {
            case .failure(let error):
                return output(
                    Self.unavailableSamples(.readFailed(error.description), state: &state, count: nil, at: time),
                    .unavailable, state)

            case .success(let ticks):
                if state.selfTestPassed == false {
                    return output(
                        Self.unavailableSamples(.selfTestFailed(), state: &state, count: ticks.count, at: time),
                        .unavailable, state)
                }
                guard let baseline = state.baseline else {
                    state.baseline = ticks
                    return output([], .ok, state)
                }

                switch CPUTickMath.delta(previous: baseline, current: ticks) {
                case .stale:
                    state.staleCount += 1
                    state.consecutiveStale += 1
                    let status: CollectorStatus =
                        state.consecutiveStale >= Self.degradedAfterConsecutiveStale ? .degraded : .ok
                    return output([], status, state)

                case .coreCountChanged:
                    state.baseline = ticks
                    state.consecutiveStale = 0
                    return output([], .ok, state)

                case .usage(let usage):
                    state.baseline = ticks
                    state.consecutiveStale = 0
                    let samples = Self.samples(for: usage, state: &state, at: time)
                    return output(samples, usage.droppedCores > 0 ? .degraded : .ok, state)
                }
            }
        }
    }

    public func resetBaseline() {
        state.withLock {
            $0.baseline = nil
            $0.consecutiveStale = 0
        }
    }

    // MARK: - 读取

    struct ReadError: Error, CustomStringConvertible {
        var description: String
    }

    /// 读一次每核 tick。返回的数组由内核分配，读完立即 `vm_deallocate`。
    static func readTicks() -> Result<[CoreTicks], ReadError> {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else {
            return .failure(ReadError(description: "host_processor_info kr=\(kr)"))
        }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let stride = Int(CPU_STATE_MAX)
        guard cpuCount > 0, Int(infoCount) == Int(cpuCount) * stride else {
            return .failure(ReadError(description: "unexpected layout: cpus=\(cpuCount), count=\(infoCount)"))
        }

        var ticks: [CoreTicks] = []
        ticks.reserveCapacity(Int(cpuCount))
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * stride
            ticks.append(
                CoreTicks(
                    user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                    system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                    idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                    nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
        }
        return .success(ticks)
    }

    // MARK: - 组装样本

    private func output(_ samples: [Sample], _ status: CollectorStatus, _ state: State) -> CollectorOutput {
        CollectorOutput(samples: samples, status: status, dataPath: Self.dataPath, staleCount: state.staleCount)
    }

    private static func coreIDs(count: Int, state: inout State) -> [MetricID] {
        if state.coreMetricIDs.count != count {
            state.coreMetricIDs = (0..<count).map(MetricID.cpuUsageCore)
        }
        return state.coreMetricIDs
    }

    private static func samples(for usage: CPUUsage, state: inout State, at time: SampleTime) -> [Sample] {
        let ids = coreIDs(count: usage.perCore.count, state: &state)
        var samples: [Sample] = []
        samples.reserveCapacity(usage.perCore.count + 1)

        if let total = usage.total {
            samples.append(
                Sample(
                    id: .cpuUsageTotal, value: total,
                    quality: usage.droppedCores > 0 ? .estimated : .measured, time: time))
        } else {
            samples.append(
                .unavailable(.cpuUsageTotal, reason: .counterReset("all cores dropped"), at: time))
        }

        for (index, core) in usage.perCore.enumerated() {
            switch core {
            case .ratio(let ratio):
                samples.append(Sample(id: ids[index], value: ratio, time: time))
            case .counterReset:
                samples.append(.unavailable(ids[index], reason: .counterReset(), at: time))
            case .noElapsedTicks:
                samples.append(.unavailable(ids[index], reason: .noElapsedTicks(), at: time))
            }
        }
        return samples
    }

    /// 总占用和每核（核数已知时）全部标为不可用。
    private static func unavailableSamples(
        _ reason: UnavailableReason, state: inout State, count: Int?, at time: SampleTime
    ) -> [Sample] {
        let ids = count.map { coreIDs(count: $0, state: &state) } ?? state.coreMetricIDs
        return [.unavailable(.cpuUsageTotal, reason: reason, at: time)]
            + ids.map { .unavailable($0, reason: reason, at: time) }
    }
}
