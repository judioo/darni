import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Tab groups in the shell (`BrowserViewModel+TabGroups`): the setting, the
/// menus' commands, the command bar's list, Delete Group's question, and a
/// group's tab having one page whichever spaces show it.
final class TabGroupShellTests: XCTestCase {
    private func url(_ host: String) -> URL { URL(string: "https://\(host)/")! }

    /// Home (active) and Work in one profile; the setting on unless asked.
    private func makeModel(enabled: Bool = true) -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Home", sortRank: "a")])
        store.addSpace(name: "Work")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-tabgroups-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.externalLinkDefaults = UserDefaults(suiteName: "TabGroupShellTests.\(UUID().uuidString)")!
        model.tabGroupsEnabled = enabled
        model.asksBeforeDeletingTabGroup = true
        return model
    }

    private func work(_ model: BrowserViewModel) -> Space.ID { model.store.spaces.first { $0.name == "Work" }!.id }

    // MARK: The setting

    func testTheSettingIsSavedAndOffMakesNothingNew() throws {
        let model = makeModel(enabled: false)
        XCTAssertFalse(TabGroupsPreference.isEnabled(in: model.externalLinkDefaults))
        let tab = model.store.addTab(kind: .today, title: "Docs", url: url("docs.test"))
        XCTAssertNil(model.newTabGroup(containing: [tab.id]), "off: no group is made")
        XCTAssertTrue(model.store.tabGroupsByID.isEmpty)

        model.tabGroupsEnabled = true
        XCTAssertTrue(TabGroupsPreference.isEnabled(in: model.externalLinkDefaults))
        let row = try XCTUnwrap(model.newTabGroup(containing: [tab.id]))

        // Off again: the group stays in the sidebar and keeps working; nothing lists or makes one.
        model.tabGroupsEnabled = false
        model.store.selectSpace(work(model))
        model.newTab()
        XCTAssertTrue(model.commandBarTabGroups.isEmpty, "off: the command bar lists none")
        model.dismissCommandBar()
        XCTAssertNotNil(model.store.tabGroup(withID: row.groupID))
        XCTAssertTrue(model.addTab(model.store.addTab(kind: .today, title: "More", url: url("more.test"), in: model.store.spaces[0].id).id,
                                   toGroup: row.groupID), "an existing group still takes tabs (a drop on its row)")
    }

    func testTheBlankSidebarsMenuOffersNewTabGroupOnlyWhileTheSettingIsOn() throws {
        let model = makeModel(enabled: false)
        let home = model.store.activeSpaceID
        func titles() -> [String] { SidebarEmptySpaceMenu.menu(model: model, spaceID: home).items.filter { !$0.isSeparatorItem }.map(\.title) }
        XCTAssertFalse(titles().contains("New Tab Group"))
        model.tabGroupsEnabled = true
        XCTAssertEqual(titles(), ["New Tab", "New Folder", "New Tab Group", "Reopen Closed Tab", "Task Manager"])

        let item = try XCTUnwrap(SidebarEmptySpaceMenu.menu(model: model, spaceID: work(model)).items.first { $0.title == "New Tab Group" })
        _ = item.target?.perform(item.action, with: item)
        let row = try XCTUnwrap(SidebarTree.tabGroups(model.store.content(for: work(model)).today).first, "in the list's own space")
        XCTAssertEqual(model.tabGroupEditor?.anchorID, row.id)
    }

    // MARK: Creating and editing

    func testANewGroupOpensItsEditorAtOnce() throws {
        let model = makeModel()
        let tab = model.store.addTab(kind: .today, title: "Docs", url: url("docs.test"))
        let row = try XCTUnwrap(model.newTabGroup(containing: [tab.id]))
        XCTAssertEqual(model.tabGroupEditor, TabGroupEditorRequest(anchorID: row.id, groupID: row.groupID), "from its own row")
        XCTAssertEqual(model.store.tabGroupID(holding: tab.id), row.groupID)

        let empty = try XCTUnwrap(model.newTabGroup(in: work(model)))
        XCTAssertEqual(model.tabGroupEditor?.groupID, empty.groupID, "New Tab Group on the New Tab row: an empty group, named next")
        XCTAssertTrue(empty.group.tabs.isEmpty)

        model.removeTabGroupFromSpace(empty.id)
        XCTAssertNil(model.tabGroupEditor, "the editor goes with its row")
    }

    func testTabsJoinAndLeaveAGroup() throws {
        let model = makeModel()
        let docs = model.store.addTab(kind: .today, title: "Docs", url: url("docs.test"))
        let news = model.store.addTab(kind: .today, title: "News", url: url("news.test"))
        let row = try XCTUnwrap(model.newTabGroup(containing: [docs.id]))
        model.store.setTabGroupExpanded(row.id, false)

        XCTAssertTrue(model.addTab(news.id, toGroup: row.groupID))
        XCTAssertEqual(model.store.tabGroup(withID: row.groupID)?.tabs.map(\.id), [docs.id, news.id])
        XCTAssertTrue(model.store.isTabGroupExpanded(row.id), "the group opens to show what joined")

        model.removeTabFromGroup(docs.id)
        XCTAssertNil(model.store.tabGroupID(holding: docs.id))
        XCTAssertEqual(model.store.tabGroup(withID: row.groupID)?.tabs.map(\.id), [news.id])
        XCTAssertFalse(model.canSplitWithSelectedTab(news.id), "a group's tab does not split")
    }

    func testNewTabInGroupPutsTheBarsTabInTheGroup() throws {
        let model = makeModel()
        let row = try XCTUnwrap(model.newTabGroup())
        model.newTab(inGroup: row.groupID)
        XCTAssertTrue(model.isCommandBarPresented)
        XCTAssertEqual(model.commandBarNewTabGroupID, row.groupID)
        model.navigateCommandBar(to: url("wiki.test"))
        let tab = try XCTUnwrap(model.store.tabGroup(withID: row.groupID)?.tabs.first)
        XCTAssertEqual(tab.url, url("wiki.test"))
        XCTAssertEqual(model.store.selectedTabID, tab.id)
        XCTAssertNil(model.commandBarNewTabGroupID)

        // A plain ⌘T afterwards opens a plain tab.
        model.dismissCommandBar()
        model.newTab()
        model.navigateCommandBar(to: url("plain.test"))
        XCTAssertEqual(model.store.tabGroup(withID: row.groupID)?.tabs.count, 1)

        model.newTab(inGroup: row.groupID)
        model.dismissCommandBar()
        XCTAssertNil(model.commandBarNewTabGroupID, "Esc forgets the group")
    }

    // MARK: The command bar

    func testTheEmptyBarListsGroupsOfOtherSpacesAndAClickAddsOne() throws {
        let model = makeModel()
        let there = try XCTUnwrap(model.newTabGroup(in: work(model)))
        model.store.renameTabGroup(there.groupID, to: "There")
        _ = model.store.addTab(toGroup: there.groupID, title: "A", url: url("a.test"))
        let here = try XCTUnwrap(model.newTabGroup())
        model.tabGroupEditor = nil

        XCTAssertTrue(model.commandBarTabGroups.isEmpty, "only while the ⌘T bar is open")
        model.newTab()
        XCTAssertEqual(model.commandBarTabGroups.map(\.id), [there.groupID], "not the group this space shows")
        XCTAssertEqual(model.commandBarTabGroups.first?.name, "There")
        XCTAssertEqual(model.commandBarTabGroups.first?.countText, "1 Tab")
        model.commandBarText = "t"
        XCTAssertTrue(model.commandBarTabGroups.isEmpty, "typing puts the list away")
        model.commandBarText = ""
        XCTAssertEqual(model.commandBarTabGroups.count, 1)

        model.addTabGroupToActiveSpace(there.groupID)
        XCTAssertFalse(model.isCommandBarPresented)
        let home = model.store.activeSpaceID
        let rows = SidebarTree.tabGroups(model.store.content(for: home).today)
        XCTAssertEqual(rows.map(\.groupID), [there.groupID, here.groupID], "at the top of Today")
        XCTAssertEqual(model.sidebarRowReveal?.id, rows.first?.id, "and scrolled into view")
        model.focusLocation()
        XCTAssertTrue(model.commandBarTabGroups.isEmpty, "⌘L is not the new-tab bar")
    }

    func testTheSectionTakesNoRoomWithoutGroups() {
        XCTAssertEqual(CommandBarTabGroupsSection.height(rows: 0), 0)
        XCTAssertGreaterThan(CommandBarTabGroupsSection.height(rows: 1), 0)
        XCTAssertEqual(CommandBarTabGroupsSection.height(rows: 9), CommandBarTabGroupsSection.height(rows: CommandBarTabGroupsSection.maxVisibleRows),
                       "more than four scroll")
    }

    // MARK: Delete, ungroup, remove

    func testDeleteGroupAsksFirstAndDontAskAgainIsRemembered() throws {
        let model = makeModel()
        let docs = model.store.addTab(kind: .today, title: "Docs", url: url("docs.test"))
        let row = try XCTUnwrap(model.newTabGroup(containing: [docs.id]))
        _ = try model.store.addTabGroup(row.groupID, to: work(model)).get()
        var asked: [(name: String, spaces: Int)] = []
        var answer = TabGroupDeletionAnswer(delete: false)
        model.answerTabGroupDeletion = { group, spaces in
            asked.append((group.displayName, spaces))
            return answer
        }

        model.requestTabGroupDeletion(row.groupID)
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.spaces, 2, "the question says how many spaces show it")
        XCTAssertNotNil(model.store.tabGroup(withID: row.groupID), "Cancel keeps the group")

        answer = TabGroupDeletionAnswer(delete: true, dontAskAgain: true)
        model.requestTabGroupDeletion(row.groupID)
        XCTAssertNil(model.store.tabGroup(withID: row.groupID))
        XCTAssertNil(model.store.tab(withID: docs.id))
        XCTAssertEqual(model.store.archivedTabs.map(\.id), [docs.id])
        XCTAssertNil(model.tabGroupEditor)
        XCTAssertFalse(model.asksBeforeDeletingTabGroup)
        XCTAssertFalse(TabGroupDeleteConfirmation.asks(in: model.externalLinkDefaults))

        let next = try XCTUnwrap(model.newTabGroup())
        model.requestTabGroupDeletion(next.groupID)
        XCTAssertEqual(asked.count, 2, "not asked again")
        XCTAssertNil(model.store.tabGroup(withID: next.groupID))
    }

    func testUngroupFromTheCommandBarPutsTheTabsInTheSpaceOnScreen() throws {
        let model = makeModel()
        let there = try XCTUnwrap(model.newTabGroup(in: work(model)))
        let tab = try XCTUnwrap(model.store.addTab(toGroup: there.groupID, title: "A", url: url("a.test")))
        model.ungroupTabGroup(there.groupID)
        XCTAssertNil(model.store.tabGroup(withID: there.groupID))
        XCTAssertEqual(model.store.parent(of: tab.id), .section(spaceID: model.store.activeSpaceID, section: .unpinned))
        XCTAssertTrue(SidebarTree.tabGroups(model.store.content(for: work(model)).today).isEmpty)
    }

    // MARK: Open and closed

    func testClosingAGroupBlanksTheWindowAndKeepsThePage() throws {
        let model = makeModel()
        let home = model.store.activeSpaceID
        let profile = model.store.activeProfileID
        let docs = model.store.addTab(kind: .today, title: "Docs", url: url("docs.test"))
        let plain = model.store.addTab(kind: .today, title: "Plain", url: url("plain.test"))
        let row = try XCTUnwrap(model.newTabGroup(containing: [docs.id]))
        model.selectTab(docs.id)
        let engine = try XCTUnwrap(model.engineHost.engine(forTabID: docs.id, profileID: profile))

        model.toggleTabGroupExpanded(row.id)
        XCTAssertFalse(model.store.isTabGroupExpanded(row.id))
        XCTAssertNil(model.store.selectedItemID, "nothing is selected")
        XCTAssertNil(model.selectedTab(in: nil), "the window shows the blank page, not the nearest tab")
        XCTAssertNil(model.focusedEngine(in: nil))
        XCTAssertTrue(model.engineHost.engine(forTabID: docs.id, profileID: profile) === engine, "the tab keeps its page")
        XCTAssertEqual(model.visibleRowIDs(spaceID: home, in: nil), [plain.id, row.id], "no row for its tab")

        model.toggleTabGroupExpanded(row.id)
        XCTAssertNil(model.store.selectedItemID, "opening it selects nothing")
        XCTAssertEqual(model.visibleRowIDs(spaceID: home, in: nil), [plain.id, row.id, docs.id])
        model.selectTab(docs.id)
        XCTAssertTrue(model.focusedEngine(in: nil) === engine, "the same page when the tab is chosen again")
    }

    func testAClosedGroupsRowsShowNoTabEvenASelectedOne() throws {
        let model = makeModel()
        let home = model.store.activeSpaceID
        let docs = model.store.addTab(kind: .today, title: "Docs", url: url("docs.test"))
        let row = try XCTUnwrap(model.newTabGroup(containing: [docs.id]))
        let pinned = model.store.addTab(kind: .pinned, title: "Pin", url: url("pin.test"))
        let folder = try XCTUnwrap(model.store.createFolder(containing: [pinned.id]))
        model.store.setFolderExpanded(folder.id, false)

        let today = model.store.content(for: home).today
        XCTAssertEqual(SidebarRowItem.rows(today, expanded: [], selected: docs.id).map(\.id), [row.id], "closed: the header alone")
        XCTAssertEqual(SidebarRowItem.rows(today, expanded: [row.id], selected: docs.id).map(\.id), [row.id, docs.id])
        XCTAssertEqual(SidebarRowItem.rows(model.store.content(for: home).pinned, expanded: [], selected: pinned.id).map(\.id),
                       [folder.id, pinned.id], "a folder still shows its selected tab")
    }

    func testSwitchToTabFromTheCommandBarOpensAClosedGroup() throws {
        let model = makeModel()
        let docs = model.store.addTab(kind: .today, title: "Docs", url: url("docs.test"))
        let plain = model.store.addTab(kind: .today, title: "Plain", url: url("plain.test"))
        let row = try XCTUnwrap(model.newTabGroup(containing: [docs.id]))
        model.tabGroupEditor = nil
        model.selectTab(plain.id)
        model.setTabGroupExpanded(row.id, false)

        model.focusLocation()
        model.commandBarText = "Docs"
        let index = try XCTUnwrap(model.commandBarResults.firstIndex { $0.kind == .openTab && $0.tabID == docs.id })
        model.commandBarHighlightedIndex = index
        model.submitCommandBar()
        XCTAssertEqual(model.store.selectedItemID, docs.id)
        XCTAssertTrue(model.store.isTabGroupExpanded(row.id), "the group opens to show the tab")
    }

    // MARK: One tab, one page

    func testAGroupsTabHasOnePageWhicheverSpacesShowIt() throws {
        let model = makeModel()
        let home = model.store.activeSpaceID
        let profile = model.store.activeProfileID
        let docs = model.store.addTab(kind: .today, title: "Docs", url: url("docs.test"))
        let row = try XCTUnwrap(model.newTabGroup(containing: [docs.id]))
        let second = try model.store.addTabGroup(row.groupID, to: work(model)).get()
        model.selectTab(docs.id)
        let engine = try XCTUnwrap(model.engineHost.engine(forTabID: docs.id, profileID: profile))

        model.selectSpace(work(model))
        model.selectTab(docs.id)
        model.reconcileEngineOwnership()
        XCTAssertTrue(model.engineHost.engine(forTabID: docs.id, profileID: profile) === engine, "the same page in the other space")
        XCTAssertEqual(model.engineHost.allTabEngines().filter { $0.0 == docs.id }.count, 1)

        model.removeTabGroupFromSpace(second.id)
        XCTAssertTrue(model.engineHost.engine(forTabID: docs.id, profileID: profile) === engine, "still shown in Home: the page stays")
        model.selectSpace(home)
        model.removeTabGroupFromSpace(row.id)
        XCTAssertNil(model.engineHost.engine(forTabID: docs.id, profileID: profile), "shown nowhere: the page closes")
        XCTAssertEqual(model.store.tabGroup(withID: row.groupID)?.tabs.map(\.id), [docs.id], "the group keeps the tab")
    }

    // MARK: Rows

    func testAGroupsTabRowCarriesItsGroupsColour() throws {
        let model = makeModel()
        let home = model.store.activeSpaceID
        let docs = model.store.addTab(kind: .today, title: "Docs", url: url("docs.test"))
        let plain = model.store.addTab(kind: .today, title: "Plain", url: url("plain.test"))
        let row = try XCTUnwrap(model.newTabGroup(containing: [docs.id]))
        model.store.setTabGroupColor(.green, for: row.groupID)
        let chrome = ThemeChromeColors(theme: .default, dark: false)
        XCTAssertEqual(PlainRowState.read(id: docs.id, model: model, spaceID: home, chrome: chrome).groupColor, .green)
        XCTAssertNil(PlainRowState.read(id: plain.id, model: model, spaceID: home, chrome: chrome).groupColor)
        XCTAssertTrue(PlainRowState.read(id: row.id, model: model, spaceID: home, chrome: chrome).needsHosting, "the group's own row is a SwiftUI row")

        let listed = SidebarRowItem.rows(model.store.content(for: home).today, expanded: [row.id], selected: nil)
        XCTAssertEqual(listed.map(\.id), [plain.id, row.id, docs.id])
        XCTAssertEqual(listed.map(\.depth), [0, 0, 1])
        XCTAssertFalse(BrowserViewModel.isSelectableRow(model.store.entry(withID: row.id)), "a click on the row opens and closes it")
        XCTAssertNotNil(NSImage(systemSymbolName: TabGroupMetrics.symbol, accessibilityDescription: nil), "the glyph exists on this system")
        XCTAssertFalse(TabGroupMetrics.symbol.contains("folder"))
    }

    func testEveryColourHasReadableInkOnBothAppearances() {
        for color in TabGroupColor.allCases {
            for dark in [false, true] {
                let fill = color.fill(dark: dark)
                func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
                let luminance = 0.2126 * linear(fill.red) + 0.7152 * linear(fill.green) + 0.0722 * linear(fill.blue)
                let ink = color.inkIsDark(dark: dark) ? 0.0 : 1.0
                let contrast = (max(luminance, ink) + 0.05) / (min(luminance, ink) + 0.05)
                XCTAssertGreaterThanOrEqual(contrast, 3, "\(color.title) \(dark ? "dark" : "light"): \(contrast)")
            }
        }
    }
}
