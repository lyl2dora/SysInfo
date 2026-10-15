// 面板的 Top N（D31，CPU 模块设计 §5.7、§7.2）。
//
// - 默认按应用分组，一个 coalition 一行，可展开看同 uid 成员；宿主 coalition 的副标题是占比最高的成员；
// - 同 uid 的进程才有「结束」按钮，先确认，按住 ⌥ 时默认强制；组行、root、其他用户、SysInfo 自身没有按钮；
// - 鼠标悬停在列表上时冻结排序；
// - coalition 不可用时只列同 uid 进程，并提供手动「刷新全部」（setuid ps，只在点击时运行；内存没有，D49）；
// - 内存面板（D49）复用同一套行：数值列换成 footprint，副标题、成员、外部成员合计都按 footprint。

import AppKit
import SwiftUI
import SysModel

struct TopNSection: View {
    let model: TopNModel
    let grouping: TopNGrouping
    /// 行位数（设置的行数）。行位固定、每行高度固定，数据到达只填内容，面板高度不变（学 Stats 的做法）。
    let slots: Int
    @State private var expanded: Set<String> = []
    @Environment(\.panelLayoutChanged) private var layoutChanged

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(heading)
                    .font(.caption.weight(.semibold))
                Spacer()
                if model.isFrozen {
                    Image(systemName: "pause.circle").font(.caption).foregroundStyle(.secondary).help("悬停时暂停排序")
                }
            }
            if model.isFallback {
                HStack {
                    Text("只列出你自己的进程（另有 \(model.hiddenCount) 个读不到）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.supportsRefreshAll {
                        Button(model.isRefreshingAll ? "刷新中…" : "刷新全部", action: model.refreshAll)
                            .controlSize(.mini)
                            .disabled(model.isRefreshingAll)
                            .help("运行两次 /bin/ps，间隔 2 秒，列出所有用户的进程")
                    }
                }
            }
            ForEach(model.rows.prefix(slots)) { row in
                TopNRowView(
                    row: row, metric: model.metric, expanded: expanded.contains(row.id),
                    toggle: {
                        if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
                    },
                    terminate: model.terminate)
            }
            // 没有数据的行位：同样高度的空行；还没有任何数据时第一行写「等待数据…」。
            ForEach(model.rows.count..<max(slots, model.rows.count), id: \.self) { index in
                TopNRowView.placeholder(index == 0 ? String(localized: "等待数据…") : nil)
            }
        }
        .onHover { model.isFrozen = $0 }
        .onChange(of: layoutSignature) { layoutChanged() }
    }
}

extension TopNSection {
    fileprivate var heading: String {
        switch (model.metric, grouping) {
        case (.cpu, .byApp): String(localized: "占用最高的应用")
        case (.cpu, .byProcess): String(localized: "占用最高的进程")
        case (.memory, .byApp): String(localized: "内存最多的应用")
        case (.memory, .byProcess): String(localized: "内存最多的进程")
        }
    }

    /// 影响高度的结构：行位数、回退提示、展开的行及其成员数。行高固定，行数据本身不影响高度。
    fileprivate var layoutSignature: [Int] {
        [slots, model.isFallback ? 1 : 0]
            + model.rows.prefix(slots).map { row in
                expanded.contains(row.id) ? 2 + min(row.members.count, 9) * 4 : 0
            }
    }
}

private struct TopNRowView: View {
    /// 展开后最多列出的成员数（按 CPU 降序）；宿主 coalition 可能有几十个成员，全列出来面板会比屏幕还高。
    static let memberLimit = 8

    let row: TopNRow
    let metric: TopNMetric
    let expanded: Bool
    let toggle: () -> Void
    let terminate: (pid_t, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                AppIcon(path: row.appPath)
                // 行高固定为两行（看不见的模板撑开），内容在行内垂直居中：没有副标题时名字居中，不留半行空白。
                Self.twoLineSlot {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 3) {
                            Text(row.name).lineLimit(1)
                            if row.memberCount > 1 {
                                Text("×\(row.memberCount)").foregroundStyle(.tertiary)
                            }
                        }
                        if let top = row.topMember {
                            Text("\(top.name) \(memberValue(top) ?? "")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 4)
                if let share = row.perfLevel0Share {
                    Text("P0 \(PercentFormat.string(fromRatio: share))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("在最快一档上运行的时间占比")
                }
                if let watts = row.energyWatts {
                    Text(Formatting.watts(watts)).font(.caption2).foregroundStyle(.secondary)
                }
                Text(rowValue)
                    .frame(width: valueWidth, alignment: .trailing)
                if row.eligibility.isAllowed {
                    killButton(pid: row.representativePID, name: row.name)
                } else if !row.members.isEmpty {
                    Button(action: toggle) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(expanded ? Text("收起成员") : Text("展开成员"))
                    .help(expanded ? "收起成员" : "展开成员")
                    .frame(width: 16)
                } else {
                    Color.clear.frame(width: 16)
                }
            }
            .font(.caption)
            .monospacedDigit()
            if expanded {
                ForEach(row.members.prefix(Self.memberLimit), id: \.pid) { member in
                    HStack(spacing: 6) {
                        Text(member.name).lineLimit(1).padding(.leading, 22)
                        Spacer()
                        Text(memberValue(member) ?? "—")
                            .frame(width: valueWidth, alignment: .trailing)
                        if member.eligibility.isAllowed {
                            killButton(pid: member.pid, name: member.name)
                        } else {
                            Color.clear.frame(width: 16)
                        }
                    }
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
                if row.members.count > Self.memberLimit {
                    let rest = row.members.dropFirst(Self.memberLimit)
                    let total =
                        metric == .memory
                        ? Formatting.memory(Double(rest.reduce(UInt64(0)) { $0 + ($1.footprint ?? 0) }))
                        : PercentFormat.string(fromRatio: rest.reduce(0.0) { $0 + ($1.cpu ?? 0) })
                    Text("另有 \(rest.count) 个你的进程 · \(total)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 22)
                }
                if row.residualCount > 0 {
                    let residual =
                        metric == .memory
                        ? row.residualFootprint.map { Formatting.memory(Double($0)) }
                        : row.residualCPU.map { PercentFormat.string(fromRatio: $0) }
                    Text("另有 \(row.residualCount) 个其他用户或 root 的进程\(residual.map { " · " + $0 } ?? "")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 22)
                }
            }
        }
    }

    /// 数值列宽：百分比 44 pt；内存（「12.34 GB」）要宽一些。
    private var valueWidth: CGFloat { metric == .memory ? 62 : 44 }

    private var rowValue: String {
        switch metric {
        case .cpu: PercentFormat.string(fromRatio: row.cpu)
        case .memory: row.footprint.map { Formatting.memory(Double($0)) } ?? "—"
        }
    }

    private func memberValue(_ member: TopNMember) -> String? {
        switch metric {
        case .cpu: member.cpu.map { PercentFormat.string(fromRatio: $0) }
        case .memory: member.footprint.map { Formatting.memory(Double($0)) }
        }
    }

    /// 两行高的槽位：用看不见的「名字 + 副标题」模板定高，内容叠在上面、垂直居中。
    static func twoLineSlot<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                Text(" ")
                Text(" ").font(.caption2)
            }
            .hidden()
            content()
        }
    }

    /// 空行位：与有数据的行同样的高度。
    static func placeholder(_ text: String?) -> some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 16, height: 16)
            twoLineSlot { Text(text ?? " ").foregroundStyle(.tertiary).lineLimit(1) }
            Spacer()
        }
        .font(.caption)
        .accessibilityHidden(text == nil)
    }

    private func killButton(pid: pid_t, name: String) -> some View {
        Button {
            terminate(pid, name)
        } label: {
            Image(systemName: "xmark.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("结束 \(name)"))
        .frame(width: 16)
        .help("结束（按住 ⌥ 时默认强制结束）")
    }
}

/// 应用图标（按路径缓存）；没有 .app 时显示通用图标。
private struct AppIcon: View {
    let path: String?

    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .frame(width: 16, height: 16)
    }

    private var icon: NSImage {
        guard let path else { return NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) ?? NSImage() }
        if let hit = Self.cache[path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        Self.cache[path] = image
        return image
    }
}
