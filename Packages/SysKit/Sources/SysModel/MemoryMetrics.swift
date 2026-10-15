// 内存模块的指标标识（内存模块设计 §3，D49）。命名一旦发布就不改。
//
// 字节数一律是字节（按 1024 换算显示，K24）；占用率与压力是 0…1 的比例；速率是每秒次数。

extension MetricID {
    /// 物理内存，字节（`hw.memsize`）。
    public static let memoryPhysical: MetricID = "memory.physical"
    /// 已用内存，字节：App + 联动 + 被压缩（活动监视器口径，D49 M1）。
    public static let memoryUsed: MetricID = "memory.used"
    /// 占用率，0…1：已用 ÷ 物理内存。
    public static let memoryUsage: MetricID = "memory.usage"
    /// App 内存，字节：internal − purgeable。
    public static let memoryApp: MetricID = "memory.app"
    /// 联动内存，字节（wired）。
    public static let memoryWired: MetricID = "memory.wired"
    /// 被压缩，字节：压缩器占用的页（`compressor_page_count`）。
    public static let memoryCompressed: MetricID = "memory.compressed"
    /// 已缓存文件，字节：external + purgeable（external 含 speculative，D49 事实更正）。
    public static let memoryCached: MetricID = "memory.cached"
    /// 空闲，字节（`vm.page_free_count`，不含 speculative）。
    public static let memoryFree: MetricID = "memory.free"
    /// 内存压力，0…1：1 − `kern.memorystatus_level` / 100。
    public static let memoryPressure: MetricID = "memory.pressure"
    /// 内存压力等级：1 正常、2 警告、4 严重（`kern.memorystatus_vm_pressure_level`；取一个采样间隔内出现过的最差等级）。
    public static let memoryPressureLevel: MetricID = "memory.pressure.level"
    /// Swap 已用，字节（`vm.swapusage`）。
    public static let memorySwapUsed: MetricID = "memory.swap.used"
    /// Swap 文件总大小，字节。
    public static let memorySwapTotal: MetricID = "memory.swap.total"
    /// 压缩比：压缩器里存放的原始页数 ÷ 压缩器占用的页数。没有被压缩的页时不可用。
    public static let memoryCompressionRatio: MetricID = "memory.compression.ratio"

    /// 页入，次/秒（从文件读入的页）。
    public static let memoryPageInRate: MetricID = "memory.rate.pageins"
    /// 页出，次/秒（写回文件的页）。
    public static let memoryPageOutRate: MetricID = "memory.rate.pageouts"
    /// 换入，次/秒（从 swap 读回的页）。
    public static let memorySwapInRate: MetricID = "memory.rate.swapins"
    /// 换出，次/秒（写入 swap 的页）。
    public static let memorySwapOutRate: MetricID = "memory.rate.swapouts"
    /// 压缩，次/秒（被压缩的页）。
    public static let memoryCompressionRate: MetricID = "memory.rate.compressions"
    /// 解压，次/秒。
    public static let memoryDecompressionRate: MetricID = "memory.rate.decompressions"

    /// DRAM 读带宽，字节/秒（IOReport DCS BW 直方图的分档中点估算，质量为 relative，只在诊断页，D49 M3）。
    public static let memoryBandwidthRead: MetricID = "memory.bandwidth.read"
    /// DRAM 写带宽，字节/秒（同上）。
    public static let memoryBandwidthWrite: MetricID = "memory.bandwidth.write"
}

/// 内存压力等级（`kern.memorystatus_vm_pressure_level` 与 dispatch 内存压力事件共用的取值）。
public enum MemoryPressureLevel: Int, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case normal = 1
    case warning = 2
    case critical = 4

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// 样本值（1 / 2 / 4）换回等级；其他值为 nil。
    public init?(sampleValue: Double?) {
        guard let value = sampleValue, let level = Self(rawValue: Int(value.rounded())) else { return nil }
        self = level
    }
}
