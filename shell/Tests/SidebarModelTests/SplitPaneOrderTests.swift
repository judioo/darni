import XCTest
@testable import SidebarModel

/// Split view's pane order, Add to Split View and Separate (owner report
/// 2026-11-22): a pane moves along its split and keeps its width and the
/// focus, a tab joins a split of its space from its menu, and a separated
/// pane stays in the sidebar.
final class SplitPaneOrderTests: XCTestCase {

    private func url(_ name: String) -> URL { URL(string: "https://\(name.lowercased().replacingOccurrences(of: " ", with: "-")).test/")! }

    /// A store with a split of `panes` Today tabs titled A, B, C, D.
    private func makeSplit(
        panes: Int = 3,
        orientation: SplitLayoutOrientation = .horizontal
    ) throws -> (store: SidebarStore, splitID: SplitViewItem.ID, tabs: [Tab]) {
        let store = SidebarStore(spaces: [Space(name: "One")])
        let tabs = ["A", "B", "C", "D"].prefix(panes).map { store.addTab(kind: .today, title: $0, url: url($0.lowercased())) }
        let split = try XCTUnwrap(store.createSplit(tabIDs: tabs.map(\.id), orientation: orientation))
        return (store, split.id, Array(tabs))
    }

    private func order(_ store: SidebarStore, _ splitID: SplitViewItem.ID) -> [String] {
        store.split(withID: splitID)?.tabs.map(\.title) ?? []
    }

    // MARK: Move Pane

    func testAPaneMovesLeftAndRightOnePlaceAtATime() throws {
        let (store, splitID, tabs) = try makeSplit()
        XCTAssertTrue(store.moveSplitPane(splitID: splitID, tabID: tabs[0].id, by: 1))
        XCTAssertEqual(order(store, splitID), ["B", "A", "C"])
        XCTAssertTrue(store.moveSplitPane(splitID: splitID, tabID: tabs[0].id, by: 1))
        XCTAssertEqual(order(store, splitID), ["B", "C", "A"])
        XCTAssertTrue(store.moveSplitPane(splitID: splitID, tabID: tabs[0].id, by: -1))
        XCTAssertEqual(order(store, splitID), ["B", "A", "C"])
        XCTAssertTrue(store.moveSplitPane(splitID: splitID, tabID: tabs[2].id, by: -2), "more than one place at once")
        XCTAssertEqual(order(store, splitID), ["C", "B", "A"])
        XCTAssertEqual(store.split(withID: splitID)?.orientation, .horizontal)
        XCTAssertEqual(store.split(withID: splitID)?.tabs.count, 3, "no pane is lost or copied")
    }

    func testAStackedSplitMovesItsPanesUpAndDown() throws {
        let (store, splitID, tabs) = try makeSplit(orientation: .vertical)
        let moves = try XCTUnwrap(store.split(withID: splitID)).paneMoves(for: tabs[1].id)
        XCTAssertEqual(moves.map(\.title), ["Move Pane Up", "Move Pane Down"])
        XCTAssertEqual(moves.map(\.isEnabled), [true, true])

        XCTAssertTrue(store.moveSplitPane(splitID: splitID, tabID: tabs[1].id, by: moves[0].offset))
        XCTAssertEqual(order(store, splitID), ["B", "A", "C"], "Up is towards the first pane")
        XCTAssertTrue(store.moveSplitPane(splitID: splitID, tabID: tabs[1].id, by: moves[1].offset))
        XCTAssertTrue(store.moveSplitPane(splitID: splitID, tabID: tabs[1].id, by: moves[1].offset))
        XCTAssertEqual(order(store, splitID), ["A", "C", "B"], "Down is towards the last")
        XCTAssertEqual(store.split(withID: splitID)?.orientation, .vertical, "a move never turns the split")
    }

    func testTheEndsAreNoOps() throws {
        let (store, splitID, tabs) = try makeSplit()
        let journal = store.mutationJournal.allEntries().count
        var mutations = 0
        store.onDidMutate = { mutations += 1 }
        let before = try XCTUnwrap(store.split(withID: splitID))

        XCTAssertFalse(store.moveSplitPane(splitID: splitID, tabID: tabs[0].id, by: -1), "the first pane has nowhere to go left")
        XCTAssertFalse(store.moveSplitPane(splitID: splitID, tabID: tabs[2].id, by: 1), "nor the last pane right")
        XCTAssertFalse(store.moveSplitPane(splitID: splitID, tabID: tabs[1].id, by: 0))
        XCTAssertFalse(store.moveSplitPane(splitID: splitID, tabID: tabs[1].id, by: 2), "past the end is refused, not clamped")
        XCTAssertFalse(store.moveSplitPane(splitID: splitID, tabID: UUID(), by: 1), "not a pane of the split")
        XCTAssertFalse(store.moveSplitPane(splitID: UUID(), tabID: tabs[0].id, by: 1), "no such split")
        XCTAssertFalse(store.canMoveSplitPane(splitID: splitID, tabID: tabs[0].id, by: -1))
        XCTAssertTrue(store.canMoveSplitPane(splitID: splitID, tabID: tabs[0].id, by: 1))

        XCTAssertEqual(store.split(withID: splitID), before, "nothing about the split changed")
        XCTAssertEqual(mutations, 0, "and nothing was saved or redrawn")
        XCTAssertEqual(store.mutationJournal.allEntries().count, journal, "or sent to sync")
    }

    func testAPanesWidthFollowsIt() throws {
        let (store, splitID, tabs) = try makeSplit()
        store.resizeSplitPanes(splitID: splitID, widthFactors: [tabs[0].id: 0.5, tabs[1].id: 0.3, tabs[2].id: 0.2])

        XCTAssertTrue(store.moveSplitPane(splitID: splitID, tabID: tabs[2].id, by: -2))
        let split = try XCTUnwrap(store.split(withID: splitID))
        XCTAssertEqual(split.tabs.map(\.title), ["C", "A", "B"])
        // By position, as the content area lays them out.
        let widths = split.tabs.map { split.widthFactors[$0.id] ?? 0 }
        for (width, expected) in zip(widths, [0.2, 0.5, 0.3]) { XCTAssertEqual(width, expected, accuracy: 1e-9) }
        XCTAssertEqual(split.widthFactors.count, 3)
        XCTAssertEqual(split.widthFactors.values.reduce(0, +), 1, accuracy: 1e-9)
    }

    func testTheMovedPaneHasTheFocus() throws {
        let (store, splitID, tabs) = try makeSplit()
        store.selectSplit(splitID, focusTabID: tabs[0].id)

        XCTAssertTrue(store.moveSplitPane(splitID: splitID, tabID: tabs[0].id, by: 1))
        XCTAssertEqual(store.split(withID: splitID)?.focusTabID, tabs[0].id, "the focused pane keeps the focus where it goes")
        XCTAssertEqual(store.selectedTabID, tabs[0].id)
        XCTAssertEqual(store.selectedItemID, splitID, "the split stays the selected row")

        // Another pane moved from the sidebar row takes the focus (as a pane dropped on the page does).
        XCTAssertTrue(store.moveSplitPane(splitID: splitID, tabID: tabs[2].id, by: -1))
        XCTAssertEqual(order(store, splitID), ["B", "C", "A"])
        XCTAssertEqual(store.split(withID: splitID)?.focusTabID, tabs[2].id)

        // A split that is not on screen is reordered where it is: the selection stays put.
        let other = store.addTab(kind: .today, title: "Other", url: url("other"))
        store.selectTab(other.id)
        XCTAssertTrue(store.moveSplitPane(splitID: splitID, tabID: tabs[1].id, by: 1))
        XCTAssertEqual(store.selectedItemID, other.id)
        XCTAssertEqual(store.split(withID: splitID)?.focusTabID, tabs[1].id)
    }

    func testAnUnreadPaneMovedInTheShownSplitIsRead() throws {
        let (store, splitID, tabs) = try makeSplit()
        store.selectSplit(splitID, focusTabID: tabs[0].id)
        store.setUnread(true, for: tabs[2].id)
        XCTAssertTrue(store.moveSplitPane(splitID: splitID, tabID: tabs[2].id, by: -1))
        XCTAssertEqual(store.tab(withID: tabs[2].id)?.isUnread, false, "it has the focus in the split on screen")
    }

    // MARK: Drag to a place

    func testAPaneDropsOnAnyPlaceOfItsSplit() throws {
        let (store, splitID, tabs) = try makeSplit(panes: 4)
        XCTAssertTrue(store.moveSplitPane(splitID: splitID, tabID: tabs[0].id, to: 2))
        XCTAssertEqual(order(store, splitID), ["B", "C", "A", "D"], "the index is the pane's place once it is there")
        XCTAssertTrue(store.moveSplitPane(splitID: splitID, tabID: tabs[3].id, to: 0))
        XCTAssertEqual(order(store, splitID), ["D", "B", "C", "A"])
        XCTAssertFalse(store.moveSplitPane(splitID: splitID, tabID: tabs[3].id, to: 0), "dropped on its own place: nothing moves")
        XCTAssertTrue(store.moveSplitPane(splitID: splitID, tabID: tabs[3].id, to: 99), "past the end is the last place")
        XCTAssertEqual(order(store, splitID), ["B", "C", "A", "D"])
        XCTAssertTrue(store.moveSplitPane(splitID: splitID, tabID: tabs[3].id, to: -5))
        XCTAssertEqual(order(store, splitID), ["D", "B", "C", "A"])
        XCTAssertFalse(store.moveSplitPane(splitID: splitID, tabID: UUID(), to: 1))
        XCTAssertEqual(store.split(withID: splitID)?.focusTabID, tabs[3].id, "the dropped pane has the focus")
    }

    func testTheChipUnderThePointerIsTheDropPlace() {
        // Three chips share 300 pt.
        XCTAssertEqual(SplitPaneChipDrag.chipIndex(x: 0, width: 300, count: 3), 0)
        XCTAssertEqual(SplitPaneChipDrag.chipIndex(x: 99, width: 300, count: 3), 0)
        XCTAssertEqual(SplitPaneChipDrag.chipIndex(x: 100, width: 300, count: 3), 1)
        XCTAssertEqual(SplitPaneChipDrag.chipIndex(x: 250, width: 300, count: 3), 2)
        XCTAssertEqual(SplitPaneChipDrag.chipIndex(x: 300, width: 300, count: 3), 2, "the row's far edge is the last chip")
        XCTAssertEqual(SplitPaneChipDrag.chipIndex(x: -3, width: 300, count: 3), 0, "the row's padding counts as the chip beside it")
        XCTAssertEqual(SplitPaneChipDrag.chipIndex(x: 400, width: 300, count: 3), 2)
        XCTAssertNil(SplitPaneChipDrag.chipIndex(x: 10, width: 0, count: 3), "a row not laid out yet has no chips")
        XCTAssertNil(SplitPaneChipDrag.chipIndex(x: 10, width: 300, count: 0))

        XCTAssertEqual(SplitPaneChipDrag.destination(from: 0, x: 250, width: 300, count: 3), 2)
        XCTAssertEqual(SplitPaneChipDrag.destination(from: 2, x: 20, width: 300, count: 3), 0)
        XCTAssertNil(SplitPaneChipDrag.destination(from: 1, x: 150, width: 300, count: 3), "over its own chip nothing would move")

        // The insertion line: after the chip when the pane moves towards the end, before it otherwise.
        XCTAssertEqual(SplitPaneChipDrag.boundary(from: 0, to: 2), 3)
        XCTAssertEqual(SplitPaneChipDrag.boundary(from: 0, to: 1), 2)
        XCTAssertEqual(SplitPaneChipDrag.boundary(from: 2, to: 0), 0)
        XCTAssertEqual(SplitPaneChipDrag.boundary(from: 2, to: 1), 1)
    }

    func testTheInsertionLineShowsOnlyInTheDraggedChipsRow() throws {
        let (store, splitID, tabs) = try makeSplit()
        let split = try XCTUnwrap(store.split(withID: splitID))
        var drag = SplitPaneChipDrag(splitID: splitID, tabID: tabs[0].id)
        XCTAssertNil(drag.boundary(in: split), "no place yet: no line")
        drag.destination = 2
        XCTAssertEqual(drag.boundary(in: split), 3)
        drag.destination = 0
        XCTAssertNil(drag.boundary(in: split), "its own place")

        let e = store.addTab(kind: .today, title: "E", url: url("e"))
        let f = store.addTab(kind: .today, title: "F", url: url("f"))
        let other = try XCTUnwrap(store.createSplit(tabIDs: [e.id, f.id], orientation: .horizontal))
        drag.destination = 1
        XCTAssertNil(drag.boundary(in: other), "another split's row shows nothing")
    }

    // MARK: Saved and synced

    func testAMoveIsSavedAndSyncedAsAnEditOfTheSplit() throws {
        let (store, splitID, tabs) = try makeSplit()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-pane-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sidebar.json")
        let persistence = SidebarFilePersistence(fileURL: file, debounceInterval: 0.01)
        persistence.start(autoSave: store)
        store.resizeSplitPanes(splitID: splitID, widthFactors: [tabs[0].id: 0.6, tabs[1].id: 0.3, tabs[2].id: 0.1])
        let journal = store.mutationJournal.allEntries().count

        XCTAssertTrue(store.moveSplitPane(splitID: splitID, tabID: tabs[0].id, by: 2))
        XCTAssertEqual(store.mutationJournal.allEntries().dropFirst(journal).map(\.mutation), [.upsertItem(id: splitID)],
                       "one record change, the split's own")

        persistence.flush()
        let loaded = SidebarFilePersistence.loadStore(fileURL: file) {
            XCTFail("sidebar.json did not load")
            return SidebarStore()
        }
        let saved = try XCTUnwrap(loaded.split(withID: splitID))
        XCTAssertEqual(saved.tabs.map(\.title), ["B", "C", "A"], "sidebar.json has the new order")
        XCTAssertEqual(saved.focusTabID, tabs[0].id)
        XCTAssertEqual(saved.widthFactors[tabs[0].id] ?? 0, 0.6, accuracy: 1e-9)

        // The synced record carries the panes in order.
        let moved = try XCTUnwrap(store.split(withID: splitID))
        let synced = try XCTUnwrap(SidebarSyncProjection.makeSplit(id: splitID, values: SidebarSyncProjection.splitValues(moved), rank: "m"))
        XCTAssertEqual(synced.tabs.map(\.id), moved.tabs.map(\.id))
        XCTAssertEqual(synced.widthFactors[tabs[0].id] ?? 0, 0.6, accuracy: 1e-9)
    }

    // MARK: Menu items

    func testMovePaneItemsAreNamedForTheLayoutAndDisabledAtTheEnds() throws {
        let (store, splitID, tabs) = try makeSplit()
        var split = try XCTUnwrap(store.split(withID: splitID))
        XCTAssertEqual(split.paneMoves(for: tabs[0].id), [
            SplitPaneMove(offset: -1, title: "Move Pane Left", isEnabled: false),
            SplitPaneMove(offset: 1, title: "Move Pane Right", isEnabled: true),
        ])
        XCTAssertEqual(split.paneMoves(for: tabs[1].id).map(\.isEnabled), [true, true])
        XCTAssertEqual(split.paneMoves(for: tabs[2].id).map(\.isEnabled), [true, false])
        XCTAssertTrue(split.paneMoves(for: UUID()).isEmpty, "not a pane: no items")

        store.changeSplitOrientation(splitID: splitID, orientation: .vertical)
        split = try XCTUnwrap(store.split(withID: splitID))
        XCTAssertEqual(split.paneMoves(for: tabs[0].id), [
            SplitPaneMove(offset: -1, title: "Move Pane Up", isEnabled: false),
            SplitPaneMove(offset: 1, title: "Move Pane Down", isEnabled: true),
        ])
    }

    func testTheCommandBarMovesTheFocusedPane() throws {
        let (store, splitID, tabs) = try makeSplit(panes: 2)
        store.selectSplit(splitID, focusTabID: tabs[0].id)
        func commands() -> [AppCommand] {
            AppCommandRegistry.all(in: CommandBarContext(store: store, isSidebarVisible: true, closedTabStack: store.closedTabStack))
        }
        XCTAssertEqual(commands().first { $0.action == .moveSplitPane(offset: 1) }?.title, "Move Pane Right")
        XCTAssertNil(commands().first { $0.action == .moveSplitPane(offset: -1) }, "the first pane cannot go left")

        store.changeSplitOrientation(splitID: splitID, orientation: .vertical)
        store.setSplitFocus(splitID: splitID, tabID: tabs[1].id)
        XCTAssertEqual(commands().first { $0.action == .moveSplitPane(offset: -1) }?.title, "Move Pane Up")
        XCTAssertNil(commands().first { $0.action == .moveSplitPane(offset: 1) })

        let alone = store.addTab(kind: .today, title: "Alone", url: url("alone"))
        store.selectTab(alone.id)
        XCTAssertFalse(commands().contains { if case .moveSplitPane = $0.action { true } else { false } }, "no split, no move")
    }

    func testAMenuNamesASplitAsItsSidebarRowReads() throws {
        let (store, splitID, _) = try makeSplit()
        XCTAssertEqual(store.split(withID: splitID)?.menuTitle, "A | B | C", "unnamed: its panes' titles")
        XCTAssertTrue(store.renameSplit(splitID, to: "Research"))
        XCTAssertEqual(store.split(withID: splitID)?.menuTitle, "Research")

        var long = try XCTUnwrap(store.split(withID: splitID))
        long.title = nil
        long.tabs[0].title = String(repeating: "x", count: 60)
        XCTAssertEqual(long.menuTitle, String(repeating: "x", count: 27) + "… | B | C", "a long title is cut, the rest still show")
    }

    // MARK: Add to Split View

    func testAddToSplitViewListsTheSpacesSplitsWithRoom() throws {
        let work = Space(name: "Work")
        let store = SidebarStore(spaces: [Space(name: "Home"), work])
        func tab(_ title: String, _ kind: Tab.Kind = .today, in space: Space.ID? = nil) -> Tab {
            store.addTab(kind: kind, title: title, url: url(title.lowercased()), in: space)
        }
        let two = try XCTUnwrap(store.createSplit(tabIDs: [tab("A").id, tab("B").id], orientation: .horizontal))
        let full = try XCTUnwrap(store.createSplit(tabIDs: ["C", "D", "E", "F"].map { tab($0).id }, orientation: .horizontal))
        let pinnedSplit = try XCTUnwrap(store.createSplit(tabIDs: [tab("P1", .pinned).id, tab("P2", .pinned).id], orientation: .vertical))
        let elsewhere = try XCTUnwrap(store.createSplit(
            tabIDs: [tab("W1", in: work.id).id, tab("W2", in: work.id).id], orientation: .horizontal, in: work.id))

        let plain = tab("Plain")
        XCTAssertEqual(store.splitsAccepting([plain.id]).map(\.id), [pinnedSplit.id, two.id],
                       "the space's splits with room, in sidebar order: not the full one, not another space's")
        XCTAssertFalse(store.splitsAccepting([plain.id]).contains { $0.id == full.id || $0.id == elsewhere.id })

        // Split with Current Tab's rules.
        XCTAssertTrue(store.splitsAccepting([tab("Fav", .favorite).id]).isEmpty, "no favorites")
        let pane = try XCTUnwrap(store.split(withID: two.id)).tabs[0]
        XCTAssertTrue(store.splitsAccepting([pane.id]).isEmpty, "a pane is already in a split")
        let grouped = tab("Grouped")
        XCTAssertNotNil(store.createTabGroup(name: "G", containing: [grouped.id]))
        XCTAssertTrue(store.splitsAccepting([grouped.id]).isEmpty, "no tab group's tabs")
        let folder = try XCTUnwrap(store.createFolder(title: "Folder"))
        XCTAssertTrue(store.splitsAccepting([folder.id]).isEmpty, "a folder is not a tab")
        XCTAssertTrue(store.splitsAccepting([two.id]).isEmpty, "nor is a split")
        XCTAssertTrue(store.splitsAccepting([]).isEmpty)
        XCTAssertTrue(store.splitsAccepting([UUID()]).isEmpty)
        XCTAssertEqual(store.splitsAccepting([tab("Work tab", in: work.id).id]).map(\.id), [elsewhere.id], "another space's tab sees its own space's split")

        // A pinned tab can join: it is a plain tab of the space.
        XCTAssertEqual(store.splitsAccepting([tab("Pin", .pinned).id]).map(\.id), [pinnedSplit.id, two.id])
        XCTAssertFalse(store.canAdd([plain.id], toSplit: full.id))
        XCTAssertFalse(store.addTabs([plain.id], toSplit: full.id), "a fifth pane is refused")
        XCTAssertEqual(store.split(withID: full.id)?.tabs.count, 4)
        XCTAssertNotNil(store.tab(withID: plain.id), "and the tab stays where it was")
        XCTAssertNil(store.splitContaining(tabID: plain.id))
    }

    func testSeveralTabsJoinOnlyWhenTheyAllFitInFourPanes() throws {
        let (store, splitID, _) = try makeSplit(panes: 2)
        let extra = ["X", "Y", "Z"].map { store.addTab(kind: .today, title: $0, url: url($0.lowercased())) }

        XCTAssertEqual(store.splitsAccepting([extra[0].id, extra[1].id]).map(\.id), [splitID], "2 panes + 2 tabs = 4")
        XCTAssertTrue(store.splitsAccepting(extra.map(\.id)).isEmpty, "2 + 3 would be five: not offered")
        XCTAssertFalse(store.addTabs(extra.map(\.id), toSplit: splitID))
        XCTAssertEqual(order(store, splitID), ["A", "B"], "all or none: none joined")
        XCTAssertTrue(store.splitsAccepting([extra[0].id, extra[0].id]).isEmpty, "the same tab twice is not two tabs")

        let fav = store.addTab(kind: .favorite, title: "Fav", url: url("fav"))
        XCTAssertTrue(store.splitsAccepting([extra[0].id, fav.id]).isEmpty, "one row that cannot join hides it for all")

        XCTAssertTrue(store.addTabs([extra[1].id, extra[0].id], toSplit: splitID))
        XCTAssertEqual(order(store, splitID), ["A", "B", "Y", "X"], "last panes, in the order given")
        XCTAssertTrue(store.splitsAccepting([extra[2].id]).isEmpty, "now it is full")
    }

    func testAnAddedTabIsTheLastPaneAndTheSplitIsShown() throws {
        let (store, splitID, tabs) = try makeSplit(panes: 2)
        let pinned = store.addTab(kind: .pinned, title: "Pinned", url: url("pinned"))
        let folder = try XCTUnwrap(store.createFolder(title: "Folder"))
        let inFolder = store.addTab(kind: .pinned, title: "Foldered", url: url("foldered"))
        XCTAssertTrue(store.moveItem(inFolder.id, to: .folder(folder.id), index: 0))
        let other = store.addTab(kind: .today, title: "Other", url: url("other"))
        store.selectTab(other.id)

        // The owner's case: the split is not the selected item.
        XCTAssertTrue(store.addTabs([pinned.id], toSplit: splitID))
        XCTAssertEqual(order(store, splitID), ["A", "B", "Pinned"])
        XCTAssertEqual(store.selectedItemID, splitID, "the split is shown")
        XCTAssertEqual(store.split(withID: splitID)?.focusTabID, pinned.id, "with the new pane focused")
        XCTAssertEqual(store.splitContaining(tabID: pinned.id)?.split.id, splitID)
        XCTAssertFalse(store.content(for: store.activeSpaceID).pinned.contains { $0.id == pinned.id }, "it left its own row")
        let factors = try XCTUnwrap(store.split(withID: splitID)).widthFactors
        XCTAssertEqual(factors[pinned.id] ?? 0, 1.0 / 3, accuracy: 1e-9, "it takes an equal share")
        XCTAssertEqual(factors[tabs[0].id] ?? 0, 1.0 / 3, accuracy: 1e-9)

        XCTAssertTrue(store.addTabs([inFolder.id], toSplit: splitID), "a tab in a folder joins too")
        XCTAssertEqual(order(store, splitID), ["A", "B", "Pinned", "Foldered"])
        XCTAssertEqual(store.tab(withID: inFolder.id)?.url, url("foldered"))
    }

    // MARK: Separate

    func testSeparatingAPaneKeepsItsTab() throws {
        let (store, splitID, tabs) = try makeSplit()
        XCTAssertTrue(store.moveSplitPane(splitID: splitID, tabID: tabs[0].id, by: 2))

        XCTAssertTrue(store.removeTabFromSplit(splitID: splitID, tabID: tabs[0].id))
        XCTAssertEqual(order(store, splitID), ["B", "C"], "the split keeps the others, in their order")
        XCTAssertNil(store.splitContaining(tabID: tabs[0].id))
        XCTAssertEqual(store.tab(withID: tabs[0].id)?.url, tabs[0].url, "the page is still a tab")
        XCTAssertTrue(store.content(for: store.activeSpaceID).today.contains { $0.id == tabs[0].id }, "a row of its own again")
        XCTAssertEqual(store.split(withID: splitID)?.focusTabID, tabs[2].id, "the focus goes to a pane that is left")
        XCTAssertNil(store.split(withID: splitID)?.widthFactors[tabs[0].id])

        // The last two: the split goes and both pages stay.
        XCTAssertTrue(store.removeTabFromSplit(splitID: splitID, tabID: tabs[1].id))
        XCTAssertNil(store.split(withID: splitID))
        for tab in tabs {
            XCTAssertNotNil(store.tab(withID: tab.id))
            XCTAssertTrue(store.content(for: store.activeSpaceID).today.contains { $0.id == tab.id })
        }
    }
}
