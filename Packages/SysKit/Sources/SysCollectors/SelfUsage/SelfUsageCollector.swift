// 本进程开销采集器 `app.self`（M0 设计 §5.1）。
//
// 数据源：`proc_pid_rusage(getpid(), RUSAGE_INFO_V6)`。
// - 差分 `ri_user_time + ri_system_time` 得到本进程 CPU（按单核的比例，K24）。这两个字段在 Apple 芯片上是
//   mach tick 而不是头文件注释说的纳秒，用 `mach_timebase_info` 换算，不写死 125/3（D20）；
// - `ri_phys_footprint` 即活动监视器「内存」列的口径。
//
// 自检（D05、K19）：用公开的 `getrusage(RUSAGE_SELF)` 交叉校验单位换算。
// - 换算后与 getrusage 吻合：按 mach tick 使用（正常路径）；
// - 原始值直接与 getrusage 吻合：说明内核已改成真正的纳秒，按纳秒使用（仍然正常）；
// - 都对不上：CPU 回退到 getrusage（状态 degraded），footprint 照常读取。

import Darwin
import Synchronization
import SysModel

public final class SelfUsageCollector: Collector {
    public static let collectorID: CollectorID = "app.self"
    public static let dataPath = "proc_pid_rusage(getpid(), RUSAGE_INFO_V6)"
    public static let fallbackDataPath = "getrusage(RUSAGE_SELF) + proc_pid_rusage(ri_phys_footprint)"

    public var id: CollectorID { Self.collectorID }

    /// 本进程 CPU 时间的来源与单位。
    enum CPUTimeSource: Hashable, Sendable {
        /// `ri_user_time + ri_system_time`，mach tick，按 timebase 换算成纳秒。
        case rusageMachTicks(MachTimebase)
        /// 同一字段，但已经是纳秒（自检发现原始值直接与 getrusage 吻合时切换）。
        case rusageNanoseconds
        /// 回退：公开的 `getrusage(RUSAGE_SELF)`，微秒精度。
        case getrusage
    }

    struct Baseline: Hashable, Sendable {
        var cpuNanos: UInt64
        var monotonicNanos: UInt64
    }

    private struct State {
        var baseline: Baseline?
        /// 自检前默认按 mach tick 换算；timebase 读不到时直接回退。
        var cpuSource: CPUTimeSource = MachTimebase.current.map(CPUTimeSource.rusageMachTicks) ?? .getrusage
        /// 最近一次自检里 footprint 是否可信；自检前默认可信。
        var footprintOK = true
    }

    private let state = Mutex(State())

    public init() {}

    // MARK: - Collector

    public func selfTest() -> SelfTestResult {
        var checks: [SelfTestCheck] = []
        let timebase = MachTimebase.current
        checks.append(
            SelfTestCheck(
                name: "app.self.timebase",
                passed: timebase != nil,
                detail: timebase.map { "numer/denom=\($0.numer)/\($0.denom)" } ?? "mach_timebase_info failed"))

        var cpuSource: CPUTimeSource = .getrusage
        var footprintOK = false

        switch Self.readUsage() {
        case .failure(let error):
            checks.append(SelfTestCheck(name: "app.self.read", passed: false, detail: error.description))
        case .success(let usage):
            let reference = Self.getrusageCPUNanos()
            checks.append(SelfTestCheck(name: "app.self.read", passed: true, detail: "rc=0"))

            footprintOK = usage.footprint > 0
            checks.append(
                SelfTestCheck(
                    name: "app.self.footprint", passed: footprintOK,
                    detail: "ri_phys_footprint=\(usage.footprint)"))

            let detected = reference.flatMap {
                Self.classifyCPUUnits(rawTicks: usage.cpuTicks, referenceNanos: $0, timebase: timebase)
            }
            cpuSource = detected ?? .getrusage
            checks.append(
                SelfTestCheck(
                    name: "app.self.cpuUnits",
                    passed: detected != nil,
                    detail: "raw=\(usage.cpuTicks), getrusage=\(reference.map { "\($0 / 1000)us" } ?? "failed"), "
                        + "use=\(Self.describe(cpuSource))"))
        }

        let result = SelfTestResult(checks: checks, dataPath: Self.dataPath)
        state.withLock {
            if $0.cpuSource != cpuSource { $0.baseline = nil }  // 换了来源，旧基线不可比
            $0.cpuSource = cpuSource
            $0.footprintOK = footprintOK
        }
        return result
    }

    public func sample(at time: SampleTime) -> CollectorOutput {
        let reading = Self.readUsage()
        return state.withLock { state in
            var samples: [Sample] = []
            var failures: [String] = []

            // 内存 footprint
            switch reading {
            case .success(let usage) where state.footprintOK:
                samples.append(Sample(id: .appSelfFootprint, value: Double(usage.footprint), time: time))
            case .success:
                samples.append(.unavailable(.appSelfFootprint, reason: .selfTestFailed("footprint"), at: time))
                failures.append("footprint")
            case .failure(let error):
                samples.append(.unavailable(.appSelfFootprint, reason: .readFailed(error.description), at: time))
                failures.append("footprint")
            }

            // CPU
            let cpuNanos: UInt64?
            switch (state.cpuSource, reading) {
            case (.rusageMachTicks(let timebase), .success(let usage)):
                cpuNanos = timebase.nanoseconds(fromTicks: usage.cpuTicks)
            case (.rusageNanoseconds, .success(let usage)):
                cpuNanos = usage.cpuTicks
            case (.getrusage, _):
                cpuNanos = Self.getrusageCPUNanos()
            case (_, .failure):
                cpuNanos = nil
            }

            if let cpuNanos {
                let current = Baseline(cpuNanos: cpuNanos, monotonicNanos: time.monotonicNanos)
                // 第一次（或复位后）只建立基线，不输出 CPU 样本。
                if let ratio = Self.cpuRatio(from: state.baseline, to: current) {
                    samples.append(Sample(id: .appSelfCPU, value: ratio, time: time))
                }
                state.baseline = current
            } else {
                state.baseline = nil
                let source = state.cpuSource == .getrusage ? "getrusage" : "proc_pid_rusage"
                samples.append(.unavailable(.appSelfCPU, reason: .readFailed(source), at: time))
                failures.append("cpu")
            }

            let status: CollectorStatus
            if failures.count == 2 {
                status = .unavailable
            } else if !failures.isEmpty || state.cpuSource == .getrusage {
                status = .degraded
            } else {
                status = .ok
            }
            let path = state.cpuSource == .getrusage ? Self.fallbackDataPath : Self.dataPath
            return CollectorOutput(samples: samples, status: status, dataPath: path)
        }
    }

    public func resetBaseline() {
        state.withLock { $0.baseline = nil }
    }

    // MARK: - 纯函数（单测覆盖）

    /// 两次读数之间本进程的 CPU 占用（按单核的比例）。没有基线、单调时间没前进、或 CPU 时间回退时返回 nil；
    /// 回退按计数器复位处理：调用方用本次读数重建基线，不钳为 0。
    static func cpuRatio(from previous: Baseline?, to current: Baseline) -> Double? {
        guard let previous,
            current.monotonicNanos > previous.monotonicNanos,
            current.cpuNanos >= previous.cpuNanos
        else { return nil }
        return Double(current.cpuNanos - previous.cpuNanos)
            / Double(current.monotonicNanos - previous.monotonicNanos)
    }

    /// 判断 `ri_user_time + ri_system_time` 的单位：分别按「mach tick」和「纳秒」两种假设换算，
    /// 取与 getrusage 更接近、且误差在容差内的一种；都不在容差内返回 nil。
    ///
    /// 两次读取紧挨着，真实差值只有微秒级；容差取参考值的 5% 或 2 ms 中的较大者。
    /// 进程 CPU 时间很短时两种假设可能都落在容差内，这时靠「更接近」来区分。
    static func classifyCPUUnits(rawTicks: UInt64, referenceNanos: UInt64, timebase: MachTimebase?) -> CPUTimeSource? {
        func distance(_ a: UInt64, _ b: UInt64) -> UInt64 { a > b ? a - b : b - a }
        let tolerance = max(referenceNanos / 20, 2_000_000)

        let rawDistance = distance(rawTicks, referenceNanos)
        if let timebase {
            let converted = timebase.nanoseconds(fromTicks: rawTicks)
            let convertedDistance = distance(converted, referenceNanos)
            if convertedDistance <= tolerance, convertedDistance <= rawDistance {
                return .rusageMachTicks(timebase)
            }
        }
        if rawDistance <= tolerance {
            return .rusageNanoseconds
        }
        return nil
    }

    static func describe(_ source: CPUTimeSource) -> String {
        switch source {
        case .rusageMachTicks: "machTicks"
        case .rusageNanoseconds: "nanoseconds"
        case .getrusage: "getrusage"
        }
    }

    // MARK: - 读取

    struct Usage: Sendable {
        /// `ri_user_time + ri_system_time` 的原始值（Apple 芯片上是 mach tick）。
        var cpuTicks: UInt64
        /// 字节。
        var footprint: UInt64
    }

    struct ReadError: Error, CustomStringConvertible {
        var description: String
    }

    static func readUsage() -> Result<Usage, ReadError> {
        var info = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
            }
        }
        guard rc == 0 else {
            return .failure(ReadError(description: "proc_pid_rusage rc=\(rc) errno=\(errno)"))
        }
        return .success(Usage(cpuTicks: info.ri_user_time &+ info.ri_system_time, footprint: info.ri_phys_footprint))
    }

    /// `getrusage(RUSAGE_SELF)` 的 user + system，纳秒；失败时为 nil。
    static func getrusageCPUNanos() -> UInt64? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        func nanos(_ tv: timeval) -> UInt64 {
            UInt64(max(tv.tv_sec, 0)) * 1_000_000_000 + UInt64(max(tv.tv_usec, 0)) * 1000
        }
        return nanos(usage.ru_utime) + nanos(usage.ru_stime)
    }
}
