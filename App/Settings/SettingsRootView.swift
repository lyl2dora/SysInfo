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

    private static let sidebarInset: CGFloat = 8
    private static let compactSidebarWidth: CGFloat = 52
    private static let expandedSidebarWidth: CGFloat = 180
    /// 分组卡片的最大宽度：内容栏更宽时卡片居中。显式给出（而不是依赖 Form 自己的上限，实测约 703），
    /// 页头才能按同一个数算出内容缩进（D83）。
    static let cardMaxWidth: CGFloat = 680
    /// grouped Form 自带的左右内边距、分组标题相对卡片的内缩（2026-10-18 实测）。
    static let formInset: CGFloat = 20
    static let sectionTitleInset: CGFloat = 10

    /// 红绿灯右侧归工具栏（导航项）的宽度：这里的点击不会交给内容视图（2026-10-18 实测约 55 pt）。
    static let toolbarZoneWidth: CGFloat = 58

    /// 内容栏左边缘在窗口里的 x。
    static func detailX(compact: Bool) -> CGFloat {
        sidebarInset * 2 + (compact ? compactSidebarWidth : expandedSidebarWidth)
    }

    /// 叠加在 Form 自带内边距之外的左右留白：内容栏比「卡片最大宽度 + 内边距」宽时，把多出的部分平分到两边。
    static func contentMargin(detailWidth: CGFloat) -> CGFloat {
        max(0, (detailWidth - formInset * 2 - cardMaxWidth) / 2)
    }

    /// 内容缩进线（分组标题文字的左边缘），相对内容栏左边缘。页头的第一个元素对齐它。
    static func contentIndent(detailWidth: CGFloat) -> CGFloat {
        contentMargin(detailWidth: detailWidth) + formInset + sectionTitleInset
    }

    var body: some View {
        @Bindable var state = context.state
        let compact = state.sidebarCompact
        // 不用 NavigationSplitView：它在统一样式的标题栏下给侧栏留了最小宽度（红绿灯在侧栏里），收起成图标栏时
        // 宽度改不下来。自己排（D81，Finder 样式）：
        // - 侧栏是内缩的浮动玻璃面板。展开时从窗口顶部开始，红绿灯落在面板顶上；收起成图标栏时放不下红绿灯，
        //   从标题栏下方开始；
        // - 侧栏开关和页名是内容栏顶部的页头，与红绿灯同一行，第一个元素对齐内容缩进（D83）。收起时开关改放进
        //   工具栏：红绿灯右侧约 55 pt 的区域点击归工具栏，内容栏里的按钮在那里点不到；
        // - 内容延伸到标题栏下，滚上去时由渐隐带保证页头可读。
        GeometryReader { proxy in
            let titlebar = proxy.safeAreaInsets.top
            let lights = state.trafficLights
            // 页头一行：以红绿灯的竖直中心为中心；展开时侧栏列表也从这一行下面开始。
            let row = lights.midY * 2
            HStack(alignment: .top, spacing: Self.sidebarInset) {
                SettingsSidebar(
                    selection: $state.selection, compact: compact,
                    topInset: compact ? 0 : row - Self.sidebarInset
                )
                .padding([.leading, .bottom], Self.sidebarInset)
                .padding(.top, compact ? 0 : Self.sidebarInset - titlebar)
                .zIndex(1)  // 浮出的页名要盖在内容上
                detail(for: state.selection ?? .general)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentMargins(.horizontal, Self.contentMargin(detailWidth: proxy.size.width - Self.detailX(compact: compact)), for: .scrollContent)
                    // Form 自带的背景比窗口背景浅：隐藏它，渐隐带才能与底色一致、静止时不显出一条。
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .top) { TitlebarFade(height: row + 10) }
                    .overlay(alignment: .topLeading) {
                        let detailX = Self.detailX(compact: compact)
                        let indent = Self.contentIndent(detailWidth: proxy.size.width - detailX)
                        // D83：页头的第一个元素对齐内容缩进线（分组标题文字的左边缘）。展开时是开关；收起时开关在
                        // 工具栏里，页名对齐缩进线，但至少让开红绿灯右侧的工具栏区域（窄窗口时）。
                        let leading = compact ? max(indent, lights.maxX + Self.toolbarZoneWidth - detailX) : indent
                        SettingsPageHeader(
                            title: (state.selection ?? .general).title, showsToggle: !compact,
                            toggle: { state.sidebarCompact.toggle() }
                        )
                        .padding(.leading, leading)
                        .frame(height: row)
                        .offset(y: -titlebar)
                    }
            }
        }
        // 整个窗口（含标题栏下）统一用窗口背景色，侧栏玻璃面板浮在上面，左右两栏之间不出现色差。
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        // 窗口标题（「SysInfo 设置」）只留给「窗口」菜单，不在标题栏显示：页名在内容栏的页头里。
        .toolbar(removing: .title)
        // 留一个不可见的工具栏项目：没有任何项目时，内容区顶边会多出一条分隔线，红绿灯也会缩到窄标题栏里
        // （2026-10-18 实测）。放在最右边，不占红绿灯旁的位置。
        .toolbar {
            // 收起时开关放进工具栏（D83）：红绿灯右侧这块区域的点击归工具栏，放在内容栏页头里会点不到。
            if compact {
                ToolbarItem(placement: .navigation) {
                    SidebarToggleButton(compact: true) { state.sidebarCompact.toggle() }
                }
                .sharedBackgroundVisibility(.hidden)
            }
            ToolbarItem(placement: .primaryAction) { Color.clear.frame(width: 1, height: 1) }
                .sharedBackgroundVisibility(.hidden)
        }
    }

    private func openPage(_ page: SettingsPage) {
        context.state.selection = page
    }

    @ViewBuilder
    private func detail(for page: SettingsPage) -> some View {
        switch page {
        case .general:
            GeneralSettingsView(settings: context.settings, updater: context.services.updater)
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
        case .devices:
            DevicesSettingsView(
                settings: context.settings, store: context.store, model: context.services.devicesModel, openPage: openPage)
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

/// 内容滚到标题栏下面时的渐隐带：页头那一行先实后虚。Form 底层的滚动视图不吃 scrollEdgeEffectStyle，
/// 自排的侧栏布局也拿不到 AppKit 标题栏的边缘效果（D81），不加这条的话滚上去的文字会和页头叠在一起。
private struct TitlebarFade: View {
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                stops: [
                    .init(color: Color(nsColor: .windowBackgroundColor), location: 0),
                    .init(color: Color(nsColor: .windowBackgroundColor), location: 0.6),
                    .init(color: Color(nsColor: .windowBackgroundColor).opacity(0), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: height)
            .offset(y: -proxy.safeAreaInsets.top)
        }
        .frame(height: 0)
        .allowsHitTesting(false)
    }
}

/// 内容栏顶部的页头（D81）：侧栏开关与页名，Finder 样式，不加玻璃胶囊。
private struct SettingsPageHeader: View {
    let title: String
    let showsToggle: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if showsToggle {
                SidebarToggleButton(compact: false, action: toggle)
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
        }
    }
}

/// 侧栏开关：展开时在页头里，收起时在工具栏里（D83），样式一致。
private struct SidebarToggleButton: View {
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help(compact ? "展开边栏" : "收起边栏")
        .accessibilityLabel(compact ? "展开边栏" : "收起边栏")
    }
}

/// 设置侧栏：标题栏下方的浮动玻璃面板。展开时图标加名字（180 pt），收起时只留图标（52 pt）。
/// 收起时悬停约 0.35 s，在图标右侧浮出页名。不用系统提示（.help）：AppKit 只在 app 处于前台时显示提示，
/// 而设置窗口常在 app 未被激活时就在最前（从 Xcode 运行、`--open-settings` 启动，协作式激活不让抢前台）。
private struct SettingsSidebar: View {
    @Binding var selection: SettingsPage?
    let compact: Bool
    /// 展开时面板从窗口顶部开始，列表要让出红绿灯那一行。
    var topInset: CGFloat = 0

    @State private var hovered: SettingsPage?
    @State private var shown: SettingsPage?
    @State private var showTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(SettingsPage.allCases) { page in
                    let selected = (selection ?? .general) == page
                    Button {
                        selection = page
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: page.symbol)
                                .frame(width: 20)
                                .foregroundStyle(selected ? Color.accentColor : .secondary)
                            if !compact {
                                Text(page.title).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                        .padding(.horizontal, compact ? 0 : 8)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.18))
                            } else if compact && hovered == page {
                                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08))
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in hoverChanged(page, inside: inside) }
                    .anchorPreference(key: HoverAnchorKey.self, value: .bounds) { shown == page ? $0 : nil }
                    .accessibilityLabel(page.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(6)
            .padding(.top, topInset)
        }
        .scrollIndicators(.never)
        .frame(width: compact ? 52 : 180)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        // 页名浮在侧栏右侧，盖在内容上方（侧栏在 HStack 里要排在内容之上，见 zIndex）。
        .overlayPreferenceValue(HoverAnchorKey.self) { anchor in
            GeometryReader { proxy in
                if compact, let anchor, let page = shown {
                    let rect = proxy[anchor]
                    // 左缘在面板右边外 10 pt，竖直方向与该行居中。
                    Text(page.title)
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                        .fixedSize()
                        .frame(height: rect.height)
                        .offset(x: proxy.size.width + 10, y: rect.minY)
                        .allowsHitTesting(false)
                }
            }
        }
        .onChange(of: compact) { hideHint() }
    }

    private func hoverChanged(_ page: SettingsPage, inside: Bool) {
        guard compact else { return }
        if inside {
            hovered = page
            showTask?.cancel()
            // 已经在显示别的页名时直接换，不再等；第一次悬停等约 0.35 s，划过时不闪。
            if shown != nil {
                shown = page
                return
            }
            showTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, hovered == page else { return }
                shown = page
            }
        } else if hovered == page {
            hideHint()
        }
    }

    private func hideHint() {
        showTask?.cancel()
        hovered = nil
        shown = nil
    }
}

/// 悬停的那一行在侧栏里的位置（浮出页名用）。
private struct HoverAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

// MARK: - 各页

private struct GeneralSettingsView: View {
    @Bindable var settings: AppSettings
    let updater: Updater?
    @State private var loginItem = LoginItemModel()

    var body: some View {
        Form {
            LoginItemSection(model: loginItem)
            UpdateSection(settings: settings, updater: updater)
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
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }
}

/// 检查更新（D76）：出厂每周检查、只提示；只有日用版启用。
private struct UpdateSection: View {
    @Bindable var settings: AppSettings
    let updater: Updater?

    var body: some View {
        Section {
            if let updater, updater.isEnabled {
                Picker("检查更新", selection: $settings.updateFrequency) {
                    Text("关闭").tag(UpdateCheckFrequency.off)
                    Text("每天").tag(UpdateCheckFrequency.daily)
                    Text("每周").tag(UpdateCheckFrequency.weekly)
                }
                Toggle("发现新版本时自动下载并安装", isOn: $settings.updateAutoInstall)
                    .disabled(!updater.canInstall || settings.updateFrequency == .off)
                LabeledContent {
                    HStack(spacing: 8) {
                        if updater.isBusy { ProgressView().controlSize(.small) }
                        Button("立即检查") { updater.checkNow() }
                            .disabled(updater.isBusy)
                    }
                } label: {
                    Text(Self.statusTitle(updater))
                    Text(Self.lastCheckText(updater.lastCheck))
                }
                if let offer = updater.availableOffer {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Button("查看说明") { updater.openReleasePage() }
                            if updater.canInstall {
                                Button("下载并安装") { updater.install() }
                                    .disabled(updater.isBusy)
                            }
                        }
                    } label: {
                        Text("SysInfo \(offer.version.description) 可以更新")
                        if !updater.canInstall {
                            Text(
                                updater.isTranslocated
                                    ? "SysInfo 正从系统的隔离位置运行：请在访达里把它拖进「应用程序」文件夹后重新打开，或从 Release 页面下载后手动替换。"
                                    : "当前副本不在「应用程序」文件夹或没有写权限，请从 Release 页面下载后手动替换。")
                        }
                    }
                }
                if case .failed(let message) = updater.state {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } else {
                Text(BuildInfo.isDebug ? "Debug 版不检查更新。" : "这个构建不检查更新。")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("更新")
        } footer: {
            Text("只连接本项目的 GitHub Releases 查询版本，不上传任何本机信息。安装前会校验发布包的校验值、开发者签名与公证。")
        }
    }

    private static func statusTitle(_ updater: Updater) -> String {
        switch updater.state {
        case .idle: String(localized: "当前版本 \(BuildInfo.version)")
        case .checking: String(localized: "正在检查…")
        case .upToDate: String(localized: "已是最新版本（\(BuildInfo.version)）")
        case .available: String(localized: "当前版本 \(BuildInfo.version)")
        case .downloading: String(localized: "正在下载并校验…")
        case .installing: String(localized: "正在安装，完成后自动重新打开…")
        case .failed: String(localized: "当前版本 \(BuildInfo.version)")
        }
    }

    private static func lastCheckText(_ date: Date?) -> String {
        guard let date else { return String(localized: "还没有检查过") }
        return String(localized: "上次检查：\(date.formatted(date: .abbreviated, time: .shortened))")
    }
}

/// 开机自启（D75）：出厂不注册，用户手动打开；只有从 /Applications 运行的 Release 版显示开关。
private struct LoginItemSection: View {
    let model: LoginItemModel

    var body: some View {
        Section {
            switch model.availability {
            case .available:
                Toggle("登录时启动", isOn: Binding(get: { model.isOn }, set: { model.setEnabled($0) }))
                if model.requiresApproval {
                    LabeledContent {
                        Button("打开系统设置") { model.openSystemSettings() }
                    } label: {
                        Text("需要在系统设置里批准")
                        Text("「通用 → 登录项与扩展」里允许 SysInfo 后才会生效。")
                    }
                }
                if let error = model.lastError {
                    Text("没能更改登录项：\(error)")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            case .debugBuild:
                Text("Debug 版不注册登录项。")
                    .foregroundStyle(.secondary)
            case .notInApplications:
                Text("把 SysInfo 移到「应用程序」文件夹后，才能设置登录时启动。")
                    .foregroundStyle(.secondary)
            case .translocated:
                Text("SysInfo 正从系统的隔离位置运行：请在访达里把它拖进「应用程序」文件夹，再重新打开，才能设置登录时启动。")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("启动")
        } footer: {
            Text("默认不随登录启动。")
        }
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
            orderSection

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

            if !settings.menuBarMerged {
                Section {
                    if settings.visibleWidgets.count >= Self.mergeSuggestionCount {
                        Label("已开启 \(settings.visibleWidgets.count) 个项目，部分可能被系统收进溢出区。建议打开上面的「合并为单个项目」。", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                    }
                    Text("项目较多时，部分项目可能被系统收进溢出区；可以合并为单个项目，或到「系统设置 → 菜单栏」查看和调整哪些项目允许显示。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 页面顶部的排序区（D92）：已开启的 widget 按菜单栏的样子横向排开（一行放不下时换行）。
    /// 合并模式下是合并项目里各段的顺序，可左右拖动；单 widget 模式下只读，位置由用户在菜单栏上按住 ⌘ 拖动。
    private var orderSection: some View {
        let visible = settings.visibleWidgets
        let merged = settings.menuBarMerged
        let widgets = merged ? settings.mergedWidgets(from: visible) : visible
        let configurations = widgets.map { StatusItemConfiguration(widget: $0, settings: settings) }
        return Section {
            if widgets.isEmpty {
                Text("还没有开启任何菜单栏项目。").foregroundStyle(.secondary)
            } else {
                // 27 的 reorderContainer 在 Form 里不生效（§8），容器用这一行里的流式布局。
                WidgetFlowLayout(spacing: 6) {
                    ForEach(Array(zip(widgets.indices, configurations)), id: \.1.widget) { index, configuration in
                        chip(configuration, index: index, of: widgets, draggable: merged)
                    }
                    .reorderable()
                }
                .reorderContainer(for: MenuWidget.self, itemID: \.self, isEnabled: merged) { difference in
                    apply(difference, to: widgets)
                }
                .padding(.vertical, 2)
                LabeledContent(
                    "合计宽度",
                    value: Self.points(
                        merged
                            ? MergedStatusItemView.fixedWidth(for: configurations, separator: settings.menuBarMergedSeparator)
                            : configurations.map(StatusItemView.fixedWidth(for:)).reduce(0, +)))
            }
        } header: {
            Text(merged ? "合并项目里的顺序（从左到右）" : "已开启的项目")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(merged ? "左右拖动调整顺序。" : "在菜单栏上按住 ⌘ 拖动各项目调整位置。")
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
        }
    }

    /// 一个 widget 的小块：真实的菜单栏预览，悬停显示名称、所属模块与宽度。
    /// 预览是 NSView，上面盖一层透明命中区，拖动手势交给 SwiftUI。
    private func chip(_ configuration: StatusItemConfiguration, index: Int, of widgets: [MenuWidget], draggable: Bool) -> some View {
        let widget = configuration.widget
        let title = WidgetInfo.title(widget)
        let detail = "\(WidgetInfo.module(widget.module)) · \(Self.points(StatusItemView.fixedWidth(for: configuration)))"
        return StatusItemPreview(store: store, configuration: configuration)
            .allowsHitTesting(false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: .rect(cornerRadius: 6))
            .overlay(Color.clear.contentShape(.rect))
            .help(Text("\(title)（\(detail)）"))
            .accessibilityElement()
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(detail))
            .accessibilityActions {
                if draggable {
                    if index > 0 {
                        Button("左移") { move(widgets, from: index, by: -1) }
                    }
                    if index < widgets.count - 1 {
                        Button("右移") { move(widgets, from: index, by: 1) }
                    }
                }
            }
    }

    /// 在合并顺序里把一项左移或右移一位（D65 MG1）。
    private func move(_ widgets: [MenuWidget], from index: Int, by offset: Int) {
        let target = index + offset
        guard widgets.indices.contains(index), widgets.indices.contains(target) else { return }
        var order = widgets
        order.swapAt(index, target)
        commit(order)
    }

    /// 拖拽结束（D92）：把被拖的项按拖动时选中的先后，插到目标项之前或末尾。
    private func apply(_ difference: ReorderDifference<MenuWidget, ReorderableSingleCollectionIdentifier>, to widgets: [MenuWidget]) {
        let before: MenuWidget? =
            switch difference.destination.position {
            case .before(let id): id
            case .end: nil
            }
        commit(ReorderList.applying(sources: difference.sources, before: before, to: widgets))
    }

    private func commit(_ order: [MenuWidget]) {
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
                LabeledContent("检查更新") {
                    Text(
                        settings.updateFrequency == .off
                            ? String(localized: "关闭（只在点击「立即检查」时连接）")
                            : String(localized: "api.github.com 与 Release 下载地址"))
                }
                HStack(spacing: 4) {
                    Text("除此之外 SysInfo 不连接任何网络服务。延迟只在网络面板可见或延迟 widget 打开时发包；公网 IP 只在你点击时查询一次；检查更新按「通用」页设置的频率查询本项目的 GitHub Releases。")
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

/// 横向排开、一行放不下时换行的布局（菜单栏页的排序区，D92）。每行顶部对齐，子视图按自身理想尺寸摆放。
private struct WidgetFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
