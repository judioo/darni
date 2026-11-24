import WebKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// WebKit parity for the shell features around windows, profiles and capture,
/// with real `WKEngine`s and a loopback server, and no window on screen. Each
/// test names its row in docs/ENGINE-PARITY.md (`// parity:`).
///
/// A test on a row WebKit does not have yet states the behaviour Chromium has,
/// inside `XCTExpectFailure`: it passes while the gap is there and fails once
/// it closes, so the row's verdict is updated with the fix.
@MainActor
final class WebKitWindowsAndSharingTests: XCTestCase {
    private var server: WebKitFixtureServer!
    private var dataStores: Set<UUID> = []
    private var scratch: URL!

    override func setUp() async throws {
        server = try WebKitFixtureServer()
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-webkit-windows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        server.stop()
        server = nil
        for id in dataStores { try? await WKWebsiteDataStore.remove(forIdentifier: id) }
        dataStores = []
        try? FileManager.default.removeItem(at: scratch)
    }

    private func wait(_ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line,
                      until done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(what)", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A browser model on a throwaway sidebar file, with two windows: `right`
    /// shows `first`, `left` shows a second space of the same profile.
    private struct Browser {
        let model: BrowserViewModel
        let store: SidebarStore
        let right = SidebarWindowID()
        let left = SidebarWindowID()
        let first: Space.ID
        let second: Space.ID
    }

    private func makeBrowser() throws -> Browser {
        let store = SidebarStore(spaces: [Space(name: "Engage", sortRank: "a")])
        let first = store.activeSpaceID
        let second = store.addSpace(name: "Personal").id
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: scratch.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-webkit-windows-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-webkit-windows-links-\(UUID().uuidString)")!
        let browser = Browser(model: model, store: store, first: first, second: second)
        store.registerWindow(browser.right, spaceID: first)
        store.registerWindow(browser.left, spaceID: second)
        store.windowBecameKey(browser.right)
        for profile in store.profiles { dataStores.insert(profile.id) }
        return browser
    }

    private func webKitEngine(_ model: BrowserViewModel, _ tab: SidebarModel.Tab, profile: Profile.ID) throws -> WKEngine {
        dataStores.insert(profile)
        return try XCTUnwrap(model.engineHost.engine(for: tab, profileID: profile) as? WKEngine, "a WebKit build makes WebKit pages")
    }

    // MARK: - Cross-window tab drag (c75befec, 04c67339)

    // parity: tabs.cross-window-drag
    func testATabDraggedToAnotherWindowKeepsItsWebKitPageWithoutLoadingItAgain() async throws {
        server.route("/a", .page(title: "page A", body: "<a href='/b'>B</a>"))
        server.route("/b", .page(title: "page B"))
        let b = try makeBrowser()
        let profile = try XCTUnwrap(b.store.space(withID: b.first)?.profileID)
        let tab = b.store.addTab(kind: .today, title: "A", url: server.url("/a"), in: b.first)
        let anchor = b.store.addTab(kind: .today, title: "Anchor", url: server.url("/b"), in: b.second)
        let engine = try webKitEngine(b.model, tab, profile: profile)
        engine.load(server.url("/a"))
        try await wait("page A") { engine.webView.title == "page A" && !engine.isLoading }
        engine.load(server.url("/b"))
        try await wait("page B, with A behind it") { engine.webView.title == "page B" && engine.canGoBack && !engine.isLoading }
        try await Task.sleep(nanoseconds: 300_000_000)
        let pages = { self.server.requests.map(\.path).filter { $0 != "/favicon.ico" } }
        let before = pages()

        b.model.beginSidebarDrag(tab.id, in: b.right)
        b.model.moveItem(tab.id, relativeTo: anchor.id, after: true)
        b.model.endSidebarDrag()

        XCTAssertNil(b.model.pendingProfileMove, "one profile: nothing to ask")
        XCTAssertEqual(b.store.spaceContaining(tabID: tab.id), b.second, "the tab is in the other window's space")
        XCTAssertTrue(b.model.engineHost.engine(forTabID: tab.id, profileID: profile) === engine, "the same WebKit page moved with its row")
        XCTAssertEqual(engine.webView.title, "page B")
        XCTAssertTrue(engine.canGoBack, "its history came along")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(pages(), before, "nothing was loaded again")
    }

    // parity: tabs.cross-window-drag, profiles.storage
    func testATabDraggedIntoAnotherProfileLoadsAgainSignedInAsThatProfile() async throws {
        server.route("/set") { _ in .page(title: "set", headers: ["Set-Cookie": "who=home; Max-Age=600; Path=/"]) }
        server.route("/read") { request in .page(title: "cookie:\(request.cookies["who"] ?? "none")") }
        let b = try makeBrowser()
        let home = try XCTUnwrap(b.store.space(withID: b.first)?.profileID)
        let work = b.store.addProfile(name: "Work")
        dataStores.insert(work.id)
        let workSpace = try XCTUnwrap(b.store.spaces(in: work.id).first).id
        let report = b.store.addTab(kind: .today, title: "Report", url: server.url("/read"), in: workSpace)
        let tab = b.store.addTab(kind: .today, title: "Read", url: server.url("/read"), in: b.first)
        let homePage = try webKitEngine(b.model, tab, profile: home)
        homePage.load(server.url("/set"))
        try await wait("the home profile's cookie") { homePage.webView.title == "set" && !homePage.isLoading }
        homePage.load(server.url("/read"))
        try await wait("the home page signed in") { homePage.webView.title == "cookie:home" }

        b.model.beginSidebarDrag(tab.id, in: b.right)
        b.model.moveItem(tab.id, relativeTo: report.id, after: true)
        XCTAssertNotNil(b.model.pendingProfileMove, "another profile: asked first")
        b.model.confirmProfileMove()
        b.model.endSidebarDrag()

        XCTAssertNil(b.model.engineHost.engine(forTabID: tab.id, profileID: home), "no page stays in the old profile")
        let moved = try XCTUnwrap(b.store.tab(withID: tab.id))
        let workPage = try webKitEngine(b.model, moved, profile: work.id)
        XCTAssertFalse(workPage === homePage)
        workPage.load(moved.url)
        try await wait("the page in the Work profile") { workPage.webView.title?.hasPrefix("cookie:") == true && !workPage.isLoading }
        XCTAssertEqual(workPage.webView.title, "cookie:none", "the Work profile's page does not have the home profile's cookie")
    }

    // MARK: - Screen sharing (946ffdc8, 721a3449, engine tab/101)

    // parity: media.screen-share
    func testPagesCanAskToShareTheScreenButDarniHasNoSayOnWebKit() async throws {
        server.route("/meet", .page(title: "meet"))
        let engine = WKEngine(context: EngineProfileContext(profileID: UUID(), isEphemeral: true))
        engine.load(server.url("/meet"))
        try await wait("the page") { engine.webView.title == "meet" && !engine.isLoading }
        // Only asked whether the call exists: calling it could put macOS's own picker on screen.
        let offered = try await engine.webView.evaluateJavaScript(
            "!!(navigator.mediaDevices && typeof navigator.mediaDevices.getDisplayMedia === 'function')") as? Bool
        XCTAssertEqual(offered, true, "WKWebView offers getDisplayMedia to pages, so meeting sites will try it")
        // Darni's sheet, the sharing bar and card, and Stop come from MediaCaptureProviding
        // (Chromium ABI 1.70). WKMediaCaptureType has camera and microphone only, so WebKit
        // gives the app no display request to answer. If this fails, WebKit now reports
        // capture state: revisit media.screen-share.
        XCTAssertFalse((engine as AnyObject) is MediaCaptureProviding, "the WebKit engine reports no screen sharing to the shell")
        XCTAssertNil(engine.pagePrompts.screenShare, "no Darni sheet is up")
    }

    // MARK: - Clean link copy (f41e5de1)

    // parity: links.clean-copy
    func testCopyURLOfAWebKitPageCopiesItWithoutTrackers() async throws {
        server.route("/a", .page(title: "page A"))
        let b = try makeBrowser()
        b.model.copiesCleanLinks = true
        b.model.linkPasteboard = NSPasteboard(name: NSPasteboard.Name("rearc-webkit-clean-\(UUID().uuidString)"))
        let profile = try XCTUnwrap(b.store.space(withID: b.first)?.profileID)
        let tracked = URL(string: server.url("/a").absoluteString + "?id=7&utm_source=news&fbclid=abc")!
        let tab = b.store.addTab(kind: .today, title: "A", url: tracked, in: b.first)
        b.store.selectTab(tab.id)
        let engine = try webKitEngine(b.model, tab, profile: profile)
        engine.load(tracked)
        try await wait("page A") { engine.webView.title == "page A" && !engine.isLoading }
        XCTAssertEqual(engine.currentURL, tracked, "the WebKit page is on the address with its trackers")

        b.model.copyURL(of: tab.id, format: .plain)
        XCTAssertEqual(b.model.linkPasteboard.string(forType: .string), server.url("/a").absoluteString + "?id=7",
                       "Copy URL takes the WebKit page's address and drops its trackers")
        b.model.copyLink(tracked)
        XCTAssertEqual(b.model.linkPasteboard.string(forType: .string), server.url("/a").absoluteString + "?id=7",
                       "a row's Copy Link drops them too")
    }

    // parity: links.clean-copy
    func testWebKitsOwnCopyLinkInThePageMenuCopiesItClean() {
        // WebKit's page menu as it builds it for a link; Darni rewrites some items in place.
        func item(_ title: String, _ id: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(id)
            return item
        }
        let menu = NSMenu()
        menu.addItem(item("Open Link in New Window", ReArcWebView.openLinkInNewWindow))
        menu.addItem(item("Copy Link", "WKMenuItemIdentifierCopyLink"))
        let params = PageContextMenuParams(linkURL: "https://a.test/x?utm_source=news")
        ReArcWebView.customize(menu, params: params, options: PageContextMenuPlan.Options()) { entry in
            let made = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            made.identifier = NSUserInterfaceItemIdentifier("darni.\(entry.title)")
            return made
        }
        let copy = menu.items.first { $0.title.hasPrefix("Copy Link") }
        XCTExpectFailure("links.clean-copy: the WebKit page menu keeps WebKit's own Copy Link, which copies the link with its trackers")
        XCTAssertEqual(copy?.identifier?.rawValue, "darni.Copy Link Address", "Darni's Copy Link Address, which copies the clean link")
    }

    // MARK: - Dark mode for websites (d4532c1c, engine tab/105)

    /// A page that reports whether it is in its own dark theme, and its background as drawn.
    private func darkModePages() {
        server.route("/themed", .page(title: "themed", head: """
        <style>body { background: rgb(255, 255, 255); } @media (prefers-color-scheme: dark) { body { background: rgb(20, 20, 20); } }</style>
        """))
        server.route("/plain", .page(title: "plain", body: "<p>No dark theme</p>", head: "<style>body { background: rgb(255, 255, 255); }</style>"))
    }

    private func pageLooksDark(_ engine: WKEngine) async throws -> (prefersDark: Bool, background: String) {
        let prefers = try await engine.webView.evaluateJavaScript("matchMedia('(prefers-color-scheme: dark)').matches") as? Bool ?? false
        let background = try await engine.webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String ?? ""
        return (prefers, background)
    }

    // parity: pages.dark-mode
    func testAWebKitTabUsesASitesOwnDarkThemeWhenDarniIsDark() async throws {
        darkModePages()
        let engine = WKEngine(context: EngineProfileContext(profileID: UUID(), isEphemeral: true))
        engine.webView.appearance = NSAppearance(named: .darkAqua)
        engine.load(server.url("/themed"))
        try await wait("the themed page") { engine.webView.title == "themed" && !engine.isLoading }
        var look = try await pageLooksDark(engine)
        XCTAssertTrue(look.prefersDark, "a WebKit page follows Darni's appearance")
        XCTAssertEqual(look.background, "rgb(20, 20, 20)", "so a site with a dark theme of its own uses it")

        engine.webView.appearance = NSAppearance(named: .aqua)
        var light = false
        for _ in 0..<100 where !light {
            light = try await !isDarkNow(engine)
            if !light { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertTrue(light, "the page goes light again with Darni")
        look = try await pageLooksDark(engine)
        XCTAssertEqual(look.background, "rgb(255, 255, 255)", "and back, without a reload")
    }

    private func isDarkNow(_ engine: WKEngine) async throws -> Bool {
        try await engine.webView.evaluateJavaScript("matchMedia('(prefers-color-scheme: dark)').matches") as? Bool ?? false
    }

    // parity: pages.dark-mode
    func testAWebKitTabDarkensASiteWithoutADarkTheme() async throws {
        darkModePages()
        let engine = WKEngine(context: EngineProfileContext(profileID: UUID(), isEphemeral: true))
        engine.webView.appearance = NSAppearance(named: .darkAqua)
        engine.load(server.url("/plain"))
        try await wait("the plain page") { engine.webView.title == "plain" && !engine.isLoading }
        let look = try await pageLooksDark(engine)
        XCTAssertTrue(look.prefersDark)
        XCTExpectFailure("pages.dark-mode: WebKit has no public call to darken a page; Chromium's engine does it (tab/105)")
        XCTAssertNotEqual(look.background, "rgb(255, 255, 255)", "a site with no dark theme is darkened")
    }

    // MARK: - Reader view (00b0ebac, b867a1f1)

    // parity: pages.reader
    func testTheReaderButtonOpensAWebKitTabsArticleAndClosesAgain() async throws {
        for path in [SelfTestReaderFixture.articlePath, SelfTestReaderFixture.picturePath] {
            server.route(path) { request in
                let full = request.query.isEmpty ? request.path : request.path + "?" + request.query
                guard let found = SelfTestReaderFixture.response(forPathAndQuery: full) else { return .init(status: 404) }
                return .init(type: found.type, body: found.body)
            }
        }
        let b = try makeBrowser()
        let profile = try XCTUnwrap(b.store.space(withID: b.first)?.profileID)
        let tab = b.store.addTab(kind: .today, title: "Article", url: server.url(SelfTestReaderFixture.articlePath), in: b.first)
        b.store.selectTab(tab.id)
        let engine = try webKitEngine(b.model, tab, profile: profile)
        engine.load(server.url(SelfTestReaderFixture.articlePath))
        try await wait("the article") { !engine.isLoading && engine.currentURL?.path == SelfTestReaderFixture.articlePath && engine.webView.title?.isEmpty == false }

        // The address field asks a page that finished loading whether it is an article.
        b.model.detectReaderArticle(forPage: tab.id, engine: engine)
        try await wait("the reader button", timeout: 20) { b.model.readerButtonState(for: tab, engine: engine) == .available }
        b.model.toggleReader(tabID: tab.id)
        try await wait("the reader to open", timeout: 20) { b.model.reader.isShowing(tab.id) }
        XCTAssertEqual(b.model.readerButtonState(for: tab, engine: engine), .showing)
        b.model.toggleReader(tabID: tab.id)
        XCTAssertFalse(b.model.reader.isShowing(tab.id), "the button closes it again")
        XCTAssertEqual(engine.currentURL?.path, SelfTestReaderFixture.articlePath, "the page is as it was")
    }

    // MARK: - Gaps, stated as Chromium behaves (expected failures)

    // parity: tabs.popups
    func testALinkThatOpensANewTabLoadsItsPage() async throws {
        server.route("/a", .page(title: "page A", body: "<a id='blank' href='/b' target='_blank'>B</a>"))
        server.route("/b", .page(title: "page B"))
        let engine = WKEngine(context: EngineProfileContext(profileID: UUID(), isEphemeral: true))
        engine.load(server.url("/a"))
        try await wait("page A") { engine.webView.title == "page A" && !engine.isLoading }
        _ = try await engine.webView.evaluateJavaScript("document.getElementById('blank').click(); true")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTExpectFailure("tabs.popups: WKEngine has no createWebViewWith, so a target=_blank link is dropped")
        XCTAssertEqual(server.requests(for: "/b").count, 1, "the new tab loads the linked page")
    }

    // parity: navigation.user-agent
    func testSitesSeeASafariUserAgent() async throws {
        server.route("/a", .page(title: "page A"))
        let engine = WKEngine(context: EngineProfileContext(profileID: UUID(), isEphemeral: true))
        engine.load(server.url("/a"))
        try await wait("page A") { engine.webView.title == "page A" && !engine.isLoading }
        let agent = server.requests(for: "/a").last?.headers["user-agent"] ?? ""
        XCTExpectFailure("navigation.user-agent: WKWebView's stock user agent has no Version/Safari token")
        XCTAssertTrue(agent.contains("Safari/") && agent.contains("Version/"), "user agent: \(agent)")
    }

    // parity: profiles.delete-data
    func testDeletingAProfileRemovesItsWebKitData() async throws {
        server.route("/set") { _ in .page(title: "set", headers: ["Set-Cookie": "who=work; Max-Age=600; Path=/"]) }
        let b = try makeBrowser()
        let work = b.store.addProfile(name: "Work")
        dataStores.insert(work.id)
        let space = try XCTUnwrap(b.store.spaces(in: work.id).first).id
        let tab = b.store.addTab(kind: .today, title: "Set", url: server.url("/set"), in: space)
        let page = try webKitEngine(b.model, tab, profile: work.id)
        page.load(server.url("/set"))
        try await wait("the Work profile's cookie") { page.webView.title == "set" && !page.isLoading }
        let before = await WKWebsiteDataStore.allDataStoreIdentifiers
        XCTAssertTrue(before.contains(work.id), "the Work profile has its own store")

        XCTAssertNil(b.model.deleteProfile(work.id, deletingSpaces: true))
        try await Task.sleep(nanoseconds: 500_000_000)
        let after = await WKWebsiteDataStore.allDataStoreIdentifiers
        XCTExpectFailure("profiles.delete-data: nothing removes a deleted profile's WKWebsiteDataStore")
        XCTAssertFalse(after.contains(work.id), "the deleted profile's cookies and site data are gone")
    }
}
