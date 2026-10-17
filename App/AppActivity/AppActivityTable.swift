// 应用活动的表格：AppKit NSTableView（D67）。
//
// 不用 SwiftUI `Table`：它每次刷新都对全部行做差分，并为可见行的每个单元格重建 NSHostingView，
// M5 实测窗口打开时整个 app 约 5–6% 单核（2026-10-17，`sample` 显示几乎全在 NSTableView endUpdates 与
// NSHostingView 的 KVO 注销里）。这里每次只 `reloadData()`，单元格是复用的 NSTextField，选中按行 id 恢复。
//
// - 列：点表头排序（降序优先），右键表头勾选显示哪些列，列宽与顺序按 autosave 名记住（`--factory-defaults` 时不记）；
// - 同一组列在「现在」档显示速率，在历史时段显示总量（表头文字随之改变）；
// - 右键行：在访达中显示、结束（同 uid 的单进程应用，D31）、拷贝名称。

import AppKit
import SwiftUI
import SysCollectors
import SysModel

struct AppActivityTable: NSViewRepresentable {
    let rows: [AppActivityRow]
    let isNow: Bool
    @Binding var selection: AppActivityRow.ID?
    @Binding var sortOrder: [KeyPathComparator<AppActivityRow>]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 8, height: 2)
        for column in AppActivityColumn.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.width = column.idealWidth
            tableColumn.minWidth = column.minWidth
            tableColumn.headerCell.alignment = column == .name ? .left : .right
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column == .name)
            tableColumn.isHidden = column.hiddenByDefault
            table.addTableColumn(tableColumn)
        }
        if !LaunchOptions.current.factoryDefaults {
            table.autosaveName = "AppActivityTable"
            table.autosaveTableColumns = true
        }
        table.headerView?.menu = context.coordinator.headerMenu(for: table)
        let rowMenu = NSMenu()
        rowMenu.delegate = context.coordinator
        table.menu = rowMenu
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: AppActivityTable
        weak var table: NSTableView?
        private var rows: [AppActivityRow] = []
        private var isNow: Bool?
        /// 程序改选中时不回写绑定。
        private var applyingSelection = false

        init(_ parent: AppActivityTable) {
            self.parent = parent
        }

        func apply() {
            guard let table else { return }
            if isNow != parent.isNow {
                isNow = parent.isNow
                for column in table.tableColumns {
                    guard let id = AppActivityColumn(rawValue: column.identifier.rawValue) else { continue }
                    column.title = id.title(isNow: parent.isNow)
                    column.headerToolTip = id.help
                }
            }
            syncSortIndicator(table)
            let old = rows.count
            rows = parent.rows
            applyingSelection = true
            // 原地更新：只重配可见单元格的内容，行数变化时在末尾增删（不用 reloadData：它会丢掉并重建全部可见行视图）。
            table.beginUpdates()
            if rows.count > old {
                table.insertRows(at: IndexSet(old..<rows.count), withAnimation: [])
            } else if rows.count < old {
                table.removeRows(at: IndexSet(rows.count..<old), withAnimation: [])
            }
            table.endUpdates()
            let visible = table.rows(in: table.visibleRect)
            for row in visible.lowerBound..<min(visible.upperBound, rows.count) {
                for (index, column) in table.tableColumns.enumerated() where !column.isHidden {
                    guard let cell = table.view(atColumn: index, row: row, makeIfNecessary: false) as? NSTableCellView,
                        let id = AppActivityColumn(rawValue: column.identifier.rawValue)
                    else { continue }
                    configure(cell, id, rows[row])
                }
            }
            if let id = parent.selection, let index = rows.firstIndex(where: { $0.id == id }) {
                table.selectRowIndexes([index], byExtendingSelection: false)
                // 「现在」档刷新后选中的行保持可见（D67 默认做法）。
                table.scrollRowToVisible(index)
            } else {
                table.deselectAll(nil)
            }
            applyingSelection = false
        }

        private func syncSortIndicator(_ table: NSTableView) {
            guard let first = parent.sortOrder.first,
                let column = AppActivityColumn.allCases.first(where: { $0.comparator?.keyPath == first.keyPath })
            else { return }
            let descriptor = NSSortDescriptor(key: column.rawValue, ascending: first.order == .forward)
            if table.sortDescriptors.first != descriptor { table.sortDescriptors = [descriptor] }
        }

        // MARK: 数据

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row < rows.count, let column = AppActivityColumn(rawValue: tableColumn.identifier.rawValue)
            else { return nil }
            let cell = column == .name ? nameCell(tableView) : textCell(tableView, identifier: "value")
            configure(cell, column, rows[row])
            return cell
        }

        /// 填一个单元格的内容（新建与原地更新共用）。
        private func configure(_ cell: NSTableCellView, _ column: AppActivityColumn, _ item: AppActivityRow) {
            if column == .name {
                configureName(cell, item)
                return
            }
            let (text, help) = column.text(item, isNow: parent.isNow)
            let value = text ?? "—"
            if cell.textField?.stringValue != value { cell.textField?.stringValue = value }
            cell.textField?.textColor = text == nil ? .tertiaryLabelColor : column == .sleep ? .systemOrange : .labelColor
            if cell.toolTip != help { cell.toolTip = help }
        }

        private func textCell(_ tableView: NSTableView, identifier: String) -> NSTableCellView {
            let id = NSUserInterfaceItemIdentifier(identifier)
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView { return reused }
            let cell = NSTableCellView()
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            field.alignment = .right
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func nameCell(_ tableView: NSTableView) -> NSTableCellView {
            let id = NSUserInterfaceItemIdentifier("name")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = id
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                let field = NSTextField(labelWithString: "")
                field.lineBreakMode = .byTruncatingTail
                field.translatesAutoresizingMaskIntoConstraints = false
                field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                cell.addSubview(image)
                cell.addSubview(field)
                cell.imageView = image
                cell.textField = field
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            return cell
        }

        private func configureName(_ cell: NSTableCellView, _ item: AppActivityRow) {
            cell.imageView?.image = AppIconCache.icon(path: item.appPath)
            let text = NSMutableAttributedString(string: item.name, attributes: [.foregroundColor: NSColor.labelColor])
            let secondary: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.tertiaryLabelColor]
            if let count = item.memberCount, count > 1 { text.append(NSAttributedString(string: " ×\(count)", attributes: secondary)) }
            if let member = item.topMemberName {
                text.append(NSAttributedString(string: "  \(member)", attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            }
            if cell.textField?.attributedStringValue != text { cell.textField?.attributedStringValue = text }
            if cell.toolTip != item.key { cell.toolTip = item.key }
        }

        // MARK: 选中与排序

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let table else { return }
            let index = table.selectedRow
            let id = index >= 0 && index < rows.count ? rows[index].id : nil
            if parent.selection != id { parent.selection = id }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key,
                let column = AppActivityColumn(rawValue: key), var comparator = column.comparator
            else { return }
            // 数值列第一次点按降序（从大到小），名字按升序；之后点同一列在两个方向之间切换。
            if let old = oldDescriptors.first, old.key == key {
                comparator.order = descriptor.ascending ? .forward : .reverse
            }
            if parent.sortOrder != [comparator] { parent.sortOrder = [comparator] }
        }

        // MARK: 菜单

        func headerMenu(for table: NSTableView) -> NSMenu {
            let menu = NSMenu()
            for column in AppActivityColumn.allCases where column != .name {
                let item = NSMenuItem(title: column.menuTitle, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = column.rawValue
                menu.addItem(item)
            }
            menu.delegate = self
            return menu
        }

        @objc private func toggleColumn(_ sender: NSMenuItem) {
            guard let key = sender.representedObject as? String,
                let column = table?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(key))
            else { return }
            column.isHidden.toggle()
        }

        private func actionItem(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuAction(handler)
            return item
        }

        @objc private func runMenuItem(_ sender: NSMenuItem) {
            (sender.representedObject as? MenuAction)?.handler()
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let table else { return }
            if menu === table.headerView?.menu {
                for item in menu.items {
                    guard let key = item.representedObject as? String else { continue }
                    let hidden = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(key))?.isHidden ?? true
                    item.state = hidden ? .off : .on
                }
                return
            }
            menu.removeAllItems()
            let index = table.clickedRow
            guard index >= 0, index < rows.count else { return }
            let row = rows[index]
            if let path = row.appPath {
                menu.addItem(actionItem(String(localized: "在访达中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                })
            }
            if parent.isNow, let pid = row.representativePID, row.memberCount == 1,
                ProcessControl.eligibility(uid: ProcessInfoReader.uid(of: pid), pid: pid).isAllowed
            {
                menu.addItem(actionItem(String(localized: "结束…")) {
                    ProcessTermination.confirmAndTerminate(pid: pid, name: row.name)
                })
            }
            menu.addItem(actionItem(String(localized: "拷贝名称")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.name, forType: .string)
            })
        }
    }
}

/// 菜单项的动作（放在 representedObject 里，由 Coordinator.runMenuItem 调用）。
private final class MenuAction: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
}

/// 应用图标（按路径缓存）；没有 .app 时用通用图标。与面板的 AppIcon 共用缓存规则。
enum AppIconCache {
    @MainActor private static var cache: [String: NSImage] = [:]
    @MainActor private static let generic = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) ?? NSImage()

    @MainActor static func icon(path: String?) -> NSImage {
        guard let path else { return generic }
        if let hit = cache[path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}

// MARK: - 列的文字

extension AppActivityColumn {
    var minWidth: CGFloat { self == .name ? 160 : 48 }
    var idealWidth: CGFloat {
        switch self {
        case .name: 260
        case .cpu, .gpu, .wakeups, .perfLevel0, .pageins, .members: 64
        case .cpuTime, .power, .ane, .minutes, .sleep: 80
        case .memory, .diskRead, .diskWrite: 84
        }
    }

    var hiddenByDefault: Bool { [.cpuTime, .perfLevel0, .pageins, .members, .minutes].contains(self) }

    func title(isNow: Bool) -> String {
        switch self {
        case .name: String(localized: "名称")
        case .cpu: isNow ? "CPU" : String(localized: "CPU 时间")
        case .cpuTime: String(localized: "累计 CPU 时间")
        case .power: isNow ? String(localized: "功率") : String(localized: "能耗")
        case .memory: isNow ? String(localized: "内存") : String(localized: "内存峰值")
        case .gpu: isNow ? "GPU" : String(localized: "GPU 时间")
        case .ane: isNow ? String(localized: "ANE（估算）") : String(localized: "ANE 能耗")
        case .diskRead: isNow ? String(localized: "读") : String(localized: "读取量")
        case .diskWrite: isNow ? String(localized: "写") : String(localized: "写入量")
        case .wakeups: isNow ? String(localized: "唤醒") : String(localized: "唤醒次数")
        case .sleep: String(localized: "阻止睡眠")
        case .perfLevel0: String(localized: "P0 占比")
        case .pageins: "Pageins"
        case .members: String(localized: "进程数")
        case .minutes: String(localized: "活跃分钟")
        }
    }

    /// 表头右键菜单里的名字（不随时间段变）。
    var menuTitle: String {
        switch self {
        case .cpu: "CPU"
        case .power: String(localized: "功率 / 能耗")
        case .memory: String(localized: "内存")
        case .gpu: "GPU"
        case .ane: "ANE"
        case .diskRead: String(localized: "读")
        case .diskWrite: String(localized: "写")
        case .wakeups: String(localized: "唤醒")
        default: title(isNow: true)
        }
    }

    var help: String? {
        switch self {
        case .power: String(localized: "CPU、GPU、ANE 能耗之和（coalition 记账）。「现在」为瓦，历史时段为能耗。")
        case .ane: String(localized: "ANE 能耗（coalition 记账，估算）")
        case .wakeups: String(localized: "中断唤醒与空闲唤醒次数之和")
        case .perfLevel0: String(localized: "在最快一档上运行的时间占比")
        case .sleep: String(localized: "持有阻止系统或显示器睡眠的电源断言")
        default: nil
        }
    }

    /// 单元格文字与提示；nil 显示「—」。
    func text(_ row: AppActivityRow, isNow: Bool) -> (String?, String?) {
        switch self {
        case .name: return (row.name, row.key)
        case .cpu:
            return (isNow ? row.cpu.map { PercentFormat.string(fromRatio: $0) } : row.cpuTimeNanos.map(AppActivityView.duration), nil)
        case .cpuTime: return (isNow ? row.cpuTimeNanos.map(AppActivityView.duration) : nil, nil)
        case .power:
            if isNow { return (row.watts.map(Formatting.watts), nil) }
            return (
                row.energyJoules.map { Formatting.appEnergy($0) + (row.energyPartial ? "*" : "") },
                row.energyPartial ? String(localized: "* 部分分钟的能耗未知（槽位核对未通过），只计已知部分") : nil
            )
        case .memory: return (row.footprint.flatMap { $0 > 0 ? Formatting.memory(Double($0)) : nil }, nil)
        case .gpu:
            return (
                isNow
                    ? row.gpuShare.map { PercentFormat.string(fromRatio: min($0, 1)) }
                    : row.gpuTimeNanos.map { $0 > 0 ? AppActivityView.duration($0) : "0" }, nil
            )
        case .ane: return (isNow ? row.aneWatts.map(Formatting.watts) : row.aneJoules.map(Formatting.appEnergy), nil)
        case .diskRead: return (row.diskRead.map { isNow ? Formatting.diskRate($0) : Formatting.diskBytes($0) }, nil)
        case .diskWrite: return (row.diskWrite.map { isNow ? Formatting.diskRate($0) : Formatting.diskBytes($0) }, nil)
        case .wakeups: return (row.wakeups.map { isNow ? Formatting.rate($0) : Formatting.count($0) }, nil)
        case .sleep:
            let sleeping = row.assertions.filter { $0.kind.preventsSleep }
            let help = sleeping.map {
                "\($0.name)（\($0.type)）" + ($0.isOnBehalf ? String(localized: "，经 \($0.holderName)") : "")
            }.joined(separator: "\n")
            if !isNow, let seconds = row.sleepPreventionSeconds { return (Formatting.duration(seconds), help) }
            return (sleeping.isEmpty ? "" : (sleeping.contains { $0.kind == .preventSleep } ? "☾" : "▭"), help)
        case .perfLevel0: return (row.perfLevel0Share.map { PercentFormat.string(fromRatio: $0) }, nil)
        case .pageins: return (row.pageins.map(Formatting.rate), nil)
        case .members: return (row.memberCount.map(String.init), nil)
        case .minutes: return (row.activeMinutes.map(String.init), nil)
        }
    }
}
