// 面板内容（D21、D47，M0 设计 §6）：顶栏玻璃按钮 + 被点击 widget 所属模块的内容。
// 单 widget 模式下不提供模块切换（D47）；合并模式（D65）下顶栏下面一行切换器，另有「总览」。
// 二级页（D64）：顶栏换成「返回 + 标题」，内容换成 PanelRoute 对应的页；子视图用环境里的 panelNavigate 推入。
// 玻璃只用在控件层；图表和数值层用标准材质（见 PanelCard）。

import SwiftUI
import SysModel

struct PanelRootView: View {
    let store: MetricStore
    @Bindable var state: PanelState
    let actions: PanelActions
    let services: AppServices
    let settings: AppSettings
    /// 内容的结构变了（展开或收起、行数变化），请面板重新量一次高度。
    var onLayoutChange: () -> Void = {}
    /// 换了模块：重新登记需求（只采当前模块要的数据）。
    var onTabChange: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            topBar

            if state.isMerged, state.path.isEmpty {
                // D65 MG4：合并模式的切换器，只在模块主页与总览出现。
                SegmentedButtons(
                    selection: Binding(get: { state.selectedTab }, set: { actions.selectTab($0) }),
                    options: state.switcherTabs.map { ($0, $0.shortTitle) })
                    .help("切换模块（⌘1–⌘\(state.switcherTabs.count)）")
            }

            if let route = state.path.last {
                subpage(route)
            } else {
                moduleRoot
            }
        }
        .onChange(of: state.selectedTab) { onTabChange() }
        .onChange(of: state.path) { onTabChange() }
        .onChange(of: state.isMerged) { onTabChange() }
        .padding(14)
        // 顶部对齐：内容先变、窗口下一轮才改高时，只是底边伸缩，整块内容不会上下跳（SwiftUI 默认把内容居中）。
        .frame(width: PanelController.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.panelLayoutChanged, PanelLayoutAction(action: onLayoutChange))
        .environment(\.panelNavigate, PanelNavigateAction { [state] in state.push($0) })
    }

    @ViewBuilder
    private var moduleRoot: some View {
        switch state.selectedTab {
        case .overview:
            OverviewPanelView(
                store: store, services: services, settings: settings, tabs: state.switcherTabs, select: actions.selectTab)
        case .cpu:
            CPUPanelView(
                store: store, services: services, settings: settings, expandDetails: state.expandDetailsInitially)
        case .power:
            PowerPanelView(store: store, services: services, settings: settings)
        case .memory:
            MemoryPanelView(store: store, services: services, settings: settings)
        case .storage:
            StoragePanelView(store: store, services: services, settings: settings)
        case .gpu:
            GPUPanelView(store: store, services: services, settings: settings)
        case .network:
            NetworkPanelView(store: store, services: services, settings: settings)
        }
    }

    /// 二级页（D64）：内容放进限高滚动区。
    @ViewBuilder
    private func subpage(_ route: PanelRoute) -> some View {
        switch route {
        case .disk(let key):
            if let disk = services.storageModel.inventory.disk(key) {
                StorageDetailView(store: store, services: services, settings: settings, disk: disk)
            } else {
                PanelSubpage { PanelCard { Text("这块盘已经断开").font(.caption).foregroundStyle(.secondary) } }
            }
        case .externalDisks:
            StorageDiskListView(store: store, services: services, settings: settings, raid: nil)
        case .raidMembers(let key):
            StorageDiskListView(store: store, services: services, settings: settings, raid: key)
        case .virtualInterfaces:
            NetworkVirtualListView(store: store, services: services, settings: settings)
        case .app(let route):
            AppDetailView(model: services.appDetail, route: route)
        }
    }

    /// 二级页的标题（顶栏中间）。
    private func title(_ route: PanelRoute) -> String {
        let inventory = services.storageModel.inventory
        switch route {
        case .disk(let key): return inventory.disk(key).map { StorageText.diskName($0, inventory: inventory) } ?? ""
        case .externalDisks: return String(localized: "外置盘")
        case .raidMembers(let key): return inventory.raidSet(key).map { String(localized: "RAID「\($0.name)」") } ?? ""
        case .virtualInterfaces: return String(localized: "虚拟接口")
        case .app(let route): return route.name
        }
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            if state.isPinned {
                Button(action: actions.close) {
                    Label("关闭", systemImage: "xmark")
                }
                .help("关闭浮窗")
            }
            if let route = state.path.last {
                // D64：二级页的顶栏是「返回 + 标题」。
                Button {
                    state.pop()
                } label: {
                    Label("返回", systemImage: "chevron.left")
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .help("返回（Esc）")
                Text(title(route))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Button(action: actions.openActivityMonitor) {
                    Label("活动监视器", systemImage: "chart.bar.xaxis")
                }
                .help("打开活动监视器")
            }

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

/// 推入一个二级页（D64）。
struct PanelNavigateAction {
    var action: (PanelRoute) -> Void = { _ in }
    func callAsFunction(_ route: PanelRoute) { action(route) }
}

extension EnvironmentValues {
    @Entry var panelLayoutChanged = PanelLayoutAction()
    @Entry var panelNavigate = PanelNavigateAction()
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
