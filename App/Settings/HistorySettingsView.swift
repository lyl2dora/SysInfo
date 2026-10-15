// 设置的「历史与导出」页（CPU 模块设计 §7.3、§6，D30）。
//
// - 是否记录 CPU 历史、是否记录每应用 CPU；一键清除每应用数据；
// - 历史库概况（大小、时间范围、行数）；
// - 导出：时间范围、粒度、格式（CSV 文件夹或 JSON Lines）、是否含每应用数据。只在点击时运行。

import AppKit
import SwiftUI
import SysStore

struct HistorySettingsView: View {
    @Bindable var settings: AppSettings
    let history: HistoryRecorder?

    @State private var stats: HistoryStats?
    @State private var message: String?
    @State private var exportRange: ExportRange = .day
    @State private var granularity: HistoryGranularity = .minute
    @State private var format: HistoryExportOptions.Format = .csv
    @State private var includeApps = true
    @State private var confirmClear = false
    @State private var busy = false

    enum ExportRange: String, CaseIterable, Identifiable {
        case hour, day, week, month, all
        var id: String { rawValue }

        var seconds: TimeInterval {
            switch self {
            case .hour: 3600
            case .day: 86_400
            case .week: 7 * 86_400
            case .month: 30 * 86_400
            case .all: 20 * 365 * 86_400
            }
        }

        var title: String {
            switch self {
            case .hour: String(localized: "最近 1 小时")
            case .day: String(localized: "最近 24 小时")
            case .week: String(localized: "最近 7 天")
            case .month: String(localized: "最近 30 天")
            case .all: String(localized: "全部")
            }
        }
    }

    var body: some View {
        Form {
            Section("记录") {
                Toggle("记录 CPU 历史", isOn: $settings.historyCPUEnabled)
                Toggle("记录每应用 CPU", isOn: $settings.historyAppsEnabled)
                Text("面板关闭时也在后台低频采样（占用、频率每 60 秒，温度与每应用每 10 秒），锁屏和显示器睡眠时不停。分钟数据与每应用数据保留 30 天，小时数据永久保留。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("清除每应用数据…") { confirmClear = true }
                    .disabled(history == nil || busy)
            }

            Section("历史库") {
                if history == nil {
                    Text("历史库打不开，本次运行不记录历史。详情见日志。").foregroundStyle(.secondary)
                } else if let stats {
                    LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: stats.fileBytes, countStyle: .file))
                    LabeledContent("分钟数据", value: rangeText(stats.minuteRange, rows: stats.minuteRows, scale: 60))
                    LabeledContent("小时数据", value: rangeText(stats.hourRange, rows: stats.hourRows, scale: 3600))
                    LabeledContent("每应用", value: String(localized: "\(stats.appCount) 个应用，\(stats.appRows) 行"))
                    if let url = HistoryStore.defaultURL(bundleIdentifier: BuildInfo.bundleIdentifier) {
                        PathRow(title: String(localized: "位置"), url: url)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }

            Section("导出") {
                Picker("时间范围", selection: $exportRange) {
                    ForEach(ExportRange.allCases) { Text($0.title).tag($0) }
                }
                Picker("粒度", selection: $granularity) {
                    Text("分钟").tag(HistoryGranularity.minute)
                    Text("小时").tag(HistoryGranularity.hour)
                }
                Picker("格式", selection: $format) {
                    Text("CSV（文件夹）").tag(HistoryExportOptions.Format.csv)
                    Text("JSON Lines").tag(HistoryExportOptions.Format.jsonLines)
                }
                Toggle("包含每应用数据（分钟粒度）", isOn: $includeApps)
                Button("导出…", action: export)
                    .disabled(history == nil || busy)
                Text("导出内容不含序列号、硬件 UUID、MAC 地址等设备唯一标识；机型标识和芯片名会写进元数据。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let message {
                    Text(message).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
        .confirmationDialog("清除全部每应用数据？", isPresented: $confirmClear) {
            Button("清除", role: .destructive) {
                Task {
                    do {
                        try await history?.clearAppData()
                        message = String(localized: "已清除每应用数据")
                    } catch {
                        message = String(localized: "清除失败：\(String(describing: error))")
                    }
                    await reload()
                }
            }
        } message: {
            Text("整机历史不受影响。此操作无法撤销。")
        }
    }

    private func reload() async {
        stats = try? await history?.stats()
    }

    private func rangeText(_ range: ClosedRange<Int64>?, rows: Int, scale: Double) -> String {
        guard let range else { return String(localized: "无") }
        let from = Date(timeIntervalSince1970: Double(range.lowerBound) * scale)
        return String(localized: "\(rows) 行，自 \(from.formatted(date: .abbreviated, time: .shortened))")
    }

    private func export() {
        guard let history else { return }
        let stamp = Date().formatted(.iso8601.year().month().day()).replacingOccurrences(of: "-", with: "")
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = format == .csv ? "SysInfo-History-\(stamp)" : "SysInfo-History-\(stamp).jsonl"
        panel.title = String(localized: "导出历史")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let now = Date()
        let options = HistoryExportOptions(
            from: now.addingTimeInterval(-exportRange.seconds), to: now, granularity: granularity, format: format,
            includeApps: includeApps, appVersion: "\(BuildInfo.version) (\(BuildInfo.build))")
        busy = true
        message = String(localized: "正在导出…")
        Task {
            do {
                let files = try await history.export(options, to: url)
                message = String(localized: "已导出 \(files.count) 个文件")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                message = String(localized: "导出失败：\(String(describing: error))")
            }
            busy = false
        }
    }
}
