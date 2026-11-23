import AppKit
import SidebarModel

/// ⇧/⌘-click selection of sidebar rows (Arc, 2026-11-11 recording) and the
/// commands that act on it: the row menu, ⌘W, ⇧⌘C, ⌘D and the Tabs menu.
/// The selection itself lives in the store, per window (`SidebarMultiSelection`).
extension BrowserViewModel {

    // MARK: - Clicks

    /// A click on a sidebar row: ⇧ extends the window's selection to it, ⌘
    /// toggles it, and neither shows the row's page. Returns false for a
    /// plain click, which drops the selection and does what it always did.
    func handleSelectionClick(on id: UUID, in window: SidebarWindowID?,
                              modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) -> Bool {
        let keys = modifiers.intersection([.shift, .command, .option, .control])
        let spaceID = store.focusedSpaceID(in: window)
        guard keys == .shift || keys == .command, Self.isSelectableRow(store.entry(withID: id)),
              store.spaceContaining(entryID: id) == spaceID else {
            store.clearMultiSelection(in: window)
            return false
        }
        if keys == .shift {
            store.extendMultiSelection(to: id, inSpace: spaceID, visibleOrder: visibleRowIDs(spaceID: spaceID, in: window), in: window)
        } else {
            store.toggleMultiSelection(id, inSpace: spaceID, in: window)
        }
        return true
    }

    /// A sidebar row's click, full or mini (⇧⌘S): ⇧ and ⌘ change the
    /// selection instead of `action`; a plain click drops it and runs
    /// `action`. While a Peek is open in the window the click only closes
    /// it, as a click anywhere outside its card does (`PeekDismissal`).
    func rowClick(_ id: UUID, in window: SidebarWindowID?, _ action: @escaping () -> Void) -> () -> Void {
        { [self] in handleRowClick(id, in: window, modifiers: NSEvent.modifierFlags, action) }
    }

    func handleRowClick(_ id: UUID, in window: SidebarWindowID?, modifiers: NSEvent.ModifierFlags, _ action: () -> Void) {
        if showsPeek(in: window) {
            performPeekAction(.close)
            return
        }
        if !handleSelectionClick(on: id, in: window, modifiers: modifiers) { action() }
    }

    /// Tabs, splits and folders take part; easels open as before, and a tab
    /// group's row opens and closes (its tabs take part as tabs do).
    static func isSelectableRow(_ entry: SidebarEntry?) -> Bool {
        switch entry {
        case .tab, .split, .folder: true
        case .easel, .tabGroup, nil: false
        }
    }

    /// The selectable rows on screen in a window, top to bottom (open
    /// folders' contents, a collapsed folder's or Pinned's shown selection).
    func visibleRowIDs(spaceID: Space.ID, in window: SidebarWindowID?) -> [UUID] {
        SidebarListRow.rows(
            outline: store.outline(for: spaceID),
            expanded: store.expandedFolderIDs,
            pinnedCollapsed: isPinnedSectionCollapsed(spaceID: spaceID, in: window),
            isDragging: false,
            selection: { store.selection(among: $0, inSpace: spaceID, in: window) }
        ).compactMap { row in
            guard case .item(let item, _) = row, item.node.kind != .easel else { return nil }
            return item.id
        }
    }

    /// `window`'s selected rows, in sidebar order, while there are several
    /// and nothing is in front of them. An open Peek sets the selection
    /// aside: it stays drawn, and ⌘C, ⌘W, ⇧⌘C and the rest act as they do
    /// without one until the Peek closes (Esc closes the Peek first).
    func activeSelectionIDs(in window: SidebarWindowID?) -> [UUID]? {
        guard !showsPeek(in: window) else { return nil }
        return store.multiSelectedIDs(in: window)
    }

    /// The key window's selected rows, in sidebar order, while there are several.
    var keySelectionIDs: [UUID]? {
        guard keyPrivateWindow == nil, keyLittleArcEngine == nil else { return nil }
        return activeSelectionIDs(in: store.keyWindowID)
    }

    func clearSelection(in window: SidebarWindowID?) {
        store.clearMultiSelection(in: window)
    }

    // MARK: - Copy Links

    /// Copy Links (⇧⌘C and ⌘C on a selection): each tab's link on its own
    /// line, cleaned of trackers, as a single tab's copy does.
    func copyLinks(of ids: [UUID], format: PageLinkCopyFormat = .plain) {
        var anyCleaned = false
        let links = store.linkTabIDs(for: ids).compactMap { id -> (url: URL, title: String)? in
            guard let tab = store.tab(withID: id) else { return nil }
            let engine = engineHost.engine(forTabID: id, profileID: profileID(for: tab))
            let (url, cleaned) = LinkCleaner.clean(engine?.currentURL ?? tab.url)
            anyCleaned = anyCleaned || cleaned
            return (url, tab.customTitle ?? engine?.pageTitle ?? tab.title)
        }
        guard !links.isEmpty else { return }
        let text = (format == .markdown ? PageLinkCopyFormat.markdown : .plain).text(links: links)
        linkPasteboard.clearContents()
        linkPasteboard.setString(text, forType: .string)
        lastCopiedLinkText = text
        showToast(PageLinkCopyFormat.multipleConfirmation(cleaned: anyCleaned),
                  systemImage: anyCleaned ? "checkmark.shield.fill" : "link")
    }

    // MARK: - Close and archive

    /// ⌘W on a selection: each tab as its own ✕ would (a Today tab to the
    /// archive, a pinned one back to its saved URL, unloaded), splits closed.
    /// ⇧⌘T brings back everything this closed at once.
    /// A selection that holds every tab of a tab group asks once, before any
    /// of them closes ("Close tabs and delete group?").
    func closeItems(_ ids: [UUID]) {
        confirmEmptyingTabGroups(byTaking: ids, closing: true) { [self] emptied in
            store.clearMultiSelection(in: store.keyWindowID)
            store.closingAsOneBatch {
                for id in ids {
                    switch store.entry(withID: id) {
                    case .tab: closeTabWithoutAsking(id, leaving: emptied)
                    case .split(let split): closeSplit(split.id)
                    default: break
                    }
                }
            }
            loadSelectedIfNeeded()
        }
    }

    /// Archive Tabs (row menu): the pinned and Today tabs, as Archive Tab does to one.
    func archiveTabs(_ ids: [UUID]) {
        let tabs = store.plainTabIDs(ids).filter { store.splitContaining(tabID: $0) == nil }
        takingFromTabGroups(tabs, closing: true) { [self] in
            for id in tabs where store.archiveTab(id) != nil { releaseEngine(for: id) }
            loadSelectedIfNeeded()
        }
    }

    /// The ⌘W item's title on a selection.
    func closeMenuTitle(for ids: [UUID]) -> String {
        let kinds = Set(store.plainTabIDs(ids).map(closeKind(of:)))
        return kinds == [.archive] ? "Archive Tabs" : "Close Tabs"
    }

    // MARK: - Pin, favorites, duplicate

    /// ⌘D on a selection: pins the Today tabs; when all are pinned, unpins them.
    func togglePinned(_ ids: [UUID]) {
        let tabs = store.plainTabIDs(ids)
        if tabs.contains(where: { store.kind(of: $0) == .today }) {
            pinTabs(tabs)
        } else {
            unpinTabs(tabs)
        }
    }

    func pinTabs(_ ids: [UUID]) {
        takingFromTabGroups(ids) { [self] in
            let pinned = store.pinTabs(ids)
            guard !pinned.isEmpty else { return }
            let space = store.spaceContaining(tabID: pinned[0]).flatMap { store.space(withID: $0) }?.name ?? ""
            showKeptToast(pinned.count == 1 ? "Pinned Tab to “\(space)”" : "Pinned \(pinned.count) Tabs to “\(space)”", systemImage: "pin.fill",
                          count: pinned.count, titleUndo: tidyTitlesIfNeeded(pinned))
            loadSelectedIfNeeded()
        }
    }

    func unpinTabs(_ ids: [UUID]) {
        let unpinned = store.unpinTabs(ids)
        guard !unpinned.isEmpty else { return }
        let space = store.spaceContaining(tabID: unpinned[0]).flatMap { store.space(withID: $0) }?.name ?? ""
        showToast(unpinned.count == 1 ? "Un-Pinned Tab from “\(space)”" : "Un-Pinned \(unpinned.count) Tabs from “\(space)”",
                  systemImage: "pin.slash")
        loadSelectedIfNeeded()
    }

    func addTabsToFavorites(_ ids: [UUID]) {
        takingFromTabGroups(ids) { [self] in
            let added = store.addTabsToFavorites(ids)
            guard !added.isEmpty else { return }
            if let undo = tidyTitlesIfNeeded(added) {
                showUndoToast(added.count == 1 ? "Added to Favorites · Title tidied" : "Added to Favorites · Titles tidied",
                              systemImage: "star.fill", undo: undo)
            }
            reconcileEngineOwnership()
            loadSelectedIfNeeded()
        }
    }

    func duplicateTabs(_ ids: [UUID]) {
        guard !store.duplicateTabs(ids).isEmpty else { return }
        loadSelectedIfNeeded()
    }

    // MARK: - Move

    /// Move to Space: each row keeps its section and its page, as one row's
    /// move does. A space of another session (another profile, or a container's
    /// space in the same strip) changes the rows' session, so it asks first.
    func moveItems(_ ids: [UUID], toSpace spaceID: Space.ID) {
        if store.crossesProfile(ids, toSpace: spaceID) { return requestProfileMove(ids, toSpace: spaceID) }
        takingFromTabGroups(ids) { [self] in
            guard !store.moveEntries(ids, toSpace: spaceID).isEmpty else { return }
            reconcileEngineOwnership()
            loadSelectedIfNeeded()
        }
    }

    // MARK: - Move to another profile

    /// Move to Profile (row menu, one row or a selection): asks once, like a
    /// space's Change Profile, for however many tabs go.
    func requestProfileMove(_ ids: [UUID], toSpace spaceID: Space.ID) {
        guard store.crossesProfile(ids, toSpace: spaceID) else { return moveItems(ids, toSpace: spaceID) }
        pendingProfileMove = SidebarProfileMove(ids: ids, spaceID: spaceID)
    }

    func confirmProfileMove() {
        defer { pendingProfileMove = nil }
        guard let move = pendingProfileMove else { return }
        moveItemsToProfile(move.ids, toSpace: move.spaceID, placement: move.placement)
    }

    func profileMoveMessage(_ move: SidebarProfileMove) -> (title: String, message: String, action: String) {
        let target = store.space(withID: move.spaceID)
        let destination = target.map { sessionName(of: $0.profileID) } ?? "the other profile"
        let source = move.ids.first.flatMap { store.spaceContaining(entryID: $0) }.flatMap { store.space(withID: $0) }
            .map { sessionName(of: $0.profileID) } ?? "this profile"
        let count = store.carriedTabIDs(move.ids).count
        let these = count == 1 ? "This tab" : "These \(count) tabs"
        // A container's space is named as itself: it is not a profile to the person.
        let title = target.flatMap { store.isContainer($0.profileID) ? $0.name : store.profile(withID: $0.profileID)?.name } ?? destination
        return ("Move to \(title)?",
                "\(these) will reload in \(destination). Cookies, sign-ins and site data stay in \(source), so you may need to sign in again. Back and forward history is lost.",
                "Move")
    }

    /// The rows move as Move to Space moves them (section, order, folder
    /// contents, split panes); then their pages change session as a space's
    /// do on Change Profile. The tab records carry nothing of the old profile.
    /// A drop that was asked about lands at its `placement` instead.
    func moveItemsToProfile(_ ids: [UUID], toSpace spaceID: Space.ID, placement: SidebarDropPlacement? = nil) {
        let carried = store.carriedTabIDs(ids)
        let live = Set(engineHost.allTabEngines().map(\.0))
        takingFromTabGroups(ids, to: placement.flatMap { store.parent(for: $0) }) { [self] in
            let moved = placement.map { store.moveEntries(ids, to: $0) } ?? store.moveEntries(ids, toSpace: spaceID)
            guard !moved.isEmpty else { return }
            if case .intoFolder(let folderID) = placement { store.setFolderExpanded(folderID, true) }
            reloadTabsInTheirProfile(carried.compactMap { store.tab(withID: $0) }, live: live)
        }
    }

    /// A drop that would take rows to another session (another profile, or a
    /// container's space) is Move to Space with a place: it asks first, with
    /// the same question, and the rows then land where they were dropped.
    /// Another profile's favorites take no such drop, as Move to Space has
    /// none. True: asked or refused, and nothing has moved.
    func asksBeforeProfileDrop(_ ids: [UUID], to placement: SidebarDropPlacement) -> Bool {
        guard let parent = store.parent(for: placement), store.crossesProfile(ids, to: parent) else { return false }
        guard let spaceID = store.spaceID(of: parent) else { return true }
        pendingProfileMove = SidebarProfileMove(ids: ids, spaceID: spaceID, placement: placement)
        return true
    }

    func moveItems(_ ids: [UUID], intoFolder folderID: UUID) {
        if asksBeforeProfileDrop(ids, to: .intoFolder(folderID)) { return }
        takingFromTabGroups(ids) { [self] in
            guard !store.moveEntries(ids, intoFolder: folderID).isEmpty else { return }
            store.setFolderExpanded(folderID, true)
            reconcileEngineOwnership()
            loadSelectedIfNeeded()
        }
    }

    /// New Folder with Selection: the rows go into a new folder, named in place.
    func newFolder(withSelection ids: [UUID]) {
        guard let first = ids.first, let spaceID = store.spaceContaining(entryID: first) else { return }
        takingFromTabGroups(ids) { [self] in
            guard let folder = store.createFolder(withSelection: ids, in: spaceID) else { return }
            store.clearMultiSelection(in: store.keyWindowID)
            reconcileEngineOwnership()
            loadSelectedIfNeeded()
            beginRename(.folder(folder.id))
        }
    }

    // MARK: - Drag

    /// The rows a drag of `id` carries: the whole selection of the window it
    /// began in when `id` is in it, else nil (the row alone, as before). A
    /// drop in another window carries them too. Drops on the page edge or a
    /// row's middle (stacking) still take the dragged row alone.
    func draggedSelection(_ id: UUID) -> [UUID]? {
        let selection: [UUID]?
        if let drag = sidebarDrag, drag.itemID == id, let window = drag.sourceWindow {
            selection = activeSelectionIDs(in: window)
        } else {
            selection = keySelectionIDs
        }
        guard let selection, selection.contains(id) else { return nil }
        return selection
    }

    /// Reorder: the dragged selection lands before or after `targetID`.
    /// False: nothing moved and nothing was asked, so the caller moves the
    /// dragged row alone. A drag that takes a tab group's last tabs out asks
    /// first; the move then follows the answer, and this returns true.
    @discardableResult
    func moveDraggedSelection(_ ids: [UUID], relativeTo targetID: UUID, after: Bool) -> Bool {
        // The target among them: refused below, and the dragged row moves alone.
        if !store.topmostEntries(ids).contains(targetID), asksBeforeProfileDrop(ids, to: .beside(targetID, after: after)) { return true }
        var moved = false
        let ran = takingFromTabGroups(ids, to: store.parent(of: targetID)) { [self] in
            guard let rows = store.moveEntries(ids, relativeTo: targetID, after: after), !rows.isEmpty else { return }
            moved = true
            reconcileEngineOwnership()
            loadSelectedIfNeeded()
        }
        return moved || !ran
    }

    /// After a section's last row (pins into Pinned, unpins into Today).
    func moveDraggedSelection(_ ids: [UUID], appendingTo destination: SidebarStore.ItemDestination) {
        if asksBeforeProfileDrop(ids, to: .end(destination)) { return }
        takingFromTabGroups(ids, to: store.resolvedParent(destination)) { [self] in
            guard !store.moveEntries(ids, appendingTo: destination).isEmpty else { return }
            reconcileEngineOwnership()
            loadSelectedIfNeeded()
        }
    }

    // MARK: - Split View

    func canOpenInSplitView(_ ids: [UUID]) -> Bool { store.canSplit(selection: ids) }

    /// Open in Split View: two to four selected tabs become one split.
    func openInSplitView(_ ids: [UUID]) {
        guard let split = store.split(selection: ids) else { return }
        store.selectSplit(split.id)
        loadSelectedIfNeeded()
    }
}
