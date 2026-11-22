import SwiftUI
import SidebarModel

/// Split view's pane order and membership from the menus and the sidebar
/// (owner report 2026-11-22): Move Pane Left/Right (Up/Down when stacked),
/// a pane chip dragged along its split's row, Separate Page from Split
/// View on the focused pane, and a tab's Add to Split View.
extension BrowserViewModel {

    // MARK: - Move Pane

    /// The pane the View menu's split items act on: the focused pane of the
    /// key window's split.
    var focusedSplitPane: (split: SplitViewItem, tabID: Tab.ID)? {
        guard let tab = store.selectedTab, let split = store.splitContaining(tabID: tab.id)?.split else { return nil }
        return (split, tab.id)
    }

    /// A pane's two move items, for its split menu and its chip's menu.
    func splitPaneMoves(for tabID: Tab.ID) -> [SplitPaneMove] {
        store.splitContaining(tabID: tabID)?.split.paneMoves(for: tabID) ?? []
    }

    /// The View menu's move item for the focused pane. With no split it
    /// keeps its side-by-side name and is disabled.
    func focusedSplitPaneMove(offset: Int) -> SplitPaneMove {
        focusedSplitPane.flatMap { pane in pane.split.paneMoves(for: pane.tabID).first { $0.offset == offset } }
            ?? SplitPaneMove(offset: offset, title: SplitPaneMove.title(offset: offset, orientation: .horizontal), isEnabled: false)
    }

    /// Move Pane Left/Right/Up/Down: the pane goes one place along its
    /// split and keeps its width and the focus. The pages stay as they are;
    /// only where their views sit changes.
    @discardableResult
    func moveSplitPane(_ tabID: Tab.ID, by offset: Int) -> Bool {
        guard let split = store.splitContaining(tabID: tabID)?.split,
              store.canMoveSplitPane(splitID: split.id, tabID: tabID, by: offset) else { return false }
        withAnimation(.easeInOut(duration: 0.2)) { _ = store.moveSplitPane(splitID: split.id, tabID: tabID, by: offset) }
        return true
    }

    @discardableResult
    func moveFocusedSplitPane(by offset: Int) -> Bool {
        guard let pane = focusedSplitPane else { return false }
        return moveSplitPane(pane.tabID, by: offset)
    }

    // MARK: - A chip dragged along its row

    /// A sidebar drag began on `entry`'s row. On a pane's chip of an
    /// unnamed split it may reorder the panes; anywhere else it is the row
    /// drag it always was.
    func sidebarDragBegan(on entry: SidebarEntry) {
        guard case .split(let split) = entry, !split.showsAsNamedRow, let hovered = hoveredSplitPaneChip,
              hovered.splitID == split.id, split.tabs.contains(where: { $0.id == hovered.tabID }) else {
            if splitPaneChipDrag != nil { splitPaneChipDrag = nil }
            return
        }
        splitPaneChipDrag = SplitPaneChipDrag(splitID: split.id, tabID: hovered.tabID)
    }

    /// A drag began on a pane's own chip (`SplitRowView`'s chips are drag
    /// sources themselves): the pane is known from the chip, with no need
    /// of the hover. The split's row is still what the drag carries.
    func splitPaneChipDragBegan(_ tabID: Tab.ID, in split: SplitViewItem) {
        guard !split.showsAsNamedRow, split.tabs.contains(where: { $0.id == tabID }) else {
            if splitPaneChipDrag != nil { splitPaneChipDrag = nil }
            return
        }
        splitPaneChipDrag = SplitPaneChipDrag(splitID: split.id, tabID: tabID)
    }

    /// Whether the sidebar opens its drop areas for the drag of `dragged`
    /// (`SidebarDragLayout`): not for a chip still along its own row, whose
    /// rows must stay under the pointer.
    func sidebarOpensDropAreas(dragging dragged: UUID?) -> Bool {
        SidebarDragLayout.opensDropAreas(dragging: dragged, chipDrag: splitPaneChipDrag)
    }

    /// The pointer left the row of the chip being dragged (or is over
    /// another drop target): the drag is the row's own from here on.
    func splitPaneChipDragLeftRow() {
        guard splitPaneChipDrag?.hasLeftRow == false else { return }
        splitPaneChipDrag?.leaveRow()
    }

    /// The pointer went on or off a pane's chip. Not observed: only the
    /// start of a drag reads it.
    func splitPaneChipHovered(_ hovering: Bool, tabID: Tab.ID, in splitID: SplitViewItem.ID) {
        if hovering {
            hoveredSplitPaneChip = (splitID, tabID)
        } else if hoveredSplitPaneChip?.tabID == tabID {
            hoveredSplitPaneChip = nil
        }
    }

    /// The place the dragged chip would take at `x` of `split`'s chips
    /// (`width` wide in all); nil when this drag reorders nothing there.
    func splitPaneChipDestination(in split: SplitViewItem, x: Double, width: Double) -> Int? {
        guard let drag = splitPaneChipDrag, drag.splitID == split.id, !split.showsAsNamedRow,
              let source = split.tabs.firstIndex(where: { $0.id == drag.tabID }) else { return nil }
        return SplitPaneChipDrag.destination(from: source, x: x, width: width, count: split.tabs.count)
    }

    /// The drag moved over `split`'s row: where the insertion line shows.
    func splitPaneChipDragMoved(to destination: Int?, in split: SplitViewItem) {
        guard splitPaneChipDrag?.splitID == split.id, splitPaneChipDrag?.destination != destination else { return }
        splitPaneChipDrag?.destination = destination
    }

    /// The chip was dropped on another chip's place in its own row.
    @discardableResult
    func dropSplitPaneChip(in split: SplitViewItem, at destination: Int) -> Bool {
        guard let drag = splitPaneChipDrag, drag.splitID == split.id else { return false }
        splitPaneChipDrag = nil
        var moved = false
        withAnimation(.easeInOut(duration: 0.15)) {
            moved = store.moveSplitPane(splitID: split.id, tabID: drag.tabID, to: destination)
        }
        return moved
    }

    /// The drag is over, wherever it ended.
    func sidebarDragEnded() {
        if splitPaneChipDrag != nil { splitPaneChipDrag = nil }
    }

    // MARK: - Separate Page from Split View

    /// Arc's View › Separate Page from Split View: the focused pane goes
    /// back to the sidebar as a tab of its own and the split keeps the rest.
    func separateFocusedPageFromSplit() {
        guard let pane = focusedSplitPane else { return }
        unsplitTabIfInSplit(pane.tabID)
    }

    // MARK: - Add to Split View

    /// The splits a row menu's Add to Split View lists for these rows: the
    /// space's splits with room for all of them.
    func addToSplitChoices(for ids: [UUID]) -> [SplitViewItem] {
        store.splitsAccepting(ids)
    }

    /// Add to Split View › a split: the tabs become its last panes and the
    /// split is shown.
    func addTabs(_ ids: [UUID], toSplit splitID: SplitViewItem.ID) {
        closeLibrary()
        guard store.addTabs(ids, toSplit: splitID) else {
            if store.split(withID: splitID)?.isFull == true { showSplitFullToast() }
            return
        }
        store.clearMultiSelection(in: store.keyWindowID)
        loadSelectedIfNeeded()
    }
}
