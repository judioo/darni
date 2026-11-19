import XCTest
@testable import SidebarModel

final class LittleArcMenusTests: XCTestCase {
    private let profile = UUID()

    private func window(_ title: String, _ url: String) -> LittleArcWindow {
        LittleArcWindow(url: URL(string: url)!, title: title, profileID: profile)
    }

    func testDockListsLittleArcsByTitleThenNewWindows() {
        let news = window("Hacker News", "https://news.ycombinator.com/")
        let blank = window("Little Darni", "about:blank")
        let untitled = window("  ", "https://example.com/page")
        // Saved by a build from before the rename, and restored by this one.
        let saved = window("Little ReArc", "about:blank")
        let savedOnAPage = window("Little ReArc", "https://example.org/")
        let entries = LittleArcDockMenu.entries(for: [news, blank, untitled, saved, savedOnAPage], canOpenBrowserWindow: true)
        XCTAssertEqual(entries, [
            .littleArc(id: news.id, title: "Hacker News"),
            .littleArc(id: blank.id, title: "Little Darni"),
            .littleArc(id: untitled.id, title: "example.com"),
            .littleArc(id: saved.id, title: "Little Darni"),
            .littleArc(id: savedOnAPage.id, title: "example.org"),
            .separator,
            .newLittleArc,
            .newWindow,
        ])
    }

    func testNoLittleArcsMeansNoSeparatorAndNewWindowOnlyWhereSupported() {
        XCTAssertEqual(LittleArcDockMenu.entries(for: [], canOpenBrowserWindow: true), [.newLittleArc, .newWindow])
        XCTAssertEqual(LittleArcDockMenu.entries(for: [], canOpenBrowserWindow: false), [.newLittleArc])
    }
}
