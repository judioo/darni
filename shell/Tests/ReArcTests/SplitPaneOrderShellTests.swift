import XCTest
import SidebarModel
@testable import ReArc

/// Split view's menus in the shell (owner report 2026-11-22): the View menu
/// has Arc's split items with Separate Page from Split View and the focused
/// pane's Move Pane Left/Right (Up/Down stacked), the pane's own menus show
/// the same moves, a tab's Add to Split View lists the splits that can take
/// it, and a chip dragged along its row reorders the panes.
@MainActor
final class SplitPaneOrderShellTests: XCTestCase {
    private func makeModel() -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Demo", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-pane-order-\(UUID().uuidString)")
        return BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
    }

    private func makeSplit(
        _ model: BrowserViewModel,
        panes: Int = 3,
        orientation: SplitLayoutOrientation = .horizontal,
        prefix: String = "Pane"
    ) throws -> (SplitViewItem.ID, [Tab]) {
        let tabs = (0..<panes).map {
            model.store.addTab(kind: .today, title: "\(prefix) \($0)", url: URL(string: "https://\(prefix.lowercased())\($0).test/page")!)
        }
        let split = try XCTUnwrap(model.store.createSplit(tabIDs: tabs.map(\.id), orientation: orientation))
        model.selectSplit(split.id, focusTabID: tabs[0].id)
        return (split.id, tabs)
    }

    private func titles(_ groups: [[ShellMenuItem]]) -> [String] { groups.flatMap { $0.map(\.title) } }

    private func item(_ title: String, in groups: [[ShellMenuItem]]) throws -> ShellMenuItem {
        try XCTUnwrap(groups.flatMap { $0 }.first { $0.shownTitle == title }, "no menu item titled \(title)")
    }

    private func order(_ model: BrowserViewModel, _ splitID: SplitViewItem.ID) -> [String] {
        model.store.split(withID: splitID)?.tabs.map(\.title) ?? []
    }

    // MARK: View menu

    func testTheViewMenuHasArcsSplitItems() {
        let model = makeModel()
        let view = titles(ShellMenus.viewPageAndSplit(model))
        // Arc's View menu, docs/observations/arc/live-menu-keybindings.tsv lines 78-80.
        for title in ["Add Split View", "Close this Split Pane", "Separate Page from Split View", "Move Pane Left", "Move Pane Right"] {
            XCTAssertTrue(view.contains(title), "View menu lacks \(title)")
        }
        XCTAssertLessThan(view.firstIndex(of: "Close this Split Pane")!, view.firstIndex(of: "Separate Page from Split View")!, "Arc's order")
        XCTAssertFalse(view.contains("Separate from Split View"), "the menu bar uses Arc's menu wording")

        // They are in View only: the Tabs menu's groups no longer carry them.
        let tabsMenu = titles(ShellMenus.tabNavigation(model) + ShellMenus.tabSwitcher(model) + ShellMenus.tabPositions(model)
            + ShellMenus.sidebarItems(model))
        for title in ["Add Split View", "Close this Split Pane", "Separate Page from Split View", "Separate from Split View",
                      "Move Pane Left", "Move Pane Right"] {
            XCTAssertFalse(tabsMenu.contains(title), "\(title) is twice in the menu bar")
        }
        // Arc binds no key to the new items, and the old two keep theirs.
        let items = ShellMenus.split(model).flatMap { $0 }
        XCTAssertEqual(items.filter { $0.key != nil }.map(\.title), ["Add Split View", "Close this Split Pane"])
    }

    func testTheViewMenusSplitItemsAreDisabledWithNoSplit() throws {
        let model = makeModel()
        let tab = model.store.addTab(kind: .today, title: "Alone", url: URL(string: "https://alone.test")!)
        model.selectTab(tab.id)
        let menu = ShellMenus.split(model)
        XCTAssertFalse(try item("Separate Page from Split View", in: menu).isEnabledNow)
        XCTAssertFalse(try item("Move Pane Left", in: menu).isEnabledNow, "shown and disabled, as Arc's are")
        XCTAssertFalse(try item("Move Pane Right", in: menu).isEnabledNow)
        XCTAssertTrue(try item("Add Split View", in: menu).isEnabledNow, "an item with no rule of its own is always enabled")
        try item("Move Pane Right", in: menu).action()
        try item("Separate Page from Split View", in: menu).action()
        XCTAssertNotNil(model.store.tab(withID: tab.id), "and their actions do nothing")
    }

    func testMovePaneInTheViewMenuMovesTheFocusedPaneAndStopsAtTheEnds() throws {
        let model = makeModel()
        let (splitID, tabs) = try makeSplit(model, panes: 2)
        let menu = ShellMenus.split(model)
        XCTAssertFalse(try item("Move Pane Left", in: menu).isEnabledNow, "the first pane")
        XCTAssertTrue(try item("Move Pane Right", in: menu).isEnabledNow)

        try item("Move Pane Left", in: menu).action()
        XCTAssertEqual(order(model, splitID), ["Pane 0", "Pane 1"], "a disabled item's action changes nothing")

        try item("Move Pane Right", in: menu).action()
        XCTAssertEqual(order(model, splitID), ["Pane 1", "Pane 0"])
        XCTAssertEqual(model.store.split(withID: splitID)?.focusTabID, tabs[0].id, "the focus stays on the moved pane")
        XCTAssertEqual(model.store.selectedTabID, tabs[0].id)
        // The same items, read again as an open menu does.
        XCTAssertTrue(try item("Move Pane Left", in: menu).isEnabledNow)
        XCTAssertFalse(try item("Move Pane Right", in: menu).isEnabledNow, "now it is the last pane")

        // The other pane focused: the items follow the focus.
        model.focusSplitPane(tabs[1].id, in: splitID)
        XCTAssertFalse(try item("Move Pane Left", in: menu).isEnabledNow)
        XCTAssertTrue(try item("Move Pane Right", in: menu).isEnabledNow)
    }

    func testAStackedSplitsItemsReadUpAndDown() throws {
        let model = makeModel()
        let (splitID, tabs) = try makeSplit(model, panes: 3, orientation: .vertical)
        let menu = ShellMenus.split(model)
        let shown = menu.flatMap { $0 }.compactMap(\.shownTitle)
        XCTAssertTrue(shown.contains("Move Pane Up") && shown.contains("Move Pane Down"), "\(shown)")
        XCTAssertFalse(shown.contains("Move Pane Left") || shown.contains("Move Pane Right"))
        XCTAssertFalse(try item("Move Pane Up", in: menu).isEnabledNow, "the top pane")

        try item("Move Pane Down", in: menu).action()
        XCTAssertEqual(order(model, splitID), ["Pane 1", "Pane 0", "Pane 2"])
        XCTAssertTrue(try item("Move Pane Up", in: menu).isEnabledNow)
        XCTAssertTrue(try item("Move Pane Down", in: menu).isEnabledNow, "a middle pane goes both ways")

        // Arrange Side by Side: the same items are Left and Right again.
        model.flipSplitOrientation(splitID)
        XCTAssertEqual(try item("Move Pane Left", in: menu).isEnabledNow, true)
        XCTAssertEqual(model.store.split(withID: splitID)?.focusTabID, tabs[0].id)
    }

    func testSeparatePageFromSplitViewTakesTheFocusedPaneOutAndKeepsItsTab() throws {
        let model = makeModel()
        let (splitID, tabs) = try makeSplit(model)
        model.focusSplitPane(tabs[1].id, in: splitID)
        let menu = ShellMenus.split(model)
        XCTAssertTrue(try item("Separate Page from Split View", in: menu).isEnabledNow)

        try item("Separate Page from Split View", in: menu).action()
        XCTAssertEqual(order(model, splitID), ["Pane 0", "Pane 2"])
        XCTAssertNil(model.store.splitContaining(tabID: tabs[1].id))
        XCTAssertEqual(model.store.tab(withID: tabs[1].id)?.url, tabs[1].url, "the page is a tab of its own again")
        XCTAssertTrue(model.store.content(for: model.store.activeSpaceID).today.contains { $0.id == tabs[1].id })
    }

    // MARK: The pane's own menus

    func testAPanesSplitMenuAndChipMenuShowItsMoves() throws {
        let model = makeModel()
        let (splitID, tabs) = try makeSplit(model)
        // What `SplitPaneMoveMenuItems` draws in the pane's split button menu and its chip's right-click.
        XCTAssertEqual(model.splitPaneMoves(for: tabs[0].id), [
            SplitPaneMove(offset: -1, title: "Move Pane Left", isEnabled: false),
            SplitPaneMove(offset: 1, title: "Move Pane Right", isEnabled: true),
        ])
        XCTAssertEqual(model.splitPaneMoves(for: tabs[2].id).map(\.isEnabled), [true, false])
        XCTAssertTrue(model.splitPaneMoves(for: UUID()).isEmpty)

        // A chip's menu moves its own pane, focused or not.
        XCTAssertTrue(model.moveSplitPane(tabs[2].id, by: -1))
        XCTAssertEqual(order(model, splitID), ["Pane 0", "Pane 2", "Pane 1"])
        XCTAssertEqual(model.store.split(withID: splitID)?.focusTabID, tabs[2].id)
        XCTAssertFalse(model.moveSplitPane(tabs[0].id, by: -1), "the end")
        XCTAssertEqual(order(model, splitID), ["Pane 0", "Pane 2", "Pane 1"])

        model.flipSplitOrientation(splitID)
        XCTAssertEqual(model.splitPaneMoves(for: tabs[2].id).map(\.title), ["Move Pane Up", "Move Pane Down"])
    }

    func testTheCommandBarsMovePaneRunsOnTheFocusedPane() throws {
        let model = makeModel()
        let (splitID, tabs) = try makeSplit(model, panes: 2)
        XCTAssertNil(model.executeCommand(.moveSplitPane(offset: 1), commandID: nil))
        XCTAssertEqual(order(model, splitID), ["Pane 1", "Pane 0"])
        XCTAssertNotNil(model.executeCommand(.moveSplitPane(offset: 1), commandID: nil), "at the end it says so")
        XCTAssertEqual(model.store.split(withID: splitID)?.focusTabID, tabs[0].id)
    }

    // MARK: Add to Split View

    func testAddToSplitViewListsOnlyTheSplitsThatCanTakeTheTab() throws {
        let model = makeModel()
        let (roomy, _) = try makeSplit(model, panes: 2, prefix: "Roomy")
        let (full, _) = try makeSplit(model, panes: 4, prefix: "Full")
        XCTAssertTrue(model.store.renameSplit(roomy, to: "Research"))
        let (unnamed, _) = try makeSplit(model, panes: 2, prefix: "Doc")
        let tab = model.store.addTab(kind: .today, title: "Loose", url: URL(string: "https://loose.test")!)
        model.selectTab(tab.id)

        // The submenu's rows, named as the sidebar names each split.
        let choices = model.addToSplitChoices(for: [tab.id])
        XCTAssertEqual(Set(choices.map(\.menuTitle)), ["Research", "Doc 0 | Doc 1"])
        XCTAssertFalse(choices.contains { $0.id == full }, "a split of four panes is not offered")

        let favorite = model.store.addTab(kind: .favorite, title: "Fav", url: URL(string: "https://fav.test")!)
        XCTAssertTrue(model.addToSplitChoices(for: [favorite.id]).isEmpty, "no submenu for a favorite")
        let pane = try XCTUnwrap(model.store.split(withID: unnamed)).tabs[0]
        XCTAssertTrue(model.addToSplitChoices(for: [pane.id]).isEmpty, "nor for a pane")

        // Chosen while another tab is the selected item: the owner's case.
        XCTAssertNil(model.activeSplit)
        model.addTabs([tab.id], toSplit: unnamed)
        XCTAssertEqual(order(model, unnamed), ["Doc 0", "Doc 1", "Loose"], "the tab is the split's last pane")
        XCTAssertEqual(model.activeSplit?.id, unnamed, "and the split is shown")
        XCTAssertEqual(model.store.selectedTabID, tab.id)
        XCTAssertTrue(model.addToSplitChoices(for: [tab.id]).isEmpty)
    }

    func testSeveralSelectedTabsAreOfferedASplitOnlyWhenTheyAllFit() throws {
        let model = makeModel()
        let (splitID, _) = try makeSplit(model, panes: 2)
        let loose = (0..<3).map { model.store.addTab(kind: .today, title: "Loose \($0)", url: URL(string: "https://loose\($0).test")!) }

        XCTAssertEqual(model.addToSplitChoices(for: [loose[0].id, loose[1].id]).map(\.id), [splitID], "two more make four")
        XCTAssertTrue(model.addToSplitChoices(for: loose.map(\.id)).isEmpty, "three more would be five: the item is hidden")
        XCTAssertTrue(model.addToSplitChoices(for: [loose[0].id, splitID]).isEmpty, "a selection with a split in it is not offered")

        model.addTabs([loose[0].id, loose[1].id], toSplit: splitID)
        XCTAssertEqual(order(model, splitID), ["Pane 0", "Pane 1", "Loose 0", "Loose 1"])
        XCTAssertEqual(model.activeSplit?.id, splitID)

        // Full now: a late choice changes nothing and says why.
        model.addTabs([loose[2].id], toSplit: splitID)
        XCTAssertEqual(model.store.split(withID: splitID)?.tabs.count, 4)
        XCTAssertNil(model.store.splitContaining(tabID: loose[2].id))
        XCTAssertEqual(model.toast?.message, SplitViewItem.fullMessage)
    }

    // MARK: A chip dragged along its row

    func testAChipDroppedOnAnotherChipsPlaceReordersThePanes() throws {
        let model = makeModel()
        let (splitID, tabs) = try makeSplit(model)
        let split = try XCTUnwrap(model.store.split(withID: splitID))

        // The pointer is on the first chip when the row's drag begins.
        model.splitPaneChipHovered(true, tabID: tabs[0].id, in: splitID)
        model.sidebarDragBegan(on: .split(split))
        XCTAssertEqual(model.splitPaneChipDrag, SplitPaneChipDrag(splitID: splitID, tabID: tabs[0].id))

        // Three chips share 300 pt. Over its own chip nothing would move.
        XCTAssertNil(model.splitPaneChipDestination(in: split, x: 40, width: 300))
        model.splitPaneChipDragMoved(to: nil, in: split)
        XCTAssertNil(model.splitPaneChipDrag?.boundary(in: split), "no insertion line over its own chip")

        // Over the last chip: it would land after it.
        let destination = try XCTUnwrap(model.splitPaneChipDestination(in: split, x: 260, width: 300))
        XCTAssertEqual(destination, 2)
        model.splitPaneChipDragMoved(to: destination, in: split)
        XCTAssertEqual(model.splitPaneChipDrag?.boundary(in: split), 3, "the insertion line is after the last chip")

        XCTAssertTrue(model.dropSplitPaneChip(in: split, at: destination))
        XCTAssertEqual(order(model, splitID), ["Pane 1", "Pane 2", "Pane 0"])
        XCTAssertEqual(model.store.split(withID: splitID)?.focusTabID, tabs[0].id)
        XCTAssertNil(model.splitPaneChipDrag, "the drag is over")
        XCTAssertFalse(model.dropSplitPaneChip(in: split, at: 0), "a second drop without a drag moves nothing")
    }

    func testADragThatLeavesTheRowIsTheRowsOwnDrag() throws {
        let model = makeModel()
        let (splitID, tabs) = try makeSplit(model)
        let split = try XCTUnwrap(model.store.split(withID: splitID))
        let (otherID, _) = try makeSplit(model, panes: 2, prefix: "Other")
        let other = try XCTUnwrap(model.store.split(withID: otherID))

        model.splitPaneChipHovered(true, tabID: tabs[1].id, in: splitID)
        model.sidebarDragBegan(on: .split(split))
        XCTAssertEqual(model.splitPaneChipDrag?.tabID, tabs[1].id)
        XCTAssertEqual(model.splitPaneChipDestination(in: split, x: 10, width: 300), 0, "its own row has a place for it")
        // Another split's row is not a place for this chip: the row drop rules apply there, as before.
        XCTAssertNil(model.splitPaneChipDestination(in: other, x: 10, width: 300))
        model.splitPaneChipDragMoved(to: 1, in: other)
        XCTAssertNil(model.splitPaneChipDrag?.destination, "another row never sets this drag's place")
        XCTAssertFalse(model.dropSplitPaneChip(in: other, at: 0))
        XCTAssertEqual(order(model, otherID), ["Other 0", "Other 1"])

        // Dropped anywhere else, the session ends and nothing of the split's order changed.
        model.sidebarDragEnded()
        XCTAssertNil(model.splitPaneChipDrag)
        XCTAssertEqual(order(model, splitID), ["Pane 0", "Pane 1", "Pane 2"])
    }

    func testOnlyADragBegunOnAChipOfAnUnnamedSplitCanReorder() throws {
        let model = makeModel()
        let (splitID, tabs) = try makeSplit(model)
        let split = try XCTUnwrap(model.store.split(withID: splitID))
        let plain = model.store.addTab(kind: .today, title: "Plain", url: URL(string: "https://plain.test")!)

        // No chip under the pointer (the row's edge, or a drag from another row).
        model.sidebarDragBegan(on: .split(split))
        XCTAssertNil(model.splitPaneChipDrag)

        // A tab row's drag, with a chip's hover left over, is no chip drag.
        model.splitPaneChipHovered(true, tabID: tabs[0].id, in: splitID)
        model.sidebarDragBegan(on: .tab(plain))
        XCTAssertNil(model.splitPaneChipDrag)

        // The pointer moved from one chip to the next: the newer chip counts, whichever event comes last.
        model.splitPaneChipHovered(true, tabID: tabs[1].id, in: splitID)
        model.splitPaneChipHovered(false, tabID: tabs[0].id, in: splitID)
        model.sidebarDragBegan(on: .split(split))
        XCTAssertEqual(model.splitPaneChipDrag?.tabID, tabs[1].id)
        model.sidebarDragEnded()

        // Off the chips, no chip drag.
        model.splitPaneChipHovered(false, tabID: tabs[1].id, in: splitID)
        model.sidebarDragBegan(on: .split(split))
        XCTAssertNil(model.splitPaneChipDrag)

        // A named split's row has no chips: its drag moves the row.
        model.splitPaneChipHovered(true, tabID: tabs[0].id, in: splitID)
        XCTAssertTrue(model.store.renameSplit(splitID, to: "Named"))
        model.sidebarDragBegan(on: .split(try XCTUnwrap(model.store.split(withID: splitID))))
        XCTAssertNil(model.splitPaneChipDrag)
    }
}
