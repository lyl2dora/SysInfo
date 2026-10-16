// 诊断页的存储部分（存储模块设计 §6.4，D54、D55）：
// - 每块物理盘：BSD 名、接口、SMART 连接状态与最近一次读取的 CPU 耗时、驱动累计的错误与重试；
// - RAID 组与容量组（含辅助组）；SMART 焦点盘的当前状态；
// - NVMe 节流计数：默认折叠，展开时每 2 s 在后台读一次私有 IOReport「NVMe」组，含义未经验证（D54）。

import SwiftUI
import SysCollectors
import SysModel

struct StorageDiagnosticsSection: View {
    let store: MetricStore
    let services: AppServices

    @State private var throttleExpanded = false
    @State private var throttle = NVMeThrottleModel()

    var body: some View {
        let _ = store.engineStatus?.tickCount  // 随 tick 刷新
        disksSection
        groupsSection
        throttleSection
    }

    private var disksSection: some View {
        Section("存储数据源") {
            let inventory = services.storageModel.inventory
            let statuses = services.storage.smart?.statuses ?? [:]
            let counters = services.storage.io?.latestCounters ?? [:]
            LabeledContent("物理盘清单") {
                Text("\(inventory.disks.count) 块盘 · \(inventory.raidSets.count) 个 RAID 组 · 第 \(inventory.generation) 代")
            }
            ForEach(inventory.disks) { disk in
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Self.smartStatus(statuses[disk.key], capable: disk.smartCapable))
                        if let c = counters[disk.key] {
                            Text("错误 读 \(c.readErrors) / 写 \(c.writeErrors) · 重试 读 \(c.readRetries) / 写 \(c.writeRetries)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    Text("\(disk.bsdName ?? "?") · \(StorageText.diskName(disk, inventory: inventory))")
                    Text("\(StorageText.location(disk.location)) · \(disk.interconnect) · 键 \(disk.key.rawValue)")
                }
            }
            LabeledContent("SMART 读取范围") {
                Text(
                    services.storageModel.panelVisible || services.storageModel.diagnosticsVisible
                        ? String(localized: "全部盘（面板或诊断页打开）")
                        : services.storageModel.widgetFocus.map {
                            $0.isEmpty ? String(localized: "只给历史（每分钟一次）") : String(localized: "盘温 widget 绑定的 \($0.count) 块盘，其余每分钟一次")
                        } ?? String(localized: "全部盘（所有盘最高温）"))
            }
            Text("盘的键是本地加盐哈希，不含序列号；只在本机历史库里用来认出同一块盘（D54）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var groupsSection: some View {
        Section("RAID 与容量组") {
            let model = services.storageModel
            ForEach(model.inventory.raidSets) { set in
                LabeledContent("RAID「\(set.name)」") {
                    Text("\(StorageText.raidSummary(set)) · \(set.bsdName ?? "—")")
                }
            }
            ForEach(model.groups) { group in
                LabeledContent {
                    Text("\(Formatting.diskBytes(Double(group.usedBytes))) / \(Formatting.diskBytes(Double(group.totalBytes)))")
                        .monospacedDigit()
                } label: {
                    Text("\(group.name) · \(group.fileSystem)")
                    Text(
                        [
                            group.isBoot ? String(localized: "启动") : nil, group.isAuxiliary ? String(localized: "辅助组（不进标题与历史）") : nil,
                            String(localized: "\(group.volumes.count) 个卷"),
                        ].compactMap { $0 }.joined(separator: " · "))
                }
            }
        }
    }

    private var throttleSection: some View {
        Section {
            DisclosureGroup(isExpanded: $throttleExpanded) {
                if let readings = throttle.readings {
                    let inventory = services.storageModel.inventory
                    ForEach(Array(readings.enumerated()), id: \.offset) { _, reading in
                        LabeledContent {
                            Text(reading.delta.map { "\(reading.value)（+\($0)）" } ?? "\(reading.value)")
                                .monospacedDigit()
                        } label: {
                            Text(reading.channel)
                            Text(
                                "\(reading.disk.flatMap { inventory.disk($0) }.map { "\($0.bsdName ?? "?") · " } ?? "")\(reading.driver) · \(reading.subgroup)")
                        }
                    }
                } else {
                    Text(throttle.isReading ? String(localized: "读取中…") : String(localized: "IOReport 不可用或没有 NVMe 组"))
                        .foregroundStyle(.secondary)
                }
            } label: {
                Text("NVMe 节流计数（未验证）")
            }
            .onChange(of: throttleExpanded) { throttle.setActive(throttleExpanded) }
            .onDisappear { throttle.setActive(false) }
        } footer: {
            Text("IOReport「NVMe」组的 BW Scale Factor（绝对值，小于 100 疑为节流）与加权节流时间（括号里是 2 秒内的增量）。外置盘上节流时间等于总时长，含义未经验证，只作观察（D54）。")
        }
    }

    private static func smartStatus(_ status: DiskSMARTStatus?, capable: Bool) -> String {
        guard capable else { return String(localized: "不支持 NVMe SMART") }
        guard let status else { return String(localized: "尚未读取") }
        switch status.state {
        case .ok:
            let cost = status.lastCPUNanos.map(Formatting.milliseconds) ?? "—"
            return String(localized: "SMART 正常 · 上次 \(cost) CPU")
        case .notSupported: return String(localized: "不支持 NVMe SMART")
        case .openFailed(let code): return String(localized: "打开失败 0x\(String(UInt32(bitPattern: code), radix: 16))")
        case .busy(let count): return String(localized: "被其他程序占用（连续 \(count) 次），稍后重试")
        case .readFailed(let code): return String(localized: "读取失败 0x\(String(UInt32(bitPattern: code), radix: 16))")
        case .implausible(let detail): return String(localized: "读数不合理：\(detail)")
        }
    }
}

/// 诊断页展开节流计数时，每 2 s 在后台读一次（不占 MainActor，D03）。
@Observable
final class NVMeThrottleModel {
    private(set) var readings: [NVMeThrottleReading]?
    private(set) var isReading = false
    @ObservationIgnored private let reader = NVMeThrottleReader()
    @ObservationIgnored private var task: Task<Void, Never>?

    func setActive(_ active: Bool) {
        task?.cancel()
        task = nil
        guard active else { return }
        isReading = true
        let reader = reader
        task = Task { [weak self] in
            while !Task.isCancelled {
                let readings = await Task.detached(priority: .utility) { reader.read() }.value
                guard let self, !Task.isCancelled else { return }
                self.readings = readings
                self.isReading = false
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
