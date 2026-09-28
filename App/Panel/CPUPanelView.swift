// 面板的 CPU tab（M0 设计 §6）：大号总占用、最近 2 分钟的折线图（读环形缓冲）、每核占用的小柱状图（不区分核类型）。

import Charts
import SwiftUI
import SysCollectors
import SysModel

struct CPUPanelView: View {
    let store: MetricStore

    /// 折线图的时间跨度，秒。
    static let chartSpan: Double = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelCard {
                header
            }
            PanelCard {
                chart
            }
            PanelCard {
                cores
            }
        }
    }

    // MARK: - 总占用

    private var header: some View {
        let sample = store.latest[.cpuUsageTotal]
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("总占用")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(sample?.value.map { PercentFormat.string(fromRatio: $0) } ?? PercentFormat.placeholder)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer()
            if let sample {
                qualityBadge(sample.quality)
            }
        }
    }

    @ViewBuilder
    private func qualityBadge(_ quality: DataQuality) -> some View {
        switch quality {
        case .estimated:
            Text("估算")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("部分核的计数器复位，总占用由其余核估算")
        case .unavailable:
            Text("不可用")
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    // MARK: - 折线图

    /// 图表上的一个点：x 为相对最新样本的秒数（−120…0），`segment` 在不可用处和长间隔处断开折线。
    /// 时间用包含睡眠的连续时钟：系统睡眠前的点不会被标成「几秒前」，也不会和醒来后的点连成一条线。
    private struct ChartPoint: Identifiable {
        var id: UInt64
        var x: Double
        var y: Double
        var segment: Int
    }

    private var chartPoints: [ChartPoint] {
        let points = store.recentPoints(.cpuUsageTotal, seconds: Self.chartSpan)
        guard let newest = points.last?.continuousNanos else { return [] }
        let maxGap = store.maxContinuousGapNanos(for: CPULoadCollector.collectorID)
        return TimeSeries.segmented(points, maxGapNanos: maxGap).map { point, value, segment in
            ChartPoint(
                id: point.continuousNanos,
                x: -Double(newest - point.continuousNanos) / 1e9,
                y: value,
                segment: segment)
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("最近 2 分钟")
                .font(.caption)
                .foregroundStyle(.secondary)
            Chart {
                let points = chartPoints
                AreaPlot(
                    points, x: .value("时间", \.x), y: .value("占用", \.y), series: .value("段", \.segment),
                    stacking: .unstacked
                )
                .foregroundStyle(Color.accentColor.opacity(0.18))
                LinePlot(points, x: .value("时间", \.x), y: .value("占用", \.y), series: .value("段", \.segment))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartXScale(domain: -Self.chartSpan...0)
            .chartYScale(domain: 0...1)
            .chartXAxis {
                AxisMarks(values: [-120, -60, 0]) { value in
                    AxisGridLine()
                    // 两端的标签向内对齐，避免被裁掉或与 Y 轴标签重叠。
                    let anchor: UnitPoint =
                        value.index == 0 ? .topLeading : (value.index == value.count - 1 ? .topTrailing : .top)
                    AxisValueLabel(anchor: anchor, collisionResolution: .disabled) {
                        if let seconds = value.as(Double.self) {
                            Text(seconds == 0 ? "现在" : "\(Int(-seconds)) 秒前")
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, 0.5, 1]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let ratio = value.as(Double.self) {
                            Text(PercentFormat.string(fromRatio: ratio))
                        }
                    }
                }
            }
            .frame(height: 110)
        }
    }

    // MARK: - 每核

    private var cores: some View {
        let cores = store.cpuCores
        return VStack(alignment: .leading, spacing: 6) {
            Text("每核占用（\(cores.count) 个逻辑核）")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(cores.enumerated()), id: \.offset) { index, sample in
                    CoreBar(index: index, value: sample.value)
                }
            }
            .frame(height: 44)
        }
    }
}

/// 一个核的小柱。不可用时画成空槽，不画成 0。
private struct CoreBar: View {
    let index: Int
    let value: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.quaternary)
                if let value {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor)
                        .frame(height: max(proxy.size.height * min(max(value, 0), 1), 1))
                }
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        let percent = value.map { PercentFormat.string(fromRatio: $0) } ?? String(localized: "不可用")
        return String(localized: "核 \(index)：\(percent)")
    }
}
