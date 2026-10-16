// 哪些指标进历史库、怎么聚合（CPU 模块设计 §6，边界稿 §5.5）。
//
// CPU 每分钟约 12–16 行；功耗与散热每分钟约 6 行（整机、SoC、GPU、DRAM 功率，最热点，风扇转速）；
// 内存每分钟 13 行（已用、占用率、App、联动、被压缩、已缓存、Swap、压力与等级、页入 / 页出、换入 / 换出）；
// GPU 与加速器每分钟 3 行（GPU 活跃、GPU 温度、ANE 上电比例），随拓扑变化：总占用、用户/系统、每档占用、每簇频率、每簇温度与 CPU 最高温、
// 每簇与总功耗、1 分钟负载均值、热状态与热压力。每核、每簇占用、中断、任务数不入库。
//
// 两类聚合：
// - 区间量（占用、频率）：样本本身是一段区间的平均值，区间长度就是它覆盖的秒数。按墙钟把区间拆到所跨的分钟上，
//   按重叠秒数加权。区间长于 `peakWindowLimit` 的样本没有峰值意义：这一分钟只要混进一个这样的样本，max 就记为空，
//   不假装有峰值（菜单栏 1 s、面板 5 s 有峰值；后台 60 s 差分没有）；
// - 瞬时量（温度、功耗、负载均值、热状态）：读数代表采样时刻，整份记到所在的分钟，覆盖秒数取距上次采样的间隔，
//   max 就是读数的最大值。

import SysCollectors
import SysModel

/// 一个指标的聚合方式。
public enum HistoryAggregation: String, Sendable, Hashable, Codable {
    case interval
    case instant
}

/// 指标属于哪个模块：各模块的「记录历史」开关分别控制（D41：记录开关在模块页）。
public enum HistoryModule: String, Sendable, Hashable, Codable, CaseIterable {
    case cpu
    case power
    case memory
    case storage
    case gpu
}

/// 历史库里一个指标的说明。
public struct HistoryMetricSpec: Sendable, Hashable {
    public var aggregation: HistoryAggregation
    /// SI 单位（导出时写进 metadata）：`ratio`、`Hz`、`degC`、`W`、`load`、`level`。
    public var unit: String
    /// 产生它的采集器：用来算样本覆盖的区间（距该采集器上一次运行的时间）。
    public var collector: CollectorID
    public var module: HistoryModule = .cpu

    public init(aggregation: HistoryAggregation, unit: String, collector: CollectorID, module: HistoryModule = .cpu) {
        self.aggregation = aggregation
        self.unit = unit
        self.collector = collector
        self.module = module
    }
}

public enum HistoryCatalog {
    /// 区间量的峰值只在样本区间不超过这么长时才有意义，秒。
    public static let peakWindowLimit: Double = 10

    /// 判断一个指标要不要入库；要的话返回说明。按前缀匹配，拓扑决定的指标（每档、每簇）不必逐个登记。
    public static func spec(for id: MetricID) -> HistoryMetricSpec? {
        switch id {
        case .cpuUsageTotal, .cpuUsageUser, .cpuUsageSystem:
            return HistoryMetricSpec(aggregation: .interval, unit: "ratio", collector: CPULoadCollector.collectorID)
        case .cpuTemperatureMax:
            return HistoryMetricSpec(aggregation: .instant, unit: "degC", collector: SensorCollector.collectorID)
        case .cpuPowerTotal:
            return HistoryMetricSpec(aggregation: .instant, unit: "W", collector: SensorCollector.collectorID)
        case .cpuLoadAverage1:
            return HistoryMetricSpec(aggregation: .instant, unit: "load", collector: CPUMiscCollector.collectorID)
        case .cpuThermalState, .cpuThermalPressure:
            return HistoryMetricSpec(aggregation: .instant, unit: "level", collector: CPUMiscCollector.collectorID)
        // 功耗与散热（功耗与散热模块设计 §6）：墙插估算、风扇目标与模式、低功耗模式不入库。
        case .powerSystem:
            return HistoryMetricSpec(aggregation: .instant, unit: "W", collector: PowerRailCollector.collectorID, module: .power)
        case .powerSoC, .powerDRAM:
            return HistoryMetricSpec(aggregation: .instant, unit: "W", collector: PowerSensorCollector.collectorID, module: .power)
        case .powerGPU:
            // AGX 是累计计数的差分，样本本身就是一段区间的平均功率。
            return HistoryMetricSpec(aggregation: .interval, unit: "W", collector: GPUPowerCollector.collectorID, module: .power)
        case .thermalSoCHotspot:
            return HistoryMetricSpec(
                aggregation: .instant, unit: "degC", collector: PowerSensorCollector.collectorID, module: .power)
        // 内存（内存模块设计 §6，D49）：物理内存、空闲、Swap 总量、压缩比、压缩 / 解压速率不入库。
        case .memoryUsed, .memoryApp, .memoryWired, .memoryCompressed, .memoryCached, .memorySwapUsed:
            return HistoryMetricSpec(aggregation: .instant, unit: "B", collector: MemoryCollector.collectorID, module: .memory)
        case .memoryUsage, .memoryPressure:
            return HistoryMetricSpec(aggregation: .instant, unit: "ratio", collector: MemoryCollector.collectorID, module: .memory)
        case .memoryPressureLevel:
            return HistoryMetricSpec(aggregation: .instant, unit: "level", collector: MemoryCollector.collectorID, module: .memory)
        case .memoryPageInRate, .memoryPageOutRate, .memorySwapInRate, .memorySwapOutRate:
            // 两次读数之间的平均速率，样本本身就是一段区间。
            return HistoryMetricSpec(aggregation: .interval, unit: "1/s", collector: MemoryCollector.collectorID, module: .memory)
        // GPU 与加速器（GPU 模块设计 §7，D57 G9）：GPU 功率已由功耗模块记录；频率、GPU 内存、媒体引擎、ANE 估算不入库。
        case .gpuActive:
            // GPUPH 驻留的差分：样本本身就是一段区间的平均值。
            return HistoryMetricSpec(aggregation: .interval, unit: "ratio", collector: GPUPowerCollector.collectorID, module: .gpu)
        case .gpuTemperature:
            return HistoryMetricSpec(aggregation: .instant, unit: "degC", collector: GPUTemperatureCollector.collectorID, module: .gpu)
        case .anePowered:
            // 0 / 1 的瞬时状态；分钟均值即这一分钟里上电的比例。
            return HistoryMetricSpec(aggregation: .instant, unit: "ratio", collector: GPUAcceleratorCollector.collectorID, module: .gpu)
        default:
            break
        }
        // 存储（存储模块设计 §5）：每盘读写、温度、寿命、备用块、介质错误、累计读写；每组已用与可用。
        // IOPS、延迟、critical warning 不入库。
        if let (_, metric) = id.storageDiskMetric {
            switch metric {
            case .read, .write:
                // 驱动计数的差分：样本本身就是一段区间的平均速率。
                return HistoryMetricSpec(aggregation: .interval, unit: "B/s", collector: StorageIOCollector.collectorID, module: .storage)
            case .temp:
                return HistoryMetricSpec(aggregation: .instant, unit: "degC", collector: SMARTCollector.collectorID, module: .storage)
            case .life, .spare:
                return HistoryMetricSpec(aggregation: .instant, unit: "ratio", collector: SMARTCollector.collectorID, module: .storage)
            case .mediaErrors:
                return HistoryMetricSpec(aggregation: .instant, unit: "count", collector: SMARTCollector.collectorID, module: .storage)
            case .dataRead, .dataWritten:
                return HistoryMetricSpec(aggregation: .instant, unit: "B", collector: SMARTCollector.collectorID, module: .storage)
            case .readOps, .writeOps, .readLatency, .writeLatency, .warning:
                return nil
            }
        }
        if let (_, metric) = id.storageGroupMetric, metric != .total {
            return HistoryMetricSpec(
                aggregation: .instant, unit: "B", collector: StorageCapacityCollector.collectorID, module: .storage)
        }
        if id.fanSpeedIndex != nil {
            return HistoryMetricSpec(aggregation: .instant, unit: "rpm", collector: PowerSensorCollector.collectorID, module: .power)
        }
        if id.cpuUsagePerfLevelIndex != nil {
            return HistoryMetricSpec(aggregation: .interval, unit: "ratio", collector: CPULoadCollector.collectorID)
        }
        if id.cpuFrequencyClusterKey != nil {
            return HistoryMetricSpec(aggregation: .interval, unit: "Hz", collector: CPUFrequencyCollector.collectorID)
        }
        if id.cpuTemperatureClusterKey != nil {
            return HistoryMetricSpec(aggregation: .instant, unit: "degC", collector: SensorCollector.collectorID)
        }
        if id.cpuPowerClusterKey != nil {
            return HistoryMetricSpec(aggregation: .instant, unit: "W", collector: SensorCollector.collectorID)
        }
        return nil
    }
}

/// 数据质量在库里的编码：数字越大越差，分钟内取最差的（`q` 列）。不可用的样本不入库。
public enum HistoryQuality: Int, Sendable, Hashable, Codable, CaseIterable, Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    case measured = 0
    case relative = 1
    case estimated = 2
    case inferred = 3
    case batched30min = 4

    public init?(_ quality: DataQuality) {
        switch quality {
        case .measured: self = .measured
        case .relative: self = .relative
        case .estimated: self = .estimated
        case .inferred: self = .inferred
        case .batched30min: self = .batched30min
        case .unavailable: return nil
        }
    }

    /// 导出用的名字。
    public var name: String {
        switch self {
        case .measured: "measured"
        case .relative: "relative"
        case .estimated: "estimated"
        case .inferred: "inferred"
        case .batched30min: "batched30min"
        }
    }
}
