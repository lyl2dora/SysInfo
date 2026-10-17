// 设置窗口内容（D25 的侧栏结构，M0 设计 §6）。

import AppKit
import SwiftUI
import SysCollectors
import SysModel
import SysStore

struct SettingsRootView: View {
    let context: SettingsContext

    var body: some View {
        Group {
            if context.state.isWindowOpen {
                SettingsSplitView(context: context)
            } else {
                // 窗口不在屏幕上：不读 MetricStore，不随 tick 重算。
                Color.clear
            }
        }
        .frame(minWidth: 700, idealWidth: 740, minHeight: 480, idealHeight: 540)
        .background(WindowReader(onWindow: context.windowAttached))
    }
}

private struct SettingsSplitView: View {
    let context: SettingsContext

    var body: some View {
        @Bindable var state = context.state
        // 不用 NavigationSplitView：它在统一样式的标题栏下给侧栏留了最小宽度（红绿灯在侧栏里），
        // 收起成图标栏时宽度改不下来；自己排两栏，宽度完全由收起状态决定。
        HStack(spacing: 0) {
            List(SettingsPage.allCases, selection: $state.selection) { page in
                Group {
                    if state.sidebarCompact {
                        // 收起时只留图标，名字放进提示与辅助功能标签。
                        Image(systemName: page.symbol)
                            .frame(maxWidth: .infinity)
                            .help(page.title)
                            .accessibilityLabel(page.title)
                    } else {
                        Label(page.title, systemImage: page.symbol)
                    }
                }
                .tag(page)
            }
            .listStyle(.sidebar)
            .frame(width: state.sidebarCompact ? 56 : 180)
            Divider()
            detail(for: state.selection ?? .general)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(state.selection?.title ?? "")
        .toolbar {
            // 侧栏开关放在标题栏红绿灯右侧；收起时保留图标栏而不是整栏隐藏。
            ToolbarItem(placement: .navigation) {
                Button {
                    state.sidebarCompact.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(state.sidebarCompact ? "展开边栏" : "收起边栏")
                .accessibilityLabel(state.sidebarCompact ? "展开边栏" : "收起边栏")
            }
        }
    }

    private func openPage(_ page: SettingsPage) {
        context.state.selection = page
    }

    @ViewBuilder
    private func detail(for page: SettingsPage) -> some View {
        switch page {
        case .general:
            GeneralSettingsView(settings: context.settings)
        case .menuBar:
            MenuBarSettingsView(settings: context.settings, store: context.store, openPage: openPage)
        case .cpu:
            CPUSettingsView(settings: context.settings, store: context.store, openPage: openPage)
        case .power:
            PowerSettingsView(
                settings: context.settings, store: context.store, services: context.services, openPage: openPage)
        case .memory:
            MemorySettingsView(settings: context.settings, store: context.store, openPage: openPage)
        case .storage:
            StorageSettingsView(
                settings: context.settings, store: context.store, model: context.services.storageModel, openPage: openPage)
        case .gpu:
            GPUSettingsView(settings: context.settings, store: context.store, openPage: openPage)
        case .network:
            NetworkSettingsView(
                settings: context.settings, store: context.store, model: context.services.networkModel, openPage: openPage)
        case .appActivity:
            AppActivitySettingsView(
                settings: context.settings, store: context.store, services: context.services, openPage: openPage)
        case .history:
            HistorySettingsView(settings: context.settings, history: context.services.history, openPage: openPage)
        case .privacy:
            PrivacySettingsView(settings: context.settings, openPage: openPage)
        case .diagnostics:
            DiagnosticsView(
                store: context.store, throttle: context.throttle, runSelfTests: context.runSelfTests,
                services: context.services, catalogVisibilityChanged: context.catalogVisibilityChanged,
                bandwidthVisibilityChanged: context.bandwidthVisibilityChanged,
                gpuDetailsVisibilityChanged: context.gpuDetailsVisibilityChanged)
                .onAppear { context.diagnosticsVisibilityChanged(true) }
                .onDisappear { context.diagnosticsVisibilityChanged(false) }
        case .about:
            AboutView()
        }
    }
}

// MARK: - 各页

private struct GeneralSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("默认采集间隔", selection: $settings.globalInterval) {
                    ForEach(SamplingInterval.allCases) { interval in
                        Text(DisplayNames.interval(interval)).tag(interval)
                    }
                }
                Text("各模块默认按这个间隔采样，可以在模块页里单独覆盖。间隔越短，本进程开销越高。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("自动降频", isOn: $settings.autoThrottle)
                Text("低电量模式、过热或由 UPS/电池供电时，采样间隔加倍；锁屏或显示器睡眠时暂停菜单栏和面板的采样。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// 菜单栏页（D41）：只放与具体指标无关的容器级设置——全局排版与小标签、合并为单个 item（D65 MG6）、
/// 已开启 widget 的只读总览（合并模式下可调整合并顺序）、溢出区提示。各 widget 的开关与配置在所属模块页。
private struct MenuBarSettingsView: View {
    @Bindable var settings: AppSettings
    let store: MetricStore
    let openPage: (SettingsPage) -> Void

    /// 已开启的项目达到这么多时，建议切换到合并模式（D65 MG6）。
    static let mergeSuggestionCount = 6

    var body: some View {
        Form {
            Section {
                Picker("排版", selection: $settings.menuBarLayout) {
                    Text("上下（标签在上）").tag(MenuBarLayout.stacked)
                    Text("左右").tag(MenuBarLayout.inline)
                }
                Toggle("显示小标签", isOn: $settings.menuBarShowsLabel)
            } header: {
                Text("外观")
            } footer: {
                Text("对所有模块的 widget 统一生效。折线、柱状等图形固定按上下排版绘制。")
            }

            Section {
                Toggle("合并为单个项目", isOn: $settings.menuBarMerged)
                if settings.menuBarMerged {
                    Picker("分隔", selection: $settings.menuBarMergedSeparator) {
                        Text("细线").tag(MergedSeparator.line)
                        Text("留空").tag(MergedSeparator.space)
                    }
                }
            } header: {
                Text("合并")
            } footer: {
                Text("合并后所有已开启的项目并排显示在一个菜单栏项目里，点哪一段就打开哪个模块；面板里可以在模块之间切换，另有「总览」。")
            }

            Section {
                let visible = settings.visibleWidgets
                let widgets = settings.menuBarMerged ? settings.mergedWidgets(from: visible) : visible
                if widgets.isEmpty {
                    Text("还没有开启任何菜单栏项目。").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(widgets.enumerated()), id: \.element) { index, widget in
                        let configuration = StatusItemConfiguration(widget: widget, settings: settings)
                        LabeledContent {
                            HStack(spacing: 8) {
                                StatusItemPreview(store: store, configuration: configuration)
                                if settings.menuBarMerged {
                                    Button {
                                        move(widgets, from: index, by: -1)
                                    } label: {
                                        Image(systemName: "arrow.up")
                                    }
                                    .disabled(index == 0)
                                    .help("在合并项目里左移")
                                    Button {
                                        move(widgets, from: index, by: 1)
                                    } label: {
                                        Image(systemName: "arrow.down")
                                    }
                                    .disabled(index == widgets.count - 1)
                                    .help("在合并项目里右移")
                                }
                            }
                            .buttonStyle(.borderless)
                        } label: {
                            Text(WidgetInfo.title(widget))
                            Text("\(WidgetInfo.module(widget.module)) · \(Self.points(StatusItemView.fixedWidth(for: configuration)))")
                        }
                    }
                    let configurations = widgets.map { StatusItemConfiguration(widget: $0, settings: settings) }
                    LabeledContent(
                        "合计宽度",
                        value: Self.points(
                            settings.menuBarMerged
                                ? MergedStatusItemView.fixedWidth(for: configurations, separator: settings.menuBarMergedSeparator)
                                : configurations.map(StatusItemView.fixedWidth(for:)).reduce(0, +)))
                }
            } header: {
                Text(settings.menuBarMerged ? "合并项目里的顺序（从左到右）" : "已开启的项目")
            } footer: {
                HStack(spacing: 4) {
                    Text("各项目的开关和配置在所属模块页。")
                    Button("CPU") { openPage(.cpu) }
                        .buttonStyle(.link)
                    Button("功耗与散热") { openPage(.power) }
                        .buttonStyle(.link)
                    Button("内存") { openPage(.memory) }
                        .buttonStyle(.link)
                    Button("存储") { openPage(.storage) }
                        .buttonStyle(.link)
                    Button("GPU 与加速器") { openPage(.gpu) }
                        .buttonStyle(.link)
                    Button("网络") { openPage(.network) }
                        .buttonStyle(.link)
                }
            }

            if !settings.menuBarMerged {
                Section {
                    if settings.visibleWidgets.count >= Self.mergeSuggestionCount {
                        Label("已开启 \(settings.visibleWidgets.count) 个项目，部分可能被系统收进溢出区。建议打开上面的「合并为单个项目」。", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                    }
                    Text("每个菜单栏项目只显示一项，可以按住 ⌘ 单独拖动位置。项目较多时，部分项目可能被系统收进溢出区；可以合并为单个项目，或到「系统设置 → 菜单栏」查看和调整哪些项目允许显示。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 在合并顺序里把一项左移或右移一位（D65 MG1）。
    private func move(_ widgets: [MenuWidget], from index: Int, by offset: Int) {
        let target = index + offset
        guard widgets.indices.contains(index), widgets.indices.contains(target) else { return }
        var order = widgets
        order.swapAt(index, target)
        // 关着的 widget 保留在顺序记录的末尾，再开时出现在它记录的位置。
        settings.menuBarMergedOrder = order + settings.menuBarMergedOrder.filter { !order.contains($0) }
    }

    private static func points(_ width: CGFloat) -> String {
        String(localized: "\(Int(width.rounded())) pt")
    }
}

/// D22：列出所有可能的出站连接与授权申请。出站目标只有网络模块的延迟（D61）与公网 IP（D62），都默认关闭或为空。
private struct PrivacySettingsView: View {
    @Bindable var settings: AppSettings
    let openPage: (SettingsPage) -> Void

    var body: some View {
        Form {
            Section {
                if let targets = settings.latencyTargets {
                    LabeledContent("延迟（ICMP）") {
                        Text([targets.gateway ? String(localized: "默认网关") : nil, targets.custom].compactMap { $0 }.joined(separator: "、"))
                    }
                } else {
                    LabeledContent("延迟（ICMP）", value: String(localized: "关闭"))
                }
                LabeledContent("公网 IP 查询") {
                    Text(settings.publicIPService.isEmpty ? String(localized: "未设置（只在点击「查询」时连接）") : settings.publicIPService)
                }
                HStack(spacing: 4) {
                    Text("除此之外 SysInfo 不连接任何网络服务。延迟只在网络面板可见或延迟 widget 打开时发包；公网 IP 只在你点击时查询一次。")
                    Button("在「网络」页设置") { openPage(.network) }
                        .buttonStyle(.link)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } header: {
                Text("网络连接")
            }
            Section("系统授权") {
                LabeledContent("申请的授权", value: String(localized: "无"))
                Text("SysInfo 不申请定位、蓝牙、辅助功能、本地网络、通知等授权。延迟只测默认网关和你填写的地址，不向局域网内的其他设备发包，所以不需要「本地网络」授权。以后如果有功能需要授权，只会在你手动开启该功能时才申请。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("数据存放") {
                Text("采集到的数据只保存在本机。诊断信息和日志也只写在本机。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let url = HistoryStore.defaultURL(bundleIdentifier: BuildInfo.bundleIdentifier) {
                    PathRow(title: String(localized: "历史库"), url: url)
                }
                if let url = ChipProfileStore.calibrationDirectory() {
                    PathRow(title: String(localized: "传感器校准缓存"), url: url)
                }
                Text("历史库和导出文件不含序列号、硬件 UUID、MAC 地址等设备唯一标识。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("名称", value: BuildInfo.displayName)
                LabeledContent("版本", value: BuildInfo.version)
                LabeledContent("Build", value: BuildInfo.build)
                if BuildInfo.isDebug {
                    LabeledContent("Git", value: BuildInfo.gitCommit ?? String(localized: "未知"))
                }
                LabeledContent("Bundle ID", value: BuildInfo.bundleIdentifier)
                LabeledContent("私有层版本", value: "\(PrivateLayer.version)")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 工具

/// 一个本机路径，可以在访达中显示。
struct PathRow: View {
    let title: String
    let url: URL

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(url.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Button {
                    let target = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("在访达中显示")
            }
        }
    }
}

/// 取得 SwiftUI 内容所在的 NSWindow（设置窗口关闭时要切回 accessory）。
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.onWindow = onWindow
    }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onWindow?(window)
            }
        }
    }
}
