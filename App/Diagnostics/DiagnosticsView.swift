// 诊断页（K19，M0 设计 §6，CPU 模块设计 §7.4）：Release 版也保留。
// - CPU 部分放在最前（数据源路径、拓扑与档案、被动核对、校准、诊断读数），见 CPUDiagnosticsSection；
// - 采集器表：状态、数据路径、自检结果、最近一次和平均耗时（墙钟与线程 CPU）；
// - 调度器：tick 数、定时器、有效需求、降频因子与原因；手动降频开关（K20，测试用）；
// - 本进程：CPU 占用（按单核的比例，1 分钟均值）和内存 footprint。

import SwiftUI
import SysCollectors
import SysModel

struct DiagnosticsView: View {
    let store: MetricStore
    @Bindable var throttle: ThrottleMonitor
    let runSelfTests: () -> Void
    let services: CPUServices

    var body: some View {
        Form {
            CPUDiagnosticsSection(store: store, services: services, model: services.diagnostics)
            collectorsSection
            schedulerSection
            selfUsageSection
        }
        .formStyle(.grouped)
    }

    // MARK: - 采集器

    private var collectorsSection: some View {
        Section {
            ForEach(store.engineStatus?.health ?? [], id: \.id) { health in
                CollectorHealthRow(health: health)
            }
            Button("重新自检", action: runSelfTests)
        } header: {
            Text("采集器")
        }
    }

    // MARK: - 调度器

    private var schedulerSection: some View {
        Section {
            if let status = store.engineStatus {
                LabeledContent("tick 数", value: "\(status.tickCount)")
                LabeledContent("上次 tick") {
                    Text(status.lastTick.map(Self.tickTime) ?? String(localized: "尚未采样"))
                }
                LabeledContent("定时器") {
                    if let next = status.nextTick {
                        Text("运行中，下次 \(Self.tickTime(next))")
                    } else {
                        Text("已停止（没有生效的需求，不再唤醒）")
                    }
                }
                if let cost = store.lastTickCost {
                    LabeledContent("最近一个 tick 耗时") {
                        Text("墙钟 \(Formatting.milliseconds(cost.wallNanos))，CPU \(Formatting.milliseconds(cost.cpuNanos))")
                    }
                }
                LabeledContent("降频") {
                    Text(throttleDescription(status))
                }
                LabeledContent("有效需求") {
                    VStack(alignment: .trailing, spacing: 2) {
                        if status.demands.isEmpty {
                            Text("无")
                        }
                        ForEach(status.demands, id: \.id) { registered in
                            Text(demandDescription(registered))
                                .foregroundStyle(registered.isActive ? .primary : .secondary)
                        }
                    }
                }
            } else {
                Text("调度器尚未就绪")
            }
            Toggle("手动降频（测试用）", isOn: $throttle.manual)
        } header: {
            Text("调度器")
        }
    }

    private func throttleDescription(_ status: EngineStatus) -> String {
        let factor = DisplayNames.throttleFactor(status.throttle)
        guard !status.throttleReasons.isEmpty else { return factor }
        let reasons = status.throttleReasons.sorted().map(DisplayNames.throttleReason).joined(separator: "、")
        return "\(factor)（\(reasons)）"
    }

    private func demandDescription(_ registered: RegisteredDemand) -> String {
        let source = DisplayNames.demandSource(registered.demand.source)
        let collectors = registered.demand.collectors.sorted().map(DisplayNames.collector).joined(separator: "、")
        if let interval = registered.effectiveInterval {
            return String(localized: "\(source)：\(collectors)，每 \(interval) 秒")
        }
        return String(localized: "\(source)：\(collectors)，已暂停")
    }

    // MARK: - 本进程

    private var selfUsageSection: some View {
        Section {
            LabeledContent("CPU（1 分钟均值，按单核）") {
                Text(store.mean(.appSelfCPU, seconds: 60).map { PercentFormat.string(fromRatio: $0, fractionDigits: 2) }
                    ?? String(localized: "采样中…"))
            }
            LabeledContent("内存 footprint") {
                Text(store.latest[.appSelfFootprint]?.value.map(Formatting.memory) ?? String(localized: "采样中…"))
            }
        } header: {
            Text("本进程")
        } footer: {
            Text("诊断页打开期间才采样本进程开销；刚打开时 1 分钟均值还不完整。")
        }
    }

    private static func tickTime(_ tick: Int64) -> String {
        Formatting.time(Date(timeIntervalSince1970: TimeInterval(tick)))
    }
}

private struct CollectorHealthRow: View {
    let health: CollectorHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(DisplayNames.collector(health.id))
                    .font(.headline)
                Text(health.id.rawValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(DisplayNames.status(health.status))
                    .foregroundStyle(statusColor)
            }
            Text(health.dataPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            costLine
            if let selfTest = health.selfTest {
                ForEach(selfTest.checks, id: \.name) { check in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        checkIcon(check)
                        Text(DisplayNames.selfTestCheck(check.name))
                        Spacer()
                        Text(check.detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(check.detail)
                    }
                    .font(.callout)
                }
            } else {
                Text("尚未自检")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var costLine: some View {
        if let last = health.lastCost, let average = health.averageCost {
            Text(
                "最近 \(Formatting.milliseconds(last.wallNanos))（CPU \(Formatting.milliseconds(last.cpuNanos))）· 平均 \(Formatting.milliseconds(average.wallNanos))（CPU \(Formatting.milliseconds(average.cpuNanos))）· 采样 \(health.sampleCount) 次 · 陈旧 \(health.staleCount) 次\(health.skippedBusyCount > 0 ? " · 忙碌跳过 \(health.skippedBusyCount) 次" : "")"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Text("尚未采样")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 通过：绿色对勾；提示项没通过（照常出数，状态降级）：橙色三角；必需项没通过（数据源不可用）：红色。
    @ViewBuilder
    private func checkIcon(_ check: SelfTestCheck) -> some View {
        if check.passed {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
        } else if check.severity == .advisory {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
                .help(String(localized: "提示项未通过：数据源照常使用，状态降级"))
        } else {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(Color.red)
                .help(String(localized: "必需项未通过：数据源不可用"))
        }
    }

    private var statusColor: Color {
        switch health.status {
        case .ok: .green
        case .degraded: .orange
        case .unavailable: .red
        }
    }
}
