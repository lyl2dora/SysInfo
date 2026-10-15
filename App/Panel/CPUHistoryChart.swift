// 面板 CPU tab 的历史图（CPU 模块设计 §7.2、§6，K39）。
//
// - 2 分、15 分读内存环形缓冲（原始值）；1 时、24 时、7 天读历史库：1 时用分钟表，24 时用分钟表降采样到
//   5 分钟一桶（288 点），7 天用小时表。画成均值线加峰值带（有峰值时），空洞处断开；
// - 历史库的数据在 tab 可见期间每 60 s 重读一次（读之前记录器会先提交内存里的分钟）。

import Charts
import SwiftUI
import SysCollectors
import SysModel
import SysStore

struct CPUHistoryChart: View {
    let store: MetricStore
    let history: HistoryRecorder?
    let defaultSpan: ChartSpan

    @State private var span: ChartSpan?
    @State private var stored: [StoredPoint] = []
    @State private var loadError = false

    private var current: ChartSpan { span ?? defaultSpan }

    /// 一个点：x 为相对现在的秒数（≤ 0），`segment` 在空洞处断开。
    struct ChartPoint: Identifiable {
        var id: Double { x }
        var x: Double
        var y: Double
        var peak: Double?
        var segment: Int
    }

    struct StoredPoint {
        var date: Date
        var avg: Double
        var max: Double?
        /// 桶宽，秒（判断空洞）。
        var bucket: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("跨度", selection: Binding(get: { current }, set: { span = $0 })) {
                ForEach(ChartSpan.allCases) { s in
                    Text(Self.title(s)).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            chart
                .frame(height: 110)
            if current.usesHistory, history == nil || loadError {
                Text("历史库不可用").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task(id: current) {
            guard current.usesHistory else { return }
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    static func title(_ span: ChartSpan) -> String {
        switch span {
        case .twoMinutes: String(localized: "2 分")
        case .fifteenMinutes: String(localized: "15 分")
        case .oneHour: String(localized: "1 时")
        case .oneDay: String(localized: "24 时")
        case .sevenDays: String(localized: "7 天")
        }
    }

    // MARK: - 数据

    private func load() async {
        guard let history else { return }
        let now = Date()
        let span = current
        let (granularity, bucket): (HistoryGranularity, Int64) =
            switch span {
            case .oneHour: (.minute, 1)
            case .oneDay: (.minute, 5)
            default: (.hour, 60)
            }
        do {
            let points = try await history.series(
                .cpuUsageTotal, from: now.addingTimeInterval(-span.seconds), to: now, granularity: granularity,
                bucketMinutes: bucket)
            stored = points.map {
                StoredPoint(
                    date: Date(timeIntervalSince1970: TimeInterval($0.minute * 60)), avg: $0.avg, max: $0.max,
                    bucket: Double(bucket * 60))
            }
            loadError = false
        } catch {
            loadError = true
        }
    }

    private var points: [ChartPoint] {
        if current.usesHistory {
            let now = Date()
            var segment = 0
            var previous: StoredPoint?
            return stored.map { p in
                if let previous, p.date.timeIntervalSince(previous.date) > p.bucket * 1.5 { segment += 1 }
                previous = p
                // 点画在桶的中间
                let x = p.date.addingTimeInterval(p.bucket / 2).timeIntervalSince(now)
                return ChartPoint(x: min(x, 0), y: p.avg, peak: p.max, segment: segment)
            }
        }
        let raw = store.recentPoints(.cpuUsageTotal, seconds: current.seconds)
        guard let newest = raw.last?.continuousNanos else { return [] }
        let maxGap = store.maxContinuousGapNanos(for: CPULoadCollector.collectorID)
        return TimeSeries.segmented(raw, maxGapNanos: maxGap).map { point, value, segment in
            ChartPoint(x: -Double(newest - point.continuousNanos) / 1e9, y: value, peak: nil, segment: segment)
        }
    }

    // MARK: - 图

    private var chart: some View {
        let points = points
        let span = current.seconds
        return Chart {
            ForEach(points.filter { $0.peak != nil }) { p in
                AreaMark(
                    x: .value("时间", p.x), yStart: .value("均值", p.y), yEnd: .value("峰值", p.peak ?? p.y),
                    series: .value("段", "peak\(p.segment)")
                )
                .foregroundStyle(Color.accentColor.opacity(0.15))
            }
            if !current.usesHistory {
                AreaPlot(
                    points, x: .value("时间", \.x), y: .value("占用", \.y), series: .value("段", \.segment),
                    stacking: .unstacked
                )
                .foregroundStyle(Color.accentColor.opacity(0.18))
            }
            LinePlot(points, x: .value("时间", \.x), y: .value("占用", \.y), series: .value("段", \.segment))
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXScale(domain: -span...0)
        .chartYScale(domain: 0...1)
        .chartXAxis {
            AxisMarks(values: [-span, -span / 2, 0]) { value in
                AxisGridLine()
                let anchor: UnitPoint =
                    value.index == 0 ? .topLeading : (value.index == value.count - 1 ? .topTrailing : .top)
                AxisValueLabel(anchor: anchor, collisionResolution: .disabled) {
                    if let seconds = value.as(Double.self) {
                        Text(Self.axisLabel(-seconds))
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
    }

    static func axisLabel(_ secondsAgo: Double) -> String {
        if secondsAgo <= 0 { return String(localized: "现在") }
        if secondsAgo < 3600 { return String(localized: "\(Int(secondsAgo / 60)) 分前") }
        if secondsAgo < 86_400 * 2 { return String(localized: "\(Int(secondsAgo / 3600)) 时前") }
        return String(localized: "\(Int(secondsAgo / 86_400)) 天前")
    }
}
