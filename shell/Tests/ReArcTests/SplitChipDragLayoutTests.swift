import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Found on screen 2026-11-22 (QA build of main 2e0c72cb): a pane chip
/// dragged straight along its split's row reordered nothing. As the drag
/// began every Today row moved down 28 pt: the sidebar opened its drop
/// areas for the drag (the Favorites row's end zone, 18 pt, and the drop
/// row after Pinned, 10 pt). The pointer was then above the row, over the
/// row before it, and the drag was a row's. Now a chip's drag leaves the
/// rows where they are until the pointer leaves the split's row; off the
/// row it moves the whole split as before. The chip is its own drag source
/// (its image is the chip, not the row), and the upright insertion line is
/// the row insertion line's weight and the row's height.
@MainActor
final class SplitChipDragLayoutTests: XCTestCase {
    private struct Fixture {
        let model: BrowserViewModel
        let splitID: SplitViewItem.ID
        let panes: [SidebarModel.Tab]
        let pinned: SidebarModel.Tab
        let today: SidebarModel.Tab

        var split: SplitViewItem { model.store.split(withID: splitID)! }
        var order: [String] { split.tabs.map(\.title) }
    }

    /// A space as the QA profile had it: a favorite, a pinned tab, and in Today a tab and a three-pane split.
    private func makeFixture() throws -> Fixture {
        let model = Build1164TestSupport.makeModel()
        let store = model.store
        _ = store.addTab(kind: .favorite, title: "Favorite", url: URL(string: "https://favorite.test")!)
        let pinned = store.addTab(kind: .pinned, title: "Pinned", url: URL(string: "https://pinned.test")!)
        let today = store.addTab(kind: .today, title: "Today", url: URL(string: "https://today.test")!)
        let panes = (0 ..< 3).map { store.addTab(kind: .today, title: "Pane \($0)", url: URL(string: "https://pane\($0).test")!) }
        let split = try XCTUnwrap(store.createSplit(tabIDs: panes.map(\.id), orientation: .horizontal))
        model.selectTab(today.id)
        return Fixture(model: model, splitID: split.id, panes: panes, pinned: pinned, today: today)
    }

    // MARK: The drag's state

    func testAChipDragAlongItsRowHoldsTheRowsAndReordersThePanes() throws {
        let f = try makeFixture()
        let model = f.model
        XCTAssertFalse(model.sidebarOpensDropAreas(dragging: nil), "no drag: no drop areas")

        // The press is on the first chip; the drag carries the split's row.
        model.splitPaneChipDragBegan(f.panes[0].id, in: f.split)
        XCTAssertEqual(model.splitPaneChipDrag, SplitPaneChipDrag(splitID: f.splitID, tabID: f.panes[0].id))
        XCTAssertFalse(model.sidebarOpensDropAreas(dragging: f.splitID), "along its own row the sidebar opens nothing: the rows stay")

        // Straight along the row to the last chip (three chips share 300 pt).
        for x in stride(from: 40.0, through: 260.0, by: 20.0) {
            model.splitPaneChipDragMoved(to: model.splitPaneChipDestination(in: f.split, x: x, width: 300), in: f.split)
            XCTAssertFalse(model.sidebarOpensDropAreas(dragging: f.splitID), "still along the row at x \(x)")
        }
        XCTAssertEqual(model.splitPaneChipDrag?.boundary(in: f.split), 3, "the insertion line is after the last chip")
        let destination = try XCTUnwrap(model.splitPaneChipDestination(in: f.split, x: 260, width: 300))
        XCTAssertTrue(model.dropSplitPaneChip(in: f.split, at: destination))
        XCTAssertEqual(f.order, ["Pane 1", "Pane 2", "Pane 0"], "the drop is a chip reorder")
        model.sidebarDragEnded()
        XCTAssertNil(model.splitPaneChipDrag)
        XCTAssertFalse(model.sidebarOpensDropAreas(dragging: nil))
    }

    func testDraggedOffItsRowTheChipTakesTheWholeSplit() throws {
        let f = try makeFixture()
        let model = f.model
        model.splitPaneChipDragBegan(f.panes[1].id, in: f.split)
        model.splitPaneChipDragMoved(to: 2, in: f.split)
        XCTAssertEqual(model.splitPaneChipDrag?.boundary(in: f.split), 3)

        // The pointer leaves the row: no place among the chips, and the sidebar opens its drop areas as for any row.
        model.splitPaneChipDragLeftRow()
        XCTAssertEqual(model.splitPaneChipDrag?.hasLeftRow, true)
        XCTAssertNil(model.splitPaneChipDrag?.boundary(in: f.split), "no insertion line left in the row")
        XCTAssertTrue(model.sidebarOpensDropAreas(dragging: f.splitID))

        // Dropped before the Today tab, as the row's drop does it: the split moves, its panes keep their order.
        model.moveItem(f.splitID, relativeTo: f.today.id, after: false)
        model.sidebarDragEnded()
        let today = model.store.content(for: model.store.activeSpaceID).today.map(\.id)
        XCTAssertEqual(today, [f.splitID, f.today.id], "the whole split moved above the tab")
        XCTAssertEqual(f.order, ["Pane 0", "Pane 1", "Pane 2"])
        XCTAssertNil(model.splitPaneChipDrag)
    }

    func testBackOnItsRowTheChipReordersAgainAndTheDropAreasStayOpen() throws {
        let f = try makeFixture()
        let model = f.model
        model.splitPaneChipDragBegan(f.panes[0].id, in: f.split)
        model.splitPaneChipDragLeftRow()
        // Following the row to where it now is: a place among the chips again. The rows do not move a second time.
        let destination = try XCTUnwrap(model.splitPaneChipDestination(in: f.split, x: 150, width: 300))
        model.splitPaneChipDragMoved(to: destination, in: f.split)
        XCTAssertEqual(model.splitPaneChipDrag?.boundary(in: f.split), 2)
        XCTAssertTrue(model.sidebarOpensDropAreas(dragging: f.splitID), "once open the drop areas stay for the rest of the drag")
        XCTAssertTrue(model.dropSplitPaneChip(in: f.split, at: destination))
        XCTAssertEqual(f.order, ["Pane 1", "Pane 0", "Pane 2"])
    }

    func testOnlyAChipOfAnUnnamedSplitStartsAChipDrag() throws {
        let f = try makeFixture()
        let model = f.model
        // A row's own drag (a tab, or a split taken by its edge) opens the drop areas at once, as before.
        model.sidebarDragBegan(on: .tab(f.today))
        XCTAssertNil(model.splitPaneChipDrag)
        XCTAssertTrue(model.sidebarOpensDropAreas(dragging: f.today.id))
        model.sidebarDragBegan(on: .split(f.split))
        XCTAssertTrue(model.sidebarOpensDropAreas(dragging: f.splitID), "no chip under the pointer: the row's drag")

        // A tab that is no pane of the split, and a named split's row (it has no chips).
        model.splitPaneChipDragBegan(f.today.id, in: f.split)
        XCTAssertNil(model.splitPaneChipDrag)
        model.splitPaneChipDragBegan(f.panes[0].id, in: f.split)
        XCTAssertNotNil(model.splitPaneChipDrag)
        XCTAssertFalse(model.sidebarOpensDropAreas(dragging: f.splitID))
        XCTAssertTrue(model.sidebarOpensDropAreas(dragging: f.today.id), "a chip's drag holds the rows for its own split's drag only")
        XCTAssertTrue(model.store.renameSplit(f.splitID, to: "Named"))
        model.splitPaneChipDragBegan(f.panes[0].id, in: f.split)
        XCTAssertNil(model.splitPaneChipDrag, "and a drag left over is cleared")
        // Leaving a row with no chip drag under way is nothing.
        model.splitPaneChipDragLeftRow()
        XCTAssertNil(model.splitPaneChipDrag)
    }

    // MARK: The list's rows

    /// The table's rows and where the split's row is, as `SidebarListTable` drives its controller.
    func testTheTableAddsNoDropRowsUntilTheChipLeavesItsRow() throws {
        let f = try makeFixture()
        let model = f.model
        let context = SidebarListCellContext(
            chrome: ThemeChromeColors(theme: .default, dark: false), window: nil, pager: nil, colorScheme: .light, tint: .blue)
        let controller = SidebarListController(model: model, spaceID: model.store.activeSpaceID, context: context)
        let scroll = controller.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 228, height: 600)
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        func splitRowY() throws -> CGFloat {
            let row = try XCTUnwrap(controller.rows.firstIndex { $0.id == .item(f.splitID) })
            return table.rect(ofRow: row).minY
        }
        func update(dragging: UUID?) {
            controller.update(spaceID: model.store.activeSpaceID, isDragging: dragging != nil,
                              opensDropAreas: model.sidebarOpensDropAreas(dragging: dragging))
        }
        let rows = controller.rows.map(\.id)
        let y = try splitRowY()

        model.splitPaneChipDragBegan(f.panes[0].id, in: f.split)
        update(dragging: f.splitID)
        XCTAssertEqual(controller.rows.map(\.id), rows, "a chip's drag along its row adds no row")
        XCTAssertEqual(try splitRowY(), y, "the split's row is where it was when the drag began")
        XCTAssertTrue(controller.hostsAllRows, "every row is a drop target all the same")

        model.splitPaneChipDragLeftRow()
        update(dragging: f.splitID)
        XCTAssertEqual(controller.rows.map(\.id).filter { !rows.contains($0) }, [.sectionEnd(.pinned), .sectionEnd(.unpinned)])
        XCTAssertEqual(try splitRowY(), y + 10, "off the row the drop row after Pinned opens, 10 pt")

        model.sidebarDragEnded()
        update(dragging: nil)
        XCTAssertEqual(controller.rows.map(\.id), rows)
        XCTAssertEqual(try splitRowY(), y)

        // Any other row's drag opens them as it begins, as before.
        model.sidebarDragBegan(on: .tab(f.today))
        update(dragging: f.today.id)
        XCTAssertEqual(try splitRowY(), y + 10)
    }

    // MARK: The sidebar on screen (laid out off screen)

    /// The sidebar with the drag its window has, which the test sets.
    private final class DragState: ObservableObject {
        @Published var dragged: UUID?
    }

    private struct Sidebar: View {
        let model: BrowserViewModel
        @ObservedObject var drag: DragState

        var body: some View {
            SidebarView(model: model, draggedItemID: $drag.dragged)
                .environment(\.themeChrome, ThemeChromeColors(theme: .default, dark: false))
                .frame(width: 228, height: 700)
        }
    }

    /// Where the split's row is in the window: the whole sidebar laid out,
    /// the Favorites row above the list included. The QA build's row went
    /// from y 560 to 588 as the drag began.
    func testTheSplitsRowStaysUnderThePointerWhenAChipDragBegins() throws {
        let f = try makeFixture()
        let model = f.model
        model.sidebarWidth = 228
        let drag = DragState()
        try Build1164TestSupport.hosted(Sidebar(model: model, drag: drag), size: NSSize(width: 228, height: 700)) { host, _ in
            func splitRowY() throws -> CGFloat {
                Build1164TestSupport.settle(host)
                let tables = Build1164TestSupport.subviews(of: host).compactMap { $0 as? NSTableView }
                let table = try XCTUnwrap(tables.first { ($0.dataSource as? SidebarListController)?.spaceID == model.store.activeSpaceID },
                                          "no sidebar list in the hosted sidebar")
                let controller = try XCTUnwrap(table.dataSource as? SidebarListController)
                let row = try XCTUnwrap(controller.rows.firstIndex { $0.id == .item(f.splitID) })
                // From the top of the window, as a screen reading has it.
                let rect = table.convert(table.rect(ofRow: row), to: nil)
                return host.bounds.height - rect.maxY
            }
            let y = try splitRowY()

            // The press on a chip, then the drag: nothing moves.
            model.splitPaneChipDragBegan(f.panes[0].id, in: f.split)
            drag.dragged = f.splitID
            XCTAssertEqual(try splitRowY(), y, accuracy: 0.5, "the split's row moved as the chip's drag began")

            // Off the row the sidebar makes room as for any drag: Favorites' end zone (18) and the row after Pinned (10).
            model.splitPaneChipDragLeftRow()
            XCTAssertEqual(try splitRowY(), y + 28, accuracy: 0.5)

            drag.dragged = nil
            model.sidebarDragEnded()
            XCTAssertEqual(try splitRowY(), y, accuracy: 0.5, "the drag over, the rows are back")

            // A tab row's drag: the same 28 pt at once, which is what the chip's drag did before.
            model.sidebarDragBegan(on: .tab(f.today))
            drag.dragged = f.today.id
            XCTAssertEqual(try splitRowY(), y + 28, accuracy: 0.5)
        }
    }

    // MARK: The insertion line

    private func bitmap<V: View>(_ view: V, size: CGSize) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        return NSBitmapImageRep(cgImage: image)
    }

    /// The sidebar's accent as it renders: every drop area draws in `Color.accentColor`.
    private func accent() throws -> NSColor {
        let swatch = try bitmap(Rectangle().fill(Color.accentColor), size: CGSize(width: 4, height: 4))
        return try XCTUnwrap(swatch.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB))
    }

    /// The box of the pixels that are the accent, in points.
    private func accentBox(_ rep: NSBitmapImageRep) throws -> CGRect? {
        let accent = try accent()
        var box: CGRect?
        for y in 0 ..< rep.pixelsHigh {
            for x in 0 ..< rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9,
                      abs(color.redComponent - accent.redComponent) < 0.04, abs(color.greenComponent - accent.greenComponent) < 0.04,
                      abs(color.blueComponent - accent.blueComponent) < 0.04 else { continue }
                let pixel = CGRect(x: x, y: y, width: 1, height: 1)
                box = box.map { $0.union(pixel) } ?? pixel
            }
        }
        return box.map { CGRect(x: $0.minX / 2, y: $0.minY / 2, width: $0.width / 2, height: $0.height / 2) }
    }

    func testTheUprightInsertionLineIsTheRowLinesWeightAndColour() throws {
        let row = try XCTUnwrap(accentBox(try bitmap(SidebarInsertionLine(axis: .horizontal), size: CGSize(width: 60, height: 20))),
                                "the row line is not the accent")
        let upright = try XCTUnwrap(accentBox(try bitmap(SidebarInsertionLine(axis: .vertical), size: CGSize(width: 20, height: 60))),
                                    "the upright line is not the accent")
        XCTAssertEqual(row.height, SidebarInsertionLine.thickness, accuracy: 0.5)
        XCTAssertEqual(upright.width, row.height, accuracy: 0.5, "one weight for both")
        XCTAssertEqual(upright.height, SidebarMetrics.rowHeight, accuracy: 1, "as tall as the split's row")
    }

    /// In the split's row itself: the line where the pane would land, in
    /// the accent, clear of the chips' 26 pt (the height of the drag image).
    func testASplitRowDrawsTheInsertionLineTallerThanItsChips() throws {
        let f = try makeFixture()
        func rowImage(boundary: Int?) throws -> NSBitmapImageRep {
            let view = SplitRowView(
                split: f.split, isSelected: false, isDropTarget: false, focusedTabID: f.panes[0].id,
                favicon: { _ in nil }, showsAudibleIndicator: { _ in false }, onMutePane: { _ in },
                onSelectSplit: {}, onSelectPane: { _ in }, onCloseSplit: {}, onClosePane: { _, _ in },
                isRenaming: .constant(false), onRename: { _ in }, paneDropBoundary: boundary
            ) { _ in EmptyView() }
            .environment(\.themeChrome, ThemeChromeColors(theme: .default, dark: false))
            return try bitmap(view, size: CGSize(width: 212, height: SidebarMetrics.rowPitch))
        }
        XCTAssertNil(try accentBox(try rowImage(boundary: nil)), "no line without a chip's drag")
        var xs: [CGFloat] = []
        for boundary in 0 ... 3 {
            let line = try XCTUnwrap(accentBox(try rowImage(boundary: boundary)), "no insertion line at boundary \(boundary)")
            XCTAssertEqual(line.width, SidebarInsertionLine.thickness, accuracy: 0.5, "boundary \(boundary)")
            XCTAssertGreaterThanOrEqual(line.height, 34, "boundary \(boundary): the line must show above and below a 26 pt chip")
            xs.append(line.midX)
        }
        XCTAssertEqual(xs, xs.sorted(), "the boundaries run along the row")
        XCTAssertGreaterThan(xs[3] - xs[0], 150, "from before the first chip to after the last")
    }
}
