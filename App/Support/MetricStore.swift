// 指标存储（M0 设计 §6）：在 MainActor 上接收引擎的 TickResult，供菜单栏、面板和诊断页读取。
//
// - 每个 MetricID 的最新样本；
// - 内存环形缓冲：按「时间戳 + 值」逐条存，不假设采样间隔固定，每个指标保留 15 分钟（K39 的倾向值，CPU 模块再定）；
// - 采集器健康信息与调度状态（诊断页，K19）；
// - 菜单栏显示用的 CPU 总占用：EMA 平滑，τ = 1.5 s（K24）；面板图表用原始值。

import Foundation
import Observation
import SysCollectors
import SysModel
import OSLog

/// 菜单栏上 CPU 数字的状态。
enum MenuBarReading: Equatable {
    /// 还没有样本（刚启动或刚建立差分基线）。
    case noData
    /// 数据源不可用（不显示可能错误的数值，D05）。
    case unavailable
    /// 平滑后的比例 0…1；`estimated` 表示部分核被丢弃后由其余核估算（K17）。
    case value(Double, estimated: Bool)
}

@Observable
final class MetricStore {
    static let historyRetentionSeconds: Double = 15 * 60
    static let menuBarTimeConstant: Double = 1.5

    /// 每个指标的最新样本。
    private(set) var latest: [MetricID: Sample] = [:]
    /// 每个指标的环形缓冲。
    private(set) var history: [MetricID: TimeSeries] = [:]
    /// 最近一次 CPU 采样的每核占用，按核序号排列。
    private(set) var cpuCores: [Sample] = []
    /// 菜单栏显示用的 CPU 总占用。
    private(set) var menuBarCPU: MenuBarReading = .noData
    /// 调度器状态（tick 数、需求、降频、各采集器健康信息）。
    private(set) var engineStatus: EngineStatus?
    /// 最近一个 tick 的整体耗时。
    private(set) var lastTickCost: SampleCost?

    @ObservationIgnored private var smoother = ExponentialSmoother(timeConstant: MetricStore.menuBarTimeConstant)
    @ObservationIgnored private var ticksSinceLog = 0

    func apply(_ event: EngineEvent) {
        switch event {
        case .status(let status):
            updateStatus(status)
        case .tick(let result):
            ingest(result)
            updateStatus(result.status)
        }
    }

    /// 最近 `seconds` 秒内的点（以该指标最新的点为「现在」）。
    func recentPoints(_ id: MetricID, seconds: Double) -> ArraySlice<TimeSeriesPoint> {
        guard let series = history[id] else { return [] }
        return series.points(inLast: UInt64(max(seconds, 0) * 1e9))
    }

    /// 最近 `seconds` 秒内可用值的平均；没有可用值时为 nil。
    func mean(_ id: MetricID, seconds: Double) -> Double? {
        history[id]?.mean(inLast: UInt64(max(seconds, 0) * 1e9))
    }

    // MARK: - 私有

    private func ingest(_ result: TickResult) {
        lastTickCost = result.cost
        guard !result.samples.isEmpty else { return }

        var cores: [(index: Int, sample: Sample)] = []
        for sample in result.samples {
            latest[sample.id] = sample
            history[sample.id, default: TimeSeries(retentionSeconds: Self.historyRetentionSeconds)].append(sample)
            if let index = sample.id.cpuCoreIndex {
                cores.append((index, sample))
            }
            if sample.id == .cpuUsageTotal {
                updateMenuBar(with: sample)
            }
        }
        if !cores.isEmpty {
            cpuCores = cores.sorted { $0.index < $1.index }.map(\.sample)
        }

        ticksSinceLog += 1
        if ticksSinceLog >= 60 {
            ticksSinceLog = 0
            Log.store.debug(
                "tick #\(result.status.tickCount)：\(result.samples.count) 个样本，耗时 \(result.cost.wallNanos) ns（CPU \(result.cost.cpuNanos) ns）"
            )
        }
    }

    private func updateMenuBar(with sample: Sample) {
        let smoothed = smoother.update(sample.value, atMonotonicNanos: sample.time.monotonicNanos)
        let reading: MenuBarReading
        if let smoothed {
            reading = .value(smoothed, estimated: sample.quality == .estimated)
        } else {
            reading = .unavailable
        }
        if reading != menuBarCPU {
            menuBarCPU = reading
        }
    }

    private func updateStatus(_ status: EngineStatus) {
        let previous = engineStatus
        engineStatus = status

        // 调度状态的变化写 info 日志：验收第 5 条（无需求时不再唤醒）靠它核对。
        if (previous?.isTimerArmed ?? false) != status.isTimerArmed {
            if status.isTimerArmed {
                Log.store.info("采样定时器已排定，下次 tick \(status.nextTick ?? 0)")
            } else {
                Log.store.info("采样定时器已停止：没有生效的需求（累计 tick \(status.tickCount)）")
            }
        }
        if (previous?.demands ?? []) != status.demands {
            let summary = status.demands.map { registered in
                let collectors = registered.demand.collectors.map(\.rawValue).sorted().joined(separator: "+")
                let interval = registered.effectiveInterval.map { "\($0)s" } ?? "暂停"
                return "\(registered.demand.source.rawValue)[\(collectors)/\(interval)]"
            }
            Log.store.info("有效需求：\(summary.isEmpty ? "无" : summary.joined(separator: ", "), privacy: .public)")
        }
    }
}
