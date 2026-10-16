// GPU 与加速器模块的指标标识（GPU 模块设计 §4，D57、D58）。命名一旦发布就不改。
//
// 比例是 0…1；频率 Hz；温度 °C；功率 W；中断速率次/秒。GPU 功率沿用功耗模块的 `power.gpu`。

extension MetricID {
    /// GPU 活跃：GPUPH 非 OFF 驻留的比例，0…1（上电时间，不是算力占用，D57 G1）。
    public static let gpuActive: MetricID = "gpu.active"
    /// GPU 活跃期间的平均频率，Hz（按 GPUPH 各档驻留加权，D57 G2）。
    public static let gpuFrequency: MetricID = "gpu.frequency"
    /// GPU 温度，°C：芯片档案代表键有效读数的最大值（D57 G4）。
    public static let gpuTemperature: MetricID = "gpu.temperature"
    /// GPU 占用的统一内存，字节（AGX `PerformanceStatistics`「In use system memory」）。
    public static let gpuMemoryInUse: MetricID = "gpu.memory.inUse"
    /// GPU 驱动已分配的统一内存，字节（「Alloc system memory」）。
    public static let gpuMemoryAllocated: MetricID = "gpu.memory.allocated"
    /// ANE 是否上电，0 / 1（`H11ANEIn` 的 `CurrentPowerState`；关断滞后约 5–6 s）。
    public static let anePowered: MetricID = "ane.powered"
    /// ANE 功率（估算），W：全部 coalition 槽位 39 的差分合计 ÷ 墙钟，质量为 estimated（D58）。
    public static let anePowerEstimated: MetricID = "ane.power.estimated"
    /// 视频编码引擎（ave）的一级中断速率，次/秒，已减去空闲底数，相对量（D57 G6）。
    public static let mediaEncodeRate: MetricID = "media.encode.rate"
    /// 视频解码引擎（avd）的一级中断速率，次/秒，已减去空闲底数（M5 空闲约 90 次/s）。
    public static let mediaDecodeRate: MetricID = "media.decode.rate"
    /// ProRes 引擎（apr）的一级中断速率，次/秒，已减去空闲底数。
    public static let mediaProResRate: MetricID = "media.prores.rate"
}

extension UnavailableReason {
    /// 设备在整个采样间隔内都处于关断状态，没有可算的值（例如 GPU 全程 OFF 时的平均频率）。
    public static func deviceIdle(_ detail: String? = nil) -> Self { Self(code: "deviceIdle", detail: detail) }
}

/// GPU 一个性能档的驻留（诊断页）。
public struct GPUStateResidency: Hashable, Sendable, Codable {
    /// 状态名，例如 `OFF`、`P13`。
    public var name: String
    /// 占采样间隔的比例，0…1。
    public var share: Double
    /// 该档的频率，Hz；OFF 或表里没有时为 nil。
    public var frequency: Double?

    public init(name: String, share: Double, frequency: Double?) {
        self.name = name
        self.share = share
        self.frequency = frequency
    }
}

/// GPU DVFS 档位表：P*k* 对应 `frequencies[k-1]`（GPU 模块设计 §5）。
///
/// 不要求单调：M4 的表中间几档不单调（2026-10-16 实测），按表里的顺序对应档位，不排序。
public struct GPUFrequencyTable: Hashable, Sendable, Codable {
    /// pmgr 的表键号 k（`voltage-states<k>-sram`）。
    public var key: Int
    /// 各档频率，Hz，按 P1、P2… 的顺序（表中的非零项）。
    public var frequencies: [Double]
    /// 来源：芯片档案指定，还是运行时推断。
    public var fromProfile: Bool

    public init(key: Int, frequencies: [Double], fromProfile: Bool) {
        self.key = key
        self.frequencies = frequencies
        self.fromProfile = fromProfile
    }

    /// 第 `index` 个 P 档（1 起）的频率；超出表的范围时为 nil。
    public func frequency(ofPState index: Int) -> Double? {
        index >= 1 && index <= frequencies.count ? frequencies[index - 1] : nil
    }

    public var top: Double { frequencies.max() ?? 0 }
}
