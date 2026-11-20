import XCTest
@testable import SidebarModel

/// Arc's per-pane split toolbars (SPLIT-VIEW §3.1): which row has the
/// controls, which corners a row touches, the focus rule and the address.
final class SplitPaneToolbarTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    func testOnlyTheFocusedPaneShowsTheControls() {
        let layout = SplitPaneToolbarLayout(visiblePanes: [a, b, c], focus: b, orientation: .horizontal)
        XCTAssertEqual(layout.rows.map(\.tabID), [a, b, c], "a row per pane, in pane order")
        XCTAssertEqual(layout.rows.map(\.isActive), [false, true, false])
        XCTAssertEqual(layout.controlsPane, b)

        let moved = SplitPaneToolbarLayout(visiblePanes: [a, b, c], focus: c, orientation: .horizontal)
        XCTAssertEqual(moved.controlsPane, c, "the controls follow the focus")
        XCTAssertEqual(moved.rows.filter(\.isActive).count, 1)
    }

    func testAnExpandedPaneIsTheOnlyRowAndHasTheControls() {
        let layout = SplitPaneToolbarLayout(visiblePanes: [b], focus: b, orientation: .horizontal)
        XCTAssertEqual(layout.rows, [.init(tabID: b, isActive: true, isAtLeadingCorner: true, isAtTrailingCorner: true)])
        let stale = SplitPaneToolbarLayout(visiblePanes: [a, b], focus: c, orientation: .horizontal)
        XCTAssertEqual(stale.controlsPane, a, "a focus that is not on screen falls back to the first pane")
    }

    func testCornersSideBySideAndStacked() {
        let side = SplitPaneToolbarLayout(visiblePanes: [a, b, c], focus: a, orientation: .horizontal)
        XCTAssertEqual(side.rows.map(\.isAtLeadingCorner), [true, false, false])
        XCTAssertEqual(side.rows.map(\.isAtTrailingCorner), [false, false, true])

        let stacked = SplitPaneToolbarLayout(visiblePanes: [a, b], focus: b, orientation: .vertical)
        XCTAssertEqual(stacked.row(for: a)?.isAtLeadingCorner, true, "the top row spans both corners")
        XCTAssertEqual(stacked.row(for: a)?.isAtTrailingCorner, true)
        XCTAssertEqual(stacked.row(for: b)?.isAtLeadingCorner, false)
        XCTAssertEqual(stacked.row(for: b)?.isAtTrailingCorner, false)
        XCTAssertNil(stacked.row(for: c))
    }

    func testClickingAnotherPaneFocusesItAndTheFocusedPaneChangesNothing() {
        let tabs = [Tab(kind: .today, title: "A", url: URL(string: "https://a.test")!), Tab(kind: .today, title: "B", url: URL(string: "https://b.test")!)]
        let split = SplitViewItem(orientation: .horizontal, focusTabID: tabs[0].id, tabs: tabs)
        XCTAssertEqual(SplitPaneToolbarLayout.focusChange(clicked: tabs[1].id, in: split), tabs[1].id)
        XCTAssertNil(SplitPaneToolbarLayout.focusChange(clicked: tabs[0].id, in: split))
        XCTAssertNil(SplitPaneToolbarLayout.focusChange(clicked: UUID(), in: split), "not a pane of this split")
    }

    func testRowsFollowTheToolbarPreferenceAndFullscreen() {
        XCTAssertTrue(SplitPaneToolbarLayout.showsRows(urlInToolbar: true, pageFullscreen: false))
        XCTAssertFalse(SplitPaneToolbarLayout.showsRows(urlInToolbar: false, pageFullscreen: false), "URL in the sidebar: no rows")
        XCTAssertFalse(SplitPaneToolbarLayout.showsRows(urlInToolbar: true, pageFullscreen: true))
    }

    func testAddressSplitsTheHostFromTheRest() throws {
        let parts = try XCTUnwrap(SplitPaneToolbarLayout.addressParts(URL(string: "https://www.google.com/search?q=test")))
        XCTAssertEqual(parts.host, "google.com")
        XCTAssertEqual(parts.rest, "/search?q=test")
        XCTAssertEqual(SplitPaneToolbarLayout.addressParts(URL(string: "https://chatgpt.com/"))?.rest, "")
        XCTAssertNil(SplitPaneToolbarLayout.addressParts(URL(string: "about:blank")))
        let local = try XCTUnwrap(SplitPaneToolbarLayout.addressParts(URL(string: "http://localhost:3000/extension-auth?a=1")))
        XCTAssertEqual(local.host, "localhost:3000", "two local servers must not look the same")
        XCTAssertEqual(local.rest, "/extension-auth?a=1")
        XCTAssertEqual(SplitPaneToolbarLayout.addressParts(URL(string: "data:text/html,x"))?.host, "data:text/html,x")
        XCTAssertNil(SplitPaneToolbarLayout.addressParts(nil))
    }

    /// The onboarding's welcome page is a file in the data folder: the address fields show its
    /// name, and only that one file's.
    func testTheWelcomePageIsShownByName() throws {
        let root = URL(fileURLWithPath: "/Users/kai/Library/Application Support/ReArc", isDirectory: true)
        let page = WelcomePageAddress.fileURL(in: root)
        XCTAssertEqual(page.path, "/Users/kai/Library/Application Support/ReArc/Welcome/welcome.html")
        XCTAssertEqual(WelcomePageAddress.title, "Welcome to Darni")
        XCTAssertTrue(WelcomePageAddress.matches(page, root: root))
        // As an engine reports it: percent-encoded, with a fragment.
        let reported = try XCTUnwrap(URL(string: "file:///Users/kai/Library/Application%20Support/ReArc/Welcome/welcome.html#tips"))
        XCTAssertTrue(WelcomePageAddress.matches(reported, root: root))
        for other in ["file:///Users/kai/Library/Application%20Support/ReArc/Welcome/other.html",
                      "file:///Users/kai/Downloads/Welcome/welcome.html",
                      "file:///Users/kai/Library/Application%20Support/ReArc/Welcome/welcome.html?x=1",
                      "file://evil.test/Users/kai/Library/Application%20Support/ReArc/Welcome/welcome.html",
                      "https://evil.test/Users/kai/Library/Application%20Support/ReArc/Welcome/welcome.html",
                      "rearc://welcome", "about:blank"] {
            XCTAssertFalse(WelcomePageAddress.matches(URL(string: other), root: root), other)
        }
        XCTAssertFalse(WelcomePageAddress.matches(nil, root: root))

        XCTAssertEqual(WelcomePageAddress.commandBarPrefill(for: page, root: root), "", "⌘L starts empty, as on a new tab")
        XCTAssertEqual(WelcomePageAddress.commandBarPrefill(for: URL(string: "about:blank")!, root: root), "")
        XCTAssertEqual(WelcomePageAddress.commandBarPrefill(for: URL(string: "https://example.com/a")!, root: root), "https://example.com/a")
        XCTAssertEqual(WelcomePageAddress.commandBarPrefill(for: URL(string: "file:///tmp/a.html")!, root: root), "file:///tmp/a.html")

        // The address button's tooltip and accessibility help, and a split row's tooltip.
        XCTAssertEqual(WelcomePageAddress.displayAddress(for: page, root: root), "Welcome to Darni")
        XCTAssertEqual(WelcomePageAddress.displayAddress(for: reported, root: root), "Welcome to Darni")
        XCTAssertEqual(WelcomePageAddress.displayAddress(for: URL(string: "https://example.com/a?b=1#c")!, root: root), "https://example.com/a?b=1#c")
        XCTAssertEqual(WelcomePageAddress.displayAddress(for: URL(string: "file:///tmp/welcome.html")!, root: root), "file:///tmp/welcome.html",
                       "any other file is shown whole")
        XCTAssertEqual(WelcomePageAddress.tooltip(title: "Welcome to Darni", url: page, root: root), "Welcome to Darni", "not said twice")
        XCTAssertEqual(WelcomePageAddress.tooltip(title: "Start here", url: page, root: root), "Start here\nWelcome to Darni", "a renamed tab")
        XCTAssertEqual(WelcomePageAddress.tooltip(title: "Example", url: URL(string: "https://example.com/a")!, root: root),
                       "Example\nhttps://example.com/a")

        // This process's own page, in the card toolbar and a split pane's row.
        let parts = try XCTUnwrap(SplitPaneToolbarLayout.addressParts(WelcomePageAddress.fileURL()))
        XCTAssertEqual(parts.host, "Welcome to Darni")
        XCTAssertEqual(parts.rest, "")
        XCTAssertEqual(SplitPaneToolbarLayout.addressParts(URL(string: "file:///tmp/welcome.html"))?.host, "file:///tmp/welcome.html",
                       "any other file keeps its whole address")
    }

    /// Security AG-01: the host keeps its registrable domain, IPv6 keeps its brackets, and the
    /// rest cannot hide or reorder text with direction, invisible or space characters.
    func testTheAddressCannotBeSpoofed() throws {
        let long = try XCTUnwrap(SplitPaneToolbarLayout.addressParts(
            URL(string: "https://accounts.google.com.verify-session.signin.secure-login.evil.example/login")))
        XCTAssertTrue(long.host.hasSuffix("evil.example"), long.host)
        XCTAssertTrue(long.host.hasPrefix("…"), long.host)
        XCTAssertLessThanOrEqual(long.host.count, SplitPaneToolbarLayout.hostLimit)
        let v6 = try XCTUnwrap(SplitPaneToolbarLayout.addressParts(URL(string: "http://[2001:db8::1]:8080/a")))
        XCTAssertEqual(v6.host, "[2001:db8::1]:8080")
        let bidi = try XCTUnwrap(SplitPaneToolbarLayout.addressParts(URL(string: "https://example.com/%E2%80%AEfdp.exe")))
        XCTAssertEqual(bidi.rest, "/%E2%80%AEfdp.exe", "a right-to-left override stays encoded")
        let spaces = try XCTUnwrap(SplitPaneToolbarLayout.addressParts(URL(string: "https://example.com/a%20%20%20%20b?q=%0Ax")))
        XCTAssertEqual(spaces.rest, "/a%20%20%20%20b?q=%0Ax")
        let readable = try XCTUnwrap(SplitPaneToolbarLayout.addressParts(URL(string: "https://example.com/caf%C3%A9")))
        XCTAssertEqual(readable.rest, "/café", "ordinary letters still read decoded")
        // Hostless addresses: the slot that never truncates stays short; the page's text truncates.
        let padding = String(repeating: "x", count: 300)
        let blank = try XCTUnwrap(SplitPaneToolbarLayout.addressParts(URL(string: "about:blank#\(padding)mybank.example/login")))
        XCTAssertEqual(blank.host, "about:blank")
        XCTAssertTrue(blank.rest.hasPrefix("#"))
        let file = try XCTUnwrap(SplitPaneToolbarLayout.addressParts(URL(string: "file:///\(padding)/statement.pdf")))
        XCTAssertLessThanOrEqual(file.host.count, SplitPaneToolbarLayout.hostLimit)
        XCTAssertEqual(file.host + file.rest, "file:///\(padding)/statement.pdf")
        let blob = try XCTUnwrap(SplitPaneToolbarLayout.addressParts(URL(string:
            "blob:https://accounts.google.com.verify-session.signin.secure-login.portal.evil.example/6f1c-\(padding)")))
        XCTAssertTrue(blob.host.hasPrefix("blob:…"), blob.host)
        XCTAssertTrue(blob.host.hasSuffix("evil.example"), blob.host)
        XCTAssertTrue(blob.rest.hasPrefix("/6f1c-"))
        for url in ["about:blank?\(padding)", "blob:https://a.example/\(padding)", "data:text/html,\(padding)", "view-source:\(padding)"] {
            let parts = try XCTUnwrap(SplitPaneToolbarLayout.addressParts(URL(string: url)), url)
            XCTAssertLessThanOrEqual(parts.host.count, SplitPaneToolbarLayout.hostLimit, url)
        }
    }
}

