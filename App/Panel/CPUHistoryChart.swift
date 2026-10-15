// 面板 CPU tab 的历史图（CPU 模块设计 §7.2、§6，K39）。
//
// - 2 分、15 分读内存环形缓冲（原始值）；1 时、24 时、7 天读历史库：1 时用分钟表，24 时用分钟表降采样到
//   5 分钟一桶（288 点），7 天用小时表。画成均值线加峰值带（有峰值时），空洞处断开；
// - 历史库的数据在 tab 可见期间每 60 s 重读一次（读之前记录器会先提交内存里的分钟）。

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
            SegmentedButtons(
                selection: Binding(get: { current }, set: { span = $0 }),
                options: ChartSpan.allCases.map { ($0, Self.title($0)) })

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

    /// 用 Canvas 自绘（均值线 + 面积 / 峰值带、网格、刻度）。原先用 Swift Charts，每秒重新布局整张图，
    /// 是面板开销的大头之一（CPU 模块偏离记录 2026-10-15）。
    private var chart: some View {
        let points = points
        let span = current.seconds
        let showsArea = !current.usesHistory
        let ticks = [-span, -span / 2, 0]
        return VStack(spacing: 2) {
            HStack(alignment: .top, spacing: 4) {
                Canvas { context, size in
                    func x(_ v: Double) -> CGFloat { CGFloat((v + span) / span) * size.width }
                    func y(_ v: Double) -> CGFloat { size.height * (1 - CGFloat(min(max(v, 0), 1))) }
                    // 网格
                    var grid = Path()
                    for level in [0.0, 0.5, 1.0] {
                        grid.move(to: CGPoint(x: 0, y: y(level)))
                        grid.addLine(to: CGPoint(x: size.width, y: y(level)))
                    }
                    for t in ticks {
                        grid.move(to: CGPoint(x: x(t), y: 0))
                        grid.addLine(to: CGPoint(x: x(t), y: size.height))
                    }
                    context.stroke(grid, with: .color(.secondary.opacity(0.25)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                    // 按段画：空洞处断开
                    let segments = Dictionary(grouping: points, by: \.segment).values.map { $0.sorted { $0.x < $1.x } }
                    for segment in segments where !segment.isEmpty {
                        var line = Path()
                        for (i, p) in segment.enumerated() {
                            let pt = CGPoint(x: x(p.x), y: y(p.y))
                            if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
                        }
                        if showsArea, let first = segment.first, let last = segment.last {
                            var area = line
                            area.addLine(to: CGPoint(x: x(last.x), y: y(0)))
                            area.addLine(to: CGPoint(x: x(first.x), y: y(0)))
                            area.closeSubpath()
                            context.fill(area, with: .color(.accentColor.opacity(0.18)))
                        }
                        // 峰值带：均值到峰值之间
                        let peaks = segment.filter { $0.peak != nil }
                        if peaks.count == segment.count, segment.count > 1 {
                            var band = Path()
                            for (i, p) in segment.enumerated() {
                                let pt = CGPoint(x: x(p.x), y: y(p.peak ?? p.y))
                                if i == 0 { band.move(to: pt) } else { band.addLine(to: pt) }
                            }
                            for p in segment.reversed() { band.addLine(to: CGPoint(x: x(p.x), y: y(p.y))) }
                            band.closeSubpath()
                            context.fill(band, with: .color(.accentColor.opacity(0.15)))
                        }
                        context.stroke(line, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    }
                }
                VStack(alignment: .leading) {
                    Text(PercentFormat.string(fromRatio: 1))
                    Spacer()
                    Text(PercentFormat.string(fromRatio: 0.5))
                    Spacer()
                    Text(PercentFormat.string(fromRatio: 0))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            }
            HStack {
                Text(Self.axisLabel(span))
                Spacer()
                Text(Self.axisLabel(span / 2))
                Spacer()
                Text(Self.axisLabel(0))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.trailing, 38)
        }
    }

    static func axisLabel(_ secondsAgo: Double) -> String {
        if secondsAgo <= 0 { return String(localized: "现在") }
        if secondsAgo < 3600 { return String(localized: "\(Int(secondsAgo / 60)) 分前") }
        if secondsAgo < 86_400 * 2 { return String(localized: "\(Int(secondsAgo / 3600)) 时前") }
        return String(localized: "\(Int(secondsAgo / 86_400)) 天前")
    }
}
