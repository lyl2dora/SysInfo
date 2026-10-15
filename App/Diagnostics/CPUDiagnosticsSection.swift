// 诊断页的 CPU 部分（CPU 模块设计 §7.4，K19）：
// - 每个数据源当前走的路径：频率（实际 / 请求）、温度（内置档案 / 本机校准 / 学习中）、功耗（专用轨 / 不可用）、
//   Top N（coalition / 同 uid 回退）；
// - 拓扑：三种档次依据各自的结果与是否一致；芯片档案：socID、来源、已验证的 build；
// - 被动核对的最近结果；
// - 诊断读数（只在这里显示）：请求频率、每个温度与功耗键的原始值（标出占位值）、E 簇附近读数、x2 峰值；
// - 传感器校准按钮与报告。

import SwiftUI
import SysCollectors
import SysModel

struct CPUDiagnosticsSection: View {
    let store: MetricStore
    let services: CPUServices
    let model: CPUDiagnosticsModel

    var body: some View {
        sourcesSection
        topologySection
        passiveSection
        calibrationSection
        readingsSection
    }

    // MARK: - 数据源路径

    private var sourcesSection: some View {
        Section("CPU 数据源") {
            LabeledContent("频率", value: frequencyPath)
            LabeledContent("温度", value: temperaturePath)
            LabeledContent("功耗", value: powerPath)
            LabeledContent("Top N", value: topNPath)
        }
    }

    private var frequencyPath: String {
        let details = services.collectors.frequency?.latestDetails ?? []
        guard !details.isEmpty else { return String(localized: "尚未采样") }
        if details.allSatisfy({ $0.source == .actual }) { return String(localized: "实际频率通道") }
        return String(localized: "部分簇退回请求频率（多核时偏高 7–17%）")
    }

    private var temperaturePath: String {
        guard let resolved = services.collectors.sensors?.profile else {
            return String(localized: "未知芯片：学习中，只显示 CPU 最高温")
        }
        let origin =
            resolved.origin == .bundled ? String(localized: "内置档案") : String(localized: "本机校准生成，可能偏高")
        return resolved.buildVerified ? origin : origin + String(localized: "（当前系统 build 未验证）")
    }

    private var powerPath: String {
        guard let profile = services.collectors.sensors?.profile?.profile, !profile.power.clusterRails.isEmpty else {
            return String(localized: "无专用功耗轨，不可用（不估算）")
        }
        return String(localized: "专用功耗轨（不含 GPU）")
    }

    private var topNPath: String {
        let status = store.engineStatus?.health.first { $0.id == AppSampler.collectorID }?.status
        return status == .unavailable
            ? String(localized: "同 uid 回退（coalition 自检未通过）") : String(localized: "resource coalition")
    }

    // MARK: - 拓扑与档案

    private var topologySection: some View {
        Section("拓扑与芯片档案") {
            if let topology = CPUTopologyService.shared.current {
                LabeledContent("拓扑", value: Self.describe(topology))
                ForEach(topology.evidence, id: \.method) { evidence in
                    LabeledContent(Self.methodName(evidence.method)) {
                        Text(evidence.mapping == nil ? "✗ \(evidence.detail)" : "✓ \(evidence.detail)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            } else {
                Text("拓扑尚未发现")
            }
            if let sensors = services.collectors.sensors {
                LabeledContent("SoC", value: sensors.socID ?? "—")
                if let resolved = sensors.profile {
                    LabeledContent("档案", value: "\(resolved.profile.description)（\(resolved.origin.rawValue)）")
                    LabeledContent("已验证的 build", value: resolved.profile.verifiedBuilds.joined(separator: ", "))
                }
            }
        }
    }

    static func describe(_ topology: CPUTopology) -> String {
        let levels = topology.perfLevels.map { "\(DisplayNames.perfLevel($0.name)) ×\($0.cpuCount)" }.joined(separator: " + ")
        let quality: String =
            switch topology.quality {
            case .ok: String(localized: "三种依据一致")
            case .clustersOnly(let reason): String(localized: "只按簇（\(reason)）")
            case .coresOnly(let reason): String(localized: "只按核（\(reason)）")
            }
        return "\(topology.logicalCPUCount) CPU · \(topology.clusters.count) 簇 · \(levels) · \(quality)"
    }

    static func methodName(_ method: PerfLevelEvidence.Method) -> String {
        switch method {
        case .coreCount: String(localized: "依据：核数")
        case .frequency: String(localized: "依据：DVFS 表顶")
        case .l2Size: String(localized: "依据：L2 大小")
        }
    }

    // MARK: - 被动核对

    private var passiveSection: some View {
        Section("被动核对") {
            if model.findings.isEmpty {
                Text("等待足够的负载（某档忙碌超过 30% 的 10 秒以上区间）")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.findings.keys.sorted(), id: \.self) { key in
                if let f = model.findings[key] {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: f.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(f.passed ? .green : .orange)
                        Text(key).font(.callout.monospaced())
                        Spacer()
                        Text("\(f.detail)（\(f.spanSeconds) s）")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(f.detail)
                    }
                }
            }
        }
    }

    // MARK: - 诊断读数

    private var readingsSection: some View {
        Section("诊断读数") {
            DisclosureGroup("请求频率（只作对照，多核时偏高）") {
                ForEach(services.collectors.frequency?.latestDetails ?? [], id: \.cluster) { detail in
                    LabeledContent(detail.cluster.description) {
                        Text(Self.reading(detail.request)).monospacedDigit()
                    }
                }
            }
            coreFrequencies
            DisclosureGroup("SMC 键原始值（\(services.collectors.sensors?.latestReadings.count ?? 0) 个）") {
                ForEach(services.collectors.sensors?.latestReadings ?? [], id: \.key) { r in
                    HStack {
                        Text(r.key).font(.caption.monospaced()).frame(width: 50, alignment: .leading)
                        Text(Self.roleName(r.role)).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                        Text(r.cluster?.description ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Text(r.raw.map { String(format: "%.2f", $0) } ?? "—")
                            .font(.caption.monospaced())
                            .foregroundStyle(r.valid ? .primary : .tertiary)
                        if !r.valid, r.raw != nil {
                            Text("占位").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
            }
            Text("「E 簇附近」读数受 GPU 与 P 簇影响大，只在这里列出（D33）；x2 峰值组也只在这里显示。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 逐核频率与「每核 tick 忙碌 vs 逐核通道活跃」的相关性核对（被动判据，要求 ≥ 0.99）。
    @ViewBuilder
    private var coreFrequencies: some View {
        let _ = store.engineStatus?.tickCount  // 随 tick 刷新
        let snapshot = services.collectors.cores?.latest
        LabeledContent("逐核核对") {
            if let snapshot {
                if let r = snapshot.correlation {
                    Label(
                        String(format: "相关系数 %.4f", r),
                        systemImage: snapshot.correlationPassed == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(snapshot.correlationPassed == true ? .green : .orange)
                } else {
                    Text("不确定：各核负载差异太小").foregroundStyle(.secondary)
                }
            } else {
                Text("约 4 秒后显示").foregroundStyle(.secondary)
            }
        }
        .help("每核 tick 忙碌比例与逐核频率通道的活跃驻留比例应高度相关（≥ 0.99），用来发现把请求通道误当成实际通道之类的错误")
        DisclosureGroup("逐核频率（\(snapshot?.cores.count ?? 0) 个核）") {
            ForEach(snapshot?.cores ?? [], id: \.cpu) { core in
                HStack {
                    Text("cpu\(core.cpu)").font(.caption.monospaced()).frame(width: 46, alignment: .leading)
                    Text(core.cluster.description).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Text(Self.reading(core.reading)).font(.caption).monospacedDigit()
                    Text(core.busy.map { "忙碌 " + PercentFormat.string(fromRatio: $0) } ?? "—")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .trailing)
                }
            }
        }
    }

    static func reading(_ reading: ClusterFrequencyReading?) -> String {
        switch reading {
        case .active(let hz, _): Formatting.frequency(hz)
        case .idle: String(localized: "空闲")
        case .invalid(let why): "✗ \(why)"
        case nil: "—"
        }
    }

    static func roleName(_ role: SensorKeyReading.Role) -> String {
        switch role {
        case .cluster: String(localized: "簇温度")
        case .peak: String(localized: "峰值 x2")
        case .nearby: String(localized: "E 簇附近")
        case .clusterRail: String(localized: "簇功耗轨")
        case .gpuRail: String(localized: "GPU 轨")
        case .sharedRail: String(localized: "共享轨")
        }
    }

    // MARK: - 校准

    private var calibrationSection: some View {
        Section("传感器校准") {
            HStack {
                Button("传感器校准…", action: model.startCalibration)
                    .disabled(model.isCalibrating)
                Spacer()
            }
            switch model.calibration {
            case .idle:
                Text("让 CPU 各簇轮流满载约 1 分钟，重新找出温度键与功耗轨。有内置档案的芯片只生成核对报告，不覆盖内置档案。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .running(let phase, let started, let total):
                TimelineView(.periodic(from: started, by: 1)) { context in
                    ProgressView(
                        value: min(context.date.timeIntervalSince(started), total), total: total,
                        label: { Text("校准中：\(phase)") })
                }
            case .failed(let message):
                Text("校准失败：\(message)").foregroundStyle(.red)
            case .finished(let report):
                calibrationReport(report)
            }
        }
    }

    @ViewBuilder
    private func calibrationReport(_ report: CPUDiagnosticsModel.CalibrationReport) -> some View {
        LabeledContent("完成于", value: report.date.formatted(date: .omitted, time: .standard))
        ForEach(report.clusterKeyCounts, id: \.cluster) { c in
            LabeledContent(c.cluster, value: String(localized: "温度键 \(c.keys) 个，功耗轨 \(c.rails) 个"))
        }
        if let comparison = report.comparison {
            Label(
                comparison.passed ? "与内置档案一致：温度键全部找回" : "与内置档案不一致，请查看下面的遗漏项",
                systemImage: comparison.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(comparison.passed ? .green : .orange)
            ForEach(comparison.temperatures, id: \.cluster) { t in
                if !t.missing.isEmpty || !t.candidates.isEmpty {
                    Text("\(t.cluster)：缺 \(t.missing.joined(separator: " "))；候选 \(t.candidates.joined(separator: " "))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Text("内置档案保持不变（D37）。多出的候选键多为 die/SoC 传感器，需要人工确认。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let saved = report.savedTo {
            Text("本芯片没有内置档案，校准结果已保存并启用（标注「校准生成，可能偏高」）。")
                .font(.callout)
            PathRow(title: String(localized: "档案文件"), url: saved)
        }
    }
}
