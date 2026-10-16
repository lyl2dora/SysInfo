// 诊断页的 GPU 与加速器部分（GPU 模块设计 §8，D57 G10、D58）：
// - 数据源：GPUPH 与档位表（来源、各档频率）、各档驻留与平均档位、温度键与读数、ANE 节点、媒体中断设备与底数；
// - ANE 估算对账：coalition 槽位 39 积分 ÷ PMGR ANE 批次（范围 0.8–1.05，连续两次失败时隐藏估算值）；
// - GPU 细节：默认折叠，展开时才登记 gpu.diagnostics 需求（每 2 s）：PWRCTRL 原因码、节流驻留、PMP 带宽、
//   ANE 中断、Device Utilization % 原值（不可靠，仅供对照）。

import SwiftUI
import SysCollectors
import SysModel

struct GPUDiagnosticsSection: View {
    let store: MetricStore
    let services: AppServices
    let detailsVisibilityChanged: (Bool) -> Void

    @State private var detailsExpanded = false

    var body: some View {
        let _ = store.engineStatus?.tickCount  // 随 tick 刷新
        sourcesSection
        detailsSection
    }

    private var sourcesSection: some View {
        Section("GPU 与加速器数据源") {
            let gpu = services.power.gpu
            LabeledContent("活跃与频率") {
                Text(gpu?.hasResidency == true ? "GPU Stats / GPUPH" : String(localized: "不可用（没有 GPUPH）"))
                    .font(.caption.monospaced())
            }
            LabeledContent("档位表") {
                VStack(alignment: .trailing, spacing: 2) {
                    if let table = gpu?.frequencyTable {
                        Text("voltage-states\(table.key)-sram · \(table.fromProfile ? String(localized: "芯片档案") : String(localized: "推断"))")
                        Text(table.frequencies.enumerated().map { "P\($0.offset + 1) \(Int($0.element / 1e6))" }.joined(separator: " "))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    } else {
                        Text(gpu?.tableProblem ?? "—")
                    }
                }
            }
            if let residency = gpu?.latestResidency {
                LabeledContent("各档驻留") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(
                            residency.states.filter { $0.share >= 0.005 }
                                .map { "\($0.name) \(PercentFormat.string(fromRatio: $0.share))" }.joined(separator: "  "))
                            .font(.caption.monospaced())
                        Text("平均档位 \(residency.averageState.map { String(format: "%.1f", $0) } ?? "—")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let temperature = services.gpu.temperature {
                let keys = temperature.keys
                let readings = temperature.latestReadings
                LabeledContent("温度键") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Self.source(keys.source))
                        Text(keys.names.map { name in "\(name) \(readings[name].map { String(format: "%.1f", $0) } ?? "—")" }.joined(separator: "  "))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                        if case .profile(let note?) = keys.source {
                            Text(note).font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            if let accelerators = services.gpu.accelerators {
                let nodes = accelerators.nodes
                LabeledContent("ANE 节点") {
                    Text(
                        "\(nodes.ane ?? "—")\(nodes.aneBehindExclave ? String(localized: "（在 Exclave 后面，中断统计读不到）") : "") · GPU \(nodes.accelerator ?? "—")")
                }
            }
            if let media = services.gpu.media {
                let d = media.diagnostics
                LabeledContent("媒体引擎中断") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(d.devices.joined(separator: " "))
                        let rows = [
                            (MetricID.mediaEncodeRate, String(localized: "编码")), (.mediaDecodeRate, String(localized: "解码")),
                            (.mediaProResRate, "ProRes"),
                        ]
                        Text(
                            rows.map { id, title in
                                "\(title) \(String(format: "%.0f", d.raw[id] ?? 0)) − 底数 \(String(format: "%.0f", d.baselines[id] ?? 0))"
                            }.joined(separator: "  ")
                        )
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    }
                }
            }
            if let check = services.power.ledger?.checks.first(where: { $0.name == "ane" }) {
                LabeledContent("ANE 估算 ÷ PMGR ANE") {
                    Text(PowerDiagnosticsSection.checkText(check))
                        .foregroundStyle(check.verdict == .failed ? .red : .secondary)
                }
            }
        }
    }

    private var detailsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $detailsExpanded) {
                let r = services.gpu.details?.readings
                LabeledContent("功率控制原因") {
                    Text(
                        r.map { $0.powerControl.map { "\($0.name) \(PercentFormat.string(fromRatio: $0.value))" }.joined(separator: "  ") }
                            ?? "—")
                }
                LabeledContent("热限制 / 功率区驻留") {
                    Text(
                        "\(r?.thermalLimited.map { PercentFormat.string(fromRatio: $0) } ?? "—") / \(r?.powerZoned.map { PercentFormat.string(fromRatio: $0) } ?? "—")")
                }
                LabeledContent("带宽（\(r?.bandwidthGroup ?? "PMP") / AF BW，相对量）") {
                    Text(
                        r.map { $0.bandwidth.map { "\($0.name) \(String(format: "%.1f", $0.value / 1e9)) GB/s" }.joined(separator: "  ") }
                            ?? "—")
                        .monospacedDigit()
                }
                LabeledContent("ANE 中断") {
                    Text(
                        r?.aneInterruptsMissing == true
                            ? String(localized: "读不到") : r?.aneInterrupts.map { String(format: "%.0f 次/秒", $0) } ?? "—")
                }
                LabeledContent("Device Utilization %") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(r?.deviceUtilization.map { String(format: "%.0f", $0) } ?? "—")
                        Text("不可靠，仅供对照：多个读取者互相影响，随提交方式乱跳（D57）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } label: {
                Text("GPU 细节")
            }
            .onChange(of: detailsExpanded) { detailsVisibilityChanged(detailsExpanded) }
            .onDisappear { if detailsExpanded { detailsVisibilityChanged(false) } }
        } footer: {
            Text("节流类指标的语义按通道名推断，两台目标机在压测中都没有触发过。展开期间每 2 秒订阅一次（带宽一次 4–8 ms）。")
        }
    }

    private static func source(_ source: GPUTemperatureCollector.KeySource) -> String {
        switch source {
        case .profile: String(localized: "芯片档案")
        case .allKeys: String(localized: "未知芯片：读全部 Tg 键")
        case .none: String(localized: "无")
        }
    }
}
