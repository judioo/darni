import Foundation

public enum TabGroupError: Error, Equatable {
    case groupNotFound
    case spaceNotFound
    /// The group's pages are in another profile's storage.
    case otherProfile
    /// The space shows the group already.
    case alreadyShown
}

/// Tab groups (Chrome's, docs/briefs/2026-11-17-chrome-features.md).
///
/// A group is one record per profile (`tabGroupsByID`). A space shows it
/// through a row in its pinned or Today section (`SidebarEntry.tabGroup`),
/// at most one per space, and only spaces of the group's profile can: a tab
/// has one engine, in one profile's storage. Each row carries a copy of the
/// record, so the tree, the outline and per-row observation work as they do
/// for a folder; `writeTabGroup` is the one place that changes a group, and
/// it rewrites every row in the same write. An edit made in one space is
/// therefore in every space that shows the group.
///
/// A group's tabs are `today` tabs. Closing one (⌘W) takes it out of the
/// group everywhere and into the archive; ⇧⌘T puts it back in the group.
/// They never auto-archive and Clear leaves them, in either section:
/// archiving one would take it from every other space unasked.
///
/// A deleted space takes its rows, not the groups: a group no space shows
/// stays saved and the command bar lists it. A deleted profile takes its
/// groups. A space that changes profile keeps its groups: one only it shows
/// moves with it, one that other spaces show too is copied for it.
extension SidebarStore {

    // MARK: - Reading

    public func tabGroup(withID id: TabGroup.ID) -> TabGroup? {
        observation.access(.tabGroups)
        return tabGroupsByID[id]
    }

    /// A profile's groups by name.
    public func tabGroups(in profileID: Profile.ID) -> [TabGroup] {
        observation.access(.tabGroups)
        return tabGroupsByID.values.filter { $0.profileID == profileID }.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }

    /// A space's row for a tab group.
    public func tabGroupReference(withID id: UUID) -> TabGroupReference? {
        guard case .tabGroup(let reference) = entry(withID: id) else { return nil }
        return reference
    }

    /// The row that shows `groupID` in a space, if it has one.
    public func tabGroupReference(ofGroup groupID: TabGroup.ID, in spaceID: Space.ID? = nil) -> TabGroupReference? {
        let spaceID = spaceID ?? activeSpaceID
        return tabGroupPlaces(of: groupID).first(where: { $0.spaceID == spaceID }).flatMap { tabGroupReference(withID: $0.referenceID) }
    }

    /// The group a tab is in.
    public func tabGroupID(holding tabID: Tab.ID) -> TabGroup.ID? {
        if case .groupTab(let groupID) = indexed(tabID)?.place { return groupID }
        return nil
    }

    /// The spaces that show a group, archived ones included, in `spaces` order.
    public func spaces(showingTabGroup groupID: TabGroup.ID) -> [Space] {
        observation.access(.membership)
        return tabGroupPlaces(of: groupID).compactMap { space(withID: $0.spaceID) }
    }

    /// The groups a space could add: its profile's, less the ones it shows
    /// (the command bar's Tab Groups).
    public func tabGroupsAvailable(toAddIn spaceID: Space.ID? = nil) -> [TabGroup] {
        let spaceID = spaceID ?? activeSpaceID
        guard let space = space(withID: spaceID) else { return [] }
        observation.access(.spaceOutline(spaceID))
        return tabGroups(in: space.profileID).filter { group in
            !tabGroupPlaces(of: group.id).contains(where: { $0.spaceID == spaceID })
        }
    }

    /// The groups a tab could move into (Add Tab to Group ▸): its profile's, less its own.
    public func tabGroupsAccepting(_ tabID: Tab.ID) -> [TabGroup] {
        guard case .tab(let tab) = entry(withID: tabID) else { return [] }
        let own = tabGroupID(holding: tabID)
        observation.access(.tabGroups)
        return tabGroupsByID.values
            .filter { $0.id != own && canPlace(.tab(tab), in: .tabGroup($0.id)) }
            .sorted {
                let order = $0.displayName.localizedStandardCompare($1.displayName)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            }
    }

    /// Whether a drop of `id` on a group's row adds it: a plain tab of the
    /// group's profile that is not in the group already.
    public func canMove(_ id: UUID, intoTabGroup groupID: TabGroup.ID) -> Bool {
        guard let entry = entry(withID: id), tabGroupID(holding: id) != groupID else { return false }
        return canPlace(entry, in: .tabGroup(groupID))
    }

    /// The colour of the group a tab is in: the bar beside its row.
    public func tabGroupColor(holding tabID: Tab.ID) -> TabGroupColor? {
        guard let groupID = tabGroupID(holding: tabID) else { return nil }
        return tabGroup(withID: groupID)?.color
    }

    /// Whether a space's sections hold `id`: a row at any depth, or a tab of
    /// a group the space shows (which other spaces may show too).
    func isEntry(_ id: UUID, shownIn spaceID: Space.ID) -> Bool {
        if case .groupTab(let groupID) = lookupIndex()[id]?.place {
            return tabGroupPlaces(of: groupID).contains(where: { $0.spaceID == spaceID })
        }
        return spaceContaining(entryID: id) == spaceID
    }

    /// The row a group's tab counts as being in, for the questions that want
    /// one space (which space to switch to, whose profile its page is in):
    /// the active space's when it shows the group, else the first listed
    /// space's, else an archived space's.
    func shownPlace(ofTabGroup groupID: TabGroup.ID) -> TabGroupPlace? {
        let places = tabGroupPlaces(of: groupID)
        return places.first(where: { $0.spaceID == activeSpaceID })
            ?? places.first(where: { listedSpace(withID: $0.spaceID) != nil })
            ?? places.first
    }

    // MARK: - The one write

    /// Saves a group and rewrites every row that shows it, in one write to the trees.
    func writeTabGroup(_ group: TabGroup) {
        var group = group
        group.tabs = RankedSortable.sortedTabs(group.tabs)
        guard tabGroupsByID[group.id] != group else { return }
        let places = tabGroupPlaces(of: group.id)
        tabGroupsByID[group.id] = group
        guard !places.isEmpty else { return }
        updateContent { content in
            for place in places {
                guard var space = content[place.spaceID] else { continue }
                var entries = place.section == .pinned ? space.pinned : space.today
                guard let index = entries.firstIndex(where: { $0.id == place.referenceID }),
                      case .tabGroup(var reference) = entries[index] else { continue }
                reference.group = group
                entries[index] = .tabGroup(reference)
                if place.section == .pinned { space.pinned = entries } else { space.today = entries }
                content[place.spaceID] = space
            }
        }
    }

    /// Adds `tab` to a group (its rank decides the position).
    func insertIntoTabGroup(_ tab: Tab, groupID: TabGroup.ID) {
        guard var group = tabGroupsByID[groupID] else { return }
        var tab = tab
        tab.setKind(.today)
        group.tabs.removeAll { $0.id == tab.id }
        group.tabs.append(tab)
        writeTabGroup(group)
    }

    @discardableResult
    func removeFromTabGroup(_ tabID: Tab.ID, groupID: TabGroup.ID) -> Tab? {
        guard var group = tabGroupsByID[groupID], let index = group.tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        let tab = group.tabs.remove(at: index)
        writeTabGroup(group)
        return tab
    }

    /// Removes rows from the trees in one write; the groups are not touched.
    private func removeTabGroupRows(_ places: [TabGroupPlace]) {
        guard !places.isEmpty else { return }
        let ids = Set(places.map(\.referenceID))
        updateContent { content in
            for spaceID in Set(places.map(\.spaceID)) {
                guard var space = content[spaceID] else { continue }
                space.pinned.removeAll { ids.contains($0.id) }
                space.today.removeAll { ids.contains($0.id) }
                content[spaceID] = space
            }
        }
        expandedFolderIDs.subtract(ids)
    }

    /// The selection, when it is one of `tabIDs` in the active space, and its row index.
    private func selection(among tabIDs: [Tab.ID]) -> (id: UUID, index: Int?)? {
        guard let selected = selectedItemID, tabIDs.contains(selected) else { return nil }
        return (selected, displayEntries().firstIndex(where: { $0.id == selected }))
    }

    // MARK: - Creating and showing

    /// New Tab Group: an open group in a space, holding `tabIDs` in order
    /// (plain tabs of the space's profile; others are left where they are).
    /// It sits where the first tab was when that is a row of the space's own
    /// sections, else at the top of Today. Its colour is the profile's least
    /// used unless given.
    @discardableResult
    public func createTabGroup(
        name: String = "",
        color: TabGroupColor? = nil,
        in spaceID: Space.ID? = nil,
        containing tabIDs: [Tab.ID] = []
    ) -> TabGroupReference? {
        let spaceID = spaceID ?? tabIDs.first.flatMap { spaceContaining(tabID: $0) } ?? activeSpaceID
        guard let space = listedSpace(withID: spaceID) else { return nil }
        let group = TabGroup(
            profileID: space.profileID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            color: color ?? TabGroupColor.next(after: tabGroupsByID.values.filter { $0.profileID == space.profileID }.map(\.color))
        )
        var section = ItemContainerKind.SpaceSection.unpinned
        var index = 0
        if let first = tabIDs.first, case .section(let holder, let held)? = parent(of: first), holder == spaceID {
            section = held
            index = sectionEntries(for: held, spaceID: spaceID).firstIndex(where: { $0.id == first }) ?? 0
        }
        tabGroupsByID[group.id] = group
        var entries = sectionEntries(for: section, spaceID: spaceID)
        let reference = TabGroupReference(sortRank: rankForNewItem(in: entries, atIndex: index), group: group)
        entries.insert(.tabGroup(reference), at: min(index, entries.count))
        setSectionEntries(entries, for: section, spaceID: spaceID)
        expandedFolderIDs.insert(reference.id)
        mutationJournal.record(.upsertItem(id: group.id))
        notifyMutation(.insertItem(id: reference.id, spaceID: spaceID, container: section == .pinned ? .pinned : .unpinned, sortRank: reference.sortRank))
        for (offset, id) in tabIDs.enumerated() {
            moveItem(id, to: .tabGroup(group.id), index: offset)
        }
        return tabGroupReference(withID: reference.id)
    }

    /// Shows a group in a space (the command bar's Tab Groups): a row at
    /// `index` of the section, the top of Today unless given. The same group,
    /// not a copy.
    @discardableResult
    public func addTabGroup(
        _ groupID: TabGroup.ID,
        to spaceID: Space.ID? = nil,
        section: ItemContainerKind.SpaceSection = .unpinned,
        index: Int = 0
    ) -> Result<TabGroupReference, TabGroupError> {
        let spaceID = spaceID ?? activeSpaceID
        guard let group = tabGroupsByID[groupID] else { return .failure(.groupNotFound) }
        guard let space = listedSpace(withID: spaceID) else { return .failure(.spaceNotFound) }
        guard space.profileID == group.profileID else { return .failure(.otherProfile) }
        guard !tabGroupPlaces(of: groupID).contains(where: { $0.spaceID == spaceID }) else { return .failure(.alreadyShown) }
        var entries = sectionEntries(for: section, spaceID: spaceID)
        let clamped = max(0, min(index, entries.count))
        let reference = TabGroupReference(sortRank: rankForNewItem(in: entries, atIndex: clamped), group: group)
        entries.insert(.tabGroup(reference), at: clamped)
        setSectionEntries(entries, for: section, spaceID: spaceID)
        expandedFolderIDs.insert(reference.id)
        notifyMutation(.insertItem(id: reference.id, spaceID: spaceID, container: section == .pinned ? .pinned : .unpinned, sortRank: reference.sortRank))
        return .success(reference)
    }

    /// New Tab in Group: a tab at the end of the group's tabs. Not selected.
    @discardableResult
    public func addTab(toGroup groupID: TabGroup.ID, title: String, url: URL, tabID: Tab.ID = UUID()) -> Tab? {
        guard let group = tabGroupsByID[groupID], lookupIndex()[tabID] == nil else { return nil }
        let rank = rankForNewItem(in: group.tabs.map { .tab($0) }, atIndex: group.tabs.count)
        let tab = Tab(id: tabID, kind: .today, title: title, url: url, sortRank: rank, lastActiveAt: now())
        insertIntoTabGroup(tab, groupID: groupID)
        notifyMutation(.upsertItem(id: groupID))
        return tab
    }

    // MARK: - Editing

    /// An empty name is allowed: the group then shows its tab count, as Chrome's unnamed groups do.
    @discardableResult
    public func renameTabGroup(_ groupID: TabGroup.ID, to name: String) -> Bool {
        guard var group = tabGroupsByID[groupID] else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard group.name != trimmed else { return true }
        group.name = trimmed
        writeTabGroup(group)
        notifyMutation(.upsertItem(id: groupID))
        return true
    }

    @discardableResult
    public func setTabGroupColor(_ color: TabGroupColor, for groupID: TabGroup.ID) -> Bool {
        guard var group = tabGroupsByID[groupID] else { return false }
        guard group.color != color else { return true }
        group.color = color
        writeTabGroup(group)
        notifyMutation(.upsertItem(id: groupID))
        return true
    }

    /// Remove from Group: the tab becomes a row of its own right below the
    /// group's, in the space it is shown in (pinned there when the group's
    /// row is). It leaves the group in every space.
    @discardableResult
    public func removeTabFromGroup(_ tabID: Tab.ID, in spaceID: Space.ID? = nil) -> Bool {
        guard let groupID = tabGroupID(holding: tabID) else { return false }
        let places = tabGroupPlaces(of: groupID)
        guard let place = places.first(where: { $0.spaceID == (spaceID ?? activeSpaceID) }) ?? shownPlace(ofTabGroup: groupID) else {
            return false
        }
        let rows = sectionEntries(for: place.section, spaceID: place.spaceID)
        let index = (rows.firstIndex(where: { $0.id == place.referenceID }) ?? rows.count - 1) + 1
        return moveItem(tabID, to: .section(spaceID: place.spaceID, section: place.section), index: index)
    }

    // MARK: - Removing

    /// Remove from This Space: the space's row goes; the group, its tabs and
    /// every other space's row stay.
    @discardableResult
    public func removeTabGroupReference(_ referenceID: UUID) -> Bool {
        guard let item = lookupIndex()[referenceID], case .tabGroup(let reference) = item.entry,
              case .tree(let spaceID, let section, _) = item.place else { return false }
        let selected = spaceID == activeSpaceID ? selection(among: reference.group.tabs.map(\.id)) : nil
        removeTabGroupRows([TabGroupPlace(spaceID: spaceID, section: section, referenceID: referenceID)])
        if let selected { reconcileSelectionAfterRemoval(removedID: selected.id, priorIndex: selected.index) }
        notifyMutation(.deleteItem(id: referenceID))
        return true
    }

    /// Ungroup: the group's tabs become plain tabs where its row is in
    /// `spaceID` (pinned tabs in the pinned section), and the group is gone
    /// from every space. Returns the tabs' ids; nil when there is no such
    /// group or no space shows it.
    @discardableResult
    public func ungroupTabGroup(_ groupID: TabGroup.ID, in spaceID: Space.ID? = nil) -> [Tab.ID]? {
        let places = tabGroupPlaces(of: groupID)
        guard let group = tabGroupsByID[groupID],
              let place = places.first(where: { $0.spaceID == (spaceID ?? activeSpaceID) }) ?? shownPlace(ofTabGroup: groupID) else {
            return nil
        }
        var entries = sectionEntries(for: place.section, spaceID: place.spaceID)
        let index = entries.firstIndex(where: { $0.id == place.referenceID }) ?? entries.count
        entries.removeAll { $0.id == place.referenceID }
        var placed: [Tab] = []
        for (offset, tab) in group.tabs.enumerated() {
            var tab = tab
            tab.setKind(place.section == .pinned ? .pinned : .today)
            tab.sortRank = rankForNewItem(in: entries, atIndex: index + offset)
            entries.insert(.tab(tab), at: min(index + offset, entries.count))
            placed.append(tab)
        }
        let rows = Set(places.map(\.referenceID))
        updateContent { content in
            for other in places {
                guard var space = content[other.spaceID] else { continue }
                space.pinned.removeAll { rows.contains($0.id) }
                space.today.removeAll { rows.contains($0.id) }
                if other.spaceID == place.spaceID {
                    if place.section == .pinned { space.pinned = entries } else { space.today = entries }
                }
                content[other.spaceID] = space
            }
        }
        expandedFolderIDs.subtract(rows)
        tabGroupsByID[groupID] = nil
        for row in rows { mutationJournal.record(.deleteItem(id: row)) }
        let container: SidebarItemContainer = place.section == .pinned ? .pinned : .unpinned
        for tab in placed {
            mutationJournal.record(.insertItem(id: tab.id, spaceID: place.spaceID, container: container, sortRank: tab.sortRank))
        }
        if let selected = selectedItemID, !displayEntries().contains(where: { $0.id == selected }) {
            selectedItemID = restoredSelection(for: activeSpaceID)
        }
        notifyMutation(.deleteItem(id: groupID))
        return placed.map(\.id)
    }

    /// Delete Group: the group goes from every space and its tabs close, into
    /// the archive. Returns the closed tabs' ids.
    @discardableResult
    public func deleteTabGroup(_ groupID: TabGroup.ID) -> [Tab.ID] {
        guard let group = tabGroupsByID[groupID] else { return [] }
        let places = tabGroupPlaces(of: groupID)
        let archiveSpace = shownPlace(ofTabGroup: groupID)?.spaceID
        let selected = selection(among: group.tabs.map(\.id))
        for tab in group.tabs {
            appendArchiveRecord(tab, spaceID: archiveSpace, reason: .manual)
        }
        removeTabGroupRows(places)
        tabGroupsByID[groupID] = nil
        for place in places { mutationJournal.record(.deleteItem(id: place.referenceID)) }
        if let selected { reconcileSelectionAfterRemoval(removedID: selected.id, priorIndex: selected.index) }
        notifyMutation(.deleteItem(id: groupID))
        return group.tabs.map(\.id)
    }

    // MARK: - A space changes profile

    /// The space's storage is now `profileID`'s. A group only this space shows
    /// goes with it, as its own tabs do. One that other spaces show too stays
    /// theirs, and this space gets a copy with tabs of its own: one tab cannot
    /// have pages in two profiles' storage.
    func tabGroupsFollowSpace(_ spaceID: Space.ID, to profileID: Profile.ID) {
        let content = sortedContent(for: spaceID)
        for reference in SidebarTree.tabGroups(content.pinned + content.today) {
            guard var group = tabGroupsByID[reference.groupID], group.profileID != profileID else { continue }
            if tabGroupPlaces(of: group.id).allSatisfy({ $0.spaceID == spaceID }) {
                group.profileID = profileID
                writeTabGroup(group)
                mutationJournal.record(.upsertItem(id: group.id))
                continue
            }
            let copy = TabGroup(
                profileID: profileID,
                name: group.name,
                color: group.color,
                tabs: group.tabs.map { reopenedCopy(of: $0, kind: .today, sortRank: $0.sortRank) }
            )
            tabGroupsByID[copy.id] = copy
            updateContent { content in
                guard var space = content[spaceID] else { return }
                func swap(_ entries: inout [SidebarEntry]) {
                    guard let index = entries.firstIndex(where: { $0.id == reference.id }) else { return }
                    entries[index] = .tabGroup(TabGroupReference(id: reference.id, sortRank: reference.sortRank, group: copy))
                }
                swap(&space.pinned)
                swap(&space.today)
                content[spaceID] = space
            }
            mutationJournal.record(.upsertItem(id: copy.id))
            mutationJournal.record(.upsertItem(id: reference.id))
        }
        if spaceID == activeSpaceID, let selected = selectedItemID, !displayEntries().contains(where: { $0.id == selected }) {
            selectedItemID = restoredSelection(for: activeSpaceID)
        }
    }

    // MARK: - Open and closed

    /// A group's row opens and closes as a folder does; the state is the row's, so per space.
    public func isTabGroupExpanded(_ referenceID: UUID) -> Bool {
        expandedFolderIDs.contains(referenceID)
    }

    public func setTabGroupExpanded(_ referenceID: UUID, _ expanded: Bool) {
        guard case .tabGroup = lookupIndex()[referenceID]?.entry, expandedFolderIDs.contains(referenceID) != expanded else { return }
        if expanded {
            expandedFolderIDs.insert(referenceID)
        } else {
            expandedFolderIDs.remove(referenceID)
        }
        notifyMutation()
    }

    public func toggleTabGroupExpanded(_ referenceID: UUID) {
        setTabGroupExpanded(referenceID, !isTabGroupExpanded(referenceID))
    }

    // MARK: - Saving

    /// The groups and their rows as `sidebar.json` keeps them, apart from the
    /// trees (`SidebarSnapshot.tabGroups`).
    func tabGroupsSnapshot() -> TabGroupsSnapshot {
        var references: [TabGroupsSnapshot.Reference] = []
        for space in spaces {
            let content = sortedContent(for: space.id)
            for (section, entries) in [(ItemContainerKind.SpaceSection.pinned, content.pinned), (.unpinned, content.today)] {
                for reference in SidebarTree.tabGroups(entries) {
                    references.append(.init(
                        id: reference.id, groupID: reference.groupID, spaceID: space.id,
                        pinned: section == .pinned, sortRank: reference.sortRank
                    ))
                }
            }
        }
        return TabGroupsSnapshot(
            groups: tabGroupsByID.values.sorted { $0.id.uuidString < $1.id.uuidString },
            references: references
        )
    }

    /// Loads the groups and returns each space's rows for them. `visited`
    /// keeps an id in one place: a group's tab is in that group only. A row
    /// is dropped (never its group) when its space is gone, is another
    /// profile's, or shows the group already.
    func restoreTabGroups(from snapshot: TabGroupsSnapshot, visited: inout Set<UUID>) -> [Space.ID: SpaceContent] {
        var groups: [TabGroup.ID: TabGroup] = [:]
        for var group in snapshot.groups where groups[group.id] == nil && visited.insert(group.id).inserted {
            group.tabs = TabGroup.normalized(group.tabs.filter { visited.insert($0.id).inserted })
            groups[group.id] = group
        }
        tabGroupsByID = groups
        var rows: [Space.ID: SpaceContent] = [:]
        var shown = Set<[UUID]>()
        for reference in snapshot.references {
            guard let group = groups[reference.groupID],
                  let space = spaces.first(where: { $0.id == reference.spaceID }), space.profileID == group.profileID,
                  !shown.contains([space.id, group.id]), visited.insert(reference.id).inserted else { continue }
            shown.insert([space.id, group.id])
            let row = SidebarEntry.tabGroup(TabGroupReference(id: reference.id, sortRank: reference.sortRank, group: group))
            if reference.pinned {
                rows[space.id, default: SpaceContent()].pinned.append(row)
            } else {
                rows[space.id, default: SpaceContent()].today.append(row)
            }
        }
        return rows
    }
}

/// The command bar's Tab Groups (⌘T with nothing typed): the groups the
/// current space could add.
public struct TabGroupCommandBarRow: Identifiable, Equatable, Sendable {
    public let id: TabGroup.ID
    public let name: String
    public let color: TabGroupColor
    public let tabCount: Int

    public var countText: String { TabGroup.countText(tabCount) }

    /// Rows for a space: none while the setting is off or anything is typed.
    public static func rows(in store: SidebarStore, spaceID: Space.ID? = nil, query: String, enabled: Bool) -> [TabGroupCommandBarRow] {
        guard enabled, query.isEmpty else { return [] }
        return store.tabGroupsAvailable(toAddIn: spaceID).map {
            TabGroupCommandBarRow(id: $0.id, name: $0.displayName, color: $0.color, tabCount: $0.tabs.count)
        }
    }
}
