// 面板内的二级页（D64，合并模式设计 §3）：模块主页 → 列表页 → 单项详情页，最多两层，原地推入（同 D47 的原地切换）。
//
// - 顶栏换成「返回 + 标题」（PanelRootView），Esc 与再次点击同一个 widget 先回退，回到主页后才关闭面板；
// - 换模块、关闭面板时清空；
// - 二级页的内容放进限高滚动区，面板不超出屏幕；主页本身不滚动（D64：主页定高）。

import SwiftUI
import SysModel

/// 二级页。
enum PanelRoute: Hashable {
    /// 单盘详情（D54）。
    case disk(DiskKey)
    /// 外置盘列表（超过阈值时由汇总行进入）。
    case externalDisks
    /// RAID 成员列表（成员超过 5 块时由汇总行进入）。
    case raidMembers(DiskKey)
    /// 虚拟接口列表（D60、D63）。
    case virtualInterfaces
    /// 应用详情（各模块 Top N 点行进入）。
    case app(AppRoute)
}

/// 应用详情的入口：哪个 coalition，从哪个模块的 Top N 进来（决定成员列表先显示哪一列）。
struct AppRoute: Hashable {
    var coalitionID: UInt64
    var name: String
    var metric: TopNMetric
}

extension PanelState {
    /// 二级页的最大层数（D64）。
    static let maxDepth = 2

    /// 推入一页；已经两层时替换最上面一页。
    func push(_ route: PanelRoute) {
        if path.count >= Self.maxDepth { path.removeLast() }
        path.append(route)
    }

    /// 回退一层；已在主页时返回 false。
    @discardableResult
    func pop() -> Bool {
        guard !path.isEmpty else { return false }
        path.removeLast()
        return true
    }

    /// 在模块主页（没有二级页）。各模块的 Top N 只在主页显示，二级页可见时不扫。
    var isOnModuleRoot: Bool { path.isEmpty }
}

/// 二级页的统一外框：内容放进限高滚动区。
struct PanelSubpage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: Self.maxHeight)
    }

    /// 滚动区的最大高度：屏幕可见高度减去顶栏、边距与菜单栏间距。
    static var maxHeight: CGFloat {
        max((NSScreen.main?.visibleFrame.height ?? 900) - 110, 300)
    }
}

/// 主页上的汇总行（D64）：一行概括，右侧「›」，点击推入列表页。
struct SummaryRow<Detail: View>: View {
    let title: String
    let action: () -> Void
    @ViewBuilder var detail: Detail

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.caption)
                detail
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(minHeight: 18)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// 「只看活跃 / 显示全部」切换（列表页顶部）。
struct ActiveFilterPicker: View {
    @Binding var activeOnly: Bool
    let activeCount: Int
    let totalCount: Int

    var body: some View {
        SegmentedButtons(
            selection: $activeOnly,
            options: [
                (true, String(localized: "只看活跃（\(activeCount)）")),
                (false, String(localized: "显示全部（\(totalCount)）")),
            ])
    }
}
