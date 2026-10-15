// 面板内容（D21，M0 设计 §6）：顶栏玻璃按钮 + tabs 切换模块 + 模块内容。
// 玻璃只用在控件层；图表和数值层用标准材质（见 PanelCard）。

import SwiftUI

struct PanelRootView: View {
    let store: MetricStore
    @Bindable var state: PanelState
    let actions: PanelActions
    let services: CPUServices
    let settings: AppSettings
    /// 内容的结构变了（展开或收起、行数变化），请面板重新量一次高度。
    var onLayoutChange: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            topBar

            SegmentedButtons(
                selection: $state.selectedTab, options: PanelTab.allCases.map { ($0, $0.title) }, size: .regular)

            switch state.selectedTab {
            case .cpu:
                CPUPanelView(
                    store: store, services: services, settings: settings, expandDetails: state.expandDetailsInitially)
            }
        }
        .padding(14)
        .frame(width: PanelController.width)
        .environment(\.panelLayoutChanged, PanelLayoutAction(action: onLayoutChange))
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            if state.isPinned {
                Button(action: actions.close) {
                    Label("关闭", systemImage: "xmark")
                }
                .help("关闭浮窗")
            }
            Button(action: actions.openActivityMonitor) {
                Label("活动监视器", systemImage: "chart.bar.xaxis")
            }
            .help("打开活动监视器")

            Spacer(minLength: 4)
            Text("SysInfo")
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 4)

            if !state.isPinned {
                Button(action: actions.pin) {
                    Label("固定", systemImage: "pin")
                }
                .help("固定为浮窗")
            }
            Button(action: actions.openSettings) {
                Label("设置", systemImage: "gearshape")
            }
            .help("打开设置")
            Button(action: actions.quit) {
                Label("退出", systemImage: "power")
            }
            .help("退出 SysInfo")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        // 固定为浮窗后，按住顶栏的空白处可以拖动窗口；锚定时不响应拖动。
        .contentShape(.rect)
        .gesture(WindowDragGesture(), isEnabled: state.isPinned)
    }
}

/// 图表和数值的底：标准材质，不用玻璃（M0 设计 §6）。
struct PanelCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
    }
}

/// 「内容结构变了，请重新量高度」的动作（面板只在这时改高，平时的数值更新不做整树测量）。
struct PanelLayoutAction {
    var action: () -> Void = {}
    func callAsFunction() { action() }
}

extension EnvironmentValues {
    @Entry var panelLayoutChanged = PanelLayoutAction()
}

/// 轻量的分段按钮：纯 SwiftUI 绘制。系统的分段控件底层是 NSSegmentedControl，每次布局都要重新测量，
/// 在每秒刷新的面板里占了可观的开销（CPU 模块偏离记录 2026-10-15）。
struct SegmentedButtons<Value: Hashable>: View {
    enum Size { case small, regular }

    @Binding var selection: Value
    let options: [(Value, String)]
    var size: Size = .small

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let (value, title) = options[i]
                let selected = value == selection
                Button {
                    selection = value
                } label: {
                    Text(title)
                        .font(size == .small ? .caption : .callout)
                        .padding(.horizontal, size == .small ? 8 : 14)
                        .padding(.vertical, size == .small ? 3 : 4)
                        .frame(maxWidth: size == .small ? .infinity : nil)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .background(selected ? Color.accentColor : Color.clear, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: .capsule)
    }
}
