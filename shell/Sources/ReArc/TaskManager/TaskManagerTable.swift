import AppKit
import SidebarModel
import SwiftUI

/// The Task Manager's table: an AppKit table with real columns, so the
/// header sorts on a click and offers its columns on a right-click, as
/// Chrome's does. The rows come from `TaskManagerController`; this file
/// only draws them.
struct TaskManagerTable: NSViewRepresentable {
    let controller: TaskManagerController

    func makeCoordinator() -> TaskManagerTableController {
        TaskManagerTableController(controller: controller)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}

    static func dismantleNSView(_ view: NSScrollView, coordinator: TaskManagerTableController) {
        coordinator.invalidate()
    }

    /// Takes the size it is offered: the window never measures the rows.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// The table's data source and delegate. It observes the controller's rows,
/// columns and selection and applies a change on the next main turn: a
/// reading that only moved figures redraws those rows in place, so the
/// selection and the scroll position stay where they are.
@MainActor
final class TaskManagerTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let controller: TaskManagerController
    private(set) var rows: [TaskManagerRow] = []
    private weak var tableView: NSTableView?
    private var isActive = true
    /// Bumped per observation; only the latest one's change rebuilds.
    private var generation = 0
    /// The table's selection is being set from the controller's, not by the user.
    private var appliesSelection = false

    static let taskCellID = NSUserInterfaceItemIdentifier("TaskManagerTaskCell")
    static let figureCellID = NSUserInterfaceItemIdentifier("TaskManagerFigureCell")

    init(controller: TaskManagerController) {
        self.controller = controller
    }

    func makeScrollView() -> NSScrollView {
        let table = NSTableView()
        for column in TaskManagerColumn.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            let width = TaskManagerMetrics.width(of: column)
            tableColumn.title = column.title
            tableColumn.width = width.ideal
            tableColumn.minWidth = width.minimum
            tableColumn.headerCell.alignment = Self.alignment(of: column)
            // Names sort from A first, figures from the largest first.
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: !column.isSharedByGroup)
            tableColumn.resizingMask = column == .task ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            tableColumn.isHidden = !controller.columns.isVisible(column)
            table.addTableColumn(tableColumn)
        }
        table.style = .fullWidth
        table.rowSizeStyle = .custom
        table.rowHeight = TaskManagerMetrics.rowHeight
        table.usesAutomaticRowHeights = false
        table.usesAlternatingRowBackgroundColors = false
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.allowsTypeSelect = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        // A right-click on the header: Chrome's column chooser.
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        table.headerView?.menu = menu
        table.setAccessibilityLabel("Tasks")
        tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        rebuild()
        return scroll
    }

    func invalidate() {
        isActive = false
        tableView?.dataSource = nil
        tableView?.delegate = nil
    }

    // MARK: Rows

    /// Reads what the table shows under observation; any change rebuilds
    /// once, on the next main turn.
    private func observedState() -> (rows: [TaskManagerRow], columns: TaskManagerColumns, selection: Set<Int32>) {
        generation += 1
        let current = generation
        return withObservationTracking {
            (controller.rows, controller.columns, controller.selection)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    self.rebuild()
                }
            }
        }
    }

    private func rebuild() {
        guard isActive, let table = tableView else { return }
        let state = observedState()
        for tableColumn in table.tableColumns {
            guard let column = TaskManagerColumn(rawValue: tableColumn.identifier.rawValue) else { continue }
            let hidden = !state.columns.isVisible(column)
            if tableColumn.isHidden != hidden { tableColumn.isHidden = hidden }
        }
        let old = rows
        rows = state.rows
        appliesSelection = true
        defer { appliesSelection = false }
        if old.map(\.id) == rows.map(\.id) {
            let changed = IndexSet(rows.indices.filter { rows[$0] != old[$0] })
            if !changed.isEmpty {
                table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0 ..< table.numberOfColumns))
            }
        } else {
            table.reloadData()
        }
        let selected = IndexSet(rows.indices.filter { state.selection.contains(rows[$0].pid) })
        if table.selectedRowIndexes != selected { table.selectRowIndexes(selected, byExtendingSelection: false) }
    }

    private static func alignment(of column: TaskManagerColumn) -> NSTextAlignment {
        column.isSharedByGroup ? .right : .left
    }

    private func image(for icon: TaskManagerTask.Icon) -> NSImage? {
        if let image = controller.source.icon(for: icon) { return image }
        switch icon {
        case .browser: return NSApp.applicationIconImage
        case .tab: return NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        // Chrome's puzzle piece, for extensions and for the engine's helpers.
        case .browserExtension, .system: return NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
        }
    }

    // MARK: Header menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for column in TaskManagerColumn.allCases {
            let item = ClosureMenuItem(column.title) { [weak self] in self?.controller.columns.toggle(column) }
            item.state = controller.columns.isVisible(column) ? .on : .off
            item.isEnabled = column.canHide
            menu.addItem(item)
        }
    }

    // MARK: NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let tableColumn,
              let column = TaskManagerColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let item = rows[row]
        if column == .task {
            let cell = tableView.makeView(withIdentifier: Self.taskCellID, owner: nil) as? TaskManagerTaskCell ?? TaskManagerTaskCell()
            cell.configure(title: item.title, icon: image(for: item.icon))
            return cell
        }
        let cell = tableView.makeView(withIdentifier: Self.figureCellID, owner: nil) as? TaskManagerFigureCell ?? TaskManagerFigureCell()
        cell.configure(text: item.text(for: column), alignment: Self.alignment(of: column))
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        let sort = tableView.sortDescriptors.first.flatMap { descriptor in
            descriptor.key.flatMap(TaskManagerColumn.init(rawValue:)).map { TaskManagerSort(column: $0, ascending: descriptor.ascending) }
        }
        if controller.sort != sort { controller.sort = sort }
    }

    /// A process is selected whole: a click on one of its tasks takes them
    /// all, and a ⌘-click on a selected one lets them all go.
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        func pids(_ indexes: IndexSet) -> Set<Int32> {
            Set(indexes.compactMap { rows.indices.contains($0) ? rows[$0].pid : nil })
        }
        let wanted = pids(proposed).subtracting(pids(tableView.selectedRowIndexes.subtracting(proposed)))
        return IndexSet(rows.indices.filter { wanted.contains(rows[$0].pid) })
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !appliesSelection, let table = tableView else { return }
        let selection = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].pid : nil })
        if controller.selection != selection { controller.selection = selection }
    }
}

/// The Task column's cell: the task's icon and its name.
final class TaskManagerTaskCell: NSTableCellView {
    init() {
        super.init(frame: .zero)
        identifier = TaskManagerTableController.taskCellID
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(icon)
        addSubview(label)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TaskManagerMetrics.cellInset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: TaskManagerMetrics.iconSize),
            icon.heightAnchor.constraint(equalToConstant: TaskManagerMetrics.iconSize),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: TaskManagerMetrics.cellInset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -TaskManagerMetrics.cellInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(title: String, icon: NSImage?) {
        if textField?.stringValue != title { textField?.stringValue = title }
        if imageView?.image !== icon { imageView?.image = icon }
        // A long page title is cut short; the tooltip has all of it.
        toolTip = title
    }
}

/// A cell of plain text: the profile's name or one of the process's figures.
final class TaskManagerFigureCell: NSTableCellView {
    init() {
        super.init(frame: .zero)
        identifier = TaskManagerTableController.figureCellID
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        // Figures keep their place from one reading to the next.
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TaskManagerMetrics.cellInset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -TaskManagerMetrics.cellInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(text: String, alignment: NSTextAlignment) {
        if textField?.stringValue != text { textField?.stringValue = text }
        if textField?.alignment != alignment { textField?.alignment = alignment }
    }
}
