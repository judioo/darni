import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// A drag offered to views directly, as AppKit offers one: no drag session,
/// no pointer, no screen. The pasteboard is a private one.
private final class OfferedDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingLocation: NSPoint
    private weak var window: NSWindow?
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    /// SwiftUI's drop view reads the last answer it gave from AppKit's own dragging info.
    var lastOperation: NSDragOperation = []

    init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow) {
        draggingPasteboard = pasteboard
        draggingLocation = location
        self.window = window
    }

    @objc(_lastDragDestinationOperation) func lastDragDestinationOperation() -> UInt { lastOperation.rawValue }
    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.move, .copy, .generic] }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1123 }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}

/// One window's sidebar, with the drag as `BrowserView` gives it to its sidebar.
private struct WindowSidebar: View {
    let model: BrowserViewModel
    let window: SidebarWindowID

    var body: some View {
        SidebarView(model: model, draggedItemID: model.sidebarDragBinding(in: window))
            .environment(\.sidebarWindow, window)
            .environment(\.themeChrome, ThemeChromeColors(theme: .default, dark: false))
            .frame(width: 228, height: 700)
    }
}

/// A tab dragged from one window's sidebar into another window's (owner,
/// 2026-11-23, build 1255: the drop was accepted and moved nothing). The
/// drag is the model's, so both windows' drop targets find its row; where it
/// lands and what another profile asks are Move to Space's rules.
///
/// The second half drives the sidebar's real drop targets for two windows
/// laid out off screen: AppKit's dragging calls on the views SwiftUI's
/// `onDrop` and the plain rows register, with a pasteboard that holds what a
/// sidebar drag holds.
@MainActor
final class CrossWindowDragTests: XCTestCase {
    private func url(_ host: String) -> URL { URL(string: "https://\(host).test/")! }

    private struct Fixture {
        let model: BrowserViewModel
        let store: SidebarStore
        /// The right window, on Engage: the drag begins here. It is the key window.
        let right = SidebarWindowID()
        /// The left window, on Personal.
        let left = SidebarWindowID()
        let engage: Space.ID
        let personal: Space.ID
        /// Engage's Today, top to bottom: Maps, Docs, Mail.
        let maps: SidebarModel.Tab, docs: SidebarModel.Tab, mail: SidebarModel.Tab
        /// Personal's Today, top to bottom: Welcome, News.
        let welcome: SidebarModel.Tab, news: SidebarModel.Tab
    }

    private func makeFixture() -> Fixture {
        let store = SidebarStore(spaces: [Space(name: "Engage", sortRank: "a")])
        let engage = store.activeSpaceID
        let personal = store.addSpace(name: "Personal").id
        // Named by where they are in Today, whichever end a new tab goes to.
        func tabs(_ titles: [String], in space: Space.ID) -> [SidebarModel.Tab] {
            let added = titles.map { store.addTab(kind: .today, title: $0, url: url("tab-\(UUID().uuidString.prefix(8))"), in: space) }
            let order = store.outlineOrder(in: space)
            let sorted = added.sorted { order.firstIndex(of: $0.id)! < order.firstIndex(of: $1.id)! }
            for (tab, title) in zip(sorted, titles) { store.updateTab(tab.id, title: title) }
            return sorted.map { store.tab(withID: $0.id)! }
        }
        let engageTabs = tabs(["Google Maps", "Docs", "Mail"], in: engage)
        let personalTabs = tabs(["Welcome to ReArc", "News"], in: personal)
        let maps = engageTabs[0], docs = engageTabs[1], mail = engageTabs[2]
        let welcome = personalTabs[0], news = personalTabs[1]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-xwindow-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-xwindow-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-xwindow-links-\(UUID().uuidString)")!
        model.sidebarWidth = 228
        let f = Fixture(model: model, store: store, engage: engage, personal: personal,
                        maps: maps, docs: docs, mail: mail, welcome: welcome, news: news)
        store.registerWindow(f.right, spaceID: engage)
        store.registerWindow(f.left, spaceID: personal)
        store.windowBecameKey(f.right)
        XCTAssertEqual(today(f, engage), [maps.id, docs.id, mail.id])
        XCTAssertEqual(today(f, personal), [welcome.id, news.id])
        return f
    }

    private func today(_ f: Fixture, _ space: Space.ID) -> [UUID] { f.store.outline(for: space).today.map(\.id) }
    private func pinned(_ f: Fixture, _ space: Space.ID) -> [UUID] { f.store.outline(for: space).pinned.map(\.id) }

    /// A second profile, Work, with its space and one tab.
    private func addWork(_ f: Fixture) throws -> (profile: Profile.ID, space: Space.ID, report: SidebarModel.Tab) {
        let work = f.store.addProfile(name: "Work")
        let space = try XCTUnwrap(f.store.spaces(in: work.id).first).id
        let report = f.store.addTab(kind: .today, title: "Report", url: url("report"), in: space)
        return (work.id, space, report)
    }

    // MARK: - The drag is the model's

    func testAWindowSeesTheDragOnceItHasBeenOverIt() {
        let f = makeFixture()
        let right = f.model.sidebarDragBinding(in: f.right), left = f.model.sidebarDragBinding(in: f.left)
        XCTAssertNil(right.wrappedValue)

        // A row's `onDrag` writes its id through its window's binding.
        right.wrappedValue = f.maps.id
        XCTAssertEqual(f.model.sidebarDrag, SidebarDragSession(itemID: f.maps.id, sourceWindow: f.right))
        XCTAssertEqual(right.wrappedValue, f.maps.id)
        XCTAssertNil(left.wrappedValue, "a drag that has not left its window changes nothing in the other")
        XCTAssertTrue(f.model.sidebarDragBegan(in: f.right))
        XCTAssertFalse(f.model.sidebarDragBegan(in: f.left), "the other window's page offers no split zone")
        XCTAssertFalse(f.model.sidebarOpensDropAreas(dragging: left.wrappedValue))

        // The same row writing again (a chip's drag does) keeps the windows reached.
        f.model.sidebarDragReached(f.left)
        right.wrappedValue = f.maps.id
        XCTAssertEqual(left.wrappedValue, f.maps.id, "over the other window its sidebar opens for the drop")
        XCTAssertTrue(f.model.sidebarOpensDropAreas(dragging: left.wrappedValue))
        XCTAssertFalse(f.model.sidebarDragBegan(in: f.left))

        // A drop in either window ends it for both.
        left.wrappedValue = nil
        XCTAssertNil(f.model.sidebarDrag)
        XCTAssertNil(right.wrappedValue)
        XCTAssertTrue(f.model.sidebarDragBegan(in: f.left), "no drag: nothing is held back")
        f.model.sidebarDragReached(f.left)
        XCTAssertNil(f.model.sidebarDrag, "nothing to reach without a drag")
    }

    func testADropTargetIsOfferedTheOtherWindowsRowOnlyForASidebarDrag() {
        let f = makeFixture()
        f.model.beginSidebarDrag(f.maps.id, in: f.right)
        XCTAssertEqual(f.model.sidebarDragItem(offered: nil, carriesSidebarItem: true), f.maps.id)
        XCTAssertNil(f.model.sidebarDragItem(offered: nil, carriesSidebarItem: false),
                     "a link dragged in from a page is never taken for the row")
        XCTAssertEqual(f.model.sidebarDragItem(offered: f.docs.id, carriesSidebarItem: false), f.docs.id, "its own window's drag, as before")
        f.model.endSidebarDrag()
        XCTAssertNil(f.model.sidebarDragItem(offered: nil, carriesSidebarItem: true))
    }

    func testThePointerWatchStopsWithTheDrag() {
        let f = makeFixture()
        f.model.beginSidebarDrag(f.maps.id, in: f.right)
        XCTAssertNotNil(f.model.sidebarDragPointerWatch)
        f.model.endSidebarDrag()
        XCTAssertNil(f.model.sidebarDragPointerWatch)
        XCTAssertNil(f.model.sidebarDrag)
    }

    // MARK: - Same profile: the row moves, its page stays

    func testADropInAnotherWindowsSpaceMovesTheRowThereAndKeepsItsPage() throws {
        let f = makeFixture()
        let profile = try XCTUnwrap(f.store.space(withID: f.engage)?.profileID)
        f.model.selectTab(f.maps.id)
        let page = f.model.engineHost.engine(for: f.maps, profileID: profile)

        f.model.beginSidebarDrag(f.maps.id, in: f.right)
        f.model.moveItem(f.maps.id, relativeTo: f.welcome.id, after: true)

        XCTAssertNil(f.model.pendingProfileMove, "one profile: nothing to ask")
        XCTAssertEqual(today(f, f.personal), [f.welcome.id, f.maps.id, f.news.id], "at the drop's place in the other window's space")
        XCTAssertEqual(today(f, f.engage), [f.docs.id, f.mail.id])
        XCTAssertTrue(f.model.engineHost.engine(forTabID: f.maps.id, profileID: profile) === page, "the live page moved with its row")
        // Each window keeps its space; the one the row left shows something else.
        XCTAssertEqual(f.store.focusedSpaceID(in: f.right), f.engage)
        XCTAssertEqual(f.store.focusedSpaceID(in: f.left), f.personal)
        XCTAssertEqual(f.store.activeSpaceID, f.engage)
        XCTAssertNotEqual(f.store.selectedItemID(in: f.right), f.maps.id)
    }

    func testADraggedSelectionGoesToTheOtherWindowWhole() throws {
        let f = makeFixture()
        f.model.selectTab(f.maps.id)
        XCTAssertTrue(f.model.handleSelectionClick(on: f.docs.id, in: f.right, modifiers: .shift))
        f.model.beginSidebarDrag(f.docs.id, in: f.right)
        XCTAssertEqual(f.model.draggedSelection(f.docs.id), [f.maps.id, f.docs.id])
        XCTAssertNil(f.model.draggedSelection(f.mail.id), "a row outside the selection goes alone")

        // The selection is its window's, whichever window has the keys by the drop.
        f.model.windowBecameKey(f.left)
        let selection = try XCTUnwrap(f.model.draggedSelection(f.docs.id))
        XCTAssertEqual(selection, [f.maps.id, f.docs.id])
        XCTAssertTrue(f.model.moveDraggedSelection(selection, relativeTo: f.news.id, after: false))
        XCTAssertEqual(today(f, f.personal), [f.welcome.id, f.maps.id, f.docs.id, f.news.id], "together, in order, at the drop's place")
        XCTAssertEqual(today(f, f.engage), [f.mail.id])
        XCTAssertNil(f.model.pendingProfileMove)

        f.model.endSidebarDrag()
        XCTAssertEqual(f.store.multiSelectedIDs(in: f.right) ?? [], [], "the rows left the space they were selected in")
    }

    func testDropsInTheSameSpaceAskNothing() {
        let f = makeFixture()
        f.model.beginSidebarDrag(f.maps.id, in: f.right)
        f.model.moveItem(f.maps.id, relativeTo: f.mail.id, after: true)
        XCTAssertEqual(today(f, f.engage), [f.docs.id, f.mail.id, f.maps.id])
        f.model.moveItem(f.maps.id, to: .section(spaceID: f.engage, section: .pinned), index: 0)
        XCTAssertEqual(pinned(f, f.engage), [f.maps.id])
        XCTAssertNil(f.model.pendingProfileMove)
    }

    // MARK: - Another profile: Move to Space's question, then the drop's place

    func testADropInAnotherProfilesSpaceAsksAndThenLandsWhereItWasDropped() throws {
        let f = makeFixture()
        let work = try addWork(f)
        let home = try XCTUnwrap(f.store.space(withID: f.engage)?.profileID)
        f.model.selectTab(f.maps.id)
        let page = f.model.engineHost.engine(for: f.maps, profileID: home)

        f.model.beginSidebarDrag(f.maps.id, in: f.right)
        f.model.moveItem(f.maps.id, relativeTo: work.report.id, after: true)
        let pending = try XCTUnwrap(f.model.pendingProfileMove, "another profile: asked first, as Move to Space asks")
        XCTAssertEqual(pending, SidebarProfileMove(ids: [f.maps.id], spaceID: work.space, placement: .beside(work.report.id, after: true)))
        XCTAssertEqual(f.model.profileMoveMessage(pending).title, "Move to Work?")
        XCTAssertEqual(today(f, f.engage), [f.maps.id, f.docs.id, f.mail.id], "nothing moves before the answer")

        // Cancel: nothing moved.
        f.model.pendingProfileMove = nil
        XCTAssertEqual(f.store.spaceContaining(tabID: f.maps.id), f.engage)

        f.model.moveItem(f.maps.id, relativeTo: work.report.id, after: true)
        f.model.confirmProfileMove()
        XCTAssertNil(f.model.pendingProfileMove)
        XCTAssertEqual(today(f, work.space), [work.report.id, f.maps.id], "at the drop's place, not at the top of Today")
        XCTAssertNil(f.model.engineHost.engine(forTabID: f.maps.id, profileID: home), "no page stays in the old profile")
        let reloaded = f.model.engineHost.engine(forTabID: f.maps.id, profileID: work.profile)
        XCTAssertFalse(reloaded === page)
    }

    func testEveryKindOfDropInAnotherProfileAsks() throws {
        let f = makeFixture()
        let work = try addWork(f)
        let wiki = f.store.addTab(kind: .pinned, title: "Wiki", url: url("wiki"), in: work.space)
        let folder = try XCTUnwrap(f.store.createFolder(title: "Docs", in: work.space, containing: [wiki.id]))
        let pinnedEnd = SidebarStore.ItemDestination.section(spaceID: work.space, section: .pinned)

        // After a section's last row: one row, then a selection.
        f.model.moveItem(f.maps.id, to: pinnedEnd, index: 1)
        XCTAssertEqual(f.model.pendingProfileMove?.placement, .at(pinnedEnd, index: 1))
        f.model.pendingProfileMove = nil
        f.model.moveDraggedSelection([f.maps.id, f.docs.id], appendingTo: pinnedEnd)
        XCTAssertEqual(f.model.pendingProfileMove, SidebarProfileMove(ids: [f.maps.id, f.docs.id], spaceID: work.space, placement: .end(pinnedEnd)))
        XCTAssertEqual(f.model.profileMoveMessage(try XCTUnwrap(f.model.pendingProfileMove)).message.prefix(28), "These 2 tabs will reload in ")
        f.model.confirmProfileMove()
        XCTAssertEqual(pinned(f, work.space), [folder.id, f.maps.id, f.docs.id], "after the last row, in order")
        XCTAssertEqual(f.store.kind(of: f.maps.id), .pinned)

        // Into a folder: one row, then a selection.
        f.model.moveItem(f.mail.id, intoFolder: folder.id)
        XCTAssertEqual(f.model.pendingProfileMove?.placement, .intoFolder(folder.id))
        XCTAssertEqual(f.store.spaceContaining(tabID: f.mail.id), f.engage)
        f.model.confirmProfileMove()
        XCTAssertEqual(f.store.folder(withID: folder.id)?.children.map(\.id), [wiki.id, f.mail.id])
        XCTAssertTrue(f.store.isFolderExpanded(folder.id), "opened, as a drop into a folder opens it")
        f.model.moveItems([f.welcome.id, f.news.id], intoFolder: folder.id)
        XCTAssertEqual(f.model.pendingProfileMove?.ids, [f.welcome.id, f.news.id])
        f.model.pendingProfileMove = nil
        XCTAssertEqual(today(f, f.personal), [f.welcome.id, f.news.id])

        // A selection beside a row.
        XCTAssertTrue(f.model.moveDraggedSelection([f.welcome.id, f.news.id], relativeTo: work.report.id, after: false),
                      "asked: the caller must not move the dragged row alone")
        XCTAssertEqual(f.model.pendingProfileMove?.placement, .beside(work.report.id, after: false))
        f.model.confirmProfileMove()
        XCTAssertEqual(today(f, work.space), [f.welcome.id, f.news.id, work.report.id])
    }

    func testAnotherProfilesFavoritesRefuseTheDrop() throws {
        let f = makeFixture()
        let work = try addWork(f)
        let home = try XCTUnwrap(f.store.space(withID: f.engage)?.profileID)
        XCTAssertTrue(f.model.canDropOnFavorites(f.maps.id, of: home))
        XCTAssertFalse(f.model.canDropOnFavorites(f.maps.id, of: work.profile), "it would change session with no question asked")
        let folder = try XCTUnwrap(f.store.createFolder(title: "Folder", in: f.engage))
        XCTAssertFalse(f.model.canDropOnFavorites(folder.id, of: home), "plain tabs only, as before")

        f.model.moveItem(f.maps.id, to: .favorites(work.profile), index: 0)
        XCTAssertNil(f.model.pendingProfileMove)
        XCTAssertTrue(f.store.favorites(in: work.profile).isEmpty)
        XCTAssertEqual(f.store.spaceContaining(tabID: f.maps.id), f.engage)

        f.model.moveItem(f.maps.id, to: .favorites(home), index: 0)
        XCTAssertEqual(f.store.favorites(in: home).map(\.id), [f.maps.id])
    }

    // MARK: - The drop targets of two windows

    private var pasteboards: [NSPasteboard] = []

    override func tearDown() {
        pasteboards.forEach { $0.releaseGlobally() }
        pasteboards = []
        super.tearDown()
    }

    /// What a sidebar drag puts on the pasteboard: the row's id as text and
    /// as the sidebar's own type (read from the drag the owner made).
    private func sidebarDrag(of id: UUID, privateType: Bool = true) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("rearc-xwindow-\(UUID().uuidString)"))
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(id.uuidString, forType: .string)
        if privateType { item.setData(Data(id.uuidString.utf8), forType: SidebarDragPayload.pasteboardType) }
        board.writeObjects([item])
        pasteboards.append(board)
        return board
    }

    private func settle(_ view: NSView) { Build1164TestSupport.settle(view) }

    /// Whether a view registered for drags takes one with `board`'s types.
    /// SwiftUI's drop view registers for any data; a plain row for text and links.
    private func takes(_ view: NSView, _ board: NSPasteboard) -> Bool {
        let registered = Set(view.registeredDraggedTypes.map(\.rawValue))
        if registered.contains("public.data") || registered.contains("public.item") { return !registered.isEmpty }
        return !registered.isDisjoint(with: (board.types ?? []).map(\.rawValue))
    }

    /// The view AppKit offers a drag at `point` (window coordinates): the
    /// frontmost, deepest one registered for what the drag carries.
    private func destination(in view: NSView, at point: NSPoint, for board: NSPasteboard) -> NSView? {
        guard !view.isHidden, view.convert(view.bounds, to: nil).contains(point) else { return nil }
        for sub in view.subviews.reversed() {
            if let hit = destination(in: sub, at: point, for: board) { return hit }
        }
        return takes(view, board) ? view : nil
    }

    private func list(in host: NSView, space: Space.ID) throws -> (table: NSTableView, controller: SidebarListController) {
        let tables = Build1164TestSupport.subviews(of: host).compactMap { $0 as? NSTableView }
        let table = try XCTUnwrap(tables.first { ($0.dataSource as? SidebarListController)?.spaceID == space }, "no list for the space")
        return (table, try XCTUnwrap(table.dataSource as? SidebarListController))
    }

    /// A row's frame in its window.
    private func frame(of row: SidebarListRow.ID, in host: NSView, space: Space.ID) throws -> NSRect {
        let (table, controller) = try list(in: host, space: space)
        let index = try XCTUnwrap(controller.rows.firstIndex { $0.id == row }, "no row \(row)")
        return table.convert(table.rect(ofRow: index), to: nil)
    }

    private enum Part { case before, middle, after }

    /// A point of a frame in window coordinates, where y grows upward: a row's upper part is before it.
    private func point(_ part: Part, of rect: NSRect) -> NSPoint {
        let fraction: CGFloat = part == .before ? 0.8 : part == .middle ? 0.5 : 0.2
        return NSPoint(x: rect.midX, y: rect.minY + rect.height * fraction)
    }

    /// The pointer of a drag arrives at `point`: the view there is offered it.
    @discardableResult
    private func enter(_ board: NSPasteboard, at point: NSPoint, host: NSView, window: NSWindow) throws -> NSDragOperation {
        let drag = OfferedDrag(pasteboard: board, location: point, window: window)
        let operation = try XCTUnwrap(destination(in: host, at: point, for: board), "nothing takes a drag at \(point)").draggingEntered(drag)
        settle(host)
        return operation
    }

    /// The pointer moves over `point` and the button comes up there.
    private func drop(_ board: NSPasteboard, at point: NSPoint, host: NSView, window: NSWindow) throws -> (operation: NSDragOperation, performed: Bool) {
        let drag = OfferedDrag(pasteboard: board, location: point, window: window)
        let target = try XCTUnwrap(destination(in: host, at: point, for: board), "nothing takes a drag at \(point)")
        var operation = target.draggingEntered(drag)
        for _ in 0 ..< 2 {
            drag.lastOperation = operation
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            operation = target.draggingUpdated(drag)
        }
        guard !operation.isEmpty, target.prepareForDragOperation(drag) else {
            target.draggingExited(drag)
            settle(host)
            return (operation, false)
        }
        let performed = target.performDragOperation(drag)
        target.concludeDragOperation(drag)
        settle(host)
        return (operation, performed)
    }

    /// Both windows' sidebars, laid out off screen.
    private func withBothSidebars(_ f: Fixture, _ body: (_ right: NSView, _ rightWindow: NSWindow, _ left: NSView, _ leftWindow: NSWindow) throws -> Void) throws {
        let size = NSSize(width: 228, height: 700)
        try Build1164TestSupport.hosted(WindowSidebar(model: f.model, window: f.right), size: size) { right, rightWindow in
            try Build1164TestSupport.hosted(WindowSidebar(model: f.model, window: f.left), size: size) { left, leftWindow in
                try body(right, rightWindow, left, leftWindow)
            }
        }
    }

    /// The owner's drag: Google Maps from the right window's Today onto the
    /// left window's Today, beside Welcome to ReArc.
    func testATabDroppedOnARowOfAnotherWindowMovesThere() throws {
        let f = makeFixture()
        try withBothSidebars(f) { right, _, left, leftWindow in
            let leftRows = try list(in: left, space: f.personal).controller.rows.map(\.id)
            // The drag begins on the row in the right window.
            f.model.sidebarDragBinding(in: f.right).wrappedValue = f.maps.id
            settle(right)
            settle(left)
            XCTAssertTrue(try list(in: right, space: f.engage).controller.hostsAllRows)
            XCTAssertEqual(try list(in: left, space: f.personal).controller.rows.map(\.id), leftRows,
                           "the other window's sidebar is as it was until the drag comes over it")
            XCTAssertFalse(try list(in: left, space: f.personal).controller.hostsAllRows)

            // Over the left window's row: a plain row is offered the drag, and the sidebar opens.
            let board = sidebarDrag(of: f.maps.id)
            try enter(board, at: point(.after, of: try frame(of: .item(f.welcome.id), in: left, space: f.personal)), host: left, window: leftWindow)
            XCTAssertEqual(f.model.sidebarDragItem(in: f.left), f.maps.id)
            let opened = try list(in: left, space: f.personal).controller
            XCTAssertTrue(opened.hostsAllRows, "every row of the other window is a drop target now")
            XCTAssertTrue(opened.rows.contains { $0.id == .sectionEnd(.pinned) }, "and its drop areas are open")

            // The row is where the layout put it; the drop goes after it.
            let result = try drop(board, at: point(.after, of: try frame(of: .item(f.welcome.id), in: left, space: f.personal)),
                                  host: left, window: leftWindow)
            XCTAssertEqual(result.operation, .move)
            XCTAssertTrue(result.performed, "the drop was accepted and then moved nothing (build 1255)")
            XCTAssertEqual(today(f, f.personal), [f.welcome.id, f.maps.id, f.news.id])
            XCTAssertEqual(today(f, f.engage), [f.docs.id, f.mail.id])
            XCTAssertNil(f.model.sidebarDrag, "the drop ends the drag for both windows")
            XCTAssertNil(f.model.pendingProfileMove)
            XCTAssertEqual(try list(in: left, space: f.personal).controller.rows.filter { $0.id == .sectionEnd(.pinned) }.count, 0,
                           "the drop areas close again")
            settle(right)
            XCTAssertFalse(try list(in: right, space: f.engage).controller.hostsAllRows)
        }
    }

    func testATabDroppedBeforeARowOfAnotherWindowLandsBeforeIt() throws {
        let f = makeFixture()
        try withBothSidebars(f) { _, _, left, leftWindow in
            f.model.beginSidebarDrag(f.docs.id, in: f.right)
            let board = sidebarDrag(of: f.docs.id)
            try enter(board, at: point(.before, of: try frame(of: .item(f.news.id), in: left, space: f.personal)), host: left, window: leftWindow)
            let result = try drop(board, at: point(.before, of: try frame(of: .item(f.news.id), in: left, space: f.personal)),
                                  host: left, window: leftWindow)
            XCTAssertTrue(result.performed)
            XCTAssertEqual(today(f, f.personal), [f.welcome.id, f.docs.id, f.news.id])
        }
    }

    /// A selected row carries its window's selection into the other window.
    func testASelectionDroppedOnAnotherWindowGoesWhole() throws {
        let f = makeFixture()
        f.model.selectTab(f.maps.id)
        XCTAssertTrue(f.model.handleSelectionClick(on: f.docs.id, in: f.right, modifiers: .shift))
        try withBothSidebars(f) { _, _, left, leftWindow in
            f.model.beginSidebarDrag(f.maps.id, in: f.right)
            let board = sidebarDrag(of: f.maps.id)
            try enter(board, at: point(.after, of: try frame(of: .item(f.news.id), in: left, space: f.personal)), host: left, window: leftWindow)
            let result = try drop(board, at: point(.after, of: try frame(of: .item(f.news.id), in: left, space: f.personal)),
                                  host: left, window: leftWindow)
            XCTAssertTrue(result.performed)
            XCTAssertEqual(today(f, f.personal), [f.welcome.id, f.news.id, f.maps.id, f.docs.id], "the whole selection, in order")
            XCTAssertEqual(today(f, f.engage), [f.mail.id])
        }
    }

    func testADropAfterAnotherWindowsEmptyPinnedSectionPinsThere() throws {
        let f = makeFixture()
        try withBothSidebars(f) { _, _, left, leftWindow in
            f.model.beginSidebarDrag(f.maps.id, in: f.right)
            let board = sidebarDrag(of: f.maps.id)
            try enter(board, at: point(.middle, of: try frame(of: .item(f.welcome.id), in: left, space: f.personal)), host: left, window: leftWindow)
            // "Drop here to pin": open only now that the drag is over this window.
            let zone = try frame(of: .sectionEnd(.pinned), in: left, space: f.personal)
            let result = try drop(board, at: point(.middle, of: zone), host: left, window: leftWindow)
            XCTAssertEqual(result.operation, .move)
            XCTAssertTrue(result.performed)
            XCTAssertEqual(pinned(f, f.personal), [f.maps.id])
            XCTAssertEqual(f.store.kind(of: f.maps.id), .pinned)
            XCTAssertEqual(today(f, f.engage), [f.docs.id, f.mail.id])
        }
    }

    func testADropAfterAnotherWindowsTodayLandsAtItsEnd() throws {
        let f = makeFixture()
        try withBothSidebars(f) { _, _, left, leftWindow in
            f.model.beginSidebarDrag(f.maps.id, in: f.right)
            let board = sidebarDrag(of: f.maps.id)
            try enter(board, at: point(.middle, of: try frame(of: .item(f.welcome.id), in: left, space: f.personal)), host: left, window: leftWindow)
            let zone = try frame(of: .sectionEnd(.unpinned), in: left, space: f.personal)
            let result = try drop(board, at: point(.middle, of: zone), host: left, window: leftWindow)
            XCTAssertTrue(result.performed)
            XCTAssertEqual(today(f, f.personal), [f.welcome.id, f.news.id, f.maps.id])
        }
    }

    func testADropOnAFolderOfAnotherWindowGoesIntoIt() throws {
        let f = makeFixture()
        let kept = f.store.addTab(kind: .pinned, title: "Kept", url: url("kept"), in: f.personal)
        let folder = try XCTUnwrap(f.store.createFolder(title: "Work", in: f.personal, containing: [kept.id]))
        try withBothSidebars(f) { _, _, left, leftWindow in
            f.model.beginSidebarDrag(f.maps.id, in: f.right)
            let board = sidebarDrag(of: f.maps.id)
            try enter(board, at: point(.middle, of: try frame(of: .item(folder.id), in: left, space: f.personal)), host: left, window: leftWindow)
            let result = try drop(board, at: point(.middle, of: try frame(of: .item(folder.id), in: left, space: f.personal)),
                                  host: left, window: leftWindow)
            XCTAssertTrue(result.performed)
            XCTAssertEqual(f.store.folder(withID: folder.id)?.children.map(\.id), [kept.id, f.maps.id])
            XCTAssertEqual(f.store.kind(of: f.maps.id), .pinned)
        }
    }

    /// The SwiftUI drop targets of a hosted sidebar that lie wholly above or below its list.
    private func targets(in host: NSView, space: Space.ID, above: Bool) throws -> [NSRect] {
        let scroll = try XCTUnwrap(try list(in: host, space: space).table.enclosingScrollView)
        let listFrame = scroll.convert(scroll.bounds, to: nil)
        let bounds = host.convert(host.bounds, to: nil)
        return Build1164TestSupport.subviews(of: host)
            .filter { $0.registeredDraggedTypes.map(\.rawValue).contains("public.data") && !$0.isHidden && !$0.isDescendant(of: scroll) }
            .map { $0.convert($0.bounds, to: nil) }
            .filter { bounds.contains($0) && $0.width > 1 && $0.height > 1 && (above ? $0.minY >= listFrame.maxY - 1 : $0.maxY <= listFrame.minY + 1) }
            .sorted { $0.minX < $1.minX }
    }

    func testADropOnAnotherWindowsFavoritesMakesAFavorite() throws {
        let f = makeFixture()
        let profile = try XCTUnwrap(f.store.space(withID: f.personal)?.profileID)
        try withBothSidebars(f) { _, _, left, leftWindow in
            XCTAssertEqual(try targets(in: left, space: f.personal, above: true).count, 0, "no favorites row until there is one or a drag")
            f.model.beginSidebarDrag(f.maps.id, in: f.right)
            let board = sidebarDrag(of: f.maps.id)
            try enter(board, at: point(.middle, of: try frame(of: .item(f.welcome.id), in: left, space: f.personal)), host: left, window: leftWindow)
            // "Drop here to add to Favorites", open now.
            let strip = try XCTUnwrap(try targets(in: left, space: f.personal, above: true).max { $0.width * $0.height < $1.width * $1.height },
                                      "the favorites strip did not open for the other window's drag")
            let result = try drop(board, at: NSPoint(x: strip.midX, y: strip.midY), host: left, window: leftWindow)
            XCTAssertEqual(result.operation, .move)
            XCTAssertTrue(result.performed)
            XCTAssertEqual(f.store.favorites(in: profile).map(\.id), [f.maps.id])
            XCTAssertEqual(today(f, f.engage), [f.docs.id, f.mail.id])
            XCTAssertNil(f.model.sidebarDrag)
        }
    }

    func testAnotherProfilesFavoritesStripRefusesTheOtherWindowsTab() throws {
        let f = makeFixture()
        let work = try addWork(f)
        f.store.unregisterWindow(f.left)
        f.store.registerWindow(f.left, spaceID: work.space)
        try withBothSidebars(f) { _, _, left, leftWindow in
            f.model.beginSidebarDrag(f.maps.id, in: f.right)
            let board = sidebarDrag(of: f.maps.id)
            try enter(board, at: point(.middle, of: try frame(of: .item(work.report.id), in: left, space: work.space)), host: left, window: leftWindow)
            let strip = try XCTUnwrap(try targets(in: left, space: work.space, above: true).max { $0.width * $0.height < $1.width * $1.height })
            let result = try drop(board, at: NSPoint(x: strip.midX, y: strip.midY), host: left, window: leftWindow)
            XCTAssertFalse(result.performed, "refused, not accepted and then dropped")
            XCTAssertTrue(f.store.favorites(in: work.profile).isEmpty)
            XCTAssertEqual(f.store.spaceContaining(tabID: f.maps.id), f.engage)
            XCTAssertNil(f.model.pendingProfileMove)
        }
    }

    /// A drop on a space's icon in the other window's bottom bar is Move to
    /// Space, as in the drag's own window: the top of that space's Today,
    /// and a tab that was on show takes its window along, as the menu item does.
    func testADropOnASpaceIconOfAnotherWindowMovesToThatSpace() throws {
        let f = makeFixture()
        f.model.selectTab(f.mail.id)
        try withBothSidebars(f) { _, _, left, leftWindow in
            let icons = try targets(in: left, space: f.personal, above: false)
            XCTAssertEqual(icons.count, 2, "one drop target per space of the profile: \(icons)")
            // Personal is the second space of the strip.
            let personalIcon = try XCTUnwrap(icons.last)
            let onIcon = NSPoint(x: personalIcon.midX, y: personalIcon.midY)

            f.model.beginSidebarDrag(f.maps.id, in: f.right)
            let result = try drop(sidebarDrag(of: f.maps.id), at: onIcon, host: left, window: leftWindow)
            XCTAssertEqual(result.operation, .move)
            XCTAssertTrue(result.performed)
            XCTAssertEqual(today(f, f.personal), [f.maps.id, f.welcome.id, f.news.id])
            XCTAssertEqual(today(f, f.engage), [f.docs.id, f.mail.id])
            XCTAssertEqual(f.store.activeSpaceID, f.engage, "a tab that was not on show leaves its window where it was")
            XCTAssertEqual(f.store.selectedItemID(in: f.right), f.mail.id)
            XCTAssertNil(f.model.sidebarDrag)

            // The tab on show: Move to Space takes its window to the space with it.
            f.model.beginSidebarDrag(f.mail.id, in: f.right)
            XCTAssertTrue(try drop(sidebarDrag(of: f.mail.id), at: onIcon, host: left, window: leftWindow).performed)
            XCTAssertEqual(today(f, f.personal), [f.mail.id, f.maps.id, f.welcome.id, f.news.id])
            XCTAssertEqual(f.store.activeSpaceID, f.personal)
            XCTAssertEqual(f.store.selectedItemID, f.mail.id)
        }
    }

    func testADropInAnotherWindowOnAnotherProfileAsksFirst() throws {
        let f = makeFixture()
        let work = try addWork(f)
        f.store.unregisterWindow(f.left)
        f.store.registerWindow(f.left, spaceID: work.space)
        try withBothSidebars(f) { _, _, left, leftWindow in
            f.model.beginSidebarDrag(f.maps.id, in: f.right)
            let board = sidebarDrag(of: f.maps.id)
            try enter(board, at: point(.after, of: try frame(of: .item(work.report.id), in: left, space: work.space)), host: left, window: leftWindow)
            let result = try drop(board, at: point(.after, of: try frame(of: .item(work.report.id), in: left, space: work.space)),
                                  host: left, window: leftWindow)
            XCTAssertTrue(result.performed)
            XCTAssertEqual(f.model.pendingProfileMove,
                           SidebarProfileMove(ids: [f.maps.id], spaceID: work.space, placement: .beside(work.report.id, after: true)))
            XCTAssertEqual(f.store.spaceContaining(tabID: f.maps.id), f.engage, "nothing moves before the answer")
            f.model.confirmProfileMove()
            XCTAssertEqual(today(f, work.space), [work.report.id, f.maps.id])
        }
    }

    // MARK: - The same window, as before

    func testADropInTheDragsOwnWindowStillReorders() throws {
        let f = makeFixture()
        try withBothSidebars(f) { right, rightWindow, left, _ in
            let leftRows = try list(in: left, space: f.personal).controller.rows.map(\.id)
            f.model.sidebarDragBinding(in: f.right).wrappedValue = f.maps.id
            settle(right)
            let board = sidebarDrag(of: f.maps.id)
            let result = try drop(board, at: point(.after, of: try frame(of: .item(f.mail.id), in: right, space: f.engage)),
                                  host: right, window: rightWindow)
            XCTAssertEqual(result.operation, .move)
            XCTAssertTrue(result.performed)
            XCTAssertEqual(today(f, f.engage), [f.docs.id, f.mail.id, f.maps.id])
            XCTAssertEqual(today(f, f.personal), [f.welcome.id, f.news.id])
            XCTAssertNil(f.model.sidebarDrag)
            settle(left)
            XCTAssertEqual(try list(in: left, space: f.personal).controller.rows.map(\.id), leftRows, "the other window never changed")
        }
    }

    func testADropAtTheEndOfTheDragsOwnPinnedSectionStillPins() throws {
        let f = makeFixture()
        try withBothSidebars(f) { right, rightWindow, _, _ in
            f.model.sidebarDragBinding(in: f.right).wrappedValue = f.docs.id
            settle(right)
            let board = sidebarDrag(of: f.docs.id)
            let result = try drop(board, at: point(.middle, of: try frame(of: .sectionEnd(.pinned), in: right, space: f.engage)),
                                  host: right, window: rightWindow)
            XCTAssertTrue(result.performed)
            XCTAssertEqual(pinned(f, f.engage), [f.docs.id])
            XCTAssertEqual(today(f, f.engage), [f.maps.id, f.mail.id])
        }
    }

    // MARK: - Drags the model does not know

    /// With no drag in the model, a sidebar drag is read from its own text.
    /// This is the path build 1255 took for every drop in another window: it
    /// asked the drag for the sidebar's type, which SwiftUI hands over empty.
    func testASidebarDragTheModelDoesNotKnowIsReadFromTheDrag() throws {
        let f = makeFixture()
        try withBothSidebars(f) { _, _, left, leftWindow in
            XCTAssertNil(f.model.sidebarDrag)
            let board = sidebarDrag(of: f.maps.id)
            let row = point(.after, of: try frame(of: .item(f.welcome.id), in: left, space: f.personal))
            let target = try liveTarget(board, at: row, host: left, window: leftWindow)
            let drag = OfferedDrag(pasteboard: board, location: row, window: leftWindow)
            XCTAssertEqual(target.draggingEntered(drag), .move)
            XCTAssertEqual(target.draggingUpdated(drag), .move)
            XCTAssertTrue(target.performDragOperation(drag), "a drop that is accepted must move its row")
            settle(left)
            XCTAssertEqual(today(f, f.personal), [f.welcome.id, f.maps.id, f.news.id])
        }
    }

    /// The row's SwiftUI drop target, live under a drag that has just come over a plain row.
    private func liveTarget(_ board: NSPasteboard, at point: NSPoint, host: NSView, window: NSWindow) throws -> NSView {
        _ = try XCTUnwrap(destination(in: host, at: point, for: board)).draggingEntered(OfferedDrag(pasteboard: board, location: point, window: window))
        // The rows stay live for a drag from outside only while a button is down: no long wait.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let target = try XCTUnwrap(destination(in: host, at: point, for: board))
        XCTAssertFalse(target is SidebarPlainRowCell, "the row's SwiftUI drop target is under the drag")
        return target
    }

    /// A row's id as plain text, without the sidebar's type, is text: it
    /// moves nothing, even while a sidebar drag is under way elsewhere.
    func testPlainTextThatLooksLikeARowIsNotADrag() throws {
        let f = makeFixture()
        try withBothSidebars(f) { _, _, left, leftWindow in
            f.model.beginSidebarDrag(f.maps.id, in: f.right)
            let board = sidebarDrag(of: f.maps.id, privateType: false)
            let row = point(.after, of: try frame(of: .item(f.welcome.id), in: left, space: f.personal))
            let target = try liveTarget(board, at: row, host: left, window: leftWindow)
            let drag = OfferedDrag(pasteboard: board, location: row, window: leftWindow)
            let operation = target.draggingEntered(drag)
            XCTAssertTrue(operation.isEmpty, "text is not offered a place among the rows")
            if !operation.isEmpty { _ = target.performDragOperation(drag) }
            settle(left)
            XCTAssertNil(f.model.sidebarDragItem(in: f.left), "and it does not open the window for the drag")
            XCTAssertEqual(today(f, f.personal), [f.welcome.id, f.news.id])
            XCTAssertEqual(today(f, f.engage), [f.maps.id, f.docs.id, f.mail.id])
        }
    }

    /// A link dragged in from a page while a sidebar drag was left over (it
    /// ended outside every window) opens the link. The left-over row stays.
    func testALinkIsNotTakenForALeftOverDrag() throws {
        let f = makeFixture()
        try withBothSidebars(f) { _, _, left, leftWindow in
            f.model.beginSidebarDrag(f.maps.id, in: f.right)
            let board = NSPasteboard(name: NSPasteboard.Name("rearc-xwindow-\(UUID().uuidString)"))
            board.clearContents()
            board.writeObjects([URL(string: "https://dropped.test/page")! as NSURL])
            pasteboards.append(board)
            let row = point(.after, of: try frame(of: .item(f.welcome.id), in: left, space: f.personal))
            let target = try liveTarget(board, at: row, host: left, window: leftWindow)
            let drag = OfferedDrag(pasteboard: board, location: row, window: leftWindow)
            XCTAssertEqual(target.draggingEntered(drag), .copy, "a link is copied in, not moved")
            XCTAssertTrue(target.performDragOperation(drag))
            settle(left)
            let rows = today(f, f.personal)
            XCTAssertEqual(rows.count, 3)
            XCTAssertEqual(f.store.tab(withID: rows[1])?.url.host, "dropped.test", "the link opened after the row it was dropped on")
            XCTAssertEqual(today(f, f.engage), [f.maps.id, f.docs.id, f.mail.id], "the left-over drag's row did not move")
        }
    }

    /// The source provider still loads from the sidebar's own type, and the
    /// text beside it is read only by a caller that saw the type.
    func testThePayloadLoadsFromItsTypeOrItsText() async {
        let id = UUID()
        let fromText = await withCheckedContinuation { continuation in
            XCTAssertTrue(SidebarDragPayload.loadText([NSItemProvider(object: id.uuidString as NSString)]) { continuation.resume(returning: $0) })
        }
        XCTAssertEqual(fromText, id)
        XCTAssertFalse(SidebarDragPayload.loadText([]) { _ in XCTFail("nothing to load") })
        XCTAssertFalse(SidebarDragPayload.load([NSItemProvider()]) { _ in XCTFail("an empty provider is what SwiftUI hands over") })
    }
}
