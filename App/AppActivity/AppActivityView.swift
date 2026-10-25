// 应用活动窗口的内容（D67，合并模式设计 §6）。
//
// - 工具栏：时间段（现在 / 1 小时 / 今天 / 7 天 / 30 天）、搜索与详情开关；侧栏：分类；
//   搜索平时是放大镜按钮，点击或 ⌘F 展开，失焦且没有内容时缩回（Finder 样式，D81）；
// - 表格（AppActivityTable，AppKit）：多列可排序，列可隐藏、可拖动顺序。同一组列在「现在」档显示速率，在历史时段显示总量；
// - 底部：「现在」档为应用合计功率与 SoC 功率（不给百分比，D67 AA2），历史时段为应用合计能耗；
// - 右侧详情栏：选中应用的详情（「现在」档复用面板的应用详情组件，另加最近 1 小时曲线；历史时段为总量、曲线与断言区间）。
//   打开时窗口向右加宽一个详情栏的宽度，表格与各列宽度不变；全屏或平铺时退回挤占表格（D81，开关由窗口控制器处理）。

import AppKit
import Charts
import SwiftUI
import SysCollectors
import SysModel
import SysStore

struct AppActivityView: View {
    @Bindable var model: AppActivityModel
    let store: MetricStore
    let services: AppServices
    let settings: AppSettings
    /// 开关详情栏（窗口控制器决定向外加宽还是挤占表格）。
    var toggleInspector: () -> Void = {}

    static let inspectorWidth: CGFloat = 320

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    notice
                    table
                    Divider()
                    footer
                }
                if model.showsInspector {
                    Divider()
                    AppActivityInspector(model: model, services: services)
                        .frame(width: Self.inspectorWidth)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("时间段", selection: $model.range) {
                    ForEach(AppActivityRange.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("「现在」为实时扫描；其余时段读历史库")
            }
            // 搜索在左、详情开关在右（D81）。
            ToolbarItemGroup(placement: .primaryAction) {
                ExpandingSearchField(text: $model.search, prompt: String(localized: "搜索应用"))
                Button(action: toggleInspector) {
                    Label("详情", systemImage: "sidebar.right")
                }
                .help("显示或隐藏应用详情")
            }
        }
        .navigationTitle(Text("应用活动"))
        .navigationSubtitle(Text(subtitle))
        .onChange(of: model.selection) { model.updateDetail() }
    }

    private var subtitle: String {
        let rows = model.visibleRows.count
        return String(localized: "\(rows) 个应用")
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        List(selection: Binding(get: { model.category }, set: { model.category = $0 ?? .all })) {
            Section("分类") {
                ForEach(AppActivityCategory.allCases, id: \.self) { category in
                    Label(category.title, systemImage: category.symbol)
                        .badge(model.categoryCounts[category] ?? 0)
                        .tag(category)
                }
            }
        }
    }

    // MARK: - 提示

    @ViewBuilder
    private var notice: some View {
        if model.range == .now, model.coalitionUnavailable {
            NoticeBar(text: String(localized: "应用活动数据不可用（coalition 自检未通过），可在诊断页查看原因"))
        } else if model.range != .now, let reason = model.historyUnavailableReason {
            NoticeBar(text: reason)
        } else if model.range == .now, let live = model.live, !live.slotsTrusted {
            NoticeBar(text: String(localized: "能耗槽位核对未通过，功率列暂不显示"))
        }
    }

    // MARK: - 表格

    private var isNow: Bool { model.range == .now }

    private var table: some View {
        AppActivityTable(
            rows: model.visibleRows, isNow: isNow, selection: $model.selection, sortOrder: $model.sortOrder,
            scrollToTopToken: model.scrollToTopToken)
    }

    // MARK: - 底部合计

    /// 底部合计单独成一个视图：它读 MetricStore（每个 tick 都变），不能让整张表跟着重绘。
    private var footer: some View {
        AppActivityFooter(model: model, store: store, interval: settings.appActivityInterval)
    }

    /// CPU / GPU 时间：「1:02:03」或「12.3 s」。
    static func duration(_ nanos: UInt64) -> String {
        let seconds = Double(nanos) / 1e9
        guard seconds >= 60 else { return String(format: "%.1f s", seconds) }
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - 搜索

/// Finder 样式的搜索（D81）：平时是放大镜按钮；点击或 ⌘F 展开为输入框并获得焦点；失焦且没有内容时缩回，
/// 有内容时保持展开（否则看不出列表正被过滤）。Esc 清空并缩回。SwiftUI 的 `.searchToolbarBehavior(.minimize)`
/// 在 macOS 上不可用；工具栏里的 TextField 也拿不到 @FocusState 的焦点，所以输入框用 AppKit 的 NSSearchField。
private struct ExpandingSearchField: View {
    @Binding var text: String
    let prompt: String

    @State private var expanded = false

    var body: some View {
        Group {
            if expanded || !text.isEmpty {
                ToolbarSearchField(
                    text: $text, prompt: prompt, focusOnAppear: expanded,
                    onEndEditing: { if text.isEmpty { expanded = false } },
                    onCancel: {
                        text = ""
                        expanded = false
                    }
                )
                .frame(width: 200)
            } else {
                Button { expanded = true } label: {
                    Label(prompt, systemImage: "magnifyingglass")
                }
                .help("搜索应用（⌘F）")
            }
        }
        // ⌘F 在两种状态下都能用：展开并把焦点放进输入框。
        .background {
            Button("") {
                if expanded {
                    NotificationCenter.default.post(name: ToolbarSearchField.focusRequest, object: nil)
                } else {
                    expanded = true
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// 工具栏里的 NSSearchField：出现时拿焦点；结束编辑、按 Esc 时回调。
private struct ToolbarSearchField: NSViewRepresentable {
    static let focusRequest = Notification.Name("AppActivitySearchFocusRequest")

    @Binding var text: String
    let prompt: String
    let focusOnAppear: Bool
    let onEndEditing: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: Self.focusRequest, object: nil, queue: .main
        ) { [weak field] _ in
            MainActor.assumeIsolated {
                if let field { field.window?.makeFirstResponder(field) }
            }
        }
        if focusOnAppear {
            // 先进视图树、进窗口，下一轮再拿焦点。
            DispatchQueue.main.async { [weak field] in
                if let field { field.window?.makeFirstResponder(field) }
            }
        }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ToolbarSearchField
        var observer: NSObjectProtocol?

        init(_ parent: ToolbarSearchField) { self.parent = parent }

        @objc func changed(_ sender: NSSearchField) {
            parent.text = sender.stringValue
        }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { parent.text = field.stringValue }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onEndEditing()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            control.window?.makeFirstResponder(nil)
            parent.onCancel()
            return true
        }
    }
}

// MARK: - 底部合计

private struct AppActivityFooter: View {
    let model: AppActivityModel
    let store: MetricStore
    let interval: Int

    var body: some View {
        let isNow = model.range == .now
        HStack(spacing: 6) {
            if isNow {
                let total = model.live?.totalWatts.map(Formatting.watts) ?? "—"
                let soc = store.latest[.powerSoC]?.value.map(Formatting.watts) ?? "—"
                Text("应用合计 \(total) · SoC \(soc)")
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(
                        "应用合计 = 全部应用的 CPU、GPU、ANE 能耗之和。SoC 功率里还有不属于任何应用的部分（fabric、显示、DRAM 控制器等静态功耗），空闲时占大头，所以两者不能相除。"
                    )
            } else {
                let total = model.historyTotalJoules.map { Formatting.appEnergy($0.joules) + ($0.partial ? "*" : "") } ?? "—"
                Text("应用合计 \(total)")
                    .help(model.historyTotalJoules?.partial == true ? String(localized: "* 有分钟的能耗未知，只计已知部分") : "")
                if let start = model.historyRangeStart {
                    Text("· \(start.formatted(date: .abbreviated, time: .shortened)) 起")
                }
                if model.isLoadingHistory { ProgressView().controlSize(.small) }
            }
            Spacer()
            if isNow {
                Text("每 \(interval) 秒刷新").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct NoticeBar: View {
    let text: String

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(text)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5))
    }
}

extension AppActivityRange {
    var title: String {
        switch self {
        case .now: String(localized: "现在")
        case .hour: String(localized: "1 小时")
        case .today: String(localized: "今天")
        case .week: String(localized: "7 天")
        case .month: String(localized: "30 天")
        }
    }
}

extension AppActivityCategory {
    var title: String {
        switch self {
        case .all: String(localized: "全部")
        case .apps: String(localized: "App")
        case .background: String(localized: "后台与系统")
        case .preventingSleep: String(localized: "阻止睡眠")
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .apps: "app"
        case .background: "gearshape.2"
        case .preventingSleep: "moon.zzz"
        }
    }
}

// MARK: - 详情

private struct AppActivityInspector: View {
    let model: AppActivityModel
    let services: AppServices

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let row = model.selectedRow {
                    if model.range == .now, let id = row.coalitionID {
                        AppDetailView(model: model.detail, route: AppRoute(coalitionID: id, name: row.name, metric: .cpu))
                    } else {
                        HistorySummary(row: row, range: model.range)
                    }
                    AssertionList(row: row, spans: model.historySpans.filter { $0.appKey == row.key }, isNow: model.range == .now)
                    AppHistoryChart(key: row.key, range: model.range, history: services.history)
                } else {
                    Text("选中一个应用查看详情")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(12)
        }
    }
}

private struct HistorySummary: View {
    let row: AppActivityRow
    let range: AppActivityRange

    /// 没有值显示「—」；只合计了部分分钟时注明（D98）。
    private func value(_ text: String?, _ column: AppHistoryPartial) -> String {
        guard let text else { return "—" }
        return row.historyPartial.contains(column) ? text + String(localized: "（部分分钟未知）") : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AppIcon(path: row.appPath, size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(row.key).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            PanelCard {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(range.title)合计").font(.caption.weight(.semibold))
                    KeyValue(title: String(localized: "CPU 时间"), value: row.cpuTimeNanos.map(AppActivityView.duration) ?? "—")
                    KeyValue(
                        title: String(localized: "能耗"),
                        value: row.energyJoules.map { Formatting.appEnergy($0) + (row.energyPartial ? String(localized: "（部分分钟未知）") : "") } ?? "—")
                    KeyValue(
                        title: String(localized: "内存峰值"),
                        value: value(row.footprint.map { Formatting.memory(Double($0)) }, .footprint))
                    KeyValue(title: String(localized: "GPU 时间"), value: value(row.gpuTimeNanos.map(AppActivityView.duration), .gpuTime))
                    KeyValue(title: String(localized: "ANE 能耗"), value: value(row.aneJoules.map(Formatting.appEnergy), .ane))
                    KeyValue(
                        title: String(localized: "读取 / 写入"),
                        value: "\(value(row.diskRead.map(Formatting.diskBytes), .diskRead)) / \(value(row.diskWrite.map(Formatting.diskBytes), .diskWrite))")
                    KeyValue(title: String(localized: "唤醒"), value: value(row.wakeups.map(Formatting.count), .wakeups))
                    KeyValue(title: String(localized: "有记录的分钟"), value: row.activeMinutes.map(String.init) ?? "—")
                }
                .monospacedDigit()
            }
            Text("历史只记每分钟各项前 10 名的应用，没进前列的分钟不计入，所以这里可能偏低。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct AssertionList: View {
    let row: AppActivityRow
    let spans: [PowerAssertionSpan]
    let isNow: Bool

    var body: some View {
        let current = row.assertions.filter { $0.kind.preventsSleep }
        if isNow, !current.isEmpty {
            PanelCard {
                VStack(alignment: .leading, spacing: 3) {
                    Text("正在阻止睡眠").font(.caption.weight(.semibold))
                    ForEach(current, id: \.spanKey) { assertion in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(assertion.name.isEmpty ? assertion.type : assertion.name).font(.caption).lineLimit(2)
                            Text(detail(assertion)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } else if !isNow, !spans.isEmpty {
            PanelCard {
                VStack(alignment: .leading, spacing: 3) {
                    Text("阻止睡眠的时段").font(.caption.weight(.semibold))
                    ForEach(spans.suffix(20), id: \.self) { span in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(span.name.isEmpty ? span.type : span.name).font(.caption).lineLimit(1)
                            Text(spanText(span)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if spans.count > 20 {
                        Text("另有 \(spans.count - 20) 段").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func detail(_ assertion: PowerAssertion) -> String {
        var parts = [assertion.kind == .preventSleep ? String(localized: "阻止睡眠") : String(localized: "阻止显示器睡眠")]
        if let since = assertion.since {
            let text = Calendar.current.isDateInToday(since)
                ? since.formatted(date: .omitted, time: .shortened) : since.formatted(date: .abbreviated, time: .shortened)
            parts.append(String(localized: "自 \(text)"))
        }
        if assertion.isOnBehalf { parts.append(String(localized: "经 \(assertion.holderName)")) }
        if assertion.count > 1 { parts.append("×\(assertion.count)") }
        return parts.joined(separator: " · ")
    }

    private func spanText(_ span: PowerAssertionSpan) -> String {
        let start = span.start.formatted(date: .abbreviated, time: .shortened)
        let end = span.end.map { $0.formatted(date: .omitted, time: .shortened) } ?? String(localized: "进行中")
        return "\(start) – \(end)" + (span.endEstimated ? String(localized: "（估计）") : "")
    }
}

/// 一个应用的 CPU 与功率曲线（历史库）：「现在」档看最近 1 小时，历史时段看所选时段。
/// 一条小曲线：标题、最大值，按分钟画线。
private struct MiniSeriesChart: View {
    let title: String
    let points: [(minute: Int64, value: Double)]
    let format: (Double) -> String
    var color: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("峰值 \(format(points.map(\.value).max() ?? 0))").font(.caption2).foregroundStyle(.secondary)
            }
            Chart(points, id: \.minute) { point in
                AreaMark(x: .value("时间", Self.date(point.minute)), y: .value(title, point.value))
                    .foregroundStyle(color.opacity(0.2))
                LineMark(x: .value("时间", Self.date(point.minute)), y: .value(title, point.value))
                    .foregroundStyle(color)
            }
            .chartYAxis(.hidden)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            .frame(height: 60)
        }
        .monospacedDigit()
    }

    static func date(_ minute: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(minute * 60)) }
}

private struct AppHistoryChart: View {
    let key: String
    let range: AppActivityRange
    let history: HistoryRecorder?

    @State private var points: [AppSeriesPoint] = []

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(range == .now ? "最近 1 小时" : "\(range.title)走势").font(.caption.weight(.semibold))
                if points.isEmpty {
                    Text("历史库里还没有这个应用的记录").font(.caption2).foregroundStyle(.secondary)
                } else {
                    MiniSeriesChart(title: "CPU", points: points.map { ($0.minute, $0.cpu) }, format: { PercentFormat.string(fromRatio: $0) })
                    if points.contains(where: { $0.watts != nil }) {
                        MiniSeriesChart(
                            title: String(localized: "功率"), points: points.compactMap { p in p.watts.map { (p.minute, $0) } },
                            format: Formatting.watts, color: .orange)
                    }
                }
            }
        }
        .task(id: "\(key)|\(range.rawValue)") { await load() }
    }

    private func load() async {
        guard let history else { return }
        let now = Date()
        let start = range.start(now: now) ?? now.addingTimeInterval(-3600)
        let span = now.timeIntervalSince(start)
        // 约 120 个桶。
        let bucket = max(1, Int64(span / 60 / 120))
        points = (try? await history.appSeries(key: key, from: start, to: now, bucketMinutes: bucket)) ?? []
    }
}
