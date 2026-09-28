// M0 用到的指标标识（K17，M0 设计 §4）。
//
// 命名一旦发布就不改：它们会进入环形缓冲、历史库、导出列名和小组件快照。

extension MetricID {
    /// 整机 CPU 总占用，0…1（所有逻辑核的平均）。
    public static let cpuUsageTotal: MetricID = "cpu.usage.total"

    /// 第 `index` 个逻辑核的占用，0…1。`index` 与 `host_processor_info` 的顺序一致，从 0 开始。
    public static func cpuUsageCore(_ index: Int) -> MetricID {
        MetricID("cpu.usage.core.\(index)")
    }

    /// 本进程 CPU 占用，按单核的比例（K24）：1 表示占满一个核，多线程时可以大于 1。
    public static let appSelfCPU: MetricID = "app.self.cpu"

    /// 本进程物理内存 footprint，单位字节（与活动监视器「内存」列同口径）。
    public static let appSelfFootprint: MetricID = "app.self.footprint"
}
