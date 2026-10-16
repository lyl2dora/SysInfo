// 面板的「GPU 与加速器」tab（GPU 模块设计 §8，D57、D58）。
//
// 分区：概览（GPU 活跃大字 + 频率、功率、温度）→ 历史图（活跃，或功率）→ 加速器（ANE、媒体引擎、GPU 内存）→ Top N（按 GPU 时间）。
// 每秒都在变的部分用 AppKit 自绘（做法同 LiveViews.swift），SwiftUI 只放外框。需求由 PanelController 按 tab 可见性登记。

import AppKit
import SwiftUI
import SysCollectors
import SysModel

struct GPUPanelView: View {
    let store: MetricStore
    let services: AppServices
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelCard {
                LiveView(make: { GPUOverviewDrawView(store: store) })
                    .frame(height: GPUOverviewDrawView.height)
            }
            PanelCard {
                HistoryChart(
                    store: store, history: services.history, defaultSpan: settings.gpuChartSpan,
                    series: settings.gpuChartShowsPower
                        ? ChartSeries(metric: .powerGPU, overlay: nil, collector: GPUPowerCollector.collectorID, scale: .watts)
                        : ChartSeries(metric: .gpuActive, overlay: nil, collector: GPUPowerCollector.collectorID, scale: .unit))
            }
            PanelCard {
                LiveView(make: { AcceleratorDrawView(store: store) })
                    .frame(height: AcceleratorDrawView.height)
            }
            if settings.gpuTopNRows > 0 {
                PanelCard {
                    TopNSection(model: services.gpuTopN, grouping: settings.gpuGrouping, slots: settings.gpuTopNRows)
                }
            }
        }
    }
}

// MARK: - 概览

final class GPUOverviewDrawView: LiveDrawView {
    static let height: CGFloat = 86

    private static let big: NSFont = {
        let base = NSFont.monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 34) } ?? base
    }()
    private static let subheadline = NSFont.systemFont(ofSize: 13)
    private static let callout = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)

    override func draw(_ dirtyRect: NSRect) {
        countDraw()
        let latest = store.latest
        Self.draw(Self.text(String(localized: "GPU 活跃"), Self.subheadline, .secondaryLabelColor), x: 0, y: 0)
        let active = latest[.gpuActive]
        let activeText = active?.value.map { PercentFormat.string(fromRatio: $0) } ?? PercentFormat.placeholder
        Self.draw(Self.text(activeText, Self.big), x: 0, y: 16)
        // 活跃的含义（D57 G1）：上电时间，不是算力占用。
        Self.draw(
            Self.text(String(localized: "上电运行的时间比例，不是算力占用"), Self.caption2, .secondaryLabelColor), x: 0, y: 64)

        let right = bounds.width
        var y: CGFloat = 0
        func item(_ title: String, _ value: String) {
            Self.drawRight(Self.text(title, Self.caption2, .secondaryLabelColor), right: right, y: y)
            Self.drawRight(Self.text(value, Self.callout), right: right, y: y + 12)
            y += 29
        }
        item(String(localized: "频率"), Self.frequencyText(latest[.gpuFrequency]))
        item(String(localized: "功率"), store.smoothed[.powerGPU].map(Formatting.watts) ?? "—")
        item(String(localized: "温度"), Self.temperatureText(latest[.gpuTemperature]))
        setAccessibilityLabel(String(localized: "GPU 活跃 \(activeText)"))
    }

    static func frequencyText(_ sample: Sample?) -> String {
        guard let sample else { return "—" }
        if let value = sample.value { return Formatting.frequency(value) + (sample.quality == .inferred ? "*" : "") }
        if case .unavailable(let reason) = sample.quality, reason.code == "deviceIdle" { return String(localized: "关断") }
        return "—"
    }

    static func temperatureText(_ sample: Sample?) -> String {
        guard let sample else { return "—" }
        if let value = sample.value { return Formatting.temperature(value) }
        if case .unavailable(let reason) = sample.quality, reason.code == "sensorPowerGated" {
            return String(localized: "— 关断")
        }
        return "—"
    }
}

// MARK: - 加速器

/// ANE（开 / 关与估算功率）、媒体引擎（编码 / 解码 / ProRes 的活动与相对强度）、GPU 占用的统一内存。
final class AcceleratorDrawView: LiveDrawView {
    static let rowHeight: CGFloat = 18
    static let height: CGFloat = 16 + rowHeight * 2 + 8 + 16 + rowHeight * 3 + 8 + rowHeight + 28

    /// 媒体引擎的相对强度：除以本次运行观察到的最大速率（每个引擎至少按 `minimumScale` 算，避免空闲时的零星中断显得很满）。
    private var maxima: [MetricID: Double] = [:]
    static let minimumScale: [MetricID: Double] = [.mediaEncodeRate: 60, .mediaDecodeRate: 300, .mediaProResRate: 120]
    /// 高于底数这么多次/秒才算「工作中」。
    static let activeThreshold: Double = 5

    static let engines: [(MetricID, String)] = [
        (.mediaEncodeRate, String(localized: "视频编码")),
        (.mediaDecodeRate, String(localized: "视频解码")),
        (.mediaProResRate, String(localized: "ProRes")),
    ]

    override func draw(_ dirtyRect: NSRect) {
        countDraw()
        let latest = store.latest
        let width = bounds.width
        var y: CGFloat = 0

        // ANE
        Self.draw(Self.text(String(localized: "神经网络引擎（ANE）"), Self.captionBold), x: 0, y: y)
        y += 16
        let powered = latest[.anePowered]
        let state: (String, NSColor) =
            switch powered?.value {
            case .some(let v) where v > 0: (String(localized: "工作中"), .systemGreen)
            case .some: (String(localized: "关断"), .secondaryLabelColor)
            case .none: (String(localized: "不可用"), .tertiaryLabelColor)
            }
        Self.draw(Self.text(String(localized: "状态"), Self.caption, .secondaryLabelColor), x: 0, y: y)
        Self.drawRight(Self.text(state.0, Self.captionBold, state.1), right: width, y: y)
        y += Self.rowHeight
        Self.draw(Self.text(String(localized: "功率（估算）"), Self.caption, .secondaryLabelColor), x: 0, y: y)
        Self.drawRight(Self.text(Self.aneWattsText(latest[.anePowerEstimated]), Self.captionDigits), right: width, y: y)
        y += Self.rowHeight + 8

        // 媒体引擎
        Self.draw(Self.text(String(localized: "媒体引擎"), Self.captionBold), x: 0, y: y)
        y += 16
        for (id, title) in Self.engines {
            Self.draw(Self.text(title, Self.caption, .secondaryLabelColor), x: 0, y: y)
            let sample = latest[id]
            let bar = NSRect(x: 80, y: y + 5, width: max(width - 80 - 64, 20), height: 5)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
            var label = "—"
            if let rate = sample?.value {
                let scale = max(maxima[id] ?? 0, Self.minimumScale[id] ?? 60)
                if rate > (maxima[id] ?? 0) { maxima[id] = rate }
                let fill = CGFloat(min(rate / scale, 1))
                if rate >= Self.activeThreshold {
                    NSColor.systemPurple.setFill()
                    NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(bar.width * fill, 3), height: bar.height), xRadius: 2, yRadius: 2).fill()
                    label = String(localized: "工作中")
                } else {
                    label = String(localized: "空闲")
                }
            } else if case .unavailable(let reason)? = sample?.quality, reason.code == "learning" {
                label = String(localized: "学习中")
            }
            Self.drawRight(Self.text(label, Self.caption, sample?.value.map { $0 >= Self.activeThreshold } == true ? .labelColor : .secondaryLabelColor), right: width, y: y)
            y += Self.rowHeight
        }
        y += 8

        // GPU 内存
        Self.draw(Self.text(String(localized: "GPU 占用的统一内存"), Self.caption, .secondaryLabelColor), x: 0, y: y)
        let inUse = latest[.gpuMemoryInUse]?.value.map(Formatting.memory) ?? "—"
        let allocated = latest[.gpuMemoryAllocated]?.value.map(Formatting.memory) ?? "—"
        Self.drawRight(Self.text("\(inUse) / \(allocated)", Self.captionDigits), right: width, y: y)
        y += Self.rowHeight
        Self.draw(
            Self.text(String(localized: "ANE 关断滞后约 5 秒；功率按应用的能耗记账估算。"), Self.caption2, .secondaryLabelColor), x: 0, y: y)
        Self.draw(
            Self.text(String(localized: "媒体引擎只给相对强度；内存为在用 / 已分配。"), Self.caption2, .secondaryLabelColor), x: 0, y: y + 13)
        setAccessibilityLabel(String(localized: "加速器：ANE \(state.0)"))
    }

    static func aneWattsText(_ sample: Sample?) -> String {
        guard let sample else { return String(localized: "等待数据…") }
        if let value = sample.value { return Formatting.watts(value) }
        if case .unavailable(let reason) = sample.quality, reason.code == "selfTestFailed" {
            return String(localized: "对账未通过，已隐藏")
        }
        return "—"
    }
}
