// 设置窗口内容（D25 的侧栏结构，M0 设计 §6）。

import AppKit
import SwiftUI
import SysCollectors

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

    @ViewBuilder
    private func detail(for page: SettingsPage) -> some View {
        switch page {
        case .general:
            GeneralSettingsView(settings: context.settings)
        case .menuBar:
            MenuBarSettingsView(settings: context.settings)
        case .cpu:
            CPUSettingsView(settings: context.settings)
        case .history:
            HistorySettingsView()
        case .diagnostics:
            DiagnosticsView(store: context.store, throttle: context.throttle, runSelfTests: context.runSelfTests)
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

private struct MenuBarSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("菜单栏项目") {
                Toggle("CPU", isOn: $settings.cpuItemVisible)
            }
            Section {
                Text("菜单栏项目较多时，部分项目可能被系统收进溢出区。可以到「系统设置 → 菜单栏」查看和调整哪些项目允许显示。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct CPUSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("采集间隔", selection: $settings.cpuIntervalOverride) {
                    Text("跟随默认（\(DisplayNames.interval(settings.globalInterval))）")
                        .tag(SamplingInterval?.none)
                    ForEach(SamplingInterval.allCases) { interval in
                        Text(DisplayNames.interval(interval)).tag(Optional(interval))
                    }
                }
                Text("面板打开期间 CPU 固定按 1 秒采样。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("高开销选项") {
                Text("暂无高开销选项。之后加入的选项会在这里标注大致开销。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct HistorySettingsView: View {
    var body: some View {
        Form {
            Section {
                Text("历史记录的持久化与导出尚未实现。目前只在内存中保留最近 15 分钟的数据。")
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
