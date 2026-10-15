// CPU 模块「详情」区的指标标识（CPU 模块设计 §4.2、§5.6）。命名一旦发布就不改。

extension MetricID {
    /// 1 分钟负载均值（`getloadavg`）。内核约每 5 s 更新一次。
    public static let cpuLoadAverage1: MetricID = "cpu.loadavg.1"
    /// 5 分钟负载均值。
    public static let cpuLoadAverage5: MetricID = "cpu.loadavg.5"
    /// 15 分钟负载均值。
    public static let cpuLoadAverage15: MetricID = "cpu.loadavg.15"

    /// 任务（进程）数，来自 `processor_set_statistics(PROCESSOR_SET_LOAD_INFO)`。
    public static let cpuTaskCount: MetricID = "cpu.tasks"
    /// 线程数，同上。
    public static let cpuThreadCount: MetricID = "cpu.threads"

    /// 每秒处理器间中断（IPI）次数，全部核之和（`PROCESSOR_CPU_STAT64` 的 `ipi_cnt`）。
    public static let cpuInterruptIPIRate: MetricID = "cpu.irq.ipi"
    /// 每秒定时器中断次数（`timer_cnt`）。
    public static let cpuInterruptTimerRate: MetricID = "cpu.irq.timer"
    /// 每秒其余中断次数：`irq_ex_cnt` 扣掉 IPI 和定时器后的余量，约等于设备中断（边界稿 §1.1、§8 C8）。
    public static let cpuInterruptOtherRate: MetricID = "cpu.irq.other"

    /// 热状态，`ProcessInfo.ThermalState` 的原始值：0 nominal、1 fair、2 serious、3 critical。
    public static let cpuThermalState: MetricID = "cpu.thermal.state"
    /// 热压力等级，notify `com.apple.system.thermalpressurelevel` 的状态值：
    /// 0 nominal、1 moderate、2 heavy、3 trapping、4 sleeping。
    public static let cpuThermalPressure: MetricID = "cpu.thermal.pressure"
}
