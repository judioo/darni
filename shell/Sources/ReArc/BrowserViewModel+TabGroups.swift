import AppKit
import SidebarModel

/// The open editor of a tab group (its name and colour) and where it opens from.
struct TabGroupEditorRequest: Equatable {
    /// What the popover points at: the group's row in a space, or the
    /// group's own id for its row in the command bar.
    let anchorID: UUID
    let groupID: TabGroup.ID
}

/// What the person answered to "Delete tab group?".
struct TabGroupDeletionAnswer: Equatable {
    var delete: Bool
    var dontAskAgain = false
}

/// Tab groups in the shell (Chrome's, docs/briefs/2026-11-17-chrome-features.md).
/// The store holds each group once (`SidebarStore+TabGroups`); a space shows
/// it through a row, so a tab of a group is one tab with one engine, whichever
/// spaces show it. Settings › General › Tab groups (`tabGroupsEnabled`, off
/// by default) decides only what the menus and the command bar offer: groups
/// made while it was on stay in the sidebar and keep working.
extension BrowserViewModel {

    // MARK: - Creating

    /// New Tab Group (the "+ New Tab" row's and the blank sidebar's menu) and
    /// Add Tab to New Group: a group in `spaceID` holding `tabIDs`, with its
    /// editor open so it can be named at once, as Chrome's is.
    @discardableResult
    func newTabGroup(in spaceID: Space.ID? = nil, containing tabIDs: [Tab.ID] = []) -> TabGroupReference? {
        guard tabGroupsEnabled, let reference = store.createTabGroup(in: spaceID, containing: tabIDs) else { return nil }
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
        editTabGroup(reference.groupID, from: reference.id)
        return reference
    }

    /// Add Tab to Group ▸ and a drop on a group's row: the tab joins the end
    /// of the group, in every space that shows it.
    @discardableResult
    func addTab(_ tabID: Tab.ID, toGroup groupID: TabGroup.ID) -> Bool {
        guard let group = store.tabGroup(withID: groupID),
              store.moveItem(tabID, to: .tabGroup(groupID), index: group.tabs.count) else { return false }
        revealTabGroup(groupID)
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
        // The tab left the sidebar on screen: say where it went.
        if store.tabGroupReference(ofGroup: groupID) == nil {
            showToast("Added to “\(group.displayName)”", systemImage: "square.stack.3d.up.fill")
        }
        return true
    }

    /// A dragged selection dropped on a group's row: its plain tabs join, in order.
    func addTabs(_ ids: [UUID], toGroup groupID: TabGroup.ID) {
        let tabs = store.plainTabIDs(ids)
        guard !tabs.isEmpty else { return }
        store.clearMultiSelection(in: store.keyWindowID)
        for id in tabs {
            let count = store.tabGroup(withID: groupID)?.tabs.count ?? 0
            store.moveItem(id, to: .tabGroup(groupID), index: count)
        }
        revealTabGroup(groupID)
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
    }

    /// Opens the group's row in the active space, so a tab that just joined shows.
    private func revealTabGroup(_ groupID: TabGroup.ID) {
        guard let row = store.tabGroupReference(ofGroup: groupID) else { return }
        store.setTabGroupExpanded(row.id, true)
    }

    /// Remove from Group: the tab becomes a row of its own below the group's.
    func removeTabFromGroup(_ tabID: Tab.ID, in window: SidebarWindowID? = nil) {
        guard store.removeTabFromGroup(tabID, in: space(in: window).id) else { return }
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
    }

    /// New Tab in Group: ⌘T's bar; the tab it opens joins the group.
    func newTab(inGroup groupID: TabGroup.ID) {
        guard store.tabGroup(withID: groupID) != nil else { return }
        newTab()
        commandBarNewTabGroupID = groupID
    }

    /// The command bar's new tab, when it was asked for by New Tab in Group.
    func joinCommandBarTabGroup(_ tabID: Tab.ID) {
        guard let groupID = commandBarNewTabGroupID, let group = store.tabGroup(withID: groupID) else { return }
        commandBarNewTabGroupID = nil
        guard store.moveItem(tabID, to: .tabGroup(groupID), index: group.tabs.count) else { return }
        revealTabGroup(groupID)
    }

    // MARK: - Showing

    /// The command bar's Tab Groups: what an empty ⌘T bar lists.
    var commandBarTabGroups: [TabGroupCommandBarRow] {
        guard commandBarCreatesNewTab, commandBarSiteSearch == nil, commandBarURLIntent == nil else { return [] }
        return TabGroupCommandBarRow.rows(in: store, query: commandBarText, enabled: tabGroupsEnabled)
    }

    /// A click on a group in the command bar: the active space shows it, at the top of Today.
    func addTabGroupToActiveSpace(_ groupID: TabGroup.ID) {
        guard case .success(let row) = store.addTabGroup(groupID) else { return }
        dismissCommandBar()
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
        sidebarRowReveal = SidebarReveal(id: row.id, serial: (sidebarRowReveal?.serial ?? 0) + 1)
    }

    /// Remove from This Space: the space's row goes. The group and its tabs
    /// stay for the other spaces and for the command bar; pages no space
    /// shows any more are closed.
    func removeTabGroupFromSpace(_ referenceID: UUID) {
        let tabs = store.tabGroupReference(withID: referenceID)?.group.tabs.map(\.id) ?? []
        guard store.removeTabGroupReference(referenceID) else { return }
        if tabGroupEditor?.anchorID == referenceID { tabGroupEditor = nil }
        releaseEngines(ofTabsNoLongerShown: tabs)
        loadSelectedIfNeeded()
    }

    private func releaseEngines(ofTabsNoLongerShown tabs: [Tab.ID]) {
        for id in tabs where store.tab(withID: id) == nil { releaseEngine(for: id) }
        reconcileEngineOwnership()
    }

    // MARK: - Editing

    /// Opens the editor (name field and colour dots) from `anchorID`'s row.
    func editTabGroup(_ groupID: TabGroup.ID, from anchorID: UUID) {
        guard store.tabGroup(withID: groupID) != nil else { return }
        tabGroupEditor = TabGroupEditorRequest(anchorID: anchorID, groupID: groupID)
    }

    // MARK: - Ungroup and delete

    /// Ungroup: the tabs become plain tabs where the group's row is in the
    /// active space (at the top of its Today when it does not show the
    /// group), and the group is gone from every space.
    func ungroupTabGroup(_ groupID: TabGroup.ID) {
        if store.tabGroupReference(ofGroup: groupID) == nil {
            // From the command bar: the tabs land in the space on screen.
            guard case .success = store.addTabGroup(groupID) else { return }
        }
        guard store.ungroupTabGroup(groupID, in: store.activeSpaceID) != nil else { return }
        if tabGroupEditor?.groupID == groupID { tabGroupEditor = nil }
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
    }

    /// Delete Group: asks first (Chrome's "Delete tab group?") unless
    /// "Don't ask again" was ticked, then closes the group's tabs everywhere.
    func requestTabGroupDeletion(_ groupID: TabGroup.ID) {
        guard let group = store.tabGroup(withID: groupID) else { return }
        if asksBeforeDeletingTabGroup {
            let spaces = store.spaces(showingTabGroup: groupID).count
            let answer = answerTabGroupDeletion?(group, spaces) ?? MainActor.assumeIsolated {
                Self.runTabGroupDeletionAlert(group: group, spaceCount: spaces, syncOn: isSyncEnabled)
            }
            guard answer.delete else { return }
            if answer.dontAskAgain { asksBeforeDeletingTabGroup = false }
        }
        deleteTabGroup(groupID)
    }

    func deleteTabGroup(_ groupID: TabGroup.ID) {
        guard store.tabGroup(withID: groupID) != nil else { return }
        if tabGroupEditor?.groupID == groupID { tabGroupEditor = nil }
        let closed = store.deleteTabGroup(groupID)
        closed.forEach(releaseEngine(for:))
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
    }

    /// The question as an alert with Chrome's wording and its checkbox.
    @MainActor
    static func runTabGroupDeletionAlert(group: TabGroup, spaceCount: Int, syncOn: Bool) -> TabGroupDeletionAnswer {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = TabGroupDeleteConfirmation.title
        alert.informativeText = TabGroupDeleteConfirmation.message(
            groupName: group.name, tabCount: group.tabs.count, spaceCount: spaceCount, syncOn: syncOn
        )
        // Cancel is the default button, so Return never deletes.
        alert.addButton(withTitle: TabGroupDeleteConfirmation.cancelTitle)
        let delete = alert.addButton(withTitle: TabGroupDeleteConfirmation.confirmTitle)
        delete.hasDestructiveAction = true
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = TabGroupDeleteConfirmation.dontAskTitle
        let deleted = alert.runModal() == .alertSecondButtonReturn
        return TabGroupDeletionAnswer(delete: deleted, dontAskAgain: deleted && alert.suppressionButton?.state == .on)
    }
}
