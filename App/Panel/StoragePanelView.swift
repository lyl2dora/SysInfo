// 面板的「存储」tab（存储模块设计 §6.2，D54）。
//
// 两级：
// - 概览页：按「内置 / RAID ‹名称›（每个阵列一组）/ 外置」分组；RAID 组可以折叠（默认展开，状态记住）；
//   每块盘一行（名称与「温度 · 寿命」或异常项；读写速率与最近 60 s 的小曲线），点击进入详情页；
//   容量挂在它的归属上：RAID 组标题，或拥有容量组的那块盘；盘多时盘列表放进限高滚动区；最下面是按磁盘 IO 的 Top N；
// - 单盘详情页：读写历史图、IO 统计、SMART 全部字段、身份信息、卷构成；左上角返回。
//
// 每秒都在变的部分用 AppKit 自绘（同 LiveViews.swift），SwiftUI 只放外框；结构（几块盘、几个组）读 StorageModel。

import AppKit
import SwiftUI
import SysCollectors
import SysModel

struct StoragePanelView: View {
    let store: MetricStore
    let services: AppServices
    @Bindable var settings: AppSettings
    @Bindable var state: PanelState

    var body: some View {
        let model = services.storageModel
        if let key = state.storageDetail, let disk = model.inventory.disk(key) {
            StorageDetailView(store: store, services: services, settings: settings, disk: disk, back: { state.storageDetail = nil })
        } else {
            StorageOverviewView(store: store, services: services, settings: settings, open: { state.storageDetail = $0 })
        }
    }
}

// MARK: - 概览页

private struct StorageOverviewView: View {
    let store: MetricStore
    let services: AppServices
    @Bindable var settings: AppSettings
    let open: (DiskKey) -> Void
    @Environment(\.panelLayoutChanged) private var layoutChanged

    /// 盘列表超过这么多块时放进限高滚动区（存储模块设计 §6.2）。
    static let scrollThreshold = 7

    var body: some View {
        let model = services.storageModel
        let inventory = model.inventory
        let internalDisks = inventory.disks.filter { $0.location == .internal && $0.raid == nil }
        let externalDisks = inventory.disks.filter { $0.location == .external && $0.raid == nil }
        VStack(alignment: .leading, spacing: 10) {
            if inventory.disks.isEmpty {
                PanelCard {
                    Text("正在查找物理盘…").font(.caption).foregroundStyle(.secondary)
                }
            } else if inventory.disks.count > Self.scrollThreshold {
                ScrollView {
                    sections(inventory: inventory, internalDisks: internalDisks, externalDisks: externalDisks)
                }
                .frame(height: CGFloat(Self.scrollThreshold) * (DiskRowDrawView.height + 8) + 60)
            } else {
                sections(inventory: inventory, internalDisks: internalDisks, externalDisks: externalDisks)
            }
            if settings.storageTopNRows > 0 {
                PanelCard {
                    TopNSection(model: services.diskTopN, grouping: settings.storageGrouping, slots: settings.storageTopNRows)
                }
            }
        }
        .onChange(of: layoutSignature) { layoutChanged() }
    }

    /// 影响高度的结构：盘与组的个数、折叠状态。
    private var layoutSignature: [String] {
        let model = services.storageModel
        return model.inventory.disks.map(\.key.rawValue) + model.groups.map(\.key.rawValue)
            + settings.storageCollapsedRAIDs.sorted()
    }

    @ViewBuilder
    private func sections(inventory: StorageInventory, internalDisks: [PhysicalDisk], externalDisks: [PhysicalDisk]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !internalDisks.isEmpty {
                PanelCard {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionTitle(text: String(localized: "内置"))
                        ForEach(internalDisks) { disk in row(disk, inventory: inventory) }
                    }
                }
            }
            ForEach(inventory.raidSets) { set in
                let collapsed = settings.storageCollapsedRAIDs.contains(set.key.rawValue)
                PanelCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            if collapsed {
                                settings.storageCollapsedRAIDs.remove(set.key.rawValue)
                            } else {
                                settings.storageCollapsedRAIDs.insert(set.key.rawValue)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                                    .font(.caption2.weight(.semibold))
                                    .frame(width: 10)
                                SectionTitle(text: String(localized: "RAID「\(set.name)」"))
                                Text(StorageText.raidSummary(set)).font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                if !set.isOnline {
                                    StatusBadge(text: StorageText.raidStatus(set.status), color: .red)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(collapsed ? Text("展开 RAID「\(set.name)」") : Text("收起 RAID「\(set.name)」"))
                        LiveView(make: { CapacityDrawView(store: store, services: services, owner: .raid(set.key)) })
                            .frame(height: CapacityDrawView.height)
                        if !collapsed {
                            let members = set.members.compactMap { inventory.disk($0) }
                                .sorted { ($0.raid?.index ?? .max) < ($1.raid?.index ?? .max) }
                            ForEach(members) { disk in row(disk, inventory: inventory) }
                        }
                    }
                }
            }
            if !externalDisks.isEmpty {
                PanelCard {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionTitle(text: String(localized: "外置"))
                        ForEach(externalDisks) { disk in row(disk, inventory: inventory) }
                    }
                }
            }
        }
    }

    private func row(_ disk: PhysicalDisk, inventory: StorageInventory) -> some View {
        let ownsCapacity = services.storageModel.groups.contains { $0.owner == .disk(disk.key) && !$0.isAuxiliary }
        return Button {
            open(disk.key)
        } label: {
            HStack(spacing: 4) {
                LiveView(make: { DiskRowDrawView(store: store, services: services, disk: disk) }) { view in
                    view.disk = disk
                    view.showsCapacity = ownsCapacity
                }
                .frame(height: DiskRowDrawView.height + (ownsCapacity ? CapacityDrawView.height + 2 : 0))
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(StorageText.diskName(disk, inventory: inventory)))
        .help("查看这块盘的 SMART 与读写详情")
    }
}

private struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.weight(.semibold))
    }
}

private struct StatusBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.22), in: .capsule)
    }
}

// MARK: - 文案

enum StorageText {
    /// 盘的显示名：RAID 成员为「成员 n · 型号」，其余为型号。
    static func diskName(_ disk: PhysicalDisk, inventory: StorageInventory) -> String {
        if let raid = disk.raid {
            let index = raid.index.map { "\($0 + 1)" } ?? "?"
            return String(localized: "成员 \(index) · \(disk.model)")
        }
        return disk.model
    }

    static func location(_ location: DiskLocation) -> String {
        switch location {
        case .internal: String(localized: "内置")
        case .external: String(localized: "外置")
        }
    }

    /// RAID 级别：常见的几种本地化，其余原样。
    static func raidLevel(_ level: String) -> String {
        switch level {
        case "Stripe": String(localized: "条带（RAID 0）")
        case "Mirror": String(localized: "镜像（RAID 1）")
        case "Concat": String(localized: "串联")
        default: level
        }
    }

    static func raidStatus(_ status: String) -> String {
        switch status {
        case "Online": String(localized: "在线")
        case "Degraded": String(localized: "降级")
        case "Offline": String(localized: "离线")
        case "Rebuilding": String(localized: "重建中")
        case "Failed": String(localized: "失败")
        case "": String(localized: "未知")
        default: status
        }
    }

    static func raidSummary(_ set: RAIDSet) -> String {
        "\(raidLevel(set.level)) · \(raidStatus(set.status)) · \(set.members.count) " + String(localized: "块盘")
    }

    /// 健康问题的简短说明（概览行右侧、详情页健康节）。
    static func issue(_ issue: SMARTHealthIssue) -> String {
        switch issue {
        case .criticalWarning(let warning): String(localized: "严重警告 0x\(String(warning.rawValue, radix: 16))")
        case .spareBelowThreshold: String(localized: "备用块低于阈值")
        case .mediaErrors(let count): String(localized: "介质错误 \(Formatting.count(count))")
        }
    }

    /// critical warning 各位的说明。
    static func warningBits(_ warning: NVMeCriticalWarning) -> String {
        if warning.isEmpty { return String(localized: "无") }
        var parts: [String] = []
        if warning.contains(.spareBelowThreshold) { parts.append(String(localized: "备用块不足")) }
        if warning.contains(.temperature) { parts.append(String(localized: "温度越限")) }
        if warning.contains(.reliabilityDegraded) { parts.append(String(localized: "可靠性下降")) }
        if warning.contains(.readOnly) { parts.append(String(localized: "已转为只读")) }
        if warning.contains(.volatileBackupFailed) { parts.append(String(localized: "掉电保护失效")) }
        if warning.contains(.persistentMemoryRegion) { parts.append(String(localized: "持久内存区异常")) }
        return parts.joined(separator: "、")
    }

    /// APFS 卷角色。
    static func role(_ role: String?) -> String? {
        switch role {
        case nil: nil
        case "System": String(localized: "系统")
        case "Data": String(localized: "数据")
        case "VM": String(localized: "虚拟内存")
        case "Preboot": String(localized: "预启动")
        case "Recovery": String(localized: "恢复")
        case "Update": String(localized: "更新")
        case "User": String(localized: "用户")
        case "Installer": String(localized: "安装器")
        case "Backup": String(localized: "备份")
        case "Hardware": String(localized: "硬件")
        case "xART": String(localized: "xART")
        default: role
        }
    }
}

// MARK: - 概览的盘行

/// 一块盘的两行（可选第三行容量条）：名称与「温度 · 寿命」或异常项；读写速率与最近 60 s 小曲线。
final class DiskRowDrawView: LiveDrawView {
    static let height: CGFloat = 32
    static let sparklineSeconds: Double = 60

    private let services: AppServices
    var disk: PhysicalDisk {
        didSet { needsDisplay = true }
    }
    var showsCapacity = false {
        didSet { needsDisplay = true }
    }

    init(store: MetricStore, services: AppServices, disk: PhysicalDisk) {
        self.services = services
        self.disk = disk
        super.init(store: store)
    }

    override func draw(_ dirtyRect: NSRect) {
        countDraw()
        let latest = store.latest
        let key = disk.key
        let inventory = services.storageModel.inventory
        let name = StorageText.diskName(disk, inventory: inventory)
        Self.draw(Self.text(name, Self.caption), x: 0, y: 0)

        // 右侧：异常项（橙 / 红）或「温度 · 寿命」。
        let record = services.storage.smart?.latestRecords[key]
        let issues = record?.healthIssues ?? []
        let memberOffline = disk.raid.map { !$0.isOnline } ?? false
        if memberOffline, let raid = disk.raid {
            Self.drawRight(Self.text(StorageText.raidStatus(raid.status), Self.captionBold, .systemRed), right: bounds.width, y: 0)
        } else if let issue = issues.first {
            let critical = { if case .criticalWarning = issue { return true } else { return false } }()
            Self.drawRight(
                Self.text("⚠︎ " + StorageText.issue(issue), Self.captionBold, critical ? .systemRed : .systemOrange),
                right: bounds.width, y: 0)
        } else {
            let temp = latest[.storageDisk(key, .temp)]?.value.map(Formatting.temperature)
            let life = latest[.storageDisk(key, .life)]?.value.map { String(localized: "寿命 \(PercentFormat.string(fromRatio: $0))") }
            let text: String =
                if disk.smartCapable {
                    [temp ?? "—", life].compactMap { $0 }.joined(separator: " · ")
                } else {
                    String(localized: "不支持 SMART")
                }
            Self.drawRight(Self.text(text, Self.captionDigits, .secondaryLabelColor), right: bounds.width, y: 0)
        }

        // 第二行：读写速率与小曲线。
        let read = latest[.storageDisk(key, .read)]?.value
        let write = latest[.storageDisk(key, .write)]?.value
        let rates = String(
            localized: "读 \(read.map(Formatting.diskRate) ?? "—")  写 \(write.map(Formatting.diskRate) ?? "—")")
        Self.draw(Self.text(rates, Self.caption2Digits, .secondaryLabelColor), x: 0, y: 17)
        drawSparkline(in: NSRect(x: bounds.width - 70, y: 17, width: 70, height: 12), key: key)

        if showsCapacity {
            CapacityDrawView.drawCapacity(
                groups: services.storageModel.groups.filter { $0.owner == .disk(key) && !$0.isAuxiliary },
                in: NSRect(x: 0, y: Self.height + 2, width: bounds.width, height: CapacityDrawView.height))
        }
        setAccessibilityLabel("\(name) \(rates)")
    }

    /// 读（强调色）与写（橙）两条线，纵轴按两者的最大值。
    private func drawSparkline(in rect: NSRect, key: DiskKey) {
        let reads = store.recentPoints(.storageDisk(key, .read), seconds: Self.sparklineSeconds)
        let writes = store.recentPoints(.storageDisk(key, .write), seconds: Self.sparklineSeconds)
        NSColor.tertiaryLabelColor.setFill()
        NSRect(x: rect.minX, y: rect.maxY - 0.5, width: rect.width, height: 0.5).fill()
        let newest = max(reads.last?.continuousNanos ?? 0, writes.last?.continuousNanos ?? 0)
        guard newest > 0 else { return }
        let top = max((reads.compactMap(\.value) + writes.compactMap(\.value)).max() ?? 0, 100_000)
        for (points, color) in [(reads, NSColor.controlAccentColor), (writes, NSColor.systemOrange)] {
            let path = NSBezierPath()
            path.lineWidth = 1
            var started = false
            for point in points {
                guard let value = point.value else {
                    started = false
                    continue
                }
                let age = Double(newest &- point.continuousNanos) / 1e9
                let x = rect.maxX - CGFloat(age / Self.sparklineSeconds) * rect.width
                let y = rect.maxY - CGFloat(min(value / top, 1)) * rect.height
                if started { path.line(to: NSPoint(x: x, y: y)) } else { path.move(to: NSPoint(x: x, y: y)) }
                started = true
            }
            color.setStroke()
            path.stroke()
        }
    }
}

/// 容量条：「已用 / 总量 · 可用」，一个归属下的主容量组合计。
final class CapacityDrawView: LiveDrawView {
    static let height: CGFloat = 22

    private let services: AppServices
    let owner: CapacityOwner

    init(store: MetricStore, services: AppServices, owner: CapacityOwner) {
        self.services = services
        self.owner = owner
        super.init(store: store)
    }

    override func draw(_ dirtyRect: NSRect) {
        countDraw()
        _ = store.latest  // 观察：容量刷新时重绘
        let groups = services.storageModel.groups.filter { $0.owner == owner && !$0.isAuxiliary }
        Self.drawCapacity(groups: groups, in: bounds)
        setAccessibilityLabel(String(localized: "容量"))
    }

    /// 画在 `rect` 里：上面一条 6 pt 的条，下面一行文字。没有容量组时写「没有已挂载的卷」。
    static func drawCapacity(groups: [CapacityGroup], in rect: NSRect) {
        guard !groups.isEmpty else {
            draw(text(String(localized: "没有已挂载的卷"), caption2, .tertiaryLabelColor), x: rect.minX, y: rect.minY + 6)
            return
        }
        let total = groups.reduce(0.0) { $0 + Double($1.totalBytes) }
        let used = groups.reduce(0.0) { $0 + Double($1.usedBytes) }
        let available = groups.reduce(0.0) { $0 + Double($1.availableBytes) }
        let bar = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 6)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
        if total > 0 {
            NSColor.controlAccentColor.withAlphaComponent(0.8).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(min(used / total, 1)), height: bar.height),
                xRadius: 3, yRadius: 3
            ).fill()
        }
        let left = String(localized: "已用 \(Formatting.diskBytesShort(used)) / \(Formatting.diskBytesShort(total))")
        draw(text(left, caption2Digits, .secondaryLabelColor), x: rect.minX, y: bar.maxY + 2)
        // 可清除空间放在详情页的卷构成里，这里只给可用（与访达的「可用」不含可清除的部分一致）。
        let right = String(localized: "可用 \(Formatting.diskBytesShort(available))")
        drawRight(text(right, caption2Digits, .secondaryLabelColor), right: rect.maxX, y: bar.maxY + 2)
    }
}

// MARK: - 单盘详情页

private struct StorageDetailView: View {
    let store: MetricStore
    let services: AppServices
    @Bindable var settings: AppSettings
    let disk: PhysicalDisk
    let back: () -> Void

    var body: some View {
        let inventory = services.storageModel.inventory
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button(action: back) {
                    Label("存储", systemImage: "chevron.left")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .help("返回存储概览")
                VStack(alignment: .leading, spacing: 0) {
                    Text(StorageText.diskName(disk, inventory: inventory)).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(subtitle(inventory)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            // 详情比概览高得多（SMART 全字段、卷构成）：放进限高滚动区，面板不超出屏幕（存储模块设计 §6.2）。
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    PanelCard {
                        VStack(alignment: .leading, spacing: 4) {
                            HistoryChart(
                                store: store, history: services.history, defaultSpan: settings.storageChartSpan,
                                series: ChartSeries(
                                    metric: .storageDisk(disk.key, .read), overlay: .storageDisk(disk.key, .write),
                                    collector: StorageIOCollector.collectorID, scale: .bytesPerSecond))
                            HStack(spacing: 10) {
                                Legend(color: .accentColor, text: String(localized: "读"))
                                Legend(color: .orange, text: String(localized: "写"))
                            }
                        }
                    }
                    PanelCard {
                        LiveView(make: { DiskIODrawView(store: store, services: services, key: disk.key) })
                            .frame(height: DiskIODrawView.height)
                    }
                    if disk.smartCapable {
                        PanelCard {
                            LiveView(make: { SMARTDrawView(store: store, services: services, key: disk.key) }) { $0.key = disk.key }
                                .frame(height: SMARTDrawView.height)
                        }
                    } else {
                        PanelCard {
                            Text("这块盘不是 NVMe 盘，没有可读的 SMART 数据（为了只读，不开启 ATA SMART）。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    PanelCard { identity(inventory) }
                    let groups = services.storageModel.groups.filter { $0.owner == .disk(disk.key) }
                    if !groups.isEmpty {
                        PanelCard { volumes(groups) }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: Self.maxScrollHeight)
        }
    }

    /// 滚动区的最大高度：屏幕可见高度减去顶栏、标题与边距。
    static var maxScrollHeight: CGFloat {
        max((NSScreen.main?.visibleFrame.height ?? 900) - 150, 300)
    }

    private func subtitle(_ inventory: StorageInventory) -> String {
        [StorageText.location(disk.location), disk.interconnect, disk.bsdName, disk.sizeBytes.map { Formatting.diskBytes(Double($0)) }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func identity(_ inventory: StorageInventory) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("身份").font(.caption.weight(.semibold))
            KeyValue(title: String(localized: "型号"), value: disk.model)
            KeyValue(title: String(localized: "固件"), value: disk.firmware ?? "—")
            KeyValue(title: String(localized: "接口"), value: "\(StorageText.location(disk.location)) · \(disk.interconnect)")
            KeyValue(title: String(localized: "容量"), value: disk.sizeBytes.map { Formatting.diskBytes(Double($0)) } ?? "—")
            KeyValue(title: String(localized: "块大小"), value: disk.blockSize.map { "\($0) B" } ?? "—")
            if let raid = disk.raid, let set = inventory.raidSet(raid.setKey) {
                KeyValue(
                    title: String(localized: "RAID"),
                    value: String(localized: "「\(set.name)」\(StorageText.raidLevel(set.level)) · 成员 \(raid.index.map { "\($0 + 1)" } ?? "?") / \(set.members.count) · \(StorageText.raidStatus(raid.status))"))
            }
        }
    }

    private func volumes(_ groups: [CapacityGroup]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("卷").font(.caption.weight(.semibold))
            ForEach(groups) { group in
                Text("\(group.name) · \(group.fileSystem.uppercased()) · \(Formatting.diskBytesShort(Double(group.usedBytes))) / \(Formatting.diskBytesShort(Double(group.totalBytes)))" + (group.isAuxiliary ? String(localized: "（系统辅助容器）") : ""))
                    .font(.caption2).foregroundStyle(.secondary)
                if let purgeable = group.purgeableBytes, purgeable > 0 {
                    Text("可用 \(Formatting.diskBytesShort(Double(group.availableBytes)))，另有可清除空间约 \(Formatting.diskBytesShort(Double(purgeable)))（系统需要时自动释放）")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(group.volumes, id: \.self) { volume in
                    HStack {
                        Text(volume.name + (StorageText.role(volume.role).map { "（\($0)）" } ?? ""))
                            .lineLimit(1)
                        Spacer()
                        Text(volume.usedBytes.map { Formatting.diskBytesShort(Double($0)) } ?? String(localized: "未挂载"))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                    .padding(.leading, 8)
                }
            }
        }
    }
}

private struct KeyValue: View {
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).lineLimit(2)
        }
        .font(.caption)
    }
}

private struct Legend: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 10, height: 3)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// IO 统计：读 / 写的速率、IOPS、平均延迟，以及驱动累计的错误与重试。
final class DiskIODrawView: LiveDrawView {
    static let rowHeight: CGFloat = 16
    static let height: CGFloat = 16 + rowHeight * 4

    private let services: AppServices
    let key: DiskKey

    init(store: MetricStore, services: AppServices, key: DiskKey) {
        self.services = services
        self.key = key
        super.init(store: store)
    }

    override func draw(_ dirtyRect: NSRect) {
        countDraw()
        let latest = store.latest
        Self.draw(Self.text(String(localized: "读写"), Self.captionBold), x: 0, y: 0)
        let columns: [CGFloat] = [bounds.width * 0.62, bounds.width]
        Self.drawRight(Self.text(String(localized: "读"), Self.caption2, .secondaryLabelColor), right: columns[0], y: 2)
        Self.drawRight(Self.text(String(localized: "写"), Self.caption2, .secondaryLabelColor), right: columns[1], y: 2)
        var y: CGFloat = 16
        func row(_ title: String, _ read: String, _ write: String) {
            Self.draw(Self.text(title, Self.caption, .secondaryLabelColor), x: 0, y: y)
            Self.drawRight(Self.text(read, Self.captionDigits), right: columns[0], y: y)
            Self.drawRight(Self.text(write, Self.captionDigits), right: columns[1], y: y)
            y += Self.rowHeight
        }
        func value(_ metric: MetricID.DiskMetric, _ format: (Double) -> String) -> String {
            latest[.storageDisk(key, metric)]?.value.map(format) ?? "—"
        }
        row(String(localized: "速率"), value(.read, Formatting.diskRate), value(.write, Formatting.diskRate))
        row(String(localized: "IOPS"), value(.readOps) { String(format: "%.0f", $0) }, value(.writeOps) { String(format: "%.0f", $0) })
        row(String(localized: "平均延迟"), value(.readLatency, Formatting.latency), value(.writeLatency, Formatting.latency))
        let counters = services.storage.io?.latestCounters[key]
        row(
            String(localized: "累计错误 / 重试"),
            counters.map { "\($0.readErrors) / \($0.readRetries)" } ?? "—",
            counters.map { "\($0.writeErrors) / \($0.writeRetries)" } ?? "—")
        setAccessibilityLabel(String(localized: "读写统计"))
    }
}

/// SMART 全部字段（存储模块设计 §3.2），分「健康 / 温度 / 累计 / 其他」四节。行数固定，缺的字段写「—」。
final class SMARTDrawView: LiveDrawView {
    static let rowHeight: CGFloat = 15
    static let sectionGap: CGFloat = 6
    /// 各节的行数（与 `sections` 保持一致）。
    static let sectionRows = [5, 5, 7, 2]
    static let height: CGFloat =
        CGFloat(sectionRows.count) * (14 + sectionGap) + CGFloat(sectionRows.reduce(0, +)) * rowHeight + 26

    private let services: AppServices
    var key: DiskKey {
        didSet { needsDisplay = true }
    }

    init(store: MetricStore, services: AppServices, key: DiskKey) {
        self.services = services
        self.key = key
        super.init(store: store)
    }

    private typealias Row = (title: String, value: String, color: NSColor?)

    private func sections(_ r: SMARTRecord?) -> [(String, [Row])] {
        func v(_ make: (SMARTRecord) -> String) -> String { r.map(make) ?? "—" }
        let issues = r?.healthIssues ?? []
        let warningColor: NSColor? = (r?.criticalWarning.isEmpty ?? true) ? nil : .systemRed
        let spareColor: NSColor? = issues.contains(.spareBelowThreshold) ? .systemOrange : nil
        let mediaColor: NSColor? = (r?.mediaErrors ?? 0) > 0 ? .systemOrange : nil
        let health: [Row] = [
            (String(localized: "严重警告"), v { StorageText.warningBits($0.criticalWarning) }, warningColor),
            (String(localized: "已用寿命"), v { "\($0.percentageUsed)%" }, nil),
            (String(localized: "可用备用块 / 阈值"), v { "\($0.availableSpare)% / \($0.availableSpareThreshold)%" }, spareColor),
            (String(localized: "介质与数据完整性错误"), v { Formatting.count($0.mediaErrors) }, mediaColor),
            (String(localized: "错误日志条数"), v { Formatting.count($0.errorLogEntries) }, nil),
        ]
        let sensors = r?.temperatureSensors.enumerated().compactMap { i, t in t.map { "T\(i + 1) \(Int($0))" } } ?? []
        let temperature: [Row] = [
            (String(localized: "综合温度"), v { Formatting.temperature($0.temperatureCelsius) }, nil),
            (String(localized: "警告 / 严重阈值"), v { t in
                let w = t.warningThresholdCelsius.map(Formatting.temperature) ?? "—"
                let c = t.criticalThresholdCelsius.map(Formatting.temperature) ?? "—"
                return "\(w) / \(c)"
            }, nil),
            (String(localized: "超警告 / 严重温度时长"), v { String(localized: "\($0.warningTemperatureMinutes) / \($0.criticalTemperatureMinutes) 分钟") }, nil),
            (String(localized: "温度传感器"), sensors.isEmpty ? String(localized: "无") : sensors.joined(separator: " · ") + " °C", nil),
            (String(localized: "热管理降速次数 / 时长"), v { String(localized: "\($0.thermalTransitions.reduce(0, +)) 次 / \($0.thermalSeconds.reduce(0, +)) 秒") }, nil),
        ]
        let totals: [Row] = [
            (String(localized: "读取量"), v { Formatting.diskBytes($0.bytesRead) }, nil),
            (String(localized: "写入量"), v { Formatting.diskBytes($0.bytesWritten) }, nil),
            (String(localized: "主机读命令"), v { Formatting.count($0.hostReadCommands) }, nil),
            (String(localized: "主机写命令"), v { Formatting.count($0.hostWriteCommands) }, nil),
            (String(localized: "通电次数"), v { Formatting.count($0.powerCycles) }, nil),
            (String(localized: "通电时间"), v { record in
                let hours = String(localized: "\(Formatting.count(record.powerOnHours)) 小时")
                return record.powerOnHoursUnreliable ? hours + String(localized: "（不可信）") : hours
            }, r?.powerOnHoursUnreliable == true ? .secondaryLabelColor : nil),
            (String(localized: "异常断电次数"), v { Formatting.count($0.unsafeShutdowns) }, nil),
        ]
        let other: [Row] = [
            (String(localized: "控制器忙碌时间"), v { $0.controllerBusyUnsupported ? String(localized: "不支持") : String(localized: "\(Formatting.count($0.controllerBusyMinutes)) 分钟") }, nil),
            (String(localized: "NVMe 版本 · 厂商 ID"), v { record in
                let version = record.nvmeVersion.flatMap { $0 == 0 ? nil : "\($0 >> 16).\(($0 >> 8) & 0xFF)" } ?? "—"
                let vendor = record.vendorID.map { String(format: "0x%04X", $0) } ?? "—"
                return "\(version) · \(vendor)"
            }, nil),
        ]
        return [
            (String(localized: "健康"), health), (String(localized: "温度"), temperature), (String(localized: "累计"), totals),
            (String(localized: "其他"), other),
        ]
    }

    override func draw(_ dirtyRect: NSRect) {
        countDraw()
        _ = store.latest  // 观察：SMART 读数到达时重绘
        let record = services.storage.smart?.latestRecords[key]
        var y: CGFloat = 0
        for (title, rows) in sections(record) {
            Self.draw(Self.text(title, Self.captionBold), x: 0, y: y)
            y += 14
            for row in rows {
                Self.draw(Self.text(row.title, Self.caption, .secondaryLabelColor), x: 0, y: y)
                Self.drawRight(Self.text(row.value, Self.captionDigits, row.color ?? .labelColor), right: bounds.width, y: y)
                y += Self.rowHeight
            }
            y += Self.sectionGap
        }
        let read = services.storage.smart?.statuses[key]?.lastRead
        let note = read.map { String(localized: "读取于 \(Formatting.time($0))") } ?? String(localized: "等待读取…")
        Self.draw(Self.text(note, Self.caption2, .secondaryLabelColor), x: 0, y: y)
        if record?.powerOnHoursUnreliable == true {
            Self.draw(
                Self.text(String(localized: "Apple 控制器的通电时间严重低报（实测远少于实际使用时长），仅供参考。"), Self.caption2, .secondaryLabelColor),
                x: 0, y: y + 13)
        }
        setAccessibilityLabel(String(localized: "SMART"))
    }
}
