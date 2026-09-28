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
    /// M0 的全部采集器：CPU 负载（`cpu.load`）与本进程开销（`app.self`）。每次调用返回新实例。
    public static func make() -> [any Collector] {
        [CPULoadCollector(), SelfUsageCollector()]
    }
}
