import XCTest
@testable import SidebarModel

/// Tab groups (docs/briefs/2026-11-17-chrome-features.md): a group is one
/// record per profile, and each space shows it through a row of its own.
final class TabGroupTests: XCTestCase {
    private func url(_ host: String) -> URL { URL(string: "https://\(host)/")! }
    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Fixture {
        let store: SidebarStore
        let home: Space.ID
        let work: Space.ID
        let mail: Tab.ID
        let docs: Tab.ID
        let news: Tab.ID
    }

    /// One profile with Home (three Today tabs, the active space) and Work.
    private func makeStore() -> Fixture {
        let store = SidebarStore(spaces: [Space(name: "Home", sortRank: "b")])
        store.now = { [day] in day }
        let home = store.spaces[0].id
        let work = store.addSpace(name: "Work").id
        let news = store.addTab(kind: .today, title: "News", url: url("news.test"), in: home).id
        let docs = store.addTab(kind: .today, title: "Docs", url: url("docs.test"), in: home).id
        let mail = store.addTab(kind: .today, title: "Mail", url: url("mail.test"), in: home).id
        return Fixture(store: store, home: home, work: work, mail: mail, docs: docs, news: news)
    }

    private func titles(_ entries: [SidebarEntry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .tab(let tab): return tab.displayTitle
            case .folder(let folder): return "[\(folder.title)]"
            case .split: return "split"
            case .easel: return "easel"
            case .tabGroup(let reference): return "<\(reference.group.displayName): \(reference.group.tabs.map(\.displayTitle).joined(separator: ", "))>"
            }
        }
    }

    private func groupTabs(_ store: SidebarStore, _ id: TabGroup.ID) -> [String] {
        store.tabGroup(withID: id)?.tabs.map(\.displayTitle) ?? []
    }

    // MARK: Create

    func testANewGroupTakesItsTabsAndSitsWhereTheFirstOneWas() throws {
        let f = makeStore()
        let row = try XCTUnwrap(f.store.createTabGroup(name: " Reading ", containing: [f.docs, f.news]))
        XCTAssertEqual(row.group.name, "Reading")
        XCTAssertEqual(titles(f.store.content(for: f.home).today), ["Mail", "<Reading: Docs, News>"])
        XCTAssertEqual(f.store.tabGroupID(holding: f.docs), row.groupID)
        XCTAssertEqual(f.store.parent(of: f.news), .tabGroup(row.groupID))
        XCTAssertEqual(f.store.kind(of: f.docs), .today)
        XCTAssertTrue(f.store.isTabGroupExpanded(row.id), "a new group is open")
        XCTAssertEqual(f.store.tabGroups(in: f.store.activeProfileID).map(\.id), [row.groupID])
        XCTAssertEqual(f.store.spaces(showingTabGroup: row.groupID).map(\.id), [f.home])
    }

    func testAnEmptyGroupGoesToTheTopOfTodayAndIsNamedByItsCount() throws {
        let f = makeStore()
        let row = try XCTUnwrap(f.store.createTabGroup(in: f.home))
        XCTAssertEqual(row.group.displayName, "0 Tabs")
        XCTAssertEqual(titles(f.store.content(for: f.home).today).first, "<0 Tabs: >")
        let tab = try XCTUnwrap(f.store.addTab(toGroup: row.groupID, title: "Wiki", url: url("wiki.test")))
        XCTAssertEqual(f.store.tabGroup(withID: row.groupID)?.displayName, "1 Tab")
        XCTAssertEqual(f.store.tab(withID: tab.id)?.title, "Wiki")
    }

    func testEachNewGroupTakesAColourNoOtherGroupHas() throws {
        let f = makeStore()
        let colors = try (0 ..< TabGroupColor.allCases.count).map { _ in try XCTUnwrap(f.store.createTabGroup(in: f.home)).group.color }
        XCTAssertEqual(colors, TabGroupColor.allCases, "Chrome's nine, in Chrome's order")
        XCTAssertEqual(TabGroupColor.allCases.map(\.rawValue), ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"])
    }

    func testAPinnedTabJoiningAGroupForgetsItsPinnedURL() throws {
        let f = makeStore()
        let pin = f.store.addTab(kind: .pinned, title: "Pin", url: url("pin.test"), in: f.home)
        let row = try XCTUnwrap(f.store.createTabGroup(containing: [pin.id]))
        XCTAssertEqual(titles(f.store.content(for: f.home).pinned), ["<1 Tab: Pin>"], "the group sits where the pin was")
        XCTAssertNil(f.store.tab(withID: pin.id)?.savedURL)
        XCTAssertEqual(f.store.tabGroupReference(withID: row.id)?.group.tabs.map(\.kind), [.today])
    }

    // MARK: Add, remove, reorder

    func testTabsMoveInOutAndWithinAGroup() throws {
        let f = makeStore()
        let row = try XCTUnwrap(f.store.createTabGroup(name: "G", containing: [f.docs]))
        XCTAssertTrue(f.store.moveItem(f.news, to: .tabGroup(row.groupID), index: 0))
        XCTAssertTrue(f.store.moveItem(f.mail, to: .tabGroup(row.groupID), index: 2))
        XCTAssertEqual(groupTabs(f.store, row.groupID), ["News", "Docs", "Mail"])

        XCTAssertTrue(f.store.moveTab(f.mail, to: 0), "a reorder inside the group")
        XCTAssertEqual(groupTabs(f.store, row.groupID), ["Mail", "News", "Docs"])
        XCTAssertTrue(f.store.moveItem(f.docs, relativeTo: f.mail, after: true), "a drop beside a group's tab stays in the group")
        XCTAssertEqual(groupTabs(f.store, row.groupID), ["Mail", "Docs", "News"])

        XCTAssertTrue(f.store.removeTabFromGroup(f.docs, in: f.home))
        XCTAssertEqual(titles(f.store.content(for: f.home).today), ["<G: Mail, News>", "Docs"], "it lands right below the group's row")
        XCTAssertNil(f.store.tabGroupID(holding: f.docs))
    }

    func testOnlyPlainTabsOfTheGroupsProfileCanJoin() throws {
        let f = makeStore()
        let row = try XCTUnwrap(f.store.createTabGroup(containing: [f.docs]))
        let folder = try XCTUnwrap(f.store.createFolder(title: "Folder", in: f.home))
        XCTAssertFalse(f.store.moveItem(folder.id, to: .tabGroup(row.groupID), index: 0), "a folder is not a tab")
        XCTAssertFalse(f.store.canMove(f.docs, intoTabGroup: row.groupID), "already in it")
        XCTAssertTrue(f.store.canMove(f.mail, intoTabGroup: row.groupID))

        let other = f.store.addProfile(name: "Other")
        let foreign = f.store.addTab(kind: .today, title: "Foreign", url: url("foreign.test"), in: f.store.spaces(in: other.id)[0].id)
        XCTAssertFalse(f.store.moveItem(foreign.id, to: .tabGroup(row.groupID), index: 0), "its page is in another profile's storage")
        XCTAssertEqual(f.store.addTabGroup(row.groupID, to: f.store.spaces(in: other.id)[0].id), .failure(.otherProfile))
    }

    func testAGroupsRowMovesBetweenPinnedAndTodayOfItsOwnSpaceOnly() throws {
        let f = makeStore()
        let row = try XCTUnwrap(f.store.createTabGroup(name: "G", containing: [f.docs]))
        XCTAssertTrue(f.store.moveItem(row.id, to: .section(spaceID: f.home, section: .pinned), index: 0))
        XCTAssertEqual(titles(f.store.content(for: f.home).pinned), ["<G: Docs>"])
        XCTAssertEqual(f.store.kind(of: f.docs), .today, "its tabs stay as they are wherever the row sits")
        XCTAssertFalse(f.store.moveItem(row.id, to: .section(spaceID: f.work, section: .pinned), index: 0),
                       "another space gets a row of its own, not this one")
        let folder = try XCTUnwrap(f.store.createFolder(title: "Folder", in: f.home))
        XCTAssertFalse(f.store.moveItem(row.id, to: .folder(folder.id), index: 0), "a group's row sits at section level")
    }

    func testMovingAGroupsRowToAnotherSpaceMovesTheRowNotTheTabs() throws {
        let f = makeStore()
        let row = try XCTUnwrap(f.store.createTabGroup(name: "G", containing: [f.docs]))
        XCTAssertTrue(f.store.moveEntry(row.id, toSpace: f.work))
        XCTAssertEqual(titles(f.store.content(for: f.home).today), ["Mail", "News"])
        XCTAssertEqual(titles(f.store.content(for: f.work).today), ["<G: Docs>"])
        XCTAssertNotNil(f.store.tab(withID: f.docs), "the same tab, never a copy")
    }

    // MARK: One shared instance

    func testAnEditInOneSpaceShowsInEverySpaceThatShowsTheGroup() throws {
        let f = makeStore()
        let row = try XCTUnwrap(f.store.createTabGroup(name: "Shared", containing: [f.docs, f.news]))
        let second = try f.store.addTabGroup(row.groupID, to: f.work).get()
        XCTAssertNotEqual(second.id, row.id, "each space has its own row")
        XCTAssertEqual(second.groupID, row.groupID)
        XCTAssertEqual(f.store.addTabGroup(row.groupID, to: f.work), .failure(.alreadyShown), "one row per space")

        func both() -> [[String]] { [f.home, f.work].map { titles(f.store.content(for: $0).today.filter(\.isTabGroup)) } }
        XCTAssertEqual(both(), [["<Shared: Docs, News>"], ["<Shared: Docs, News>"]])

        f.store.renameTabGroup(row.groupID, to: "Team")
        f.store.setTabGroupColor(.purple, for: row.groupID)
        f.store.updateTab(f.docs, title: "Docs v2", url: url("docs.test/v2"))
        f.store.renameTab(f.news, to: "Headlines")
        XCTAssertTrue(f.store.moveItem(f.mail, to: .tabGroup(row.groupID), index: 0))
        XCTAssertEqual(both(), [["<Team: Mail, Docs v2, Headlines>"], ["<Team: Mail, Docs v2, Headlines>"]])
        XCTAssertEqual(f.store.tabGroupReference(withID: second.id)?.group.color, .purple)
        XCTAssertEqual(f.store.tabGroupReference(withID: second.id)?.group.tabs.first { $0.id == f.docs }?.url, url("docs.test/v2"))

        // One tab identity: the same id in both spaces' rows, so one engine in the shell.
        XCTAssertEqual(f.store.displayTabs(in: f.home).filter { $0.id == f.docs }.count, 1)
        XCTAssertEqual(f.store.displayTabs(in: f.work).filter { $0.id == f.docs }.count, 1)

        f.store.closeTab(f.docs)
        XCTAssertEqual(both(), [["<Team: Mail, Headlines>"], ["<Team: Mail, Headlines>"]], "closed in every space")
        XCTAssertEqual(f.store.archivedTabs.map(\.id), [f.docs], "and kept in the archive")
    }

    func testAGroupsTabIsSelectableInEachSpaceThatShowsIt() throws {
        let f = makeStore()
        let row = try XCTUnwrap(f.store.createTabGroup(containing: [f.docs]))
        _ = try f.store.addTabGroup(row.groupID, to: f.work).get()
        f.store.selectTab(f.docs)
        XCTAssertEqual(f.store.selectedTabID, f.docs)
        f.store.selectSpace(f.work)
        f.store.selectTab(f.docs)
        XCTAssertEqual(f.store.selectedTabID, f.docs)
        XCTAssertEqual(f.store.spaceContaining(tabID: f.docs), f.work, "it counts as the active space's while that shows it")
        XCTAssertTrue(f.store.focusTab(f.docs))
        XCTAssertEqual(f.store.activeSpaceID, f.work, "focusing it does not jump to another space")
    }

    func testAClosedGroupTabReopensIntoItsGroup() throws {
        let f = makeStore()
        let row = try XCTUnwrap(f.store.createTabGroup(name: "G", containing: [f.mail, f.docs, f.news]))
        f.store.closeTab(f.docs)
        XCTAssertEqual(groupTabs(f.store, row.groupID), ["Mail", "News"])
        let reopened = try XCTUnwrap(f.store.reopenMostRecentClosedTab())
        XCTAssertEqual(f.store.tabGroupID(holding: reopened.id), row.groupID)
        XCTAssertEqual(groupTabs(f.store, row.groupID), ["Mail", "Docs", "News"])
    }

    // MARK: Auto-archive and Clear

    func testAGroupsTabsNeverAutoArchiveAndClearLeavesThem() throws {
        let f = makeStore()
        let row = try XCTUnwrap(f.store.createTabGroup(name: "G", containing: [f.docs]))
        f.store.selectTab(f.mail)
        f.store.now = { [day] in day.addingTimeInterval(400 * 24 * 3600) }
        XCTAssertEqual(f.store.autoArchiveIdleTodayTabs(), [f.news], "the idle plain tab goes; the group's tab stays")
        XCTAssertEqual(groupTabs(f.store, row.groupID), ["Docs"])

        XCTAssertTrue(f.store.moveItem(row.id, to: .section(spaceID: f.home, section: .pinned), index: 0))
        XCTAssertTrue(f.store.moveItem(row.id, to: .section(spaceID: f.home, section: .unpinned), index: 0))
        XCTAssertEqual(f.store.clearTodayTabs(in: f.home), [f.mail], "Clear takes the space's own tabs only")
        XCTAssertEqual(groupTabs(f.store, row.groupID), ["Docs"])

        XCTAssertNotNil(f.store.archiveTab(f.docs), "Archive Tab by hand still works")
        XCTAssertEqual(groupTabs(f.store, row.groupID), [])
        XCTAssertNotNil(f.store.tabGroup(withID: row.groupID), "an empty group stays")
    }

    func testAGroupsTabJoinsASplitOnlyAfterLeavingTheGroup() throws {
        let f = makeStore()
        _ = try XCTUnwrap(f.store.createTabGroup(containing: [f.docs]))
        XCTAssertFalse(f.store.canCombineIntoSplit(f.docs, onto: f.mail))
        XCTAssertFalse(f.store.canCombineIntoSplit(f.mail, onto: f.docs))
        XCTAssertNil(f.store.splitTab(f.docs, with: f.mail))
        XCTAssertNil(f.store.createSplit(tabIDs: [f.docs, f.mail], orientation: .horizontal, in: f.home))
        XCTAssertFalse(f.store.canSplit(selection: [f.docs, f.mail]))
        XCTAssertTrue(f.store.pinTab(f.docs), "Pin Tab takes it out of the group")
        XCTAssertNil(f.store.tabGroupID(holding: f.docs))
        XCTAssertEqual(f.store.kind(of: f.docs), .pinned)
    }

    // MARK: Remove from space, ungroup, delete

    func testRemoveFromThisSpaceKeepsTheGroupAndItsTabs() throws {
        let f = makeStore()
        let row = try XCTUnwrap(f.store.createTabGroup(name: "G", containing: [f.docs, f.news]))
        let second = try f.store.addTabGroup(row.groupID, to: f.work).get()
        f.store.selectTab(f.docs)

        XCTAssertTrue(f.store.removeTabGroupReference(row.id))
        XCTAssertEqual(titles(f.store.content(for: f.home).today), ["Mail"])
        XCTAssertEqual(f.store.selectedTabID, f.mail, "the selection leaves the row that went")
        XCTAssertEqual(titles(f.store.content(for: f.work).today), ["<G: Docs, News>"], "the other space keeps it")
        XCTAssertNotNil(f.store.tab(withID: f.docs))

        XCTAssertTrue(f.store.removeTabGroupReference(second.id))
        XCTAssertEqual(groupTabs(f.store, row.groupID), ["Docs", "News"], "shown nowhere, the group is still saved")
        XCTAssertNil(f.store.tab(withID: f.docs), "its tabs are in no space's rows")
        XCTAssertEqual(f.store.tabGroupsAvailable(toAddIn: f.home).map(\.id), [row.groupID], "and the command bar offers it")
        XCTAssertEqual(try f.store.addTabGroup(row.groupID, to: f.home).get().group.tabs.map(\.id), [f.docs, f.news], "back with the same tabs")
    }

    func testUngroupLeavesTheTabsInThisSpaceAndDeletesTheGroupEverywhere() throws {
        let f = makeStore()
        let row = try XCTUnwrap(f.store.createTabGroup(name: "G", containing: [f.docs, f.news]))
        _ = try f.store.addTabGroup(row.groupID, to: f.work).get()
        XCTAssertEqual(f.store.ungroupTabGroup(row.groupID, in: f.home), [f.docs, f.news])
        XCTAssertEqual(titles(f.store.content(for: f.home).today), ["Mail", "Docs", "News"], "plain tabs where the row was")
        XCTAssertEqual(titles(f.store.content(for: f.work).today), [])
        XCTAssertNil(f.store.tabGroup(withID: row.groupID))
        XCTAssertEqual(f.store.parent(of: f.docs), .section(spaceID: f.home, section: .unpinned))
        XCTAssertTrue(f.store.archivedTabs.isEmpty, "nothing closes")
    }

    func testUngroupingAPinnedGroupPinsItsTabs() throws {
        let f = makeStore()
        let row = try XCTUnwrap(f.store.createTabGroup(containing: [f.docs]))
        XCTAssertTrue(f.store.moveItem(row.id, to: .section(spaceID: f.home, section: .pinned), index: 0))
        XCTAssertEqual(f.store.ungroupTabGroup(row.groupID, in: f.home), [f.docs])
        XCTAssertEqual(f.store.kind(of: f.docs), .pinned)
        XCTAssertEqual(f.store.tab(withID: f.docs)?.savedURL, url("docs.test"))
    }

    func testDeleteGroupClosesItsTabsInEverySpace() throws {
        let f = makeStore()
        let row = try XCTUnwrap(f.store.createTabGroup(name: "G", containing: [f.docs, f.news]))
        _ = try f.store.addTabGroup(row.groupID, to: f.work).get()
        f.store.selectTab(f.docs)
        XCTAssertEqual(f.store.deleteTabGroup(row.groupID), [f.docs, f.news])
        XCTAssertNil(f.store.tabGroup(withID: row.groupID))
        XCTAssertEqual(titles(f.store.content(for: f.home).today), ["Mail"])
        XCTAssertEqual(titles(f.store.content(for: f.work).today), [])
        XCTAssertNil(f.store.tab(withID: f.docs))
        XCTAssertEqual(Set(f.store.archivedTabs.map(\.id)), [f.docs, f.news], "closed tabs go to the archive, as any closed tab")
        XCTAssertEqual(f.store.selectedTabID, f.mail)
        XCTAssertTrue(f.store.tabGroupsAvailable(toAddIn: f.home).isEmpty)
    }

    func testDeleteConfirmationSaysWhereTheGroupGoes() {
        XCTAssertEqual(TabGroupDeleteConfirmation.title, "Delete tab group?")
        XCTAssertEqual(TabGroupDeleteConfirmation.confirmTitle, "Delete Group")
        XCTAssertEqual(TabGroupDeleteConfirmation.dontAskTitle, "Don't ask again")
        XCTAssertEqual(TabGroupDeleteConfirmation.message(groupName: "Work", tabCount: 3, spaceCount: 2),
                       "“Work” is removed from every space that shows it (2 spaces). Its 3 tabs close and go to the Archive.")
        XCTAssertEqual(TabGroupDeleteConfirmation.message(groupName: "", tabCount: 1, spaceCount: 1, syncOn: true),
                       "This group is removed from the space that shows it. Its tab closes and goes to the Archive. It is deleted on your other Macs too.")
        XCTAssertEqual(TabGroupDeleteConfirmation.message(groupName: "Later", tabCount: 0, spaceCount: 0), "“Later” is deleted.")

        let defaults = UserDefaults(suiteName: "TabGroupTests.\(UUID().uuidString)")!
        XCTAssertTrue(TabGroupDeleteConfirmation.asks(in: defaults), "asks until told not to")
        TabGroupDeleteConfirmation.setAsks(false, in: defaults)
        XCTAssertFalse(TabGroupDeleteConfirmation.asks(in: defaults))
    }

    // MARK: Spaces and profiles

    func testADeletedOrArchivedSpaceTakesItsRowNotTheGroup() throws {
        let f = makeStore()
        let row = try XCTUnwrap(f.store.createTabGroup(name: "G", containing: [f.docs]))
        let second = try f.store.addTabGroup(row.groupID, to: f.work).get()

        XCTAssertNil(f.store.archiveSpace(f.work))
        XCTAssertNotNil(f.store.tabGroupReference(withID: second.id), "an archived space waits exactly as it was")
        XCTAssertEqual(f.store.spaceContaining(tabID: f.docs), f.home)
        XCTAssertNil(f.store.restoreArchivedSpace(f.work))

        f.store.selectSpace(f.work)
        XCTAssertTrue(f.store.removeSpace(f.home))
        XCTAssertEqual(groupTabs(f.store, row.groupID), ["Docs"], "the group and its tab outlive the space")
        XCTAssertEqual(titles(f.store.content(for: f.work).today), ["<G: Docs>"])

        let spare = f.store.addSpace(name: "Spare").id
        XCTAssertTrue(f.store.removeSpace(f.work))
        XCTAssertEqual(groupTabs(f.store, row.groupID), ["Docs"], "with no space showing it, it is still saved")
        XCTAssertEqual(f.store.tabGroupsAvailable(toAddIn: spare).map(\.id), [row.groupID])
    }

    func testADeletedProfileTakesItsGroups() throws {
        let f = makeStore()
        let other = f.store.addProfile(name: "Other")
        let space = f.store.spaces(in: other.id)[0].id
        let tab = f.store.addTab(kind: .today, title: "Theirs", url: url("theirs.test"), in: space)
        let theirs = try XCTUnwrap(f.store.createTabGroup(in: space, containing: [tab.id]))
        let ours = try XCTUnwrap(f.store.createTabGroup(containing: [f.docs]))
        XCTAssertEqual(f.store.tabGroupsAvailable(toAddIn: f.work).map(\.id), [ours.groupID], "only the space's own profile's groups")
        XCTAssertNil(f.store.deleteProfile(other.id, deletingSpaces: true))
        XCTAssertNil(f.store.tabGroup(withID: theirs.groupID))
        XCTAssertNotNil(f.store.tabGroup(withID: ours.groupID))
    }

    func testASpaceThatChangesProfileKeepsItsGroups() throws {
        let f = makeStore()
        let other = f.store.addProfile(name: "Other", createInitialSpace: false)
        let shared = try XCTUnwrap(f.store.createTabGroup(name: "Shared", containing: [f.docs]))
        _ = try f.store.addTabGroup(shared.groupID, to: f.work).get()
        let own = try XCTUnwrap(f.store.createTabGroup(name: "Own", in: f.work))
        let wiki = try XCTUnwrap(f.store.addTab(toGroup: own.groupID, title: "Wiki", url: url("wiki.test")))

        XCTAssertNil(f.store.changeProfile(ofSpace: f.work, to: other.id))
        // A group only Work shows goes with it, the same group with the same tab.
        XCTAssertEqual(f.store.tabGroup(withID: own.groupID)?.profileID, other.id)
        XCTAssertEqual(f.store.tabGroupID(holding: wiki.id), own.groupID)
        // One other spaces show too stays theirs; Work gets a copy with tabs of its own
        // (one tab cannot have pages in two profiles' storage).
        XCTAssertEqual(f.store.tabGroup(withID: shared.groupID)?.profileID, f.store.profiles[0].id)
        XCTAssertEqual(f.store.spaces(showingTabGroup: shared.groupID).map(\.id), [f.home])
        let copies = SidebarTree.tabGroups(f.store.content(for: f.work).today).filter { $0.group.name == "Shared" }
        XCTAssertEqual(copies.count, 1)
        XCTAssertNotEqual(copies.first?.groupID, shared.groupID)
        XCTAssertEqual(copies.first?.group.profileID, other.id)
        XCTAssertEqual(copies.first?.group.tabs.map(\.url), [url("docs.test")])
        XCTAssertNotEqual(copies.first?.group.tabs.first?.id, f.docs)
        XCTAssertEqual(f.store.tabGroupsAvailable(toAddIn: f.home).map(\.name), [], "Home's profile has no group it does not show")
    }

    // MARK: Command bar

    func testTheCommandBarListsOnlyGroupsTheSpaceDoesNotShow() throws {
        let f = makeStore()
        let here = try XCTUnwrap(f.store.createTabGroup(name: "Here", containing: [f.docs]))
        let there = try XCTUnwrap(f.store.createTabGroup(name: "There", color: .green, in: f.work))
        _ = f.store.addTab(toGroup: there.groupID, title: "A", url: url("a.test"))
        _ = f.store.addTab(toGroup: there.groupID, title: "B", url: url("b.test"))

        let rows = TabGroupCommandBarRow.rows(in: f.store, query: "", enabled: true)
        XCTAssertEqual(rows, [TabGroupCommandBarRow(id: there.groupID, name: "There", color: .green, tabCount: 2)])
        XCTAssertEqual(rows.first?.countText, "2 Tabs")
        XCTAssertEqual(TabGroupCommandBarRow.rows(in: f.store, spaceID: f.work, query: "", enabled: true).map(\.id), [here.groupID])

        XCTAssertTrue(TabGroupCommandBarRow.rows(in: f.store, query: "g", enabled: true).isEmpty, "typing puts the list away")
        XCTAssertTrue(TabGroupCommandBarRow.rows(in: f.store, query: "", enabled: false).isEmpty, "the setting is off")

        _ = try f.store.addTabGroup(there.groupID).get()
        XCTAssertTrue(TabGroupCommandBarRow.rows(in: f.store, query: "", enabled: true).isEmpty, "added: no longer offered here")
        XCTAssertEqual(titles(f.store.content(for: f.home).today).first, "<There: A, B>", "at the top of Today")
    }

    func testTheSettingIsOffByDefault() {
        let defaults = UserDefaults(suiteName: "TabGroupTests.\(UUID().uuidString)")!
        XCTAssertFalse(TabGroupsPreference.isEnabled(in: defaults))
        TabGroupsPreference.setEnabled(true, in: defaults)
        XCTAssertTrue(TabGroupsPreference.isEnabled(in: defaults))
        XCTAssertEqual(TabGroupsPreference.defaultsKey, "rearc.tabGroupsEnabled")
    }

    func testAGroupsTabsAreFoundBySearchOnceEach() throws {
        let f = makeStore()
        let row = try XCTUnwrap(f.store.createTabGroup(containing: [f.docs]))
        _ = try f.store.addTabGroup(row.groupID, to: f.work).get()
        XCTAssertEqual(f.store.recentTabSwitcherItems().filter { $0.id == f.docs }.count, 1)
        let results = CommandBarSearch.results(for: "Docs", in: f.store)
        XCTAssertEqual(results.filter { $0.kind == .openTab && $0.tabID == f.docs }.count, 1)
    }

    // MARK: Rows

    private func rows(_ f: Fixture, in spaceID: Space.ID? = nil) -> [UUID] {
        let spaceID = spaceID ?? f.home
        return SidebarListRow.rows(outline: f.store.outline(for: spaceID), expanded: f.store.expandedFolderIDs, pinnedCollapsed: false,
                                   isDragging: false, selection: { f.store.selection(among: $0, inSpace: spaceID) })
            .compactMap { if case .item(let item, _) = $0 { return item.id } else { return nil } }
    }

    func testAGroupsRowIsOpenOrClosedWithNothingInBetween() throws {
        let f = makeStore()
        let row = try XCTUnwrap(f.store.createTabGroup(containing: [f.docs, f.news]))
        f.store.selectTab(f.mail)
        XCTAssertEqual(rows(f), [f.mail, row.id, f.docs, f.news], "open: every tab")
        f.store.toggleFolderExpanded(row.id)
        XCTAssertFalse(f.store.isTabGroupExpanded(row.id), "the folder call closes a group's row too")
        XCTAssertEqual(rows(f), [f.mail, row.id], "closed: none")
        XCTAssertEqual(f.store.outline(for: f.home).today.map(\.kind), [.tab, .tabGroup])
        XCTAssertEqual(f.store.outlineOrder(in: f.home), [f.mail, row.id, f.docs, f.news])
        XCTAssertEqual(f.store.tabGroupColor(holding: f.docs), row.group.color)
        XCTAssertNil(f.store.tabGroupColor(holding: f.mail))
    }

    func testAClosedGroupShowsNoTabEvenASelectedOneAndAFolderStillDoes() throws {
        let tab = UUID(), other = UUID()
        let children = [SidebarOutlineNode(id: tab, kind: .tab), SidebarOutlineNode(id: other, kind: .tab)]
        let group = SidebarOutlineNode(id: UUID(), kind: .tabGroup, children: children)
        let folder = SidebarOutlineNode(id: UUID(), kind: .folder, children: children)

        // Asked with the tab selected, as a file from ReArc 2026.1117.849 could have it.
        XCTAssertEqual(SidebarOutlineRow.rows([group], expanded: [], selected: tab).map(\.id), [group.id])
        XCTAssertEqual(SidebarOutlineRow.peekCandidates([group], expanded: []), [], "none of its tabs shows while selected")
        XCTAssertEqual(SidebarOutlineRow.rows([group], expanded: [group.id], selected: tab).map(\.id), [group.id, tab, other])

        XCTAssertEqual(SidebarOutlineRow.rows([folder], expanded: [], selected: tab).map(\.id), [folder.id, tab], "a folder keeps its peek")
        XCTAssertEqual(SidebarOutlineRow.peekCandidates([folder], expanded: []), [tab, other])
    }

    // MARK: Open and closed

    func testClosingAGroupDeselectsItsTabAndOpeningItSelectsNothing() throws {
        let f = makeStore()
        let row = try XCTUnwrap(f.store.createTabGroup(containing: [f.docs, f.news]))
        f.store.selectTab(f.news)
        XCTAssertEqual(f.store.selectedItemID, f.news)

        f.store.setTabGroupExpanded(row.id, false)
        XCTAssertNil(f.store.selectedItemID, "the space is blank: no other tab takes the selection")
        XCTAssertNil(f.store.selectedTab)
        XCTAssertEqual(rows(f), [f.mail, row.id])
        XCTAssertNotNil(f.store.tab(withID: f.news), "the tab stays in the group")

        f.store.setTabGroupExpanded(row.id, true)
        XCTAssertNil(f.store.selectedItemID, "opening the group selects nothing")
        XCTAssertEqual(rows(f), [f.mail, row.id, f.docs, f.news])

        // Away and back: still blank, not the tab the space had before.
        f.store.selectSpace(f.work)
        f.store.selectSpace(f.home)
        XCTAssertNil(f.store.selectedItemID)
    }

    func testClosingAGroupLeavesAnotherTabsSelectionAlone() throws {
        let f = makeStore()
        let row = try XCTUnwrap(f.store.createTabGroup(containing: [f.docs, f.news]))
        f.store.selectTab(f.mail)
        f.store.setTabGroupExpanded(row.id, false)
        XCTAssertEqual(f.store.selectedItemID, f.mail)
    }

    func testClosingAGroupDeselectsOnlyInTheSpaceOfTheRowThatClosed() throws {
        let f = makeStore()
        let homeRow = try XCTUnwrap(f.store.createTabGroup(containing: [f.docs, f.news]))
        let workRow = try f.store.addTabGroup(homeRow.groupID, to: f.work).get()
        // Two windows: one on Home, one on Work, both showing News.
        let homeWindow = SidebarWindowID(), workWindow = SidebarWindowID()
        f.store.registerWindow(homeWindow, spaceID: f.home)
        f.store.registerWindow(workWindow, spaceID: f.work)
        f.store.windowBecameKey(workWindow)
        f.store.selectTab(f.news)
        f.store.windowBecameKey(homeWindow)
        f.store.selectTab(f.news)
        func shown(_ window: SidebarWindowID) -> UUID? { f.store.selectedItemID(inSpace: f.store.focusedSpaceID(in: window)) }
        XCTAssertEqual([shown(homeWindow), shown(workWindow)], [f.news, f.news])

        // Home's row closes (the key window's): Home is blank, Work keeps the tab.
        f.store.setTabGroupExpanded(homeRow.id, false)
        XCTAssertEqual([shown(homeWindow), shown(workWindow)], [nil, f.news])
        XCTAssertTrue(f.store.isTabGroupExpanded(workRow.id), "open and closed is each row's own")
        XCTAssertEqual(rows(f, in: f.work), [workRow.id, f.docs, f.news])

        // Work's row closes while Home's window is key: Work is blank too, and stays so when its row opens.
        f.store.setTabGroupExpanded(workRow.id, false)
        XCTAssertEqual([shown(homeWindow), shown(workWindow)], [nil, nil])
        f.store.setTabGroupExpanded(workRow.id, true)
        XCTAssertNil(shown(workWindow), "opening the group selects nothing")
        f.store.windowBecameKey(workWindow)
        XCTAssertNil(f.store.selectedItemID)
    }

    func testSelectingAClosedGroupsTabOpensTheGroup() throws {
        let f = makeStore()
        let row = try XCTUnwrap(f.store.createTabGroup(containing: [f.docs, f.news]))
        f.store.selectTab(f.mail)
        f.store.setTabGroupExpanded(row.id, false)

        // The command bar's Switch to Tab and every other jump to a tab go through `focusTab`.
        XCTAssertTrue(f.store.focusTab(f.news))
        XCTAssertEqual(f.store.selectedItemID, f.news)
        XCTAssertTrue(f.store.isTabGroupExpanded(row.id))
        XCTAssertEqual(rows(f), [f.mail, row.id, f.docs, f.news])

        // From another space that does not show the group: its first space opens it.
        f.store.setTabGroupExpanded(row.id, false)
        f.store.selectSpace(f.work)
        XCTAssertTrue(f.store.focusTab(f.docs))
        XCTAssertEqual(f.store.activeSpaceID, f.home)
        XCTAssertEqual(f.store.selectedItemID, f.docs)
        XCTAssertTrue(f.store.isTabGroupExpanded(row.id))
    }

    func testTheKeysThatStepThroughTabsPassAClosedGroup() throws {
        let f = makeStore()
        let extra = f.store.appendTodayTab(title: "Extra", url: url("extra.test"), in: f.home).id
        let row = try XCTUnwrap(f.store.createTabGroup(containing: [f.docs, f.news]))
        XCTAssertEqual(f.store.displayEntries().map(\.id), [f.mail, f.docs, f.news, extra])
        f.store.selectTab(f.docs)
        f.store.selectTab(f.mail)
        f.store.setTabGroupExpanded(row.id, false)

        // Next Tab and Previous Tab.
        f.store.selectNextTab()
        XCTAssertEqual(f.store.selectedItemID, extra)
        f.store.selectNextTab()
        XCTAssertEqual(f.store.selectedItemID, f.mail)
        f.store.selectPreviousTab()
        XCTAssertEqual(f.store.selectedItemID, extra)
        XCTAssertFalse(f.store.isTabGroupExpanded(row.id))

        // ⌘1…9 count the rows on screen.
        XCTAssertEqual(f.store.selectItem(atPosition: 2), extra)
        XCTAssertNil(f.store.selectItem(atPosition: 3))
        XCTAssertEqual(f.store.selectItem(atPosition: 9), extra)
        XCTAssertFalse(f.store.isTabGroupExpanded(row.id))

        // ⌃Tab and ⌃⌘←/→ list no tab of a closed group; the ⌘T bar still does.
        XCTAssertEqual(Set(f.store.recentTabSwitcherItems(onScreenOnly: true).map(\.id)), [f.mail, extra])
        XCTAssertEqual(Set(f.store.recentTabSwitcherItems().map(\.id)), [f.mail, f.docs, f.news, extra])
        XCTAssertTrue(CommandBarSearch.recentTabResults(in: f.store).contains { $0.tabID == f.docs })

        f.store.setTabGroupExpanded(row.id, true)
        XCTAssertEqual(f.store.selectItem(atPosition: 2), f.docs, "open: its tabs count again")
        XCTAssertEqual(Set(f.store.recentTabSwitcherItems(onScreenOnly: true).map(\.id)), [f.mail, f.docs, f.news, extra])
    }

    func testAClosedTabsSelectionNeverLandsInAClosedGroup() throws {
        let f = makeStore()
        let row = try XCTUnwrap(f.store.createTabGroup(containing: [f.docs, f.news]))
        f.store.selectTab(f.mail)
        f.store.setTabGroupExpanded(row.id, false)
        f.store.closeTab(f.mail)
        XCTAssertNil(f.store.selectedItemID, "only the closed group's tabs are left: blank")
        XCTAssertFalse(f.store.isTabGroupExpanded(row.id))

        // A space shown for the first time picks its first row on screen.
        let pin = f.store.addTab(kind: .pinned, title: "Pin", url: url("pin.test"), in: f.work).id
        let workRow = try f.store.addTabGroup(row.groupID, to: f.work, section: .pinned).get()
        f.store.setTabGroupExpanded(workRow.id, false)
        XCTAssertEqual(f.store.displayEntries(in: f.work).map(\.id), [f.docs, f.news, pin])
        XCTAssertEqual(f.store.selectedItemID(inSpace: f.work), pin)
    }

    func testTheSelectedTabJoiningAClosedGroupOpensIt() throws {
        let f = makeStore()
        let row = try XCTUnwrap(f.store.createTabGroup(containing: [f.docs]))
        f.store.setTabGroupExpanded(row.id, false)
        f.store.selectTab(f.mail)
        XCTAssertTrue(f.store.moveItem(f.mail, to: .tabGroup(row.groupID), index: 1))
        XCTAssertEqual(f.store.selectedItemID, f.mail, "the page on screen stays on screen")
        XCTAssertTrue(f.store.isTabGroupExpanded(row.id))

        f.store.setTabGroupExpanded(row.id, false)
        f.store.selectTab(f.news)
        XCTAssertTrue(f.store.moveItem(f.mail, to: .section(spaceID: f.home, section: .unpinned), index: 0))
        XCTAssertFalse(f.store.isTabGroupExpanded(row.id), "another tab's move opens nothing")
    }
}
