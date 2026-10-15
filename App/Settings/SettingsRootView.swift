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
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $state.selection) { page in
                Label(page.title, systemImage: page.symbol)
                    .tag(page)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            detail(for: state.selection ?? .general)
                .navigationTitle(state.selection?.title ?? "")
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
        case .history:
            HistorySettingsView(settings: context.settings, history: context.services.history, openPage: openPage)
        case .privacy:
            PrivacySettingsView()
        case .diagnostics:
            DiagnosticsView(
                store: context.store, throttle: context.throttle, runSelfTests: context.runSelfTests,
                services: context.services, catalogVisibilityChanged: context.catalogVisibilityChanged)
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

/// 菜单栏页（D41）：只放与具体指标无关的容器级设置——全局排版与小标签、已开启 widget 的只读总览、溢出区提示。
/// 各 widget 的开关与配置在所属模块页。
private struct MenuBarSettingsView: View {
    @Bindable var settings: AppSettings
    let store: MetricStore
    let openPage: (SettingsPage) -> Void

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
                let widgets = settings.visibleWidgets
                if widgets.isEmpty {
                    Text("还没有开启任何菜单栏项目。").foregroundStyle(.secondary)
                } else {
                    ForEach(widgets) { widget in
                        let configuration = StatusItemConfiguration(widget: widget, settings: settings)
                        LabeledContent {
                            StatusItemPreview(store: store, configuration: configuration)
                        } label: {
                            Text(WidgetInfo.title(widget))
                            Text("\(WidgetInfo.module(widget.module)) · \(Self.points(StatusItemView.fixedWidth(for: configuration)))")
                        }
                    }
                    LabeledContent(
                        "合计宽度",
                        value: Self.points(
                            widgets.map { StatusItemView.fixedWidth(for: StatusItemConfiguration(widget: $0, settings: settings)) }
                                .reduce(0, +)))
                }
            } header: {
                Text("已开启的项目")
            } footer: {
                HStack(spacing: 4) {
                    Text("各项目的开关和配置在所属模块页。")
                    Button("CPU") { openPage(.cpu) }
                        .buttonStyle(.link)
                    Button("功耗与散热") { openPage(.power) }
                        .buttonStyle(.link)
                }
            }

            Section {
                Text("每个菜单栏项目只显示一项，可以按住 ⌘ 单独拖动位置。项目较多时，部分项目可能被系统收进溢出区；可以到「系统设置 → 菜单栏」查看和调整哪些项目允许显示。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private static func points(_ width: CGFloat) -> String {
        String(localized: "\(Int(width.rounded())) pt")
    }
}

/// D22：列出所有可能的出站连接与授权申请。目前两者都没有；以后加入联网或需授权的功能时，在这里逐项列出目标与用途（D27）。
private struct PrivacySettingsView: View {
    var body: some View {
        Form {
            Section("网络连接") {
                LabeledContent("出站连接", value: String(localized: "无"))
                Text("SysInfo 目前不连接任何网络服务。以后如果加入需要联网的功能，都要你在这里手动开启，并会列出连接目标和用途。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("系统授权") {
                LabeledContent("申请的授权", value: String(localized: "无"))
                Text("SysInfo 不申请定位、蓝牙、辅助功能、本地网络、通知等授权。以后如果有功能需要授权，只会在你手动开启该功能时才申请。")
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
