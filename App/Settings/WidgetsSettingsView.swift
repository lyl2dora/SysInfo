// 设置的「桌面小组件」页（D90、D91，规格 docs/design/widgets.md §7）。

import SwiftUI
import WidgetKit

struct WidgetsSettingsView: View {
    @Bindable var settings: AppSettings
    let writer: WidgetSnapshotWriter?

    var body: some View {
        Form {
            if writer?.available != true {
                Section {
                    Text("这个构建没有 App Group（例如 ad-hoc 签名的构建），桌面小组件不可用。")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("刷新节奏", selection: $settings.widgetRefreshInterval) {
                    Text("每 5 分钟").tag(WidgetRefreshInterval.fiveMinutes)
                    Text("每 1 分钟").tag(WidgetRefreshInterval.oneMinute)
                }
            } header: {
                Text("刷新")
            } footer: {
                Text("小组件由系统的独立进程绘制，每次刷新都要重绘。本机实测（四种尺寸各放一个）：每 5 分钟约占一个核的 0.1%，每 1 分钟约 0.3%，还不含系统合成桌面的开销。点组件上的刷新按钮会立刻现采一次，不受这里的节奏限制。")
                    .font(.callout)
            }
            Section("状态") {
                LabeledContent("已放置的组件", value: placedText)
                LabeledContent("最近一次写入") {
                    if let last = writer?.lastWrite {
                        Text(last, style: .relative).monospacedDigit()
                    } else {
                        Text("—")
                    }
                }
                Text("没有放置组件时 SysInfo 不为小组件采样，也不写快照。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("怎么放") {
                Text("在桌面上右键，选「编辑小组件」，在列表里找到「SysInfo」，把「总览」拖到桌面。有小、中、大、超大竖版四种尺寸：小号是四个圆环，中号起是带 24 小时曲线的卡片，大号加核心分档与网速、磁盘，超大竖版再加四张带标注的 24 小时曲线。SysInfo 没在运行时，组件保留最后的数据并注明「未运行」。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await writer?.refreshPlacement() }
    }

    private var placedText: String {
        let families = writer?.placedFamilies ?? []
        guard !families.isEmpty else { return String(localized: "没有") }
        // currentConfigurations 的顺序不固定，按尺寸从小到大列。
        return families.sorted { Self.sizeRank($0) < Self.sizeRank($1) }.map(Self.familyName).joined(separator: "、")
    }

    private static func sizeRank(_ family: WidgetFamily) -> Int {
        [WidgetFamily.systemSmall, .systemMedium, .systemLarge, .systemExtraLargePortrait].firstIndex(of: family) ?? .max
    }

    private static func familyName(_ family: WidgetFamily) -> String {
        switch family {
        case .systemSmall: String(localized: "小")
        case .systemMedium: String(localized: "中")
        case .systemLarge: String(localized: "大")
        case .systemExtraLargePortrait: String(localized: "超大竖版")
        default: String(describing: family)
        }
    }
}
