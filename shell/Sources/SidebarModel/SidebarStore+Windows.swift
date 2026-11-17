import Foundation

/// Identifies one browser window for per-window sidebar state.
public struct SidebarWindowID: Hashable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// What a window other than the key window shows: its space, and the item
/// selected there (nil: the space with nothing selected).
public struct WindowSelection: Hashable, Sendable {
    public var spaceID: Space.ID
    public var itemID: UUID?
    public init(spaceID: Space.ID, itemID: UUID?) {
        self.spaceID = spaceID
        self.itemID = itemID
    }
}

/// Per-window focused space and selection (SIDEBAR-SPEC §2.6, DATA-SCHEMA
/// StorableWindows). Every window shows its own space; the spaces and their
/// content are shared. `activeSpaceID` and `selectedItemID` belong to the key
/// window, so menus, shortcuts and the command bar act on it. A window that
/// becomes key brings its space and its own selection back; the other windows
/// keep theirs (`selectionByWindow`). Two windows on one space are separate
/// browsers: an item shows in one window at a time, so selecting it in one
/// window leaves the other on the same space with nothing selected (owner,
/// 2026-11-17: navigation in one window moved the other, and a call's video
/// had two homes).
extension SidebarStore {

    /// A new window starts on the key window's space.
    public func registerWindow(_ window: SidebarWindowID, spaceID: Space.ID? = nil) {
        let space = spaceID.flatMap { listedSpace(withID: $0)?.id } ?? activeSpaceID
        focusedSpaceByWindow[window] = space
        if keyWindowID == nil { keyWindowID = window }
    }

    public func unregisterWindow(_ window: SidebarWindowID) {
        focusedSpaceByWindow[window] = nil
        selectionByWindow[window] = nil
        if keyWindowID == window { keyWindowID = nil }
    }

    /// The window became key: its space becomes the active space (and its
    /// profile the active profile), with that space's remembered selection.
    /// The window's own selection comes back with it; the window it takes
    /// over from keeps what it showed. A window with no selection of its own
    /// (a new one) on the space another window shows starts with nothing selected.
    public func windowBecameKey(_ window: SidebarWindowID) {
        let target = focusedSpaceByWindow[window].flatMap { listedSpace(withID: $0)?.id } ?? activeSpaceID
        let previous = keyWindowID
        guard previous != window else {
            if target != activeSpaceID { selectSpace(target) }
            focusedSpaceByWindow[window] = activeSpaceID
            return
        }
        let own = ownSelection(of: window, in: target)
        if let previous, focusedSpaceByWindow[previous] != nil {
            selectionByWindow[previous] = WindowSelection(spaceID: activeSpaceID, itemID: selectedItemID)
        }
        let sharedSpace = previous != nil && target == activeSpaceID
        keyWindowID = window
        selectionByWindow[window] = nil
        if target != activeSpaceID { selectSpace(target) }
        if let own {
            selectedItemID = own
        } else if sharedSpace {
            selectedItemID = nil
        }
        focusedSpaceByWindow[window] = activeSpaceID
    }

    /// The item `window` shows: the key window's is `selectedItemID`. Another
    /// window's is its own, while it is still in its space; failing that, its
    /// space's remembered one unless the key window already shows it.
    public func selectedItemID(in window: SidebarWindowID?) -> UUID? {
        guard let window, isOtherWindow(window) else { return selectedItemID(inSpace: focusedSpaceID(in: window)) }
        let spaceID = focusedSpaceID(in: window)
        if let own = ownSelection(of: window, in: spaceID) { return own }
        let remembered = selectedItemID(inSpace: spaceID)
        return remembered == selectedItemID ? nil : remembered
    }

    /// The tab `window`'s content area shows (a split's focused pane).
    public func selectedTab(in window: SidebarWindowID?) -> Tab? {
        guard let id = selectedItemID(in: window) else { return nil }
        if easelRef(withSidebarID: id) != nil { return nil }
        if let split = split(withID: id) { return tab(withID: split.focusTabID) }
        return tab(withID: id)
    }

    /// Whether `id` is the selected row in `window`'s sidebar for `spaceID`.
    /// The key window's rows observe their own row only (`isSelected(_:inSpace:)`).
    public func isSelected(_ id: UUID, inSpace spaceID: Space.ID, in window: SidebarWindowID?) -> Bool {
        guard let window, isOtherWindow(window) else { return isSelected(id, inSpace: spaceID) }
        return selectedItemID(in: window) == id
    }

    /// A registered window that is not the key window.
    private func isOtherWindow(_ window: SidebarWindowID) -> Bool {
        guard let keyWindowID, window != keyWindowID else { return false }
        return focusedSpaceByWindow[window] != nil
    }

    /// `window`'s own selection while it still applies: same space, and the
    /// item is still a row there. `.some(nil)`: the space with nothing selected.
    private func ownSelection(of window: SidebarWindowID, in spaceID: Space.ID) -> UUID?? {
        guard let own = selectionByWindow[window], own.spaceID == spaceID else { return nil }
        guard let id = own.itemID else { return .some(nil) }
        guard displayRows(in: spaceID).ids.contains(id) || easelRef(withSidebarID: id) != nil,
              !isInClosedTabGroup(id, in: spaceID) else { return nil }
        return .some(id)
    }

    /// The key window now shows `id`: any other window showing it, or a tab
    /// of it (a split's pane), keeps its space with nothing selected.
    func takeFromOtherWindows(_ id: UUID?) {
        guard let id, !selectionByWindow.isEmpty else { return }
        let taken = shownTabIDs(id)
        for (window, other) in selectionByWindow where window != keyWindowID {
            guard let shown = other.itemID, !shownTabIDs(shown).isDisjoint(with: taken) else { continue }
            selectionByWindow[window]?.itemID = nil
        }
    }

    /// The item and, for a split, its panes.
    private func shownTabIDs(_ id: UUID) -> Set<UUID> {
        guard let split = split(withID: id) else { return [id] }
        return Set(split.tabs.map(\.id)).union([id])
    }

    /// The space a window shows. Unknown windows, the key window and windows
    /// whose space was deleted or archived show the active space.
    public func focusedSpaceID(in window: SidebarWindowID?) -> Space.ID {
        guard let window, window != keyWindowID,
              let id = focusedSpaceByWindow[window], listedSpace(withID: id) != nil else { return activeSpaceID }
        return id
    }

    public func focusedSpace(in window: SidebarWindowID?) -> Space {
        space(withID: focusedSpaceID(in: window)) ?? activeSpace
    }

    /// The selected item of a space: the live selection for the active space,
    /// the remembered one otherwise.
    public func selectedItemID(inSpace spaceID: Space.ID) -> UUID? {
        spaceID == activeSpaceID ? selectedItemID : restoredSelection(for: spaceID)
    }

    /// The tab a window's content area shows (a split's focused pane).
    public func selectedTab(inSpace spaceID: Space.ID) -> Tab? {
        guard let id = selectedItemID(inSpace: spaceID) else { return nil }
        if easelRef(withSidebarID: id) != nil { return nil }
        if let split = split(withID: id) { return tab(withID: split.focusTabID) }
        return tab(withID: id)
    }

    func followActiveSpaceInKeyWindow() {
        guard let keyWindowID else { return }
        focusedSpaceByWindow[keyWindowID] = activeSpaceID
    }
}
