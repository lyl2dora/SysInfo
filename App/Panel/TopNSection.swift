// 面板的 Top N（D31，CPU 模块设计 §5.7、§7.2）。
//
// - 默认按应用分组，一个 coalition 一行；宿主 coalition 的副标题是占比最高的成员；
// - 按应用分组时点击一行推入应用详情页（D64：不再就地展开成员，成员与各域数值都在详情页）；按进程分组时不推入；
// - 同 uid 的进程才有「结束」按钮，先确认，按住 ⌥ 时默认强制；组行、root、其他用户、SysInfo 自身没有按钮；
// - 鼠标悬停在列表上时冻结排序；
// - coalition 不可用时只列同 uid 进程，并提供手动「刷新全部」（setuid ps，只在点击时运行；内存没有，D49）；
// - GPU 面板（D57 G7）：数值列是 GPU 时间占比，副标题列 GPU 与 ANE 能耗；成员只列名字（没有按进程的公开 GPU 计数）；
// - 内存面板（D49）复用同一套行：数值列换成 footprint，副标题、成员、外部成员合计都按 footprint；
// - 存储面板（存储模块设计 §4.5）同样复用：数值列是「读 / 写」速率（B/s，按 1000 换算）。

import AppKit
import SwiftUI
import SysModel

struct TopNSection: View {
    let model: TopNModel
    let grouping: TopNGrouping
    /// 行位数（设置的行数）。行位固定、每行高度固定，数据到达只填内容，面板高度不变（学 Stats 的做法）。
    let slots: Int
    @Environment(\.panelLayoutChanged) private var layoutChanged
    @Environment(\.panelNavigate) private var navigate

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
            if model.isFallback, model.metric == .gpu {
                Text("应用活动数据不可用：没有按进程的公开 GPU 计数，无法列出")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if model.isFallback {
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
                    row: row, metric: model.metric,
                    open: row.kind == .coalition && !model.isFallback
                        ? { navigate(.app(AppRoute(coalitionID: row.coalitionID, name: row.name, metric: model.metric))) }
                        : nil,
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
        case (.disk, .byApp): String(localized: "读写最多的应用")
        case (.disk, .byProcess): String(localized: "读写最多的进程")
        case (.gpu, .byApp): String(localized: "GPU 时间最多的应用")
        case (.gpu, .byProcess): String(localized: "GPU 时间最多的进程")
        }
    }

    /// 影响高度的结构：行位数、回退提示。行高固定，行数据本身不影响高度。
    fileprivate var layoutSignature: [Int] {
        [slots, model.isFallback ? 1 : 0]
    }
}

private struct TopNRowView: View {
    let row: TopNRow
    let metric: TopNMetric
    /// 推入应用详情页；按进程分组、回退模式时为 nil。
    let open: (() -> Void)?
    let terminate: (pid_t, String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button {
                open?()
            } label: {
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
                    if metric == .gpu {
                        if let ane = row.aneWatts, ane >= 0.005 {
                            Text("ANE \(Formatting.watts(ane))").font(.caption2).foregroundStyle(.tertiary)
                                .help("ANE 能耗（coalition 记账，估算）")
                        }
                        if let watts = row.gpuWatts {
                            Text(Formatting.watts(watts)).font(.caption2).foregroundStyle(.secondary).help("GPU 能耗")
                        }
                    }
                    Text(rowValue)
                        .frame(width: valueWidth, alignment: .trailing)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .allowsHitTesting(open != nil)
            .help(open == nil ? "" : "查看这个应用的成员与各项数值")
            if row.eligibility.isAllowed {
                killButton(pid: row.representativePID, name: row.name)
            } else {
                Color.clear.frame(width: 16)
            }
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .opacity(open == nil ? 0 : 1)
                .frame(width: 8)
                .accessibilityHidden(true)
        }
        .font(.caption)
        .monospacedDigit()
    }

    /// 数值列宽：百分比 44 pt；内存（「12.34 GB」）要宽一些；磁盘是「读 / 写」两个速率。
    private var valueWidth: CGFloat {
        switch metric {
        case .cpu, .gpu: 44
        case .memory: 62
        case .disk: 112
        }
    }

    private var rowValue: String {
        switch metric {
        case .cpu: PercentFormat.string(fromRatio: row.cpu)
        case .memory: row.footprint.map { Formatting.memory(Double($0)) } ?? "—"
        case .disk: Formatting.diskRatePair(row.diskRead ?? 0, row.diskWrite ?? 0)
        // 多个命令缓冲同时在飞时 GPU 时间之和会超过墙钟（M5 实测 141%），钳到 100%。
        case .gpu: PercentFormat.string(fromRatio: min(row.gpuShare ?? 0, 1))
        }
    }

    private func memberValue(_ member: TopNMember) -> String? {
        switch metric {
        case .cpu: member.cpu.map { PercentFormat.string(fromRatio: $0) }
        case .memory: member.footprint.map { Formatting.memory(Double($0)) }
        case .disk: member.diskRead.flatMap { r in member.diskWrite.map { Formatting.diskRatePair(r, $0) } }
        case .gpu: nil  // 没有按进程的 GPU 计数，成员只列名字
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
struct AppIcon: View {
    let path: String?
    var size: CGFloat = 16

    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .frame(width: size, height: size)
    }

    private var icon: NSImage {
        guard let path else { return NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) ?? NSImage() }
        if let hit = Self.cache[path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        Self.cache[path] = image
        return image
    }
}
