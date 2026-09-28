// 采集器状态（K17、K19，M0 设计 §4）：诊断页、sysinfo-cli selftest 和自检复检都用这些类型。

/// 采集器的稳定标识，例如 `cpu.load`、`app.self`。
public struct CollectorID: RawRepresentable, Hashable, Comparable, Codable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }

    public static func < (lhs: CollectorID, rhs: CollectorID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 采集器的整体状态。
public enum CollectorStatus: String, Sendable, Hashable, Codable, CaseIterable {
    /// 正常。
    case ok
    /// 能出数，但质量下降（例如连续读到陈旧数据、部分核被丢弃）。
    case degraded
    /// 不可用：读取失败或自检未通过，不输出数值。
    case unavailable
}

/// 自检中的一项检查。
public struct SelfTestCheck: Sendable, Hashable, Codable {
    /// 稳定的检查代码，例如 `cpu.load.coreCount`，由 app 映射成本地化名称。
    public var name: String
    public var passed: Bool
    /// 技术细节（读数、期望值），不做本地化，不含设备唯一标识。
    public var detail: String

    public init(name: String, passed: Bool, detail: String) {
        self.name = name
        self.passed = passed
        self.detail = detail
    }
}

/// 一次自检的结果（K19）。
public struct SelfTestResult: Sendable, Hashable, Codable {
    public var checks: [SelfTestCheck]
    /// 自检时实际使用的数据路径说明。
    public var dataPath: String

    public init(checks: [SelfTestCheck], dataPath: String) {
        self.checks = checks
        self.dataPath = dataPath
    }

    /// 至少有一项检查，并且全部通过。
    public var passed: Bool {
        !checks.isEmpty && checks.allSatisfy(\.passed)
    }
}

/// 一次采样的耗时。
public struct SampleCost: Sendable, Hashable, Codable {
    /// 墙钟耗时，纳秒。
    public var wallNanos: UInt64
    /// 采样线程的 CPU 时间，纳秒（`CLOCK_THREAD_CPUTIME_ID`）。
    public var cpuNanos: UInt64

    public init(wallNanos: UInt64, cpuNanos: UInt64) {
        self.wallNanos = wallNanos
        self.cpuNanos = cpuNanos
    }
}

/// 采集器的健康信息，供诊断页显示（K19）。
public struct CollectorHealth: Sendable, Hashable, Codable {
    public var id: CollectorID
    public var status: CollectorStatus
    /// 当前数据路径的说明，例如 `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`。
    public var dataPath: String
    /// 最近一次自检的结果；还没自检过时为 nil。
    public var selfTest: SelfTestResult?
    /// 最近一次采样的耗时；还没采样过时为 nil。
    public var lastCost: SampleCost?
    /// 至今所有采样的平均耗时；还没采样过时为 nil。
    public var averageCost: SampleCost?
    /// 至今的采样次数（含陈旧、失败的次数）。
    public var sampleCount: UInt64
    /// 至今读到陈旧数据而跳过的次数。
    public var staleCount: UInt64

    public init(
        id: CollectorID,
        status: CollectorStatus,
        dataPath: String,
        selfTest: SelfTestResult? = nil,
        lastCost: SampleCost? = nil,
        averageCost: SampleCost? = nil,
        sampleCount: UInt64 = 0,
        staleCount: UInt64 = 0
    ) {
        self.id = id
        self.status = status
        self.dataPath = dataPath
        self.selfTest = selfTest
        self.lastCost = lastCost
        self.averageCost = averageCost
        self.sampleCount = sampleCount
        self.staleCount = staleCount
    }
}
