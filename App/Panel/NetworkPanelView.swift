// 面板的「网络」tab（网络模块设计 §7，D60–D62）。
//
// 分区：概览（主接口、链路速率、VPN 标记、↓↑ 大字）→ 历史图（主接口入，叠加出）→ 流量统计（今日 / 本月）
// → 接口列表（物理接口各一行；虚拟接口折成一行汇总，点击进入列表页，D64）→ 连接信息（地址、网关、DNS、代理、公网 IP 按钮）
// → Wi-Fi 卡片（有活跃 Wi-Fi 时）→ 延迟卡片（开启时）。
// 每秒都在变的部分用 AppKit 自绘（做法同 LiveViews.swift），SwiftUI 只放外框和结构（读 NetworkModel，不读 MetricStore）。
// 需求由 PanelController 按 tab 可见性登记。本机地址只显示、不写日志。

import AppKit
import SwiftUI
import SysCollectors
import SysModel
import SysStore

struct NetworkPanelView: View {
    let store: MetricStore
    let services: AppServices
    @Bindable var settings: AppSettings
    @Environment(\.panelLayoutChanged) private var layoutChanged
    @Environment(\.panelNavigate) private var navigate

    var body: some View {
        let state = services.networkModel.state
        VStack(alignment: .leading, spacing: 10) {
            PanelCard {
                LiveView(make: { NetworkOverviewDrawView(store: store, services: services) }) { view in
                    view.bits = settings.networkThroughputBits
                }
                .frame(height: NetworkOverviewDrawView.height)
            }
            PanelCard {
                VStack(alignment: .leading, spacing: 4) {
                    HistoryChart(
                        store: store, history: services.history, defaultSpan: settings.networkChartSpan,
                        series: ChartSeries(
                            metric: .networkPrimaryIn, overlay: .networkPrimaryOut, collector: NetworkIOCollector.collectorID,
                            scale: .bytesPerSecond))
                    Text("主接口：蓝线为下载，橙线为上传")
                        .font(.panelNote).foregroundStyle(.secondary)
                }
            }
            PanelCard {
                NetworkTotalsView(services: services, settings: settings, state: state)
            }
            PanelCard {
                interfaces(state)
            }
            PanelCard {
                NetworkConnectionView(services: services, settings: settings, state: state)
            }
            if state.activeWiFi != nil || settings.latencyTargets != nil {
                PanelCard {
                    VStack(alignment: .leading, spacing: 8) {
                        if state.activeWiFi != nil {
                            LiveView(make: { WiFiDrawView(store: store, services: services) })
                                .frame(height: WiFiDrawView.height)
                        }
                        if let targets = settings.latencyTargets {
                            LiveView(make: { LatencyDrawView(store: store, services: services, targets: targets) }) { view in
                                view.targets = targets
                            }
                            .frame(height: LatencyDrawView.height(for: targets))
                        }
                    }
                }
            }
        }
        .onChange(of: layoutSignature(state)) { layoutChanged() }
    }

    /// 影响高度的结构：接口、Wi-Fi 卡片、延迟卡片、公网 IP 行。
    private func layoutSignature(_ state: NetworkState) -> [String] {
        state.interfaces.map(\.name) + [
            state.activeWiFi == nil ? "-" : "wifi", settings.latencyTargets.map { "\($0.gateway)\($0.custom ?? "")" } ?? "-",
            "\(services.networkModel.publicIP)", settings.publicIPService.isEmpty ? "e" : "s",
        ]
    }

    @ViewBuilder
    private func interfaces(_ state: NetworkState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("接口").font(.panelRow.weight(.semibold))
            if state.physical.isEmpty {
                Text("没有活跃的物理接口").font(.panelRow).foregroundStyle(.secondary)
            }
            // 主接口排最前，其余按 index。
            ForEach(state.physical.sorted { ($0.name == state.primary ? 0 : 1) < ($1.name == state.primary ? 0 : 1) }) { interface in
                row(interface, primary: interface.name == state.primary)
            }
            if !state.virtual.isEmpty {
                // D64：虚拟接口不就地展开，只给个数与活跃数（D60：不相加，不给合计速率）。
                SummaryRow(title: String(localized: "虚拟接口 \(state.virtual.count) 个"), action: { navigate(.virtualInterfaces) }) {
                    LiveView(make: { VirtualInterfacesSummaryDrawView(store: store, interfaces: state.virtual) }) {
                        $0.interfaces = state.virtual
                    }
                    .frame(height: VirtualInterfacesSummaryDrawView.height)
                }
                .help("隧道、虚拟机网卡与网桥、AirDrop。它们的流量通常也会计在物理接口上，不要相加。")
            }
        }
    }

    private func row(_ interface: NetworkInterface, primary: Bool) -> some View {
        NetworkInterfaceRow(store: store, interface: interface, primary: primary, bits: settings.networkThroughputBits)
    }
}

/// 一个接口的两行（主页与虚拟接口列表页共用）。
struct NetworkInterfaceRow: View {
    let store: MetricStore
    let interface: NetworkInterface
    let primary: Bool
    let bits: Bool

    var body: some View {
        LiveView(make: { NetworkInterfaceRowDrawView(store: store, interface: interface, primary: primary) }) { view in
            view.interface = interface
            view.primary = primary
            view.bits = bits
        }
        .frame(height: NetworkInterfaceRowDrawView.height)
    }
}

// MARK: - 虚拟接口列表页

/// 虚拟接口逐个列出（D64 二级页）：按类型分组、组内按 index，不按实时速率排（避免行跳动）；默认只看活跃。
struct NetworkVirtualListView: View {
    let store: MetricStore
    let services: AppServices
    @Bindable var settings: AppSettings
    @Environment(\.panelLayoutChanged) private var layoutChanged
    /// 活跃接口的名字：定期重算，变了才写，页面不跟着每个 tick 重建（审计 A40）。nil 表示还没算过。
    @State private var activeNames: Set<String>?

    private func currentActiveNames() -> Set<String> {
        Set(services.networkModel.state.virtual.filter { NetworkActivity.isActive($0, store: store) }.map(\.name))
    }

    var body: some View {
        let all = services.networkModel.state.virtual
        let names = activeNames ?? currentActiveNames()
        let active = all.filter { names.contains($0.name) }
        let activeOnly = settings.networkVirtualActiveOnly && !active.isEmpty
        let shown = activeOnly ? active : all
        let kinds = NetworkInterfaceKind.allCases.filter { kind in shown.contains { $0.kind == kind } }
        PanelSubpage {
            ActiveFilterPicker(activeOnly: $settings.networkVirtualActiveOnly, activeCount: active.count, totalCount: all.count)
            Text("虚拟接口的流量通常也会计在物理接口上，不要相加。")
                .font(.panelNote).foregroundStyle(.secondary)
            if settings.networkVirtualActiveOnly && active.isEmpty {
                Text("最近 60 秒没有虚拟接口有流量，下面列出全部。").font(.panelNote).foregroundStyle(.secondary)
            }
            ForEach(kinds, id: \.self) { kind in
                PanelCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(NetworkText.kind(kind)).font(.panelRow.weight(.semibold))
                        ForEach(shown.filter { $0.kind == kind }) { interface in
                            NetworkInterfaceRow(
                                store: store, interface: interface, primary: false, bits: settings.networkThroughputBits)
                        }
                    }
                }
            }
        }
        .onChange(of: shown.map(\.name)) { layoutChanged() }
        .onChange(of: settings.networkVirtualActiveOnly) { layoutChanged() }
        .task {
            while !Task.isCancelled {
                let names = currentActiveNames()
                if names != activeNames { activeNames = names }
                try? await Task.sleep(for: .seconds(NetworkActivity.refreshSeconds))
            }
        }
    }
}

/// 「活跃」的判定：最近 60 s 内入或出超过 1 KB/s。
enum NetworkActivity {
    static let threshold: Double = 1_000
    static let seconds: Double = 60
    /// 列表页重算活跃集合的间隔。
    static let refreshSeconds: Double = 2

    /// 不被观察系统跟踪（`recentPointsUntracked`）：列表页定期重算，汇总行随 tick 重绘。
    static func isActive(_ interface: NetworkInterface, store: MetricStore) -> Bool {
        for direction in [MetricID.NetworkDirection.in, .out] {
            if store.recentPointsUntracked(.network(interface, direction), seconds: seconds).contains(where: { ($0.value ?? 0) > threshold }) {
                return true
            }
        }
        return false
    }
}

/// 汇总行右侧：「n 个有流量」。只给个数，不给合计速率（D60）。
final class VirtualInterfacesSummaryDrawView: LiveDrawView {
    static let height: CGFloat = 17

    var interfaces: [NetworkInterface] {
        didSet { if interfaces != oldValue { needsDisplay = true } }
    }

    init(store: MetricStore, interfaces: [NetworkInterface]) {
        self.interfaces = interfaces
        super.init(store: store)
    }

    override func draw(_ dirtyRect: NSRect) {
        countDraw()
        _ = store.latest  // 订阅每秒的数据，活跃数随之更新
        let active = interfaces.filter { NetworkActivity.isActive($0, store: store) }.count
        let text = active == 0 ? String(localized: "都没有流量") : String(localized: "\(active) 个有流量")
        Self.drawRight(Self.text(text, Self.caption2Digits, .secondaryLabelColor), right: bounds.width, y: 1)
        setAccessibilityLabel(text)
    }
}

extension String {
    /// 空串为 nil。
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - 文案

enum NetworkText {
    static func kind(_ kind: NetworkInterfaceKind) -> String {
        switch kind {
        case .ethernet: String(localized: "以太网")
        case .wifi: String(localized: "Wi-Fi")
        case .bridge: String(localized: "网桥")
        case .tunnel: String(localized: "隧道")
        case .virtualMachine: String(localized: "虚拟机")
        case .awdl: String(localized: "AirDrop")
        case .other: String(localized: "其他")
        }
    }

    /// 「以太网（en0）」；没有本地化名时用类型。
    static func interfaceName(_ interface: NetworkInterface) -> String {
        "\(interface.displayName ?? kind(interface.kind))（\(interface.name)）"
    }

    /// 链路速率：「10 Gb/s」「2.5 Gb/s」「100 Mb/s」。
    static func linkSpeed(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1e9
            ? String(format: bitsPerSecond.truncatingRemainder(dividingBy: 1e9) == 0 ? "%.0f Gb/s" : "%.1f Gb/s", bitsPerSecond / 1e9)
            : String(format: "%.0f Mb/s", bitsPerSecond / 1e6)
    }

    /// 网速：按设置用字节或比特（K24：默认字节 / 秒）。
    static func rate(_ bytesPerSecond: Double, bits: Bool) -> String {
        guard bits else { return Formatting.diskRate(bytesPerSecond) }
        let units = ["b/s", "Kb/s", "Mb/s", "Gb/s"]
        var v = max(bytesPerSecond * 8, 0)
        var unit = 0
        while v >= 999.5, unit < units.count - 1 {
            v /= 1000
            unit += 1
        }
        return String(format: unit == 0 || v >= 9.95 ? "%.0f %@" : "%.1f %@", v, units[unit])
    }
}

// MARK: - 概览

final class NetworkOverviewDrawView: LiveDrawView {
    static let height: CGFloat = 94

    private let services: AppServices
    /// 用比特 / 秒（跟随网速 widget 的单位设置）。
    var bits = false {
        didSet { if bits != oldValue { needsDisplay = true } }
    }
    private static let big: NSFont = {
        let base = NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 24) } ?? base
    }()
    private static let subheadline = NSFont.systemFont(ofSize: PanelType.title)
    private static let callout = NSFont.monospacedDigitSystemFont(ofSize: PanelType.title, weight: .medium)

    init(store: MetricStore, services: AppServices) {
        self.services = services
        super.init(store: store)
    }

    override func draw(_ dirtyRect: NSRect) {
        countDraw()
        let latest = store.latest
        let state = services.networkModel.state
        let title: String =
            if let primary = state.primaryInterface { String(localized: "主接口 · \(NetworkText.interfaceName(primary))") }
            else { String(localized: "离线") }
        Self.draw(Self.text(title, Self.subheadline, .secondaryLabelColor), x: 0, y: 0)
        let down = latest[.networkPrimaryIn]?.value
        let up = latest[.networkPrimaryOut]?.value
        let downText = down.map { NetworkText.rate($0, bits: bits) } ?? PercentFormat.placeholder
        let upText = up.map { NetworkText.rate($0, bits: bits) } ?? PercentFormat.placeholder
        var x = Self.draw(Self.text("↓ ", Self.big, .controlAccentColor), x: 0, y: 21)
        x += Self.draw(Self.text(downText, Self.big), x: x, y: 21) + 14
        x += Self.draw(Self.text("↑ ", Self.big, .systemOrange), x: x, y: 21)
        Self.draw(Self.text(upText, Self.big), x: x, y: 21)
        // 字节口径说明（D60）。
        Self.draw(Self.text(String(localized: "接口字节（含协议头），不是应用载荷"), Self.caption2, .secondaryLabelColor), x: 0, y: 66)

        let right = bounds.width
        var y: CGFloat = 0
        func item(_ title: String, _ value: String, _ color: NSColor = .labelColor) {
            Self.drawRight(Self.text(title, Self.caption2, .secondaryLabelColor), right: right, y: y)
            Self.drawRight(Self.text(value, Self.callout, color), right: right, y: y + 14)
            y += 31
        }
        if let primary = state.primaryInterface {
            if primary.kind == .wifi {
                let tx = latest[.networkWiFiTxRate]?.value
                item(String(localized: "Wi-Fi 发送速率"), tx.map(NetworkText.linkSpeed) ?? "—")
            } else {
                item(String(localized: "链路速率"), primary.linkSpeed.map(NetworkText.linkSpeed) ?? "—")
            }
        }
        if state.vpnActive {
            item(String(localized: "VPN"), String(localized: "已连接 · \(state.defaultRouteInterface ?? "—")"), .systemGreen)
        }
        setAccessibilityLabel(String(localized: "网络 下载 \(downText) 上传 \(upText)"))
    }
}

// MARK: - 接口行

/// 一个接口两行：名称与类型（链路速率）；入 / 出速率与最近 60 s 小曲线。
final class NetworkInterfaceRowDrawView: LiveDrawView {
    static let height: CGFloat = 34
    static let sparklineSeconds: Double = 60

    var interface: NetworkInterface {
        didSet { if interface != oldValue { needsDisplay = true } }
    }
    var primary: Bool {
        didSet { if primary != oldValue { needsDisplay = true } }
    }
    var bits = false {
        didSet { if bits != oldValue { needsDisplay = true } }
    }

    init(store: MetricStore, interface: NetworkInterface, primary: Bool) {
        self.interface = interface
        self.primary = primary
        super.init(store: store)
    }

    override func draw(_ dirtyRect: NSRect) {
        countDraw()
        let latest = store.latest
        let name = NetworkText.interfaceName(interface)
        let width = Self.draw(Self.text(name, Self.caption), x: 0, y: 0)
        if primary {
            Self.draw(Self.text(String(localized: "主接口"), Self.caption2, .controlAccentColor), x: width + 6, y: 1)
        }
        var detail = NetworkText.kind(interface.kind)
        if let speed = interface.linkSpeed { detail += " · " + NetworkText.linkSpeed(speed) }
        Self.drawRight(Self.text(detail, Self.caption2, .secondaryLabelColor), right: bounds.width, y: 1)

        let down = latest[.network(interface, .in)]?.value
        let up = latest[.network(interface, .out)]?.value
        let rates = "↓ \(down.map { NetworkText.rate($0, bits: bits) } ?? "—")  ↑ \(up.map { NetworkText.rate($0, bits: bits) } ?? "—")"
        Self.draw(Self.text(rates, Self.caption2Digits, .secondaryLabelColor), x: 0, y: 18)
        drawSparkline(in: NSRect(x: bounds.width - 70, y: 19, width: 70, height: 12))
        setAccessibilityLabel("\(name) \(rates)")
    }

    /// 下载（强调色）与上传（橙）两条线，纵轴按两者的最大值。
    private func drawSparkline(in rect: NSRect) {
        let downs = store.recentPoints(.network(interface, .in), seconds: Self.sparklineSeconds)
        let ups = store.recentPoints(.network(interface, .out), seconds: Self.sparklineSeconds)
        NSColor.tertiaryLabelColor.setFill()
        NSRect(x: rect.minX, y: rect.maxY - 0.5, width: rect.width, height: 0.5).fill()
        let newest = max(downs.last?.continuousNanos ?? 0, ups.last?.continuousNanos ?? 0)
        guard newest > 0 else { return }
        let top = max((downs.compactMap(\.value) + ups.compactMap(\.value)).max() ?? 0, 10_000)
        for (points, color) in [(downs, NSColor.controlAccentColor), (ups, NSColor.systemOrange)] {
            let path = NSBezierPath()
            path.lineWidth = 1
            var started = false
            for point in points {
                guard let value = point.value else {
                    started = false
                    continue
                }
                let age = Double(newest &- point.continuousNanos) / 1e9
                let x = rect.maxX - CGFloat(age / Self.sparklineSeconds) * rect.width
                let y = rect.maxY - CGFloat(min(value / top, 1)) * rect.height
                if started { path.line(to: NSPoint(x: x, y: y)) } else { path.move(to: NSPoint(x: x, y: y)) }
                started = true
            }
            color.setStroke()
            path.stroke()
        }
    }
}

// MARK: - 流量统计

/// 今日 / 本月流量（网络模块设计 §6）：Σ(分钟均值 × 覆盖秒数)，按本地时区切日、切月；每 60 s 重读一次。
private struct NetworkTotalsView: View {
    let services: AppServices
    @Bindable var settings: AppSettings
    let state: NetworkState

    @State private var totals: [String: Double] = [:]
    @State private var failed = false

    private var interface: String? { settings.networkTotalsInterface }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("流量统计").font(.panelRow.weight(.semibold))
                Spacer()
                Picker("", selection: $settings.networkTotalsInterface) {
                    Text("主接口").tag(String?.none)
                    ForEach(state.physical) { interface in
                        Text(NetworkText.interfaceName(interface)).tag(String?.some(interface.name))
                    }
                    if let name = interface, !state.physical.contains(where: { $0.name == name }) {
                        Text(name).tag(String?.some(name))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            if !settings.historyNetworkEnabled {
                Text("没有开启「记录网络历史」，无法统计").font(.panelNote).foregroundStyle(.secondary)
            } else if services.history == nil || failed {
                Text("历史库不可用").font(.panelNote).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    totalRow(String(localized: "今日"), "day")
                    totalRow(String(localized: "本月"), "month")
                }
                .help("从开始记录网络历史算起；睡眠期间与 app 未运行时没有记录")
            }
        }
        .task(id: interface) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func totalRow(_ title: String, _ period: String) -> some View {
        GridRow {
            Text(title).font(.panelRow).foregroundStyle(.secondary)
            Text("↓ \(totals["\(period).in"].map(Formatting.diskBytes) ?? "—")").font(.panelRow.monospacedDigit())
            Text("↑ \(totals["\(period).out"].map(Formatting.diskBytes) ?? "—")").font(.panelRow.monospacedDigit())
        }
    }

    private func load() async {
        guard let history = services.history, settings.historyNetworkEnabled else { return }
        let now = Date()
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        let month = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? day
        let name = interface
        func metric(_ direction: MetricID.NetworkDirection) -> MetricID {
            name.map { .networkInterface($0, direction) } ?? .networkPrimary(direction)
        }
        do {
            var out: [String: Double] = [:]
            for direction in MetricID.NetworkDirection.allCases {
                out["day.\(direction.rawValue)"] = try await history.total(metric(direction), from: day, to: now)
                out["month.\(direction.rawValue)"] = try await history.total(metric(direction), from: month, to: now)
            }
            totals = out
            failed = false
        } catch {
            failed = true
        }
    }
}

// MARK: - 连接信息

private struct NetworkConnectionView: View {
    let services: AppServices
    @Bindable var settings: AppSettings
    let state: NetworkState
    @State private var editingService = false
    @State private var serviceDraft = ""

    /// 公网 IP 查询服务的候选（D62：用户自己选，app 不预设）。
    static let serviceCandidates = ["https://api.ipify.org", "https://ifconfig.me/ip", "https://ipinfo.io/ip", "https://4.ipw.cn"]

    var body: some View {
        let primary = state.primaryInterface
        VStack(alignment: .leading, spacing: 4) {
            Text("连接").font(.panelRow.weight(.semibold))
            if let primary {
                copyRow(String(localized: "IPv4"), primary.ipv4.first, more: primary.ipv4.count - 1)
                copyRow(String(localized: "IPv6"), primary.ipv6.first, more: primary.ipv6.count - 1)
            }
            copyRow(String(localized: "网关"), state.gatewayIPv4 ?? state.gatewayIPv6, more: 0)
            copyRow(String(localized: "DNS"), state.dnsServers.first, more: state.dnsServers.count - 1)
            if state.proxyEnabled || state.vpnActive {
                row(
                    String(localized: "代理 / VPN"),
                    [state.proxyEnabled ? String(localized: "系统代理已开启") : nil,
                     state.vpnActive ? String(localized: "VPN（\(state.defaultRouteInterface ?? "—")）") : nil]
                        .compactMap { $0 }.joined(separator: " · "))
            }
            publicIP
        }
    }

    @ViewBuilder
    private var publicIP: some View {
        let status = services.networkModel.publicIP
        HStack {
            Text("公网 IP").font(.panelRow).foregroundStyle(.secondary)
            Spacer()
            switch status {
            case .idle:
                EmptyView()
            case .loading:
                ProgressView().controlSize(.mini)
            case .result(let address, _):
                Button(address) { copy(address) }
                    .buttonStyle(.plain).font(.panelRow.monospacedDigit())
                    .help("点击复制")
            case .failed(let message):
                Text(message).font(.panelNote).foregroundStyle(.red).lineLimit(1)
            }
            Button("查询") {
                if settings.publicIPService.isEmpty {
                    serviceDraft = Self.serviceCandidates[0]
                    editingService = true
                } else {
                    services.networkModel.lookUpPublicIP(service: settings.publicIPService)
                }
            }
            .controlSize(.small)
            .help("向设置里的服务发一次 HTTPS 请求，结果只显示、不保存")
        }
        if editingService {
            VStack(alignment: .leading, spacing: 4) {
                Text("第一次查询：选择或填写查询服务（以后可在设置 › 网络里修改）").font(.panelNote).foregroundStyle(.secondary)
                HStack {
                    TextField("https://…", text: $serviceDraft).textFieldStyle(.roundedBorder).font(.panelRow)
                    Menu("候选") {
                        ForEach(Self.serviceCandidates, id: \.self) { candidate in
                            Button(candidate) { serviceDraft = candidate }
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
                HStack {
                    Spacer()
                    Button("取消") { editingService = false }.controlSize(.small)
                    Button("保存并查询") {
                        settings.publicIPService = serviceDraft.trimmingCharacters(in: .whitespaces)
                        editingService = false
                        services.networkModel.lookUpPublicIP(service: settings.publicIPService)
                    }
                    .controlSize(.small)
                    .disabled(!serviceDraft.hasPrefix("https://"))
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.panelRow).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.panelRow)
        }
    }

    @ViewBuilder
    private func copyRow(_ title: String, _ value: String?, more: Int) -> some View {
        HStack {
            Text(title).font(.panelRow).foregroundStyle(.secondary)
            Spacer()
            if let value {
                Button {
                    copy(value)
                } label: {
                    Text(more > 0 ? "\(value) 等 \(more + 1) 个" : value)
                        .font(.panelRow.monospacedDigit())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help("点击复制")
            } else {
                Text("—").font(.panelRow).foregroundStyle(.secondary)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Wi-Fi

/// Wi-Fi 卡片（D60 N5）：面板可见时每 5 s 读一次 CoreWLAN；不读 SSID。
final class WiFiDrawView: LiveDrawView {
    static let rowHeight: CGFloat = 18
    static let height: CGFloat = 17 + rowHeight * 3

    private let services: AppServices

    init(store: MetricStore, services: AppServices) {
        self.services = services
        super.init(store: store)
        toolTip = String(localized: "面板可见时每 5 秒更新；不读取网络名称（无需定位权限）")
    }

    override func draw(_ dirtyRect: NSRect) {
        countDraw()
        let latest = store.latest
        let info = services.network.wifi?.latestInfo
        let width = bounds.width
        var y: CGFloat = 0
        Self.draw(Self.text(String(localized: "Wi-Fi"), Self.captionBold), x: 0, y: y)
        if let name = info?.interfaceName {
            Self.drawRight(Self.text(String(localized: "\(name) · 每 5 秒"), Self.caption2, .secondaryLabelColor), right: width, y: y + 1)
        }
        y += 17
        func row(_ title: String, _ value: String) {
            Self.draw(Self.text(title, Self.caption, .secondaryLabelColor), x: 0, y: y)
            Self.drawRight(Self.text(value, Self.captionDigits), right: width, y: y)
            y += Self.rowHeight
        }
        let rssi = latest[.networkWiFiRSSI]
        let signal: String
        if case .unavailable(let reason)? = rssi?.quality, reason.code == "notAssociated" {
            signal = String(localized: "未连接")
        } else {
            signal = [
                rssi?.value.map { String(format: "%.0f dBm", $0) } ?? String(localized: "等待数据…"),
                latest[.networkWiFiNoise]?.value.map { String(localized: "噪声 \(String(format: "%.0f", $0))") },
                latest[.networkWiFiSNR]?.value.map { String(localized: "信噪比 \(String(format: "%.0f dB", $0))") },
            ].compactMap { $0 }.joined(separator: " · ")
        }
        row(String(localized: "信号"), signal)
        row(
            String(localized: "发送速率"),
            [latest[.networkWiFiTxRate]?.value.map(NetworkText.linkSpeed), info?.phyMode].compactMap { $0 }.joined(separator: " · ")
                .nonEmpty ?? "—")
        let channel: String =
            if let info, let number = info.channel {
                [String(localized: "\(number)"), info.bandGHz.map { "\($0 == 2.4 ? "2.4" : String(format: "%.0f", $0)) GHz" },
                 info.widthMHz.map { "\($0) MHz" }].compactMap { $0 }.joined(separator: " · ")
            } else { "—" }
        row(String(localized: "信道"), channel)
        setAccessibilityLabel(String(localized: "Wi-Fi 信号 \(rssi?.value.map { String(format: "%.0f", $0) } ?? "—") dBm"))
    }
}

// MARK: - 延迟

final class LatencyDrawView: LiveDrawView {
    static let rowHeight: CGFloat = 18

    static func height(for targets: LatencyCollector.Targets) -> CGFloat {
        17 + rowHeight * CGFloat((targets.gateway ? 1 : 0) + (targets.custom != nil ? 1 : 0))
    }

    private let services: AppServices
    var targets: LatencyCollector.Targets {
        didSet { if targets != oldValue { needsDisplay = true } }
    }

    init(store: MetricStore, services: AppServices, targets: LatencyCollector.Targets) {
        self.services = services
        self.targets = targets
        super.init(store: store)
        toolTip = String(localized: "ICMP，只在面板可见或延迟 widget 打开时发包")
    }

    override func draw(_ dirtyRect: NSRect) {
        countDraw()
        let latest = store.latest
        let width = bounds.width
        var y: CGFloat = 0
        Self.draw(Self.text(String(localized: "延迟"), Self.captionBold), x: 0, y: y)
        Self.drawRight(Self.text(String(localized: "RTT · 丢包（最近 10 个）"), Self.caption2, .secondaryLabelColor), right: width, y: y + 1)
        y += 17
        let state = services.networkModel.state
        let rows: [(MetricID.LatencyTarget, String)] =
            (targets.gateway ? [(.gateway, String(localized: "网关 \(state.gatewayIPv4 ?? state.gatewayIPv6 ?? "")"))] : [])
            + (targets.custom.map { [(.custom, $0)] } ?? [])
        for (target, title) in rows {
            Self.draw(Self.text(title, Self.caption, .secondaryLabelColor), x: 0, y: y)
            let rtt = latest[.networkLatencyRTT(target)]
            let rttText: String =
                if let v = rtt?.value { Formatting.latency(v) }
                else if case .unavailable(let reason)? = rtt?.quality {
                    switch reason.code {
                    case "timeout": String(localized: "超时")
                    case "noTarget": String(localized: "无目标")
                    case "localNetwork": String(localized: "同网段，不测")
                    default: "—"
                    }
                } else { String(localized: "等待回包…") }
            let loss = latest[.networkLatencyLoss(target)]?.value
            let lossText = loss.map { PercentFormat.string(fromRatio: $0) } ?? "—"
            let color: NSColor = (loss ?? 0) > 0 ? .systemOrange : .labelColor
            Self.drawRight(Self.text("\(rttText) · \(lossText)", Self.captionDigits, color), right: width, y: y)
            y += Self.rowHeight
        }
    }
}
