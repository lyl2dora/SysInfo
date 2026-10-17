// 应用活动窗口的数据（D67–D69，应用活动设计 §3.3）。
//
// - 「现在」档：窗口可见时登记 `app.coalition` + `app.assertions` + `power.sensors`（SoC 功率）需求，间隔取设置（默认 2 s）；
//   每个 coalition 结果到达后在后台组装全表（AppActivityBuilder），CPU 前几名再用 Top N 补上宿主 coalition 的副标题；
// - 历史时段：读历史库的按应用汇总与断言区间（窗口可见时每 60 s 刷新一次）；应用位置按 bundle id 或路径查；
// - 筛选（分类、搜索）与排序在主线程上做（至多几百行）；选中按行 id 保持。
// 窗口不可见（关闭、最小化、被完全遮住）时注销全部需求，开销为 0（D67）。

import AppKit
import Observation
import SwiftUI
import SysCollectors
import SysModel
import SysStore

@Observable
final class AppActivityModel {
    var range: AppActivityRange = .now {
        didSet { if range != oldValue { rangeChanged() } }
    }
    var category: AppActivityCategory = .all
    var search = ""
    var sortOrder: [KeyPathComparator<AppActivityRow>] = [KeyPathComparator(\.sortCPU, order: .reverse)]
    var selection: AppActivityRow.ID?

    /// 「现在」档的全表与合计。
    private(set) var live: AppActivitySnapshot?
    /// 历史时段的行与断言区间。
    private(set) var historyRows: [AppActivityRow] = []
    private(set) var historySpans: [PowerAssertionSpan] = []
    private(set) var historyRangeStart: Date?
    private(set) var isLoadingHistory = false
    /// coalition 不可用（自检未过）：「现在」档没有数据。
    private(set) var coalitionUnavailable = false

    /// 窗口里的应用详情（与面板的详情页各用一个实例）。
    let detail: AppDetailModel

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let demand: DemandSlot
    @ObservationIgnored private let builder = AppActivityBuilder()
    @ObservationIgnored private let topBuilder = TopNBuilder()
    @ObservationIgnored private var building = false
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var appPaths: [String: String?] = [:]

    init(services: AppServices, settings: AppSettings, engine: SamplingEngine) {
        self.services = services
        self.settings = settings
        self.demand = DemandSlot(engine: engine)
        self.detail = AppDetailModel(sampler: services.collectors.apps)
    }

    // MARK: - 可见性与需求

    /// 窗口可见性变化（打开、关闭、最小化、遮挡）。
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        updateDemand()
        if visible {
            if range == .now { coalitionTick(allowStale: true) } else { startHistoryRefresh() }
        } else {
            historyTask?.cancel()
            historyTask = nil
        }
        updateDetail()
    }

    /// 设置里的间隔变了。
    func settingsChanged() {
        updateDemand()
    }

    private func updateDemand() {
        guard isVisible, range == .now else {
            demand.set(nil)
            return
        }
        var collectors: Set<CollectorID> = [AppSampler.collectorID, PowerAssertionCollector.collectorID]
        if services.power.sensors != nil { collectors.insert(PowerSensorCollector.collectorID) }
        demand.set(Demand(collectors: collectors, interval: settings.appActivityInterval, source: "appActivity"))
    }

    private func rangeChanged() {
        updateDemand()
        selection = nil
        if range == .now {
            historyTask?.cancel()
            historyTask = nil
            historyRows = []
            historySpans = []
            coalitionTick(allowStale: true)
        } else if isVisible {
            startHistoryRefresh()
        }
        updateDetail()
    }

    /// 选中变化：「现在」档的选中行驱动详情的实时数据。
    func updateDetail() {
        let row = selectedRow
        detail.show(isVisible && range == .now ? row?.coalitionID : nil)
    }

    // MARK: - 「现在」档

    /// 引擎交付了 `app.coalition` 的结果（或窗口刚打开，用已有的窗口）。
    func coalitionTick(allowStale: Bool = false) {
        guard isVisible, range == .now, !building, let sampler = services.collectors.apps else {
            coalitionUnavailable = services.collectors.apps == nil
            return
        }
        guard let window = sampler.latestWindow else { return }
        if allowStale {
            let age = Double(SampleTime.now().continuousNanos &- window.time.continuousNanos) / 1e9
            guard age <= TopNModel.firstWindowMaxAge else { return }
        }
        building = true
        let builder = builder
        let topBuilder = topBuilder
        let assertions = services.collectors.assertions?.latestSnapshot
        let trusted = sampler.auxiliarySlotsTrusted
        Task.detached(priority: .utility) { [weak self] in
            var snapshot = builder.build(window: window, assertions: assertions)
            // 宿主 coalition 的副标题：只对 CPU 前 8 名量成员（同 Top N），不为全表量 rusage。
            let top = topBuilder.build(window: window, rows: 8, grouping: .byApp, showPerfLevel0: false, slotsTrusted: trusted)
            let members = Dictionary(top.compactMap { row in row.topMember.map { (row.coalitionID, $0.name) } }) { a, _ in a }
            for index in snapshot.rows.indices {
                if let id = snapshot.rows[index].coalitionID, let name = members[id] { snapshot.rows[index].topMemberName = name }
            }
            await MainActor.run {
                guard let self else { return }
                self.building = false
                guard self.isVisible, self.range == .now else { return }
                self.live = snapshot
                self.coalitionUnavailable = false
                self.detail.tick()
            }
        }
    }

    // MARK: - 历史时段

    private func startHistoryRefresh() {
        historyTask?.cancel()
        historyTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.loadHistory()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// 历史记录已关闭或库打不开时的说明。
    var historyUnavailableReason: String? {
        if services.history == nil { return String(localized: "历史库不可用") }
        if !settings.historyAppsEnabled { return String(localized: "没有记录每应用数据（可在设置的「应用活动」页打开）") }
        return nil
    }

    private func loadHistory() async {
        guard let history = services.history, let start = range.start(now: Date()) else {
            historyRows = []
            historySpans = []
            return
        }
        isLoadingHistory = true
        let now = Date()
        let totals = (try? await history.appTotals(from: start, to: now)) ?? []
        let spans = (try? await history.assertionSpans(from: start, to: now)) ?? []
        guard !Task.isCancelled, range != .now else { return }
        var bySpanApp: [String: (seconds: Double, assertions: [PowerAssertion])] = [:]
        for span in spans where span.kind.preventsSleep {
            var entry = bySpanApp[span.appKey, default: (0, [])]
            entry.seconds += span.seconds(from: start, to: now, now: now)
            if !entry.assertions.contains(where: { $0.type == span.type && $0.name == span.name }) {
                entry.assertions.append(
                    PowerAssertion(
                        pid: 0, holderPID: 0, holderName: span.holder.isEmpty ? span.appName : span.holder, type: span.type,
                        name: span.name, since: span.start))
            }
            bySpanApp[span.appKey] = entry
        }
        var rows: [AppActivityRow] = totals.map { total in
            let path = appPath(forKey: total.key)
            var row = total.row(appPath: path, isApp: path != nil, assertions: bySpanApp[total.key]?.assertions ?? [])
            row.sleepPreventionSeconds = bySpanApp[total.key]?.seconds
            if total.key == AppIdentity.other.key { row.name = String(localized: "其余应用（合计）") }
            return row
        }
        // 只阻止过睡眠、没有进每分钟前列的应用也要出现在「阻止睡眠」分类里。
        let present = Set(rows.map(\.key))
        for (key, entry) in bySpanApp where !present.contains(key) {
            let name = spans.first { $0.appKey == key }?.appName ?? key
            let path = appPath(forKey: key)
            rows.append(
                AppActivityRow(
                    id: key, key: key, name: name, appPath: path, isApp: path != nil, sleepPreventionSeconds: entry.seconds,
                    assertions: entry.assertions))
        }
        historyRows = rows
        historySpans = spans
        historyRangeStart = start
        isLoadingHistory = false
    }

    /// 身份键 → 应用位置：bundle id 用 LaunchServices 查，路径取最外层 .app。查不到时为 nil（按后台进程显示）。
    func appPath(forKey key: String) -> String? {
        if let cached = appPaths[key] { return cached }
        var path: String?
        if key.hasPrefix("/") {
            if let range = key.range(of: ".app/") { path = String(key[..<range.lowerBound]) + ".app" } else if key.hasSuffix(".app") { path = key }
        } else if key.contains("."), !key.hasPrefix("comm:"), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) {
            path = url.path
        }
        appPaths[key] = path
        return path
    }

    // MARK: - 表格

    /// 当前时间段的全部行（未筛选）。
    var allRows: [AppActivityRow] { range == .now ? live?.rows ?? [] : historyRows }

    /// 筛选、搜索、排序后的行。
    var visibleRows: [AppActivityRow] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        let filtered = allRows.filter { row in
            row.matches(category)
                && (needle.isEmpty || row.name.localizedCaseInsensitiveContains(needle)
                    || row.key.localizedCaseInsensitiveContains(needle)
                    || (row.topMemberName?.localizedCaseInsensitiveContains(needle) ?? false))
        }
        return filtered.sorted(using: sortOrder)
    }

    var selectedRow: AppActivityRow? {
        guard let selection else { return nil }
        return allRows.first { $0.id == selection }
    }

    /// 按某一列降序（Top N 的「查看全部」、总览卡片进入时）。
    func sort(by column: AppActivityColumn) {
        guard let comparator = column.comparator else { return }
        sortOrder = [comparator]
    }

    /// 历史时段的应用合计能耗，J（只计已知部分）；一行都不知道时为 nil。
    var historyTotalJoules: (joules: Double, partial: Bool)? {
        var total = 0.0
        var known = false
        var partial = false
        for row in historyRows where row.activeMinutes != nil {
            if let joules = row.energyJoules {
                total += joules
                known = true
                partial = partial || row.energyPartial
            } else {
                partial = true
            }
        }
        return known ? (total, partial) : nil
    }
}

/// 表格的列：排序键与默认是否显示（D67 AA1）。
enum AppActivityColumn: String, CaseIterable, Identifiable {
    case name, cpu, cpuTime, power, memory, gpu, ane, diskRead, diskWrite, wakeups, sleep, perfLevel0, pageins, members,
        minutes

    var id: String { rawValue }

    /// 从某个模块的 Top N「查看全部」进入时按哪一列排序（D64）。
    init(metric: TopNMetric) {
        switch metric {
        case .cpu: self = .cpu
        case .memory: self = .memory
        case .disk: self = .diskWrite
        case .gpu: self = .gpu
        }
    }

    /// 降序的比较器。
    var comparator: KeyPathComparator<AppActivityRow>? {
        switch self {
        case .name: KeyPathComparator(\.name)
        case .cpu: KeyPathComparator(\.sortCPU, order: .reverse)
        case .cpuTime: KeyPathComparator(\.sortCPUTime, order: .reverse)
        case .power: KeyPathComparator(\.sortPower, order: .reverse)
        case .memory: KeyPathComparator(\.sortMemory, order: .reverse)
        case .gpu: KeyPathComparator(\.sortGPU, order: .reverse)
        case .ane: KeyPathComparator(\.sortANE, order: .reverse)
        case .diskRead: KeyPathComparator(\.sortDiskRead, order: .reverse)
        case .diskWrite: KeyPathComparator(\.sortDiskWrite, order: .reverse)
        case .wakeups: KeyPathComparator(\.sortWakeups, order: .reverse)
        case .sleep: KeyPathComparator(\.sortSleep, order: .reverse)
        case .perfLevel0: KeyPathComparator(\.sortPerfLevel0, order: .reverse)
        case .pageins: KeyPathComparator(\.sortPageins, order: .reverse)
        case .members: KeyPathComparator(\.sortMembers, order: .reverse)
        case .minutes: KeyPathComparator(\.sortMinutes, order: .reverse)
        }
    }
}

/// 排序键：可选值按 -1 处理（排在 0 后面），「现在」档与历史时段共用同一列。
nonisolated extension AppActivityRow {
    var sortCPU: Double { cpu ?? Double(cpuTimeNanos ?? 0) / 1e9 }
    var sortCPUTime: Double { Double(cpuTimeNanos ?? 0) }
    var sortPower: Double { watts ?? energyJoules ?? -1 }
    var sortMemory: Double { Double(footprint ?? 0) }
    var sortGPU: Double { gpuShare ?? Double(gpuTimeNanos ?? 0) / 1e9 }
    var sortANE: Double { aneWatts ?? aneJoules ?? 0 }
    var sortDiskRead: Double { diskRead ?? 0 }
    var sortDiskWrite: Double { diskWrite ?? 0 }
    var sortWakeups: Double { wakeups ?? 0 }
    var sortSleep: Double { sleepPreventionSeconds ?? (preventsSleep ? 1 : 0) }
    var sortPerfLevel0: Double { perfLevel0Share ?? -1 }
    var sortPageins: Double { pageins ?? 0 }
    var sortMembers: Double { Double(memberCount ?? 0) }
    var sortMinutes: Double { Double(activeMinutes ?? 0) }
}
