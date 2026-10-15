// 诊断页的功耗与散热部分（功耗与散热模块设计 §7.4，D44–D46）：
// - 数据源与键：整机 / SoC / DRAM 键来自档案还是默认；GPU 通道；最热点来源（M4 的旧值说明）；风扇模式键；PMGR 部件；
// - 原始功率键（PHPC 等只在这里显示）；
// - 遥测对账：最近的 60 s 段，PDTR 积分与累加器均值，漏记的段标出（D46）；
// - PMGR 最近一批与交叉核对（D44 §7）；
// - 传感器目录：默认折叠，展开时才登记 sensors.catalog 需求（D44 PT6）。

import SwiftUI
import SysCollectors
import SysModel

struct PowerDiagnosticsSection: View {
    let store: MetricStore
    let services: AppServices
    let catalogVisibilityChanged: (Bool) -> Void

    @State private var catalogExpanded = false
    @State private var catalogFilter: CatalogFilter = .grouped

    enum CatalogFilter: String, CaseIterable, Identifiable {
        case grouped, valid, placeholder, constant, nonTemperature, all
        var id: String { rawValue }

        var title: String {
            switch self {
            case .grouped: String(localized: "已验证分组")
            case .valid: String(localized: "有效")
            case .placeholder: String(localized: "占位")
            case .constant: String(localized: "恒定")
            case .nonTemperature: String(localized: "非温度")
            case .all: String(localized: "全部")
            }
        }
    }

    var body: some View {
        let _ = store.engineStatus?.tickCount  // 随 tick 刷新
        sourcesSection
        telemetrySection
        pmgrSection
        catalogSection
    }

    private var power: PowerCollectors { services.power }

    // MARK: - 数据源

    private var sourcesSection: some View {
        Section("功耗与散热数据源") {
            let keys = power.sensors?.keys
            let origin = keys?.fromProfile == true ? String(localized: "芯片档案") : String(localized: "默认键（推断）")
            LabeledContent("整机功率", value: power.rail?.key.map { "\($0) · \(origin)" } ?? String(localized: "不可用"))
            LabeledContent(
                "SoC / DRAM",
                value: "\(keys?.soc ?? "—") / \(keys?.dram ?? "—") · \(origin)")
            LabeledContent("GPU", value: power.gpu?.channel ?? String(localized: "不可用"))
            LabeledContent("最热点") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(hotspotText)
                    if case .profile(_, let note?)? = power.sensors?.hotspotSource {
                        Text(note).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
            }
            LabeledContent("风扇") {
                Text(
                    power.sensors.map { s in
                        s.fans.isEmpty
                            ? String(localized: "无风扇")
                            : s.fans.map { "\($0.actual)（模式键 \($0.mode ?? "—")）" }.joined(separator: "、")
                    } ?? "—")
            }
            LabeledContent("PMGR 部件", value: power.pmgr?.components.joined(separator: " ") ?? "—")
            let readings = power.sensors?.diagnosticReadings ?? []
            if !readings.isEmpty {
                LabeledContent("原始功率键") {
                    Text(readings.map { "\($0.key) \($0.value.map { String(format: "%.2f", $0) } ?? "?")" }.joined(separator: "  "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var hotspotText: String {
        switch power.sensors?.hotspotSource {
        case .profile(let key, _): String(localized: "\(key)（芯片档案）")
        case .learned(let key): String(localized: "\(key)（运行时检测）")
        case .learning(let n): String(localized: "学习中（已观察 \(n) 次）")
        case .unavailable, nil: String(localized: "不可用")
        }
    }

    // MARK: - 遥测对账

    private var telemetrySection: some View {
        Section {
            let segments = power.ledger?.telemetrySegments ?? []
            if segments.isEmpty {
                Text("约 1–2 分钟后显示（遥测每 60 秒发布一次）").foregroundStyle(.secondary)
            } else {
                let dropped = segments.filter(\.isDropped).count
                let deviations = segments.compactMap(\.deviation)
                LabeledContent("最近 \(segments.count) 段") {
                    Text(
                        String(
                            localized:
                                "漏记 \(dropped) 段；其余偏差中位数 \(deviations.isEmpty ? "—" : String(format: "%+.1f%%", Self.median(deviations) * 100))"))
                }
                ForEach(segments.suffix(8).reversed(), id: \.end) { segment in
                    HStack {
                        Text(Formatting.time(segment.end)).monospacedDigit()
                        Spacer()
                        Text(
                            "遥测 \(Formatting.watts(segment.telemetryWatts)) · PDTR \(segment.integratedWatts.map(Formatting.watts) ?? "—") · 计数 \(segment.countDelta)"
                        )
                        .monospacedDigit()
                        Text(segment.isDropped ? String(localized: "漏记") : segment.deviation.map { String(format: "%+.1f%%", $0 * 100) } ?? "—")
                            .foregroundStyle(segment.isDropped ? .red : .secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                    .font(.caption)
                }
            }
        } header: {
            Text("遥测对账")
        } footer: {
            Text("PowerTelemetryData 累加器在满载时会整分钟漏记，所以能耗按 PDTR 每秒积分，累加器只用来补 SysInfo 没运行的时段（D46）。")
        }
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    // MARK: - PMGR 与交叉核对

    private var pmgrSection: some View {
        Section("PMGR 批次与交叉核对") {
            if let batch = power.pmgr?.latestBatch {
                LabeledContent("最近一批") {
                    Text("\(Formatting.time(batch.start))–\(Formatting.time(batch.end))（\(Int(batch.seconds)) s）")
                }
                Text(
                    batch.joules.sorted { $0.value > $1.value }
                        .map { "\($0.key) \(String(format: "%.1f", $0.value)) J" }.joined(separator: "  ")
                        + (batch.agxJoules.map { "  agx \(String(format: "%.1f", $0)) J" } ?? "")
                )
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            } else {
                Text("还没有完整批次：开机后约每 30 分钟一次，第一次变化只建立基线。").foregroundStyle(.secondary)
            }
            ForEach(power.ledger?.checks ?? [], id: \.name) { check in
                LabeledContent(check.name == "dram" ? "PZD1 ÷ PMGR DRAM" : "AGX ÷ PMGR GPU") {
                    Text(checkText(check))
                        .foregroundStyle(check.verdict == .failed ? .red : .secondary)
                }
            }
        }
    }

    private func checkText(_ check: CrossCheckResult) -> String {
        let range = String(format: "%.2f–%.2f", check.range.lowerBound, check.range.upperBound)
        switch check.verdict {
        case .pending: return String(localized: "等待批次（允许 \(range)）")
        case .inconclusive: return String(localized: "覆盖不足，这次不下结论")
        case .passed: return String(localized: "\(String(format: "%.3f", check.ratio ?? 0)) ✓（\(range)）")
        case .failed:
            let disabled = check.consecutiveFailures >= 2 ? String(localized: "，对应指标已停用") : ""
            return String(localized: "\(String(format: "%.3f", check.ratio ?? 0)) ✗ 连续 \(check.consecutiveFailures) 次\(disabled)")
        }
    }

    // MARK: - 传感器目录

    private var catalogSection: some View {
        Section {
            DisclosureGroup(isExpanded: $catalogExpanded) {
                let entries = power.catalog?.entries ?? []
                if entries.isEmpty {
                    Text("正在读取……").foregroundStyle(.secondary)
                } else {
                    Picker("显示", selection: $catalogFilter) {
                        ForEach(CatalogFilter.allCases) { Text($0.title).tag($0) }
                    }
                    let counts = Dictionary(grouping: entries, by: \.quality).mapValues(\.count)
                    Text(
                        "\(entries.count) 个键：有效 \(counts[.valid] ?? 0) · 占位 \(counts[.placeholder] ?? 0) · 恒定 \(counts[.constant] ?? 0) · 非温度 \(counts[.nonTemperature] ?? 0)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(filtered(entries)) { entry in
                        HStack {
                            Text(entry.key).font(.caption.monospaced())
                            if let group = entry.group {
                                Text(Self.groupName(group)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(entry.value.map { String(format: "%.2f", $0) } ?? "—").font(.caption.monospaced())
                            Text(Self.qualityName(entry.quality))
                                .font(.caption2)
                                .foregroundStyle(entry.quality == .valid ? .secondary : .tertiary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            } label: {
                Text("传感器目录")
            }
            .onChange(of: catalogExpanded) { catalogVisibilityChanged(catalogExpanded) }
            .onDisappear { if catalogExpanded { catalogVisibilityChanged(false) } }
        } footer: {
            Text("SMC 的全部数值键。只有经过负载验证的分组才有名字，其余显示原始键名，不按键名猜含义（D44）。展开期间每 5 秒刷新一次。")
        }
    }

    private func filtered(_ entries: [SensorCatalogEntry]) -> [SensorCatalogEntry] {
        switch catalogFilter {
        case .grouped: entries.filter { $0.group != nil }
        case .valid: entries.filter { $0.quality == .valid }
        case .placeholder: entries.filter { $0.quality == .placeholder }
        case .constant: entries.filter { $0.quality == .constant }
        case .nonTemperature: entries.filter { $0.quality == .nonTemperature }
        case .all: entries
        }
    }

    static func groupName(_ group: String) -> String {
        if group.hasPrefix("cpu.") { return String(localized: "CPU 簇 \(group.dropFirst(4))") }
        switch group {
        case "hotspot": return String(localized: "最热点")
        case "gpu": return String(localized: "随 GPU 变化")
        case "ane": return String(localized: "随 ANE 变化")
        default: return group
        }
    }

    static func qualityName(_ quality: SensorCatalogEntry.Quality) -> String {
        switch quality {
        case .valid: String(localized: "有效")
        case .placeholder: String(localized: "占位")
        case .constant: String(localized: "恒定")
        case .nonTemperature: String(localized: "非温度")
        case .unreadable: String(localized: "读失败")
        }
    }
}
