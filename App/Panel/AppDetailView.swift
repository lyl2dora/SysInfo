// 应用详情页（D64，合并模式设计 §4）：各模块 Top N 点行进入；以后的应用活动窗口复用同一组件。
//
// - 各域当前值：CPU、内存、能耗、GPU 时间与能耗、ANE 能耗（估算）、磁盘读写，取自同一次 coalition 扫描；
// - 成员：全部同 uid 进程，数值列跟随入口模块（CPU / 内存 / 磁盘；GPU 没有按进程的公开计数，列 CPU）；
//   root 与其他用户的成员只给个数；
// - 结束按钮规则照 D31（同 uid、先确认、按住 ⌥ 默认强制；组行、root、其他用户、SysInfo 自身没有按钮）。
// 数据由 AppDetailModel 在详情页可见时按入口模块 Top N 的间隔刷新（PanelController 登记需求）。

import SwiftUI
import SysModel

struct AppDetailView: View {
    let model: AppDetailModel
    let route: AppRoute
    @Environment(\.panelLayoutChanged) private var layoutChanged

    var body: some View {
        PanelSubpage {
            if let detail = model.detail, model.coalitionID == route.coalitionID {
                header(detail)
                PanelCard { values(detail) }
                PanelCard { members(detail) }
            } else if model.ended {
                PanelCard { Text("这个应用已经退出").font(.panelRow).foregroundStyle(.secondary) }
            } else {
                PanelCard { Text("正在读取…").font(.panelRow).foregroundStyle(.secondary) }
            }
        }
        .onChange(of: layoutSignature) { layoutChanged() }
    }

    /// 影响高度的结构：有没有数据、成员数、有没有外部成员。
    private var layoutSignature: [Int] {
        guard let detail = model.detail else { return [model.ended ? -2 : -1] }
        return [detail.members.count, detail.residualCount > 0 ? 1 : 0]
    }

    private func header(_ detail: AppDetail) -> some View {
        HStack(spacing: 8) {
            AppIcon(path: detail.appPath, size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(detail.name).font(.panelTitle.weight(.semibold)).lineLimit(1)
                Text(memberSummary(detail)).font(.panelNote).foregroundStyle(.secondary)
            }
            Spacer()
            if detail.eligibility.isAllowed {
                Button("结束…") {
                    ProcessTermination.confirmAndTerminate(pid: detail.representativePID, name: detail.name)
                }
                .controlSize(.small)
                .help("结束（按住 ⌥ 时默认强制结束）")
            }
        }
    }

    private func memberSummary(_ detail: AppDetail) -> String {
        detail.memberCount <= 1
            ? "pid " + String(detail.representativePID)
            : String(localized: "\(detail.memberCount) 个进程")
    }

    private func values(_ detail: AppDetail) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("当前").font(.panelRow.weight(.semibold))
            KeyValue(title: String(localized: "CPU"), value: detail.cpu.map { PercentFormat.string(fromRatio: $0) } ?? "—")
            KeyValue(title: String(localized: "内存"), value: detail.footprint.map { Formatting.memory(Double($0)) } ?? "—")
            KeyValue(title: String(localized: "能耗"), value: detail.energyWatts.map(Formatting.watts) ?? "—")
            KeyValue(
                title: String(localized: "GPU 时间"),
                value: "\(detail.gpuShare.map { PercentFormat.string(fromRatio: min($0, 1)) } ?? "—") · \(detail.gpuWatts.map(Formatting.watts) ?? "—")")
            KeyValue(title: String(localized: "ANE 能耗（估算）"), value: detail.aneWatts.map(Formatting.watts) ?? "—")
            KeyValue(
                title: String(localized: "磁盘读写"),
                value: detail.diskRead.flatMap { r in detail.diskWrite.map { Formatting.diskRatePair(r, $0) } } ?? "—")
        }
        .monospacedDigit()
    }

    private func members(_ detail: AppDetail) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("成员").font(.panelRow.weight(.semibold))
                Spacer()
                Text(memberColumnTitle).font(.panelNote).foregroundStyle(.secondary)
                Color.clear.frame(width: 16, height: 1)
            }
            if detail.members.isEmpty {
                Text("没有你自己的进程").font(.panelNote).foregroundStyle(.secondary)
            }
            ForEach(sortedMembers(detail), id: \.pid) { member in
                HStack(spacing: 6) {
                    Text(member.name).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: String(member.pid)).foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    Text(memberValue(member) ?? "—")
                    if member.eligibility.isAllowed {
                        Button {
                            ProcessTermination.confirmAndTerminate(pid: member.pid, name: member.name)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("结束 \(member.name)"))
                        .frame(width: 16)
                        .help("结束（按住 ⌥ 时默认强制结束）")
                    } else {
                        Color.clear.frame(width: 16)
                    }
                }
                .font(.panelNote)
                .monospacedDigit()
            }
            if detail.residualCount > 0 {
                Text("另有 \(detail.residualCount) 个其他用户或 root 的进程（读不到细节）")
                    .font(.panelNote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 成员数值列跟随入口模块；GPU 没有按进程的公开计数，列 CPU。
    private var memberColumnTitle: String {
        switch route.metric {
        case .cpu, .gpu: String(localized: "CPU")
        case .memory: String(localized: "内存")
        case .disk: String(localized: "读 / 写")
        }
    }

    private func sortedMembers(_ detail: AppDetail) -> [TopNMember] {
        switch route.metric {
        case .cpu, .gpu: detail.members
        case .memory: detail.members.sorted { ($0.footprint ?? 0) > ($1.footprint ?? 0) }
        case .disk:
            detail.members.sorted { ($0.diskRead ?? 0) + ($0.diskWrite ?? 0) > ($1.diskRead ?? 0) + ($1.diskWrite ?? 0) }
        }
    }

    private func memberValue(_ member: TopNMember) -> String? {
        switch route.metric {
        case .cpu, .gpu: member.cpu.map { PercentFormat.string(fromRatio: $0) }
        case .memory: member.footprint.map { Formatting.memory(Double($0)) }
        case .disk: member.diskRead.flatMap { r in member.diskWrite.map { Formatting.diskRatePair(r, $0) } }
        }
    }
}
