// 模块页「菜单栏」节的公共部分（D41、D43）：一个 widget 的开关与就地展开的配置、名称与开销说明、开销标注、预览。
// CPU 页与功耗与散热页共用；菜单栏页的总览也用这里的名称与宽度。

import AppKit
import SwiftUI
import SysCollectors
import SysModel

/// 一个 widget：开关与说明；打开后就地展开它自己的配置（呈现形式、颜色、预览，D41）。
struct WidgetSettingsRow: View {
    @Bindable var settings: AppSettings
    let store: MetricStore
    let widget: MenuWidget

    var body: some View {
        let visible = settings.isVisible(widget)
        let latencyLocked = widget == .netLatency && !settings.latencyEnabled
        Toggle(isOn: Binding(get: { settings.isVisible(widget) }, set: { settings.setVisible(widget, $0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(WidgetInfo.title(widget))
                if let note = WidgetInfo.note(widget, settings: settings, store: store) {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(latencyLocked)
        if visible {
            Group {
                if widget == .usage {
                    Picker("呈现形式", selection: $settings.cpuUsagePresentation) {
                        ForEach(CPUUsagePresentation.allCases) { presentation in
                            Text(Self.presentationName(presentation)).tag(presentation)
                        }
                    }
                }
                if widget == .diskTemperature || widget == .diskThroughput || widget == .diskFree {
                    StorageTargetPicker(settings: settings, widget: widget)
                }
                if widget == .netThroughput {
                    NetworkTargetPicker(settings: settings, state: NetworkModel.shared.state)
                    Picker("单位", selection: $settings.networkThroughputBits) {
                        Text("字节 / 秒（12M）").tag(false)
                        Text("比特 / 秒（96Mb）").tag(true)
                    }
                }
                if widget == .netLatency {
                    Picker("目标", selection: $settings.networkLatencyWidgetTarget) {
                        Text("默认网关").tag(MetricID.LatencyTarget.gateway)
                        Text("自定义地址（\(settings.latencyHost)）").tag(MetricID.LatencyTarget.custom)
                    }
                }
                if widget == .memoryUsage {
                    Picker("显示", selection: $settings.memoryUsagePresentation) {
                        Text("占用率（%）").tag(MemoryUsagePresentation.percent)
                        Text("已用（GB）").tag(MemoryUsagePresentation.bytes)
                    }
                }
                Toggle("自定义颜色", isOn: Binding(
                    get: { settings.color(for: widget) != .system },
                    set: { settings.setColor($0 ? (WidgetColor(.systemBlue) ?? .system) : .system, for: widget) }))
                if settings.color(for: widget) != .system {
                    ColorPicker("颜色", selection: Binding(
                        get: { Color(nsColor: settings.color(for: widget).nsColor) },
                        set: { if let color = WidgetColor(NSColor($0)) { settings.setColor(color, for: widget) } }),
                        supportsOpacity: false)
                }
                LabeledContent("预览") {
                    StatusItemPreview(store: store, configuration: StatusItemConfiguration(widget: widget, settings: settings))
                }
            }
            .padding(.leading, 16)
        }
    }

    static func presentationName(_ presentation: CPUUsagePresentation) -> String {
        switch presentation {
        case .number: String(localized: "数字")
        case .sparkline: String(localized: "迷你折线")
        case .barsTotal: String(localized: "柱：总量")
        case .barsLevels: String(localized: "柱：按档")
        case .barsCores: String(localized: "柱：每核")
        }
    }

}

/// widget 的名称与说明，模块页与菜单栏总览共用。
enum WidgetInfo {
    static func title(_ widget: MenuWidget) -> String {
        switch widget {
        case .usage: String(localized: "CPU 占用")
        case .frequency: String(localized: "CPU 频率")
        case .temperature: String(localized: "CPU 温度")
        case .power: String(localized: "CPU 功耗")
        case .systemPower: String(localized: "整机功率")
        case .socHotspot: String(localized: "SoC 最热点")
        case .socPower: String(localized: "SoC 功率")
        case .gpuPower: String(localized: "GPU 功率")
        case .gpuActive: String(localized: "GPU 活跃")
        case .gpuTemperature: String(localized: "GPU 温度")
        case .fan: String(localized: "风扇转速")
        case .memoryUsage: String(localized: "内存占用")
        case .memoryPressure: String(localized: "内存压力")
        case .swapUsed: String(localized: "Swap 用量")
        case .diskTemperature: String(localized: "盘温")
        case .diskThroughput: String(localized: "读写速率")
        case .diskFree: String(localized: "可用空间")
        case .netThroughput: String(localized: "网速")
        case .netLatency: String(localized: "网络延迟")
        }
    }

    /// 所属模块的显示名（菜单栏总览）。
    static func module(_ module: MenuModule) -> String {
        switch module {
        case .cpu: String(localized: "CPU")
        case .power: String(localized: "功耗与散热")
        case .memory: String(localized: "内存")
        case .storage: String(localized: "存储")
        case .gpu: String(localized: "GPU 与加速器")
        case .network: String(localized: "网络")
        }
    }

    /// 开销说明（D19）：按所属模块的常驻采集间隔换算。
    static func note(_ widget: MenuWidget, settings: AppSettings, store: MetricStore) -> String? {
        let interval = settings.interval(for: widget.module).rawValue
        switch widget {
        case .usage:
            return nil
        case .frequency:
            return String(localized: "最忙的簇的实际频率。高开销：\(CostLabel.text(collector: CPUFrequencyCollector.collectorID, interval: interval, store: store))")
        case .temperature:
            return String(localized: "CPU 最高温。\(CostLabel.text(collector: SensorCollector.collectorID, interval: interval, store: store))")
        case .power:
            return String(localized: "CPU 各簇功耗之和，不含 GPU；没有专用功耗轨的芯片显示「—」。\(CostLabel.text(collector: SensorCollector.collectorID, interval: interval, store: store))")
        case .systemPower:
            return String(localized: "整机直流功率（SMC PDTR），约 2 秒平滑。\(CostLabel.text(collector: PowerRailCollector.collectorID, interval: interval, store: store))")
        case .socHotspot:
            return String(localized: "SoC 上最热的读数，随 CPU 和 GPU 负载变化。\(CostLabel.text(collector: PowerSensorCollector.collectorID, interval: interval, store: store))")
        case .socPower:
            return String(localized: "SoC 功率，Apple 功耗模型口径。\(CostLabel.text(collector: PowerSensorCollector.collectorID, interval: interval, store: store))")
        case .gpuPower:
            return String(localized: "GPU 实时功率（AGX 能量计数），约 2 秒平滑。与「GPU 活跃」读同一个订阅，同时开着不增加开销。\(CostLabel.text(collector: GPUPowerCollector.collectorID, interval: interval, store: store))")
        case .gpuActive:
            return String(localized: "GPU 上电并在运行的时间比例（GPUPH），不是算力占用：很小的计算任务也可能读 100%，要配合功率看。\(CostLabel.text(collector: GPUPowerCollector.collectorID, interval: interval, store: store))")
        case .gpuTemperature:
            return String(localized: "GPU 区域温度传感器的最高值。部分芯片（如 M4 Pro）GPU 关断时没有读数，显示「—」。\(CostLabel.text(collector: GPUTemperatureCollector.collectorID, interval: interval, store: store))")
        case .fan:
            return String(localized: "最快的风扇的实际转速。\(CostLabel.text(collector: PowerSensorCollector.collectorID, interval: interval, store: store))")
        case .memoryUsage:
            return String(localized: "已用内存（App + 联动 + 被压缩），与活动监视器同口径。\(CostLabel.text(collector: MemoryCollector.collectorID, interval: interval, store: store))")
        case .memoryPressure:
            return String(localized: "系统内存压力百分比（100 − 可用水位），与 memory_pressure 同源。\(CostLabel.text(collector: MemoryCollector.collectorID, interval: interval, store: store))")
        case .swapUsed:
            return String(localized: "已写入 swap 文件的数据量。\(CostLabel.text(collector: MemoryCollector.collectorID, interval: interval, store: store))")
        case .diskTemperature:
            return String(localized: "NVMe SMART 综合温度；只读绑定的那块盘（选「所有盘最高温」时读全部盘）。\(CostLabel.text(collector: SMARTCollector.collectorID, interval: interval, store: store))")
        case .diskThroughput:
            return String(localized: "一块物理盘的读写速率，上下两行（R 读、W 写），按 1000 换算。\(CostLabel.text(collector: StorageIOCollector.collectorID, interval: interval, store: store))")
        case .diskFree:
            return String(localized: "一个容量组（APFS 容器或分区）的可用空间，与访达的「可用」一致（不含可清除空间），每分钟更新。")
        case .netThroughput:
            return String(localized: "上下两行：↑ 上传、↓ 下载，接口字节（含协议头）。默认跟随主接口，开 VPN 时取它下面的物理接口。\(CostLabel.text(collector: NetworkIOCollector.collectorID, interval: interval, store: store))")
        case .netLatency:
            return String(localized: "到所选目标的 ICMP 往返时间。只有在下方开启「延迟」后才可用，按延迟的发包间隔更新。")
        }
    }
}

/// 存储 widget 绑定的盘或容量组（D54）。选项按当前的盘与组列出；选中的盘拔掉后仍保留，显示「已断开」。
struct StorageTargetPicker: View {
    @Bindable var settings: AppSettings
    let widget: MenuWidget

    private var selection: Binding<StorageTarget> {
        switch widget {
        case .diskThroughput: $settings.diskThroughputTarget
        case .diskFree: $settings.diskFreeTarget
        default: $settings.diskTemperatureTarget
        }
    }

    var body: some View {
        let model = StorageModel.shared
        let inventory = model.inventory
        let primaryDisk = inventory.primaryDisk
        let bootGroup = model.resolveGroup(.primary)
        let current = selection.wrappedValue
        Picker(widget == .diskFree ? "容量组" : "盘", selection: selection) {
            // 「内置盘」「启动卷所在的组」跟随当前的内置盘 / 启动组；它们对应的那一项不再单独列出，避免重复。
            if widget == .diskFree {
                Text(model.groups.first { $0.key == bootGroup }.map { "启动卷所在的组（\($0.name)）" } ?? "启动卷所在的组")
                    .tag(StorageTarget.primary)
                ForEach(model.groups.filter { !$0.isAuxiliary && ($0.key != bootGroup || current == .group($0.key)) }) { group in
                    Text("\(group.name)（\(Formatting.diskBytes(Double(group.totalBytes)))）").tag(StorageTarget.group(group.key))
                }
            } else {
                Text(primaryDisk.map { "内置盘（\($0.model)）" } ?? "内置盘").tag(StorageTarget.primary)
                if widget == .diskTemperature {
                    Text("所有盘最高温").tag(StorageTarget.hottest)
                }
                ForEach(inventory.disks.filter { $0.key != primaryDisk?.key || current == .disk($0.key) }) { disk in
                    Text(Self.diskLabel(disk, inventory: inventory)).tag(StorageTarget.disk(disk.key))
                }
            }
            if case .disk(let key) = current, inventory.disk(key) == nil {
                Text("已断开的盘").tag(current)
            }
            if case .group(let key) = current, !model.groups.contains(where: { $0.key == key }) {
                Text("已断开的容量组").tag(current)
            }
        }
    }

    static func diskLabel(_ disk: PhysicalDisk, inventory: StorageInventory) -> String {
        let name = StorageText.diskName(disk, inventory: inventory)
        if let raid = disk.raid, let set = inventory.raidSet(raid.setKey) {
            return "\(name)（RAID「\(set.name)」，\(disk.bsdName ?? "?")）"
        }
        return "\(name)（\(StorageText.location(disk.location))，\(disk.bsdName ?? "?")）"
    }
}

/// 网速 widget 绑定的接口（D60）。选项按当前清单列出物理接口；指定的接口不在了时仍保留，显示「已断开」。
struct NetworkTargetPicker: View {
    @Bindable var settings: AppSettings
    let state: NetworkState

    var body: some View {
        let current = settings.networkThroughputTarget
        Picker("接口", selection: $settings.networkThroughputTarget) {
            Text(state.primaryInterface.map { "主接口（当前 \(NetworkText.interfaceName($0))）" } ?? "主接口").tag(NetworkTarget.primary)
            Text("全部物理接口合计").tag(NetworkTarget.physical)
            ForEach(state.physical) { interface in
                Text(NetworkText.interfaceName(interface)).tag(NetworkTarget.interface(interface.name))
            }
            if case .interface(let name) = current, !state.physical.contains(where: { $0.name == name }) {
                Text(state.interface(name).map(NetworkText.interfaceName) ?? "已断开的接口（\(name)）").tag(current)
            }
        }
    }
}

/// 开销标注（D19）。
enum CostLabel {
    /// 参考值：单次采样的线程 CPU 时间，毫秒（偏离记录与 D34 的两台实测，取较大者）。
    static let referenceMilliseconds: [CollectorID: Double] = [
        CPUFrequencyCollector.collectorID: 9.5,  // D34：M5 约 9.5 ms，M4 约 8.5 ms
        AppSampler.collectorID: 14,  // 偏离记录 §5.7：M5 约 10.8 ms，M4 约 14 ms（含组装）
        // 功耗与散热边界稿 §2.8（真实节奏，取 M4）：PDTR + 遥测约 0.6 ms；约 10 个 SMC 键约 1 ms；AGX 单通道约 1.8 ms
        PowerRailCollector.collectorID: 0.6,
        PowerSensorCollector.collectorID: 1.0,
        GPUPowerCollector.collectorID: 1.8,
        // GPU 边界稿 §1.6（真实节奏，取 M4）：代表温度键 5 个约 0.5 ms
        GPUTemperatureCollector.collectorID: 0.5,
        // 内存模块设计 §2.4：sysctl 与 host_statistics64 一次约 0.3 ms
        MemoryCollector.collectorID: 0.3,
        // 存储模块设计 §1.1、D56：每次打开 → 读 → 关闭，一块盘约 0.7–1.0 ms（盘温 widget 只读绑定的盘）；6 块盘的驱动统计约 0.8 ms
        SMARTCollector.collectorID: 1.0,
        StorageIOCollector.collectorID: 0.8,
        // 网络模块设计 §1.4：IFMIB 每个接口约 0.003 ms，加清单快照与差分（Release 实测见验收记录）
        NetworkIOCollector.collectorID: 0.2,
    ]

    static func text(collector: CollectorID, interval: Int, store: MetricStore) -> String {
        if let health = store.engineStatus?.health.first(where: { $0.id == collector }), let cost = health.averageCost,
            health.sampleCount >= 5
        {
            let percent = Double(cost.cpuNanos) / 1e9 / Double(interval) * 100
            return String(localized: "约 \(String(format: "%.2f", percent))% 单核（本机实测）")
        }
        if let ms = referenceMilliseconds[collector] {
            let percent = ms / 1000 / Double(interval) * 100
            return String(localized: "约 \(String(format: "%.2f", percent))% 单核（参考 M5 Pro / M4 Pro）")
        }
        return String(localized: "尚无实测")
    }
}

/// 设置页的菜单栏预览：用真实的 item view 渲染。
struct StatusItemPreview: NSViewRepresentable {
    let store: MetricStore
    let configuration: StatusItemConfiguration

    func makeNSView(context: Context) -> StatusItemView {
        StatusItemView(store: store, height: NSStatusBar.system.thickness, configuration: configuration)
    }

    func updateNSView(_ view: StatusItemView, context: Context) {
        view.configuration = configuration
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: StatusItemView, context: Context) -> CGSize? {
        CGSize(width: StatusItemView.fixedWidth(for: configuration), height: NSStatusBar.system.thickness)
    }
}
