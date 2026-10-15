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
        Toggle(isOn: Binding(get: { settings.isVisible(widget) }, set: { settings.setVisible(widget, $0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(WidgetInfo.title(widget))
                if let note = WidgetInfo.note(widget, settings: settings, store: store) {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if visible {
            Group {
                if widget == .usage {
                    Picker("呈现形式", selection: $settings.cpuUsagePresentation) {
                        ForEach(CPUUsagePresentation.allCases) { presentation in
                            Text(Self.presentationName(presentation)).tag(presentation)
                        }
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
        case .fan: String(localized: "风扇转速")
        case .memoryUsage: String(localized: "内存占用")
        case .memoryPressure: String(localized: "内存压力")
        case .swapUsed: String(localized: "Swap 用量")
        }
    }

    /// 所属模块的显示名（菜单栏总览）。
    static func module(_ module: MenuModule) -> String {
        switch module {
        case .cpu: String(localized: "CPU")
        case .power: String(localized: "功耗与散热")
        case .memory: String(localized: "内存")
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
            return String(localized: "GPU 实时功率（AGX 能量计数）。\(CostLabel.text(collector: GPUPowerCollector.collectorID, interval: interval, store: store))")
        case .fan:
            return String(localized: "最快的风扇的实际转速。\(CostLabel.text(collector: PowerSensorCollector.collectorID, interval: interval, store: store))")
        case .memoryUsage:
            return String(localized: "已用内存（App + 联动 + 被压缩），与活动监视器同口径。\(CostLabel.text(collector: MemoryCollector.collectorID, interval: interval, store: store))")
        case .memoryPressure:
            return String(localized: "系统内存压力百分比（100 − 可用水位），与 memory_pressure 同源。\(CostLabel.text(collector: MemoryCollector.collectorID, interval: interval, store: store))")
        case .swapUsed:
            return String(localized: "已写入 swap 文件的数据量。\(CostLabel.text(collector: MemoryCollector.collectorID, interval: interval, store: store))")
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
        // 内存模块设计 §2.4：sysctl 与 host_statistics64 一次约 0.3 ms
        MemoryCollector.collectorID: 0.3,
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
