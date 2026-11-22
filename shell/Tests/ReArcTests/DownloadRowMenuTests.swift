import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Build 1164 (2026-11-22): "Ask Siri" headed the right-click menu of a row
/// in the sidebar's downloads stack (macOS adds it to a context menu that
/// allows system items), and the row's tooltip showed its folder's full path.
final class DownloadRowMenuTests: XCTestCase {
    private func downloads(_ ids: [String]) -> DownloadsController {
        let controller = DownloadsController(fileURL: nil)
        controller.apply(ids.map {
            DownloadEvent(kind: .created, guid: $0, url: "https://example.test/\($0)", targetPath: "/tmp/rearc-tests/Private Folder/\($0).zip",
                          totalBytes: 2_048, state: .complete)
        }, source: .chromium)
        return controller
    }

    func testADownloadsMenuHoldsDarnisItemsAndAllowsNoSystemOnes() throws {
        let controller = downloads(["a"])
        let record = try XCTUnwrap(controller.records.first)
        let menu = DownloadRowMenu.menu(for: [record], downloads: controller)
        XCTAssertFalse(menu.allowsContextMenuPlugIns, "macOS adds Ask Siri and Services to a context menu that allows plug-in items")
        let expected = DownloadMenu.sections(for: [record], isWarned: controller.needsDecision)
            .map { $0.map { $0.item.title(count: 1) } }.joined(separator: [""]).map { $0 }
        XCTAssertEqual(menu.items.map(\.title), expected)
        XCTAssertEqual(menu.items.first?.title, "Open", "the download's own item heads the menu")
        XCTAssertFalse(menu.items.contains { $0.title.localizedCaseInsensitiveContains("siri") || $0.title == "Services" || $0.submenu != nil })
        // An entry that cannot act stays disabled (the menu does not enable it by itself).
        XCTAssertFalse(menu.autoenablesItems)
        // The same menu in Library › Downloads, and for the other context menus Darni builds itself.
        XCTAssertFalse(NSMenu.darniContextMenu().allowsContextMenuPlugIns)
        let model = Build1164TestSupport.makeModel()
        XCTAssertFalse(SidebarEmptySpaceMenu.menu(model: model, spaceID: model.store.activeSpaceID).allowsContextMenuPlugIns)
    }

    /// The sidebar's downloads stack and the tray, laid out off screen: each
    /// row's right-click goes to an AppKit view that answers with that menu,
    /// and takes no other click.
    func testDownloadRowsAnswerARightClickWithThatMenu() throws {
        let controller = downloads(["one", "two"])
        let records = Array(controller.records.prefix(2))
        let stack = RecentDownloadsStack(records: records, downloads: controller).frame(width: 240)
        let tray = VStack { ForEach(records) { DownloadRowView(record: $0, downloads: controller) } }.frame(width: 340)
        for (name, view) in [("stack", AnyView(stack)), ("tray", AnyView(tray))] {
            try Build1164TestSupport.hosted(view, size: NSSize(width: 360, height: 200)) { host, window in
                let areas = Build1164TestSupport.subviews(of: host).compactMap { $0 as? DarniContextMenuView }
                XCTAssertEqual(areas.count, records.count, "\(name): one menu area per row")
                let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                             pressure: 1))
                for area in areas {
                    let menu = try XCTUnwrap(area.menu(for: click), name)
                    XCTAssertFalse(menu.allowsContextMenuPlugIns, name)
                    XCTAssertEqual(menu.items.first?.title, "Open", name)
                    XCTAssertFalse(menu.items.contains { $0.title.localizedCaseInsensitiveContains("siri") }, name)
                    // No event is being handled here: an ordinary click, hover or drag passes through to the row.
                    XCTAssertNil(area.hitTest(NSPoint(x: area.frame.midX, y: area.frame.midY)), name)
                }
            }
        }
        // What counts as asking for the menu.
        func mouse(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)
        }
        XCTAssertTrue(DarniContextMenuView.asksForMenu(mouse(.rightMouseDown)))
        XCTAssertTrue(DarniContextMenuView.asksForMenu(mouse(.leftMouseDown, .control)))
        XCTAssertFalse(DarniContextMenuView.asksForMenu(mouse(.leftMouseDown)))
        XCTAssertFalse(DarniContextMenuView.asksForMenu(mouse(.leftMouseDragged)))
        XCTAssertFalse(DarniContextMenuView.asksForMenu(nil))
    }

    /// What the stack and the tray say where a download is (a row's tooltip is
    /// its accessibility help): the file and its folder by name. The folder's
    /// path showed the person's folder names to anyone looking at the screen.
    func testDownloadRowsNameTheFolderAndNeverShowItsPath() throws {
        let controller = downloads(["one"])
        controller.setDirectory(URL(fileURLWithPath: "/tmp/rearc-tests/Private Folder", isDirectory: true))
        let records = Array(controller.records.prefix(1))
        let texts = Build1164TestSupport.accessibilityTexts(of: VStack {
            RecentDownloadsStack(records: records, downloads: controller)
            DownloadsTrayHeader(downloads: controller)
        }.frame(width: 340), size: NSSize(width: 340, height: 200))
        XCTAssertTrue(texts.contains("one.zip in Private Folder"), "the stack row's tooltip in \(texts)")
        XCTAssertTrue(texts.contains("Downloads are saved to Private Folder"), "the folder menu's tooltip in \(texts)")
        XCTAssertFalse(texts.contains { $0.contains("/tmp") || $0.contains("rearc-tests") }, "a path in \(texts)")
    }
}
