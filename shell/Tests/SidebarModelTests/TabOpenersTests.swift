import XCTest
@testable import SidebarModel

/// Back on a tab opened from a link, with no page behind it, returns to the tab
/// that opened it (owner, 2026-11-21).
final class TabOpenersTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    private func store() -> (SidebarStore, opener: Tab, opened: Tab) {
        let store = SidebarStore(spaces: [Space(name: "Home")])
        let opener = store.addTab(kind: .today, title: "Marketplace", url: url("https://rive.app/marketplace/latest/"))
        let opened = store.addTab(kind: .today, title: "Grok Bot", url: url("https://rive.app/marketplace/29188/"))
        return (store, opener, opened)
    }

    func testBackWithNoHistoryReturnsToTheOpener() {
        let (store, opener, opened) = store()
        var openers = TabOpeners()
        openers.record(opened.id, openedBy: opener.id)
        XCTAssertEqual(openers.returnTarget(for: opened.id, canGoBack: false, in: store), opener.id)
    }

    func testBackWithHistoryStaysInTheTab() {
        let (store, opener, opened) = store()
        var openers = TabOpeners()
        openers.record(opened.id, openedBy: opener.id)
        XCTAssertNil(openers.returnTarget(for: opened.id, canGoBack: true, in: store))
    }

    func testATabNoLinkOpenedHasNowhereToReturn() {
        let (store, _, opened) = store()
        XCTAssertNil(TabOpeners().returnTarget(for: opened.id, canGoBack: false, in: store))
    }

    func testAClosedOpenerIsNotReturnedTo() {
        let (store, opener, opened) = store()
        var openers = TabOpeners()
        openers.record(opened.id, openedBy: opener.id)
        store.closeTab(opener.id)
        XCTAssertNil(openers.returnTarget(for: opened.id, canGoBack: false, in: store))
    }

    func testForgettingTheOpenerDropsTheLink() {
        let (store, opener, opened) = store()
        var openers = TabOpeners()
        openers.record(opened.id, openedBy: opener.id)
        openers.forget(opener.id)
        XCTAssertNil(openers.opener(of: opened.id))
        XCTAssertNil(openers.returnTarget(for: opened.id, canGoBack: false, in: store))
    }

    func testAPinnedTabIsNeverClosedByBack() {
        let (store, opener, opened) = store()
        var openers = TabOpeners()
        openers.record(opened.id, openedBy: opener.id)
        XCTAssertTrue(store.pinTab(opened.id))
        XCTAssertNil(openers.returnTarget(for: opened.id, canGoBack: false, in: store))
    }

    func testATabInASplitIsNeverClosedByBack() {
        let (store, opener, opened) = store()
        var openers = TabOpeners()
        openers.record(opened.id, openedBy: opener.id)
        XCTAssertNotNil(store.createSplit(tabIDs: [opener.id, opened.id], orientation: .horizontal))
        XCTAssertNil(openers.returnTarget(for: opened.id, canGoBack: false, in: store))
    }

    func testATabCannotBeItsOwnOpener() {
        let (store, _, opened) = store()
        var openers = TabOpeners()
        openers.record(opened.id, openedBy: opened.id)
        XCTAssertNil(openers.returnTarget(for: opened.id, canGoBack: false, in: store))
    }
}
