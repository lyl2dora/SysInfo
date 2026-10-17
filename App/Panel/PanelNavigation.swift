// 面板内的二级页（D64，合并模式设计 §3）：模块主页 → 列表页 → 单项详情页，最多两层，原地推入（同 D47 的原地切换）。
//
// - 顶栏换成「返回 + 标题」（PanelRootView），Esc 与再次点击同一个 widget 先回退，回到主页后才关闭面板；
// - 换模块、关闭面板时清空；
// - 面板超出屏幕时内容区滚动（D66），主页与二级页同一套机制。

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

/// 二级页的统一外框。限高与滚动由面板的内容区统一处理（D66），这里只排版。
struct PanelSubpage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
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
                Text(title).font(.panelRow)
                detail
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.panelNote).foregroundStyle(.tertiary)
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
