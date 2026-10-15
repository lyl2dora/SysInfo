// 面板内容（D21，M0 设计 §6）：顶栏玻璃按钮 + tabs 切换模块 + 模块内容。
// 玻璃只用在控件层；图表和数值层用标准材质（见 PanelCard）。

import SwiftUI

struct PanelRootView: View {
    let store: MetricStore
    @Bindable var state: PanelState
    let actions: PanelActions
    let services: CPUServices
    let settings: AppSettings

    var body: some View {
        VStack(spacing: 12) {
            topBar

            Picker("模块", selection: $state.selectedTab) {
                ForEach(PanelTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.tabs)
            .labelsHidden()

            switch state.selectedTab {
            case .cpu:
                CPUPanelView(
                    store: store, services: services, settings: settings, expandDetails: state.expandDetailsInitially)
            }
        }
        .padding(14)
        .frame(width: PanelController.width)
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
