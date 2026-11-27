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
    /// A row or header menu is open. The table holds still under it: a
    /// reading that redraws or re-sorts the rows while AppKit tracks the menu
    /// moved the menu away from the pointer and left it dead (owner, RC 1447).
    private(set) var isMenuOpen = false
    /// A change came while a menu was open; applied when it closes.
    private(set) var hasDeferredRebuild = false

    static let taskCellID = NSUserInterfaceItemIdentifier("TaskManagerTaskCell")
    static let figureCellID = NSUserInterfaceItemIdentifier("TaskManagerFigureCell")

    init(controller: TaskManagerController) {
        self.controller = controller
    }

    func makeScrollView() -> NSScrollView {
        let table = TaskManagerTableView()
        table.disclose = { [weak self] open in self?.discloseSelectedStacks(open) }
        for column in TaskManagerColumn.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            let width = TaskManagerMetrics.width(of: column)
            tableColumn.title = column.title
            tableColumn.width = width.ideal
            tableColumn.minWidth = width.minimum
            tableColumn.headerCell.alignment = Self.alignment(of: column)
            tableColumn.headerToolTip = headerHelp(column)
            // Names sort from A first, figures from the largest first.
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: !column.isFigure)
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
        let menu = NSMenu.darniContextMenu()
        menu.delegate = self
        table.headerView?.menu = menu
        // A row: double-click or Show Tab brings a tab or a frame's tab forward.
        let rowMenu = NSMenu.darniContextMenu()
        rowMenu.delegate = self
        table.menu = rowMenu
        table.target = self
        table.doubleAction = #selector(showClickedTab(_:))
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
    private func observedState()
        -> (rows: [TaskManagerRow], columns: TaskManagerColumns, selection: Set<TaskManagerSelectionKey>, sleep: TaskManagerSleepSettings?) {
        generation += 1
        let current = generation
        return withObservationTracking {
            (controller.rows, controller.columns, controller.selection, controller.sleepSettings)
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
        guard !isMenuOpen else {
            hasDeferredRebuild = true
            return
        }
        let state = observedState()
        for tableColumn in table.tableColumns {
            guard let column = TaskManagerColumn(rawValue: tableColumn.identifier.rawValue) else { continue }
            let hidden = !state.columns.isVisible(column)
            if tableColumn.isHidden != hidden { tableColumn.isHidden = hidden }
            if column == .state, tableColumn.headerToolTip != headerHelp(column) { tableColumn.headerToolTip = headerHelp(column) }
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
        let selected = TaskManagerSelection.selected(keys: rows.map(\.selectionKeys), by: state.selection)
        if table.selectedRowIndexes != selected { table.selectRowIndexes(selected, byExtendingSelection: false) }
    }

    private static func alignment(of column: TaskManagerColumn) -> NSTextAlignment {
        column.isFigure ? .right : .left
    }

    /// The header's tooltip: what State, Idle and a stack's figures mean.
    private func headerHelp(_ column: TaskManagerColumn) -> String? {
        switch column {
        case .state: return TaskManagerHelp.state(controller.sleepSettings)
        case .idle: return TaskManagerHelp.idle
        case .memoryFootprint, .cpu, .network: return TaskManagerHelp.estimate
        case .task, .profile, .processID: return nil
        }
    }

    /// The stock pictures, made once: a cell keeps its picture from one
    /// reading to the next when it is the same object.
    private static let pageSymbol = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    private static let helperSymbol = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)

    private func image(for icon: TaskManagerTask.Icon) -> NSImage? {
        if let image = controller.source.icon(for: icon) { return image }
        switch icon {
        case .browser: return NSApp.applicationIconImage
        case .tab, .sidebarTab: return Self.pageSymbol
        case .frame: return Self.frameSymbol
        // Chrome's puzzle piece, for extensions and for the engine's helpers.
        case .browserExtension, .system: return Self.helperSymbol
        }
    }

    private static let frameSymbol = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)

    // MARK: Stacks

    private func toggle(_ row: TaskManagerRow) {
        controller.toggleExpanded(row.stackID, all: NSApp.currentEvent?.modifierFlags.contains(.option) ?? false)
    }

    /// → and ← on the selected stacks, as in a Finder list.
    private func discloseSelectedStacks(_ open: Bool) {
        guard let table = tableView else { return }
        for index in table.selectedRowIndexes where rows.indices.contains(index) {
            let row = rows[index]
            guard row.level == 0, row.disclosure != .none, (row.disclosure == .expanded) != open else { continue }
            controller.toggleExpanded(row.stackID)
        }
    }

    // MARK: Show Tab

    /// A tab's row shows the tab; Darni's own row opens or closes.
    @objc private func showClickedTab(_ sender: Any?) {
        guard let table = tableView, rows.indices.contains(table.clickedRow) else { return }
        let row = rows[table.clickedRow]
        if row.tab == nil, row.disclosure != .none { return toggle(row) }
        controller.showTab(of: row)
    }

    private func fillRowMenu(_ menu: NSMenu) {
        guard let table = tableView, rows.indices.contains(table.clickedRow) else { return }
        let row = rows[table.clickedRow]
        let show = ClosureMenuItem(row.isUnloaded ? "Show and Load Tab" : "Show Tab") { [weak self] in self?.controller.showTab(of: row) }
        show.isEnabled = controller.canShowTab(of: row)
        menu.addItem(show)
        menu.addItem(.separator())
        let ids = controller.stacks.filter(\.hasChildren).map(\.id)
        let expand = ClosureMenuItem("Expand All") { [weak self] in self?.controller.expanded.formUnion(ids) }
        expand.isEnabled = !Set(ids).isSubset(of: controller.expanded)
        let collapse = ClosureMenuItem("Collapse All") { [weak self] in self?.controller.expanded = [] }
        collapse.isEnabled = !controller.expanded.isEmpty
        menu.addItem(expand)
        menu.addItem(collapse)
    }

    // MARK: Header menu

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        guard hasDeferredRebuild else { return }
        hasDeferredRebuild = false
        // After the chosen item's action, which AppKit sends once the menu is gone.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Never rebuild a menu that is on screen: its items would shift under the pointer.
        guard !isMenuOpen else { return }
        menu.removeAllItems()
        if menu === tableView?.menu { return fillRowMenu(menu) }
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
            cell.configure(item, icon: image(for: item.icon)) { [weak self] in self?.toggle(item) }
            return cell
        }
        let cell = tableView.makeView(withIdentifier: Self.figureCellID, owner: nil) as? TaskManagerFigureCell ?? TaskManagerFigureCell()
        let tip: String?
        switch column {
        case .state: tip = item.sleep?.state.explanation
        case .memoryFootprint, .cpu, .network: tip = item.isEstimate ? "Estimate: the total of the processes under this row. Shared processes count their share." : nil
        default: tip = nil
        }
        cell.configure(text: item.text(for: column), alignment: Self.alignment(of: column), toolTip: tip)
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        let sort = tableView.sortDescriptors.first.flatMap { descriptor in
            descriptor.key.flatMap(TaskManagerColumn.init(rawValue:)).map { TaskManagerSort(column: $0, ascending: descriptor.ascending) }
        }
        if controller.sort != sort { controller.sort = sort }
    }

    /// A process is selected whole (`TaskManagerSelection`).
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        TaskManagerSelection.rows(
            proposed: proposed, current: tableView.selectedRowIndexes, keys: rows.map(\.selectionKeys),
            toggles: NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        )
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !appliesSelection, let table = tableView else { return }
        let selection = Set(table.selectedRowIndexes.filter(rows.indices.contains).flatMap { rows[$0].selectionKeys })
        if controller.selection != selection { controller.selection = selection }
    }
}

/// The table: → and ← open and close the selected stacks.
final class TaskManagerTableView: NSTableView {
    var disclose: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .rightArrow?: disclose?(true)
        case .leftArrow?: disclose?(false)
        default: super.keyDown(with: event)
        }
    }
}

/// The Task column's cell: a stack's disclosure chevron, the task's icon,
/// its name, and a grey note (which tab a frame is in, who shares the process).
final class TaskManagerTaskCell: NSTableCellView {
    private let disclosure = NSButton()
    private let note = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint!
    private var onToggle: (() -> Void)?

    private static let closed = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Show processes")
    private static let open = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Hide processes")

    init() {
        super.init(frame: .zero)
        identifier = TaskManagerTableController.taskCellID
        disclosure.isBordered = false
        disclosure.imagePosition = .imageOnly
        disclosure.imageScaling = .scaleProportionallyDown
        disclosure.contentTintColor = .secondaryLabelColor
        disclosure.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        disclosure.target = self
        disclosure.action = #selector(toggle)
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        // The title gives way after the note.
        label.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        note.lineBreakMode = .byTruncatingTail
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(disclosure)
        addSubview(icon)
        addSubview(label)
        addSubview(note)
        imageView = icon
        textField = label
        leading = disclosure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TaskManagerMetrics.cellInset)
        NSLayoutConstraint.activate([
            leading,
            disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: TaskManagerMetrics.disclosureWidth),
            disclosure.heightAnchor.constraint(equalToConstant: TaskManagerMetrics.iconSize),
            icon.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: TaskManagerMetrics.iconSize),
            icon.heightAnchor.constraint(equalToConstant: TaskManagerMetrics.iconSize),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: TaskManagerMetrics.cellInset),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -TaskManagerMetrics.cellInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            note.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: TaskManagerMetrics.cellInset),
            note.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -TaskManagerMetrics.cellInset),
            note.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func toggle() { onToggle?() }

    func configure(_ row: TaskManagerRow, icon: NSImage?, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        let inset = TaskManagerMetrics.cellInset + CGFloat(row.level) * TaskManagerMetrics.indent
        if leading.constant != inset { leading.constant = inset }
        disclosure.isHidden = row.disclosure == .none
        let chevron = row.disclosure == .expanded ? Self.open : Self.closed
        if disclosure.image !== chevron { disclosure.image = chevron }
        disclosure.setAccessibilityLabel(row.disclosure == .expanded ? "Hide processes" : "Show processes")
        if textField?.stringValue != row.title { textField?.stringValue = row.title }
        if note.stringValue != row.note { note.stringValue = row.note }
        if imageView?.image !== icon { imageView?.image = icon }
        // Unloaded: dimmed, as its row in the sidebar.
        imageView?.alphaValue = row.isUnloaded ? 0.45 : 1
        // A long page title is cut short; the tooltip has all of it.
        toolTip = row.note.isEmpty ? row.title : "\(row.title)\n\(row.note)"
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

    func configure(text: String, alignment: NSTextAlignment, toolTip: String? = nil) {
        if textField?.stringValue != text { textField?.stringValue = text }
        if textField?.alignment != alignment { textField?.alignment = alignment }
        if self.toolTip != toolTip { self.toolTip = toolTip }
    }
}
