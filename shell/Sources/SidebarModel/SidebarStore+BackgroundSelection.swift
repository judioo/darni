import Foundation

extension SidebarStore {
    /// Makes `id` the selected tab of its own space while another space stays
    /// on screen: the space shows it the next time it comes back.
    ///
    /// This is what an extension's `tabs.update({active: true})` means for a
    /// space that is not on screen (`ExtensionFocusGate`): the tab is its
    /// window's active tab, and the window stays where it is. A split takes
    /// the selection with the tab as its focused pane. False when the tab
    /// cannot be the selection there: it is in no listed space (a favorite,
    /// an archived space), its page is not open, or its tab group's row is
    /// closed. Nothing changes then.
    @discardableResult
    public func selectTabInItsSpace(_ id: Tab.ID) -> Bool {
        guard tab(withID: id) != nil, let spaceID = spaceContaining(tabID: id), listedSpace(withID: spaceID) != nil else { return false }
        guard spaceID != activeSpaceID else { return focusTab(id) }
        guard isTabOpen(id), !isInClosedTabGroup(id, in: spaceID) else { return false }
        var row = id
        if let split = splitContaining(tabID: id)?.split {
            row = split.id
            if split.focusTabID != id {
                var focused = split
                focused.focusTabID = id
                replaceSplit(focused)
            }
        }
        guard displayRows(in: spaceID).ids.contains(row) else { return false }
        spacesLeftBlank.remove(spaceID)
        selectionBySpace[spaceID] = row
        notifyMutation()
        return selectedTab(inSpace: spaceID)?.id == id
    }
}
