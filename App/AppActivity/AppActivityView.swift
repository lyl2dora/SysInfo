// 应用活动窗口的内容（D67，合并模式设计 §6）。
//
// - 工具栏：时间段（现在 / 1 小时 / 今天 / 7 天 / 30 天）与搜索；侧栏：分类；
// - 表格：多列可排序，列可隐藏、可拖动顺序（记在设置里）。同一组列在「现在」档显示速率，在历史时段显示总量；
// - 底部：「现在」档为应用合计功率与 SoC 功率（不给百分比，D67 AA2），历史时段为应用合计能耗；
// - 右侧 inspector：选中应用的详情（「现在」档复用面板的应用详情组件，另加最近 1 小时曲线；历史时段为总量、曲线与断言区间）。

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

    @State private var columns = TableColumnCustomization<AppActivityRow>()
    @State private var showsInspector = true

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            VStack(spacing: 0) {
                notice
                table
                Divider()
                footer
            }
            .inspector(isPresented: $showsInspector) {
                AppActivityInspector(model: model, services: services)
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
            }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: Text("搜索应用"))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("时间段", selection: $model.range) {
                    ForEach(AppActivityRange.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("「现在」为实时扫描；其余时段读历史库")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("详情", systemImage: "sidebar.right")
                }
                .help("显示或隐藏应用详情")
            }
        }
        .navigationTitle(Text("应用活动"))
        .navigationSubtitle(Text(subtitle))
        .onAppear { loadColumns() }
        .onChange(of: columns) { saveColumns() }
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
                        .badge(model.allRows.filter { $0.matches(category) }.count)
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
        ScrollViewReader { proxy in
            Table(of: AppActivityRow.self, selection: $model.selection, sortOrder: $model.sortOrder, columnCustomization: $columns) {
                Group {
                TableColumn("名称", value: \AppActivityRow.name) { row in
                    AppNameCell(row: row)
                }
                .width(min: 180, ideal: 240)
                .customizationID("name")
                .disabledCustomizationBehavior(.visibility)

                TableColumn(isNow ? "CPU" : "CPU 时间", value: \AppActivityRow.sortCPU) { row in
                    Cell(isNow ? row.cpu.map { PercentFormat.string(fromRatio: $0) } : row.cpuTimeNanos.map(Self.duration))
                }
                .width(min: 56, ideal: 80)
                .customizationID("cpu")

                TableColumn("累计 CPU 时间", value: \AppActivityRow.sortCPUTime) { row in
                    Cell(isNow ? row.cpuTimeNanos.map(Self.duration) : nil)
                }
                .width(min: 70, ideal: 84)
                .customizationID("cpuTime")
                .defaultVisibility(.hidden)

                TableColumn(isNow ? "功率" : "能耗", value: \AppActivityRow.sortPower) { row in
                    Cell(
                        isNow ? row.watts.map(Formatting.watts) : row.energyJoules.map { Formatting.appEnergy($0) + (row.energyPartial ? "*" : "") })
                        .help(row.energyPartial ? String(localized: "* 部分分钟的能耗未知（槽位核对未通过），只计已知部分") : "")
                }
                .width(min: 60, ideal: 70)
                .customizationID("power")

                TableColumn(isNow ? "内存" : "内存峰值", value: \AppActivityRow.sortMemory) { row in
                    Cell(row.footprint.flatMap { $0 > 0 ? Formatting.memory(Double($0)) : nil })
                }
                .width(min: 70, ideal: 80)
                .customizationID("memory")
                }
                Group {

                TableColumn(isNow ? "GPU" : "GPU 时间", value: \AppActivityRow.sortGPU) { row in
                    Cell(
                        isNow
                            ? row.gpuShare.map { PercentFormat.string(fromRatio: min($0, 1)) }
                            : row.gpuTimeNanos.flatMap { $0 > 0 ? Self.duration($0) : "0" })
                }
                .width(min: 56, ideal: 64)
                .customizationID("gpu")

                TableColumn(isNow ? "ANE（估算）" : "ANE 能耗", value: \AppActivityRow.sortANE) { row in
                    Cell(isNow ? row.aneWatts.map(Formatting.watts) : row.aneJoules.map(Formatting.appEnergy))
                }
                .width(min: 64, ideal: 76)
                .customizationID("ane")

                TableColumn(isNow ? "读" : "读取量", value: \AppActivityRow.sortDiskRead) { row in
                    Cell(row.diskRead.map { isNow ? Formatting.diskRate($0) : Formatting.diskBytes($0) })
                }
                .width(min: 64, ideal: 76)
                .customizationID("diskRead")

                TableColumn(isNow ? "写" : "写入量", value: \AppActivityRow.sortDiskWrite) { row in
                    Cell(row.diskWrite.map { isNow ? Formatting.diskRate($0) : Formatting.diskBytes($0) })
                }
                .width(min: 64, ideal: 76)
                .customizationID("diskWrite")

                TableColumn(isNow ? "唤醒" : "唤醒次数", value: \AppActivityRow.sortWakeups) { row in
                    Cell(row.wakeups.map { isNow ? Formatting.rate($0) : Formatting.count($0) })
                }
                .width(min: 56, ideal: 64)
                .customizationID("wakeups")

                TableColumn("阻止睡眠", value: \AppActivityRow.sortSleep) { row in
                    SleepCell(row: row, isNow: isNow)
                }
                .width(min: 56, ideal: 72)
                .customizationID("sleep")
                }
                Group {

                TableColumn("P0 占比", value: \AppActivityRow.sortPerfLevel0) { row in
                    Cell(row.perfLevel0Share.map { PercentFormat.string(fromRatio: $0) })
                }
                .width(min: 52, ideal: 60)
                .customizationID("perfLevel0")
                .defaultVisibility(.hidden)

                TableColumn("Pageins", value: \AppActivityRow.sortPageins) { row in
                    Cell(row.pageins.map(Formatting.rate))
                }
                .width(min: 52, ideal: 60)
                .customizationID("pageins")
                .defaultVisibility(.hidden)

                TableColumn("进程数", value: \AppActivityRow.sortMembers) { row in
                    Cell(row.memberCount.map(String.init))
                }
                .width(min: 44, ideal: 52)
                .customizationID("members")
                .defaultVisibility(.hidden)

                TableColumn("活跃分钟", value: \AppActivityRow.sortMinutes) { row in
                    Cell(row.activeMinutes.map(String.init))
                }
                .width(min: 56, ideal: 64)
                .customizationID("minutes")
                .defaultVisibility(.hidden)
                }
            } rows: {
                ForEach(model.visibleRows) { row in
                    TableRow(row).contextMenu { contextMenu(row) }
                }
            }
            .monospacedDigit()
            .onChange(of: model.live) {
                // 「现在」档刷新后重新排序，选中的行保持可见（D67 默认做法）。
                if let selection = model.selection { proxy.scrollTo(selection) }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ row: AppActivityRow) -> some View {
        if let path = row.appPath {
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }
        if isNow, let pid = row.representativePID, row.memberCount == 1,
            ProcessControl.eligibility(uid: ProcessInfoReader.uid(of: pid), pid: pid).isAllowed
        {
            Button("结束…") { ProcessTermination.confirmAndTerminate(pid: pid, name: row.name) }
        }
        Button("拷贝名称") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.name, forType: .string)
        }
    }

    // MARK: - 底部合计

    private var footer: some View {
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
                Text("每 \(settings.appActivityInterval) 秒刷新").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - 列配置

    private func loadColumns() {
        guard let data = settings.appActivityColumns,
            let decoded = try? JSONDecoder().decode(TableColumnCustomization<AppActivityRow>.self, from: data)
        else { return }
        columns = decoded
    }

    private func saveColumns() {
        settings.appActivityColumns = try? JSONEncoder().encode(columns)
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

// MARK: - 单元格

private struct Cell: View {
    let text: String?
    init(_ text: String?) { self.text = text }

    var body: some View {
        Text(text ?? "—")
            .foregroundStyle(text == nil ? .tertiary : .primary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct AppNameCell: View {
    let row: AppActivityRow

    var body: some View {
        HStack(spacing: 6) {
            AppIcon(path: row.appPath)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    Text(row.name).lineLimit(1)
                    if let count = row.memberCount, count > 1 {
                        Text("×\(count)").foregroundStyle(.tertiary)
                    }
                }
                if let member = row.topMemberName {
                    Text(member).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .help(row.key)
    }
}

private struct SleepCell: View {
    let row: AppActivityRow
    let isNow: Bool

    var body: some View {
        let sleeping = row.assertions.filter { $0.kind.preventsSleep }
        HStack(spacing: 3) {
            Spacer(minLength: 0)
            if !sleeping.isEmpty {
                Image(systemName: sleeping.contains { $0.kind == .preventSleep } ? "moon.zzz.fill" : "display")
                    .foregroundStyle(.orange)
            }
            if !isNow, let seconds = row.sleepPreventionSeconds {
                Text(Formatting.duration(seconds))
            }
        }
        .help(sleeping.map { "\($0.name)（\($0.type)）" + ($0.isOnBehalf ? String(localized: "，经 \($0.holderName)") : "") }.joined(separator: "\n"))
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
                    KeyValue(title: String(localized: "内存峰值"), value: row.footprint.map { Formatting.memory(Double($0)) } ?? "—")
                    KeyValue(title: String(localized: "GPU 时间"), value: row.gpuTimeNanos.map(AppActivityView.duration) ?? "—")
                    KeyValue(title: String(localized: "ANE 能耗"), value: row.aneJoules.map(Formatting.appEnergy) ?? "—")
                    KeyValue(
                        title: String(localized: "读取 / 写入"),
                        value: "\(Formatting.diskBytes(row.diskRead ?? 0)) / \(Formatting.diskBytes(row.diskWrite ?? 0))")
                    KeyValue(title: String(localized: "唤醒"), value: row.wakeups.map(Formatting.count) ?? "—")
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
