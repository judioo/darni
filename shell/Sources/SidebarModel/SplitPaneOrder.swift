import Foundation

/// One of a pane's two move commands (Arc's split context menu has a move
/// per direction, `icon-split-move-*`): "Move Pane Left" and "Move Pane
/// Right" side by side, "Move Pane Up" and "Move Pane Down" when stacked.
/// The pane's own split menu, the sidebar row's menu and the View menu all
/// show these, so they name and disable the same things.
public struct SplitPaneMove: Equatable, Identifiable, Sendable {
    /// -1 towards the first pane (left or up), 1 towards the last.
    public var offset: Int
    public var title: String
    /// False at the end the pane already sits on.
    public var isEnabled: Bool

    public var id: Int { offset }

    public init(offset: Int, title: String, isEnabled: Bool) {
        self.offset = offset
        self.title = title
        self.isEnabled = isEnabled
    }

    public static func title(offset: Int, orientation: SplitLayoutOrientation) -> String {
        switch (orientation, offset < 0) {
        case (.horizontal, true): return "Move Pane Left"
        case (.horizontal, false): return "Move Pane Right"
        case (.vertical, true): return "Move Pane Up"
        case (.vertical, false): return "Move Pane Down"
        }
    }
}

extension SplitViewItem {
    /// The two moves of `tabID`, towards the first pane then towards the
    /// last; none for a tab that is not a pane of this split.
    public func paneMoves(for tabID: Tab.ID) -> [SplitPaneMove] {
        guard tabs.contains(where: { $0.id == tabID }) else { return [] }
        return [-1, 1].map { offset in
            SplitPaneMove(
                offset: offset,
                title: SplitPaneMove.title(offset: offset, orientation: orientation),
                isEnabled: canMovePane(tabID, by: offset)
            )
        }
    }

    /// Whether pane `tabID` can go `offset` places along the split: it is a
    /// pane, the offset is not 0, and the place is not past either end. The
    /// one rule for the menus' items and the store's move.
    public func canMovePane(_ tabID: Tab.ID, by offset: Int) -> Bool {
        guard offset != 0, let index = tabs.firstIndex(where: { $0.id == tabID }) else { return false }
        return tabs.indices.contains(index + offset)
    }

    /// How a menu names the split, as its sidebar row reads: its name (or
    /// "N Tabs" under an icon of its own), else its panes' titles.
    public var menuTitle: String {
        guard !showsAsNamedRow else { return displayTitle }
        return tabs.map { tab in
            let title = tab.displayTitle
            return title.count > Self.menuPaneTitleLimit ? String(title.prefix(Self.menuPaneTitleLimit - 1)) + "…" : title
        }
        .joined(separator: " | ")
    }

    /// Characters of one pane's title in `menuTitle`: four long titles
    /// would make a menu as wide as the screen.
    static let menuPaneTitleLimit = 28
}

/// A pane chip dragged along its split's sidebar row (Arc reorders a
/// split's panes this way). The row itself is what is dragged, as before:
/// off the row the drag moves the whole split. Over the row's other chips
/// it reorders the panes.
public struct SplitPaneChipDrag: Equatable, Sendable {
    public var splitID: SplitViewItem.ID
    public var tabID: Tab.ID
    /// The place the pane takes if it is dropped now; nil over its own chip
    /// and off the row.
    public var destination: Int?
    /// The pointer has been off the split's row since the drag began. From
    /// then on the drag is a row's like any other, and the sidebar opens
    /// its drop areas for it.
    public var hasLeftRow: Bool

    public init(splitID: SplitViewItem.ID, tabID: Tab.ID, destination: Int? = nil, hasLeftRow: Bool = false) {
        self.splitID = splitID
        self.tabID = tabID
        self.destination = destination
        self.hasLeftRow = hasLeftRow
    }

    /// Along its own row the chip is dragged over rows that stay where they
    /// are: the sidebar's drop areas (`SidebarDragLayout`) wait until the
    /// pointer leaves the row. Opening them as the drag began moved the row
    /// down from under a pointer that had not moved, and a drag straight
    /// along the row reordered nothing (found on screen 2026-11-22).
    public var holdsRowsInPlace: Bool { !hasLeftRow }

    /// The pointer left the split's row: no place there any more, and the
    /// rows are free to make room.
    public mutating func leaveRow() {
        hasLeftRow = true
        destination = nil
    }

    /// The chips share the row's width equally, so the chip under the
    /// pointer is known from the pointer alone: the index of the chip at
    /// `x` in chips `width` wide in all. A point past either end counts as
    /// the chip at that end.
    public static func chipIndex(x: Double, width: Double, count: Int) -> Int? {
        guard count > 0, width > 0 else { return nil }
        let inside = min(max(x, 0), width)
        return min(Int(inside / (width / Double(count))), count - 1)
    }

    /// The index the pane at `source` takes when dropped on the chip at
    /// `x`: that chip's place. Nil over its own chip.
    public static func destination(from source: Int, x: Double, width: Double, count: Int) -> Int? {
        guard let target = chipIndex(x: x, width: width, count: count), target != source else { return nil }
        return target
    }

    /// The gap the pane lands in, for the insertion line: a chip boundary
    /// from 0 (before the first chip) to the chip count (after the last).
    public static func boundary(from source: Int, to destination: Int) -> Int {
        destination > source ? destination + 1 : destination
    }

    /// The insertion line's boundary in `split`'s row, if this drag would
    /// move a pane of it.
    public func boundary(in split: SplitViewItem) -> Int? {
        guard splitID == split.id, let destination,
              let source = split.tabs.firstIndex(where: { $0.id == tabID }), destination != source else { return nil }
        return Self.boundary(from: source, to: destination)
    }
}

/// The room the sidebar makes for a drag. While one is under way it shows
/// drop areas that are not there otherwise: the Favorites row's end zone
/// above the list (18 pt, 34 with no favorites yet) and a drop row after
/// each section (`SidebarListRow.sectionEnd`, 10 pt or the "Drop here to
/// pin" placeholder). Each one moves every row under it down.
public enum SidebarDragLayout {
    /// Whether those areas are open for the drag of the row `dragged`: for
    /// any drag, except a pane chip's while it is still along its own row.
    /// A chip drag of another split (one left over) holds nothing.
    public static func opensDropAreas(dragging dragged: UUID?, chipDrag: SplitPaneChipDrag?) -> Bool {
        guard let dragged else { return false }
        if let chipDrag, chipDrag.splitID == dragged, chipDrag.holdsRowsInPlace { return false }
        return true
    }
}

extension SidebarStore {

    // MARK: - Pane order

    /// Moves a pane to `index` in its split's order (the index it has once
    /// it is there; past the end is the last place). The pane keeps its
    /// width, which goes by tab, and takes the focus. False, with nothing
    /// changed, when the pane is already there or is not in the split.
    @discardableResult
    public func moveSplitPane(splitID: SplitViewItem.ID, tabID: Tab.ID, to index: Int) -> Bool {
        guard var split = split(withID: splitID),
              let from = split.tabs.firstIndex(where: { $0.id == tabID }) else { return false }
        let destination = min(max(index, 0), split.tabs.count - 1)
        guard destination != from else { return false }
        let pane = split.tabs.remove(at: from)
        split.tabs.insert(pane, at: destination)
        split.focusTabID = tabID
        replaceSplit(split)
        if selectedItemID == splitID, tab(withID: tabID)?.isUnread == true {
            _ = updateTabInStore(tabID) { $0.isUnread = false }
        }
        // The order is the item record's `tabs`: it syncs as any edit of the split.
        notifyMutation(.upsertItem(id: splitID))
        return true
    }

    /// Moves a pane one place (or `offset` places) along its split. At the
    /// end it already sits on, nothing moves and this is false.
    @discardableResult
    public func moveSplitPane(splitID: SplitViewItem.ID, tabID: Tab.ID, by offset: Int) -> Bool {
        guard canMoveSplitPane(splitID: splitID, tabID: tabID, by: offset),
              let from = split(withID: splitID)?.tabs.firstIndex(where: { $0.id == tabID }) else { return false }
        return moveSplitPane(splitID: splitID, tabID: tabID, to: from + offset)
    }

    public func canMoveSplitPane(splitID: SplitViewItem.ID, tabID: Tab.ID, by offset: Int) -> Bool {
        split(withID: splitID)?.canMovePane(tabID, by: offset) ?? false
    }

    // MARK: - Add to Split View

    /// The splits a tab's "Add to Split View" menu lists: those of the
    /// tabs' space with room for all of them, in sidebar order. The rules
    /// are Split with Current Tab's: plain tabs of one space, no favorites,
    /// no tab group's tabs, none already a pane. Empty when any row given
    /// is not such a tab.
    public func splitsAccepting(_ ids: [UUID]) -> [SplitViewItem] {
        guard let first = ids.first, Set(ids).count == ids.count,
              let spaceID = spaceContaining(tabID: first) else { return [] }
        let content = content(for: spaceID)
        return (content.pinned + content.today).compactMap { entry -> SplitViewItem? in
            guard case .split(let split) = entry, canAdd(ids, toSplit: split.id) else { return nil }
            return split
        }
    }

    /// Whether every one of `ids` can join the split and they all fit in
    /// its four panes.
    public func canAdd(_ ids: [UUID], toSplit splitID: SplitViewItem.ID) -> Bool {
        guard let split = split(withID: splitID), !ids.isEmpty, Set(ids).count == ids.count,
              split.tabs.count + ids.count <= SplitViewItem.maxPanes else { return false }
        return ids.allSatisfy { isSplitCandidate($0, joining: split.focusTabID) }
    }

    /// Add to Split View: the tabs become the split's last panes, in the
    /// order given, and the split is shown with the last of them focused.
    /// All or none: nothing changes unless every tab can join.
    @discardableResult
    public func addTabs(_ ids: [UUID], toSplit splitID: SplitViewItem.ID) -> Bool {
        guard canAdd(ids, toSplit: splitID), let anchor = split(withID: splitID)?.focusTabID else { return false }
        for id in ids {
            guard splitTab(id, with: anchor) != nil else { return false }
        }
        return true
    }
}
