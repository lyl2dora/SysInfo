// 诊断页的内存部分（内存模块设计 §7.4，D49）：
// - 数据路径与核对：host_statistics64 是否按 rev6 使用、陈旧次数、页面队列之和 ÷ 可用内存；
// - 页面与容量：页大小、物理 / 可用内存、引导占用、可执行与共享区页；
// - ECC 与 MTE：只在这里显示，含义未经验证；没有 `vm.mte.*` 的芯片（M4）不出现 MTE 行；
// - DRAM 带宽：默认折叠，展开时才登记 memory.bandwidth 需求（每 2 s），只作相对量。

import SwiftUI
import SysCollectors
import SysModel

struct MemoryDiagnosticsSection: View {
    let store: MetricStore
    let services: AppServices
    let bandwidthVisibilityChanged: (Bool) -> Void

    @State private var bandwidthExpanded = false

    var body: some View {
        let _ = store.engineStatus?.tickCount  // 随 tick 刷新
        sourcesSection
        bandwidthSection
    }

    private var sourcesSection: some View {
        Section("内存数据源") {
            let vm = services.memory.vm
            let health = store.engineStatus?.health.first { $0.id == MemoryCollector.collectorID }
            LabeledContent("数据路径") {
                Text(health?.dataPath ?? MemoryCollector.dataPath)
                    .font(.caption.monospaced())
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("host_statistics64") {
                Text(
                    vm?.usesVMStatistics == false
                        ? String(localized: "不可用：被压缩改用估算，速率不可用")
                        : String(localized: "rev6 · 陈旧读数 \(health?.staleCount ?? 0) 次"))
            }
            LabeledContent("页面队列之和 ÷ 可用内存") {
                Text(vm?.queueSumRatio.map { String(format: "%.4f", $0) } ?? "—")
            }
            let readings = MemoryDiagnosticReadings.read()
            let page = Double(readings.pageSize ?? 0)
            LabeledContent("页大小", value: readings.pageSize.map { "\($0) B" } ?? "—")
            LabeledContent("物理 / 可用内存") {
                Text(
                    "\(readings.physicalBytes.map { Formatting.memory(Double($0)) } ?? "—") / \(readings.usableBytes.map { Formatting.memory(Double($0)) } ?? "—")")
            }
            if let stolen = readings.bootStolenPages {
                LabeledContent("引导占用", value: Formatting.memory(Double(stolen) * page))
            }
            if let executable = readings.executablePages, let shared = readings.sharedRegionPages {
                LabeledContent("可执行映射 / 共享区") {
                    Text("\(Formatting.memory(Double(executable) * page)) / \(Formatting.memory(Double(shared) * page))")
                }
            }
            if let corrected = readings.eccCorrected {
                LabeledContent("ECC 纠错 / 未纠正") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(corrected) / \(readings.eccUncorrected.map(String.init) ?? "—")")
                        Text("vm.vm_ecc_*；计数含义未经验证，仅供观察")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let tagged = readings.mteTaggedPages {
                LabeledContent("MTE 带标签的页") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Formatting.memory(Double(tagged) * page))
                        if let storage = readings.mteTagStoragePages, let free = readings.mteFreeTagStoragePages {
                            Text("标签存储区 \(Formatting.memory(Double(storage) * page))，空闲 \(Formatting.memory(Double(free) * page))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var bandwidthSection: some View {
        Section {
            DisclosureGroup(isExpanded: $bandwidthExpanded) {
                let latest = store.latest
                let group = services.memory.bandwidth?.group
                LabeledContent("IOReport 组", value: group.map { "\($0) / DCS BW" } ?? String(localized: "正在查找……"))
                LabeledContent("读 / 写") {
                    Text(
                        "\(latest[.memoryBandwidthRead]?.value.map(Self.gbs) ?? "—") / \(latest[.memoryBandwidthWrite]?.value.map(Self.gbs) ?? "—")")
                        .monospacedDigit()
                }
                if case .unavailable(let reason)? = latest[.memoryBandwidthRead]?.quality {
                    Text(reason.description).font(.caption).foregroundStyle(.secondary)
                }
            } label: {
                Text("DRAM 带宽（估算）")
            }
            .onChange(of: bandwidthExpanded) { bandwidthVisibilityChanged(bandwidthExpanded) }
            .onDisappear { if bandwidthExpanded { bandwidthVisibilityChanged(false) } }
        } footer: {
            Text("内存控制器的读写直方图按 16 GB/s 分档，取各档中点估算，只作相对量：空闲时也落在约 8 GB/s。展开期间每 2 秒订阅一次 IOReport（D49）。")
        }
    }

    private static func gbs(_ bytesPerSecond: Double) -> String {
        String(format: "%.1f GB/s", bytesPerSecond / 1e9)
    }
}
