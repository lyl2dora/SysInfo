// 采集器协议（M0 设计 §5.1）。

import SysModel

/// 一个数据源的采集器。
///
/// 实例由 `SamplingEngine` 持有，采样和自检都在引擎的串行队列上依次调用，不会并发进入同一个实例。
/// sysinfo-cli 也会在自己的线程上直接调用（不经引擎）。协议要求 `Sendable`，实现用 `Mutex` 保护内部状态，
/// 在上面这种串行用法下锁没有竞争。
public protocol Collector: AnyObject, Sendable {
    var id: CollectorID { get }

    /// 自检（K19）。启动、唤醒、系统 build 号变化，以及运行中连续不可用时复检。
    /// 自检未通过时，采集器之后的样本一律标为不可用，不输出可能错误的数值（D05）。
    func selfTest() -> SelfTestResult

    /// 采样一次。第一次调用（或 `resetBaseline()` 之后）只建立差分基线，可以不返回样本。
    func sample(at time: SampleTime) -> CollectorOutput

    /// 丢弃差分基线。采集器从「无需求」变为「有需求」时由引擎调用，
    /// 避免第一个样本变成整段空闲期的平均值。
    func resetBaseline()

    /// 在哪条通道上采样（CPU 模块设计 §5.1）。默认 `.inline`。
    var lane: CollectorLane { get }
}

/// 采集器的执行通道。
public enum CollectorLane: String, Hashable, Codable, Sendable {
    /// 在引擎主队列上随 tick 串行执行。适合几毫秒以内的读取。
    case inline
    /// 在引擎的第二条串行队列上执行，和主 tick 并行，结果以同一个 tick 序号单独交付。
    /// 适合阻塞或较慢的读取：SMC（M5 一次约 12–15 ms 墙钟，M4 全量 60–75 ms）、coalition 全量扫描。
    case blocking
}

extension Collector {
    public var lane: CollectorLane { .inline }
}

/// 采集器一次采样的输出：样本加上健康信息。耗时由引擎测量后补进 `CollectorHealth`。
public struct CollectorOutput: Sendable, Hashable {
    public var samples: [Sample]
    public var status: CollectorStatus
    /// 当前数据路径的说明。
    public var dataPath: String
    /// 至今读到陈旧数据而跳过的次数（累计值）。
    public var staleCount: UInt64

    public init(samples: [Sample], status: CollectorStatus, dataPath: String, staleCount: UInt64 = 0) {
        self.samples = samples
        self.status = status
        self.dataPath = dataPath
        self.staleCount = staleCount
    }
}

/// 各处共用的采集器清单：app 交给引擎，sysinfo-cli selftest 逐个自检。
public enum StandardCollectors: Sendable {
    /// 全部采集器：CPU 负载（`cpu.load`）、频率（`cpu.freq`）、温度与功耗（`cpu.sensors`）、应用活动（`app.coalition`）、
    /// 本进程开销（`app.self`）。每次调用返回新实例。`cpu.load` 排在最前：它的自检会刷新拓扑，其余采集器按拓扑建方案。
    public static func make() -> [any Collector] {
        [CPULoadCollector(), CPUFrequencyCollector(), SensorCollector(), AppSampler(), SelfUsageCollector()]
    }
}
