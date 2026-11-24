import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// The reader view in the shell: its menu item and key, the address field's
/// button, opening and leaving through the view model, links, and which
/// tabs' readers may load pictures (docs/FEATURE-SPECS/READER-VIEW.md §3).
@MainActor
final class ReaderShellTests: XCTestCase {
    private var server: WebKitFixtureServer!

    override func setUp() async throws {
        server = try WebKitFixtureServer()
        for path in [SelfTestReaderFixture.articlePath, SelfTestReaderFixture.plainPath, SelfTestReaderFixture.picturePath] {
            server.route(path) { request in
                let found = SelfTestReaderFixture.response(forPathAndQuery: request.path)!
                return .init(type: found.type, body: found.body)
            }
        }
    }

    override func tearDown() async throws {
        server.stop()
        server = nil
    }

    private func makeModel() -> (model: BrowserViewModel, space: Space) {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("darni-reader-\(UUID().uuidString)")
        let model = BrowserViewModel(store: store, persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
                                     syncEngine: LocalSyncEngine(), faviconStore: FaviconStore(directory: nil))
        return (model, store.spaces[0])
    }

    private func wait(_ what: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line,
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

    /// A selected tab showing `path`, loaded.
    private func tab(in model: BrowserViewModel, showing path: String) async throws -> (tab: Tab, engine: any WebEngine) {
        let url = server.url(path)
        let tab = model.store.addTab(kind: .today, title: "Reader", url: url)
        model.store.selectTab(tab.id)
        let engine = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
        engine.load(url)
        try await wait("\(path) to load") { !engine.isLoading && engine.currentURL == url && engine.pageTitle?.isEmpty == false }
        return (tab, engine)
    }

    // MARK: The menu item and its key

    func testShowReaderIsOptionCommandRInTheViewMenuAndNoOtherItemHasThatKey() {
        let (model, _) = makeModel()
        let item = ShellMenus.reader(model).flatMap { $0 }.first
        XCTAssertEqual(item?.title, "Show Reader")
        XCTAssertEqual(item?.menuKeyEquivalent, "r")
        XCTAssertEqual(item?.modifiers, [.command, .option])
        XCTAssertEqual(item?.appKitKeyEquivalent.key, "r")
        XCTAssertTrue(ShellMenus.viewPageAndSplit(model).flatMap { $0 }.contains { $0.title == "Show Reader" }, "it is in the View menu")
        // Arc has no command on ⌥⌘R, so the key takes nothing from an Arc user.
        XCTAssertNil(item?.arcShortcut)
        XCTAssertNil(ArcShortcuts.binding(for: .character("r"), modifiers: ShortcutRouter.modifiers(of: [.command, .option])))
        // And no other Darni menu item has it.
        let groups = ShellMenus.navigation(model) + ShellMenus.reader(model) + ShellMenus.find(model) + ShellMenus.copyLink(model) + ShellMenus.zoom(model)
            + ShellMenus.tabNavigation(model) + ShellMenus.split(model) + ShellMenus.documents(model) + ShellMenus.tabSwitcher(model)
            + ShellMenus.tabPositions(model) + ShellMenus.spaces(model) + ShellMenus.sidebarItems(model) + ShellMenus.library(model)
            + ShellMenus.developer(model) + ShellMenus.capture(model) + ShellMenus.printing(model) + [ShellMenus.miniSidebar(model)]
        let items = groups.flatMap { $0 }
        let onR = items.filter { $0.menuKeyEquivalent == "r" }.map { "\($0.title)|\($0.modifiers.rawValue)" }
        XCTAssertEqual(Set(onR), ["Reload Page|\(NSEvent.ModifierFlags.command.rawValue)",
                                  "Reload Ignoring Cache|\(NSEvent.ModifierFlags([.command, .shift]).rawValue)",
                                  "Show Reader|\(NSEvent.ModifierFlags([.command, .option]).rawValue)"])
        let keys = items.filter { $0.key != nil }.map { "\($0.menuKeyEquivalent)|\($0.modifiers.rawValue)" }
        XCTAssertEqual(keys.count, Set(keys).count, "no two items share keys")
    }

    func testWithNoPageThereIsNoButtonAndTheMenuItemIsOff() {
        let (model, _) = makeModel()
        let item = ShellMenus.reader(model).flatMap { $0 }.first
        XCTAssertEqual(item?.shownTitle, "Show Reader")
        XCTAssertEqual(item?.isEnabledNow, false)
        XCTAssertEqual(model.readerButtonState(for: nil, engine: nil), .hidden)
        model.toggleReader()
        model.toggleReader(tabID: UUID())
        XCTAssertTrue(model.reader.sessions.isEmpty)
    }

    // MARK: Through the view model

    func testTheButtonShowsOnAnArticleAndTheReaderOpensAndLeaves() async throws {
        let (model, _) = makeModel()
        let (tab, engine) = try await tab(in: model, showing: SelfTestReaderFixture.articlePath)
        let window = model.store.keyWindowID
        let item = try XCTUnwrap(ShellMenus.reader(model).flatMap { $0 }.first)
        XCTAssertEqual(model.readerButtonState(for: tab, engine: engine), .hidden, "not asked yet")
        XCTAssertTrue(model.canToggleReader(in: window), "the key works before the page was asked: it may be an article")
        model.detectReaderArticle(for: tab, engine: engine)
        try await wait("the button") { model.readerButtonState(for: tab, engine: engine) == .available }
        XCTAssertEqual(item.shownTitle, "Show Reader")
        XCTAssertTrue(item.isEnabledNow)
        XCTAssertEqual(model.readerImageMode(for: tab, engine: engine), .loadedByPage)

        item.action()
        try await wait("the reader") { model.reader.isShowing(tab.id) }
        XCTAssertEqual(model.readerButtonState(for: tab, engine: engine), .showing)
        XCTAssertEqual(item.shownTitle, "Hide Reader")
        XCTAssertTrue(item.isEnabledNow)
        XCTAssertEqual(model.reader.session(for: tab.id)?.article.title, SelfTestReaderFixture.articleTitle)
        XCTAssertEqual(engine.currentURL, server.url(SelfTestReaderFixture.articlePath), "the tab is where it was")

        item.action()
        XCTAssertFalse(model.reader.isShowing(tab.id))
        XCTAssertEqual(model.readerButtonState(for: tab, engine: engine), .available)
        XCTAssertEqual(item.shownTitle, "Show Reader")
        XCTAssertFalse(engine.canGoBack)
    }

    func testOnAPageThatIsNoArticleThereIsNoButtonAndTheKeySaysSo() async throws {
        let (model, _) = makeModel()
        let (tab, engine) = try await tab(in: model, showing: SelfTestReaderFixture.plainPath)
        // Not judged yet: the key tries, finds no article, and says so.
        model.toggleReader(tabID: tab.id)
        try await wait("the notice") { model.toast != nil }
        XCTAssertEqual(model.toast?.message, "No article to show in the reader")
        XCTAssertFalse(model.reader.isShowing(tab.id))
        XCTAssertEqual(model.readerButtonState(for: tab, engine: engine), .hidden)
        XCTAssertFalse(model.canToggleReader(in: model.store.keyWindowID), "now it is known not to be one")
    }

    func testALinkFromTheReaderLoadsInTheTabAndOnlyAWebAddressDoes() async throws {
        let (model, _) = makeModel()
        let (tab, engine) = try await tab(in: model, showing: SelfTestReaderFixture.articlePath)
        model.toggleReader(tabID: tab.id)
        try await wait("the reader") { model.reader.isShowing(tab.id) }
        for refused in ["javascript:alert(1)", "chrome://settings", "file:///etc/hosts", "data:text/html,x", "about:blank", "https://user:pw@a.example/"] {
            model.openReaderLink(URL(string: refused)!, fromTab: tab.id, inNewTab: false)
            model.openReaderLink(URL(string: refused)!, fromTab: tab.id, inNewTab: true)
        }
        XCTAssertTrue(model.reader.isShowing(tab.id), "a refused address does nothing")
        XCTAssertEqual(engine.currentURL, server.url(SelfTestReaderFixture.articlePath))
        XCTAssertEqual(model.store.displayTabs().count, 1)

        let next = server.url(SelfTestReaderFixture.plainPath)
        model.openReaderLink(next, fromTab: tab.id, inNewTab: false)
        XCTAssertFalse(model.reader.isShowing(tab.id), "following a link leaves the reader")
        try await wait("the link in the tab") { engine.currentURL == next && !engine.isLoading }
        XCTAssertEqual(model.store.displayTabs().count, 1, "in the same tab")
    }

    func testClosingTheTabClosesItsReader() async throws {
        let (model, _) = makeModel()
        let (tab, _) = try await tab(in: model, showing: SelfTestReaderFixture.articlePath)
        model.toggleReader(tabID: tab.id)
        try await wait("the reader") { model.reader.isShowing(tab.id) }
        model.releaseEngine(for: tab.id)
        XCTAssertFalse(model.reader.isShowing(tab.id))
        XCTAssertTrue(model.reader.sessions.isEmpty)
    }

    func testAPrivateWindowsReaderLoadsNoPicturesAndGoesWithTheWindow() async throws {
        let (model, _) = makeModel()
        let url = server.url(SelfTestReaderFixture.articlePath)
        let window = model.openPrivateWindow(url: url)
        let engine = window.engine
        try await wait("the article in the private window") { !engine.isLoading && engine.currentURL == url && engine.pageTitle?.isEmpty == false }
        try await wait("its picture") { self.server.requests(for: SelfTestReaderFixture.picturePath).count >= 1 }
        XCTAssertEqual(model.readerImageMode(forPage: window.id, engine: engine), .off)
        model.detectReaderArticle(forPage: window.id, engine: engine)
        try await wait("the button") { model.readerButtonState(forPage: window.id, engine: engine) == .available }
        let requests = server.contentRequests.count
        model.toggleReader(pageID: window.id)
        try await wait("the reader") { model.reader.isShowing(window.id) }
        let article = try XCTUnwrap(model.reader.session(for: window.id)?.article)
        XCTAssertTrue(article.imagesOff)
        XCTAssertFalse(ReaderHTML.fragment(for: article.body).contains("<img"))
        XCTAssertEqual(model.reader.session(for: window.id)?.page.webView.configuration.websiteDataStore.isPersistent, false)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(server.contentRequests.count, requests, "a private window's reader asked the network for \(server.contentRequests.dropFirst(requests))")
        // A link stays in the private window's own engine.
        let next = server.url(SelfTestReaderFixture.plainPath)
        model.openReaderLink(next, fromPage: window.id, inNewTab: false)
        XCTAssertFalse(model.reader.isShowing(window.id))
        try await wait("the link in the private window") { engine.currentURL == next && !engine.isLoading }
        XCTAssertEqual(model.store.displayTabs().count, 0, "no ordinary tab was made")
        // The window closes: its reader and its answer go with it.
        model.toggleReader(pageID: window.id)
        model.privateWindowClosed(window.id)
        XCTAssertTrue(model.reader.sessions.isEmpty)
        XCTAssertEqual(model.reader.availability(for: window.id, url: next), .unknown)
    }

    func testAContainersReaderLoadsNoPictures() async throws {
        let (model, space) = makeModel()
        let (ordinary, ordinaryEngine) = try await tab(in: model, showing: SelfTestReaderFixture.articlePath)
        XCTAssertEqual(model.readerImageMode(for: ordinary, engine: ordinaryEngine), .loadedByPage)
        model.createContainerForSpace(space.id)
        XCTAssertNotNil(model.store.container(ofSpace: space.id))
        let tab = try XCTUnwrap(model.store.tab(withID: ordinary.id))
        let engine = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
        XCTAssertEqual(model.readerImageMode(for: tab, engine: engine), .off)
        engine.load(server.url(SelfTestReaderFixture.articlePath))
        try await wait("the article in the container") { !engine.isLoading && engine.pageTitle?.isEmpty == false }
        try await wait("its picture") { self.server.requests(for: SelfTestReaderFixture.picturePath).count >= 2 }
        let requests = server.contentRequests.count
        model.toggleReader(tabID: tab.id)
        try await wait("the reader") { model.reader.isShowing(tab.id) }
        let article = try XCTUnwrap(model.reader.session(for: tab.id)?.article)
        XCTAssertTrue(article.imagesOff)
        XCTAssertEqual(article.imagesShown, 0)
        XCTAssertFalse(ReaderHTML.fragment(for: article.body).contains("<img"))
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(server.contentRequests.count, requests, "a container's reader asked the network for \(server.contentRequests.dropFirst(requests))")
    }

    /// Security note R-2: WebKit's own Copy Link would copy a link with its trackers, past
    /// LinkCleaner, so the reader's menu keeps only Copy and Look Up.
    func testTheReadersMenuHasNoCopyLinkThatWouldSkipTheCleaner() {
        func item(_ id: String) -> NSMenuItem {
            let item = NSMenuItem(title: id, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(id)
            return item
        }
        let menu = NSMenu()
        for id in ["WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierCopyLink", "WKMenuItemIdentifierCopy",
                   "WKMenuItemIdentifierDownloadImage", "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierReload"] {
            menu.addItem(item(id))
        }
        ReaderWKWebView.trim(menu)
        XCTAssertEqual(menu.items.map { $0.identifier?.rawValue ?? "" }, ["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierLookUp"])
    }
}
