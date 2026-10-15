// CPU 负载采集器 `cpu.load`（M0 设计 §5.1）。
//
// 数据源：`host_processor_info(PROCESSOR_CPU_LOAD_INFO)`，读每核 tick 并差分；总占用取所有核之和。
// 不用 `HOST_CPU_LOAD_INFO`：它受全系统节流，其他监控 app 在跑时会拿到无标记的缓存值（调研报告 §0-7）。
// CPU 模块（设计 §5.3）在同一次读数上另外输出用户/系统、每簇、每档的占用；簇和档来自 `CPUTopologyService`，
// 拓扑降级时只出能确定的那一层（clustersOnly 不出每档，coresOnly 两者都不出）。
//
// 自检（K19，D24 修订：按通道逐项判定）：
// - 必需：能读到、返回的布局是「核数 × CPU_STATE_MAX」。不通过时整个数据源不可用；
// - 提示：核数与 `hw.logicalcpu_max` 一致、每个核的计数器非零、两次读数单调不减、拓扑判定成立。不通过时照常出数，
//   状态降为 degraded；有问题的核在采样时由差分逐个标为不可用（回退或没有前进），总占用标为估算。
//   自检同时刷新拓扑（启动、唤醒、build 变化即重新发现，K19）。

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
        /// 必需的自检项是否全部通过；nil 表示还没自检过，此时照常采样。
        var selfTestUsable: Bool?
        /// 有提示项没通过：照常出数，但状态至少为 degraded。
        var selfTestWarnings = false
        /// 按核数缓存的每核 MetricID，避免每个 tick 重新拼字符串。
        var coreMetricIDs: [MetricID] = []
    }

    private let state = Mutex(State())

    /// 读每核 tick 的函数；测试时可以换成假数据。
    typealias TickReader = @Sendable () -> Result<[CoreTicks], ReadError>

    private let readTicks: TickReader
    private let maxLogicalCPUCount: @Sendable () -> Int?
    /// 当前拓扑（采样时读）；nil 表示还没发现，只出整机和每核。
    private let topology: @Sendable () -> CPUTopology?
    /// 重新发现拓扑（自检时调用）；nil 表示不做拓扑（测试）。
    private let refreshTopology: (@Sendable () -> CPUTopology)?

    public convenience init() {
        let service = CPUTopologyService.shared
        self.init(
            readTicks: { CPULoadCollector.readTicks() }, maxLogicalCPUCount: { SystemInfo.maxLogicalCPUCount },
            topology: { service.current }, refreshTopology: { service.refresh() })
    }

    init(
        readTicks: @escaping TickReader, maxLogicalCPUCount: @escaping @Sendable () -> Int?,
        topology: @escaping @Sendable () -> CPUTopology? = { nil },
        refreshTopology: (@Sendable () -> CPUTopology)? = nil
    ) {
        self.readTicks = readTicks
        self.maxLogicalCPUCount = maxLogicalCPUCount
        self.topology = topology
        self.refreshTopology = refreshTopology
    }

    // MARK: - Collector

    public func selfTest() -> SelfTestResult {
        var checks: [SelfTestCheck] = []
        let first = readTicks()
        switch first {
        case .failure(let error):
            checks.append(SelfTestCheck(name: "cpu.load.read", passed: false, detail: error.description))
        case .success(let ticks):
            checks.append(SelfTestCheck(name: "cpu.load.read", passed: true, detail: "\(ticks.count) CPU"))

            // host_processor_info 返回全部已注册的处理器，对照值用 hw.logicalcpu_max
            // （hw.logicalcpu 是「当前电源管理模式下可用」的核数，可能更少）。
            let logicalMax = maxLogicalCPUCount()
            checks.append(
                SelfTestCheck(
                    name: "cpu.load.coreCount",
                    passed: logicalMax == ticks.count,
                    detail:
                        "host_processor_info=\(ticks.count), hw.logicalcpu_max=\(logicalMax.map(String.init) ?? "?")",
                    severity: .advisory))

            let zeroCores = ticks.indices.filter { ticks[$0].total == 0 }
            checks.append(
                SelfTestCheck(
                    name: "cpu.load.nonzero",
                    passed: zeroCores.isEmpty,
                    detail: zeroCores.isEmpty ? "all cores > 0" : "zero ticks: cpu\(zeroCores)",
                    severity: .advisory))

            switch readTicks() {
            case .failure(let error):
                checks.append(
                    SelfTestCheck(
                        name: "cpu.load.monotonic", passed: false, detail: error.description, severity: .advisory))
            case .success(let again):
                let regressed = zip(ticks, again).enumerated().filter { !$0.element.1.isMonotonic(since: $0.element.0) }
                let passed = again.count == ticks.count && regressed.isEmpty
                checks.append(
                    SelfTestCheck(
                        name: "cpu.load.monotonic",
                        passed: passed,
                        detail: passed
                            ? "2 reads non-decreasing"
                            : "count \(ticks.count)->\(again.count), regressed cpu\(regressed.map(\.offset))",
                        severity: .advisory))
            }
        }

        if let refreshTopology {
            let topology = refreshTopology()
            checks.append(
                SelfTestCheck(
                    name: "cpu.topology", passed: topology.quality.isOK, detail: Self.describe(topology),
                    severity: .advisory))
        }

        let result = SelfTestResult(checks: checks, dataPath: Self.dataPath)
        state.withLock {
            // 从不可用恢复：不可用期间没有更新基线，旧基线不可用
            if $0.selfTestUsable == false, result.isUsable {
                $0.baseline = nil
                $0.consecutiveStale = 0
            }
            $0.selfTestUsable = result.isUsable
            $0.selfTestWarnings = !result.warnings.isEmpty
        }
        return result
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        let reading = readTicks()
        return state.withLock { state in
            switch reading {
            case .failure(let error):
                return output(
                    Self.unavailableSamples(.readFailed(error.description), state: &state, count: nil, at: time),
                    .unavailable, state)

            case .success(let ticks):
                if state.selfTestUsable == false {
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
                    let samples =
                        Self.samples(for: usage, state: &state, at: time)
                        + Self.aggregateSamples(for: usage, topology: topology(), at: time)
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

    /// 本进程的 host 端口，只取一次。`mach_host_self()` 每调用一次都会给这个端口名的 send right 加一个
    /// 用户引用（urefs），从不释放的话会一直涨到上限 65535 才被内核钉住；缓存起来就只占一个引用。
    static let host: host_t = mach_host_self()

    /// 读一次每核 tick。返回的数组由内核分配，读完立即 `vm_deallocate`。
    static func readTicks() -> Result<[CoreTicks], ReadError> {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(Self.host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
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

    /// 自检有提示项没通过时，`ok` 降为 `degraded`。
    private func output(_ samples: [Sample], _ status: CollectorStatus, _ state: State) -> CollectorOutput {
        let status = status == .ok && state.selfTestWarnings ? .degraded : status
        return CollectorOutput(samples: samples, status: status, dataPath: Self.dataPath, staleCount: state.staleCount)
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

    /// 用户/系统、每簇、每档的汇总样本。拓扑核数与本次读数不符时不出簇和档。
    static func aggregateSamples(for usage: CPUUsage, topology: CPUTopology?, at time: SampleTime) -> [Sample] {
        var samples: [Sample] = []
        let allCores = 0..<usage.perCoreTicks.count
        if let all = usage.aggregate(cores: allCores) {
            let quality: DataQuality = all.partial ? .estimated : .measured
            samples.append(Sample(id: .cpuUsageUser, value: all.user, quality: quality, time: time))
            samples.append(Sample(id: .cpuUsageSystem, value: all.system, quality: quality, time: time))
        } else {
            samples.append(.unavailable(.cpuUsageUser, reason: .counterReset("all cores dropped"), at: time))
            samples.append(.unavailable(.cpuUsageSystem, reason: .counterReset("all cores dropped"), at: time))
        }

        guard let topology, topology.logicalCPUCount == usage.perCoreTicks.count else { return samples }
        func append(_ id: MetricID, _ cores: [Int]) {
            if let group = usage.aggregate(cores: cores) {
                samples.append(Sample(id: id, value: group.busy, quality: group.partial ? .estimated : .measured, time: time))
            } else {
                samples.append(.unavailable(id, reason: .counterReset("all cores in group dropped"), at: time))
            }
        }
        for cluster in topology.clusters {
            append(.cpuUsageCluster(cluster.key), cluster.cpus)
        }
        if topology.quality.isOK {
            for level in topology.perfLevels {
                let cores = topology.clusters.filter { $0.perfLevel == level.index }.flatMap(\.cpus)
                append(.cpuUsagePerfLevel(level.index), cores)
            }
        }
        return samples
    }

    /// 拓扑的一行说明（自检详情、诊断页）。不含设备唯一标识。
    static func describe(_ topology: CPUTopology) -> String {
        let quality: String
        switch topology.quality {
        case .ok: quality = "ok"
        case .clustersOnly(let reason): quality = "clustersOnly(\(reason))"
        case .coresOnly(let reason): quality = "coresOnly(\(reason))"
        }
        let levels = topology.perfLevels.map { "\($0.index):\($0.name)×\($0.cpuCount)" }.joined(separator: " ")
        return "\(topology.logicalCPUCount) CPU, \(topology.clusters.count) clusters, levels [\(levels)], \(quality)"
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
