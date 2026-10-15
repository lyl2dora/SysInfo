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

    // MARK: - 图

    /// 绘制区由 ChartDrawView 自绘（AppKit，数据变化时只重绘它自己）；刻度文字是静态的 SwiftUI。
    private var chart: some View {
        let span = current.seconds
        let stored: [StoredPoint]? = current.usesHistory ? self.stored : nil
        return VStack(spacing: 2) {
            HStack(alignment: .top, spacing: 4) {
                LiveView(make: { ChartDrawView(store: store) }) { view in
                    view.spanSeconds = span
                    view.stored = stored
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
