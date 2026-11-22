import WebKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// The WebKit engine end to end, with no window: real `WKEngine`s load pages
/// from a loopback server and the shell-facing behaviour is checked. This is
/// the WebKit pass `scripts/check-webkit.sh` runs for every release; each test
/// names its row in docs/ENGINE-PARITY.md (`parity:` in its comment).
@MainActor
final class WebKitEngineSmokeTests: XCTestCase {
    private var server: WebKitFixtureServer!
    private var profiles: [UUID] = []
    private var scratch: URL!

    override func setUp() async throws {
        server = try WebKitFixtureServer()
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-webkit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        server.stop()
        server = nil
        // The stores are on disk under the test runner's own WebKit folder: leave none behind.
        for id in profiles { try? await WKWebsiteDataStore.remove(forIdentifier: id) }
        profiles = []
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A persistent profile's engine; its data store is removed in `tearDown`.
    private func engine(profile: UUID? = nil) -> WKEngine {
        let id = profile ?? UUID()
        if !profiles.contains(id) { profiles.append(id) }
        return WKEngine(context: EngineProfileContext(profileID: id))
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

    /// Loads `path` and waits for the page itself (the web view's title), so a test
    /// fails for its own row only: what the shell sees of the title is `tabs.title`'s.
    private func load(_ engine: WKEngine, _ path: String, title: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        engine.load(server.url(path))
        do {
            try await wait("\(path) to load with the title \(title)", file: file, line: line) {
                engine.webView.title == title && !engine.isLoading && !engine.webView.isLoading
            }
        } catch {
            XCTFail("state: webView.title=\(String(describing: engine.webView.title)) isLoading=\(engine.isLoading)/\(engine.webView.isLoading) "
                + "url=\(String(describing: engine.webView.url)) requests=\(server.requests.map(\.path))", file: file, line: line)
            throw error
        }
    }

    // parity: navigation.load
    func testAPageLoadsAndTheShellSeesItsURLAndSecurity() async throws {
        server.route("/a", .page(title: "page A"))
        let engine = engine()
        try await load(engine, "/a", title: "page A")
        XCTAssertEqual(engine.currentURL, server.url("/a"))
        XCTAssertEqual(engine.securityState, .insecure, "plain http is not secure")
        XCTAssertFalse(engine.isLoading)
        XCTAssertFalse(engine.isCrashed)
        XCTAssertFalse(engine.canGoBack)
    }

    // parity: tabs.title
    func testTheShellSeesTheTitleOfAPageThatHasLoaded() async throws {
        server.route("/a", .page(title: "page A"))
        let engine = engine()
        try await load(engine, "/a", title: "page A")
        try await wait("the shell to see the title") { engine.pageTitle == "page A" }
    }

    // parity: tabs.title
    func testTheTitleFollowsThePageAfterItHasLoaded() async throws {
        server.route("/a", .page(title: "Inbox"))
        let engine = engine()
        try await load(engine, "/a", title: "Inbox")
        try await wait("the shell to see the first title") { engine.pageTitle == "Inbox" }
        _ = try await engine.webView.evaluateJavaScript("document.title = 'Inbox (3)'; true")
        try await wait("the changed title") { engine.pageTitle == "Inbox (3)" }
    }

    // parity: tabs.title
    func testAPageWithoutATitleDoesNotKeepTheLastPagesTitle() async throws {
        server.route("/a", .page(title: "page A"))
        server.route("/bare", .html("<!doctype html><html><head></head><body>no title</body></html>"))
        let engine = engine()
        try await load(engine, "/a", title: "page A")
        try await wait("the shell to see the first title") { engine.pageTitle == "page A" }
        engine.load(server.url("/bare"))
        try await wait("the untitled page") { engine.currentURL == self.server.url("/bare") && !engine.isLoading && engine.pageTitle != "page A" }
        XCTAssertEqual(engine.pageTitle ?? "", "")
    }

    // parity: navigation.history
    func testBackAndForwardFollowThePagesVisited() async throws {
        server.route("/a", .page(title: "page A"))
        server.route("/b", .page(title: "page B"))
        let engine = engine()
        try await load(engine, "/a", title: "page A")
        try await load(engine, "/b", title: "page B")
        try await wait("back to be offered") { engine.canGoBack }
        engine.goBack()
        try await wait("page A after Back") { engine.webView.title == "page A" && engine.canGoForward }
        engine.goForward()
        try await wait("page B after Forward") { engine.webView.title == "page B" && !engine.canGoForward }
    }

    // parity: profiles.storage
    func testEachProfileKeepsItsOwnCookies() async throws {
        server.route("/set") { _ in .page(title: "set", headers: ["Set-Cookie": "who=work; Max-Age=600; Path=/"]) }
        server.route("/read") { request in .page(title: "cookie:\(request.cookies["who"] ?? "none")") }
        let work = UUID(), personal = UUID()

        let first = engine(profile: work)
        try await load(first, "/set", title: "set")
        // Another tab of the same profile is signed in too.
        try await load(engine(profile: work), "/read", title: "cookie:work")
        // Another profile's tab never sees the cookie.
        try await load(engine(profile: personal), "/read", title: "cookie:none")
    }

    // parity: profiles.private
    func testAPrivateEngineSharesNothingWithItsProfile() async throws {
        server.route("/set") { _ in .page(title: "set", headers: ["Set-Cookie": "who=private; Max-Age=600; Path=/"]) }
        server.route("/read") { request in .page(title: "cookie:\(request.cookies["who"] ?? "none")") }
        let profile = UUID()
        profiles.append(profile)
        let privateEngine = WKEngine(context: EngineProfileContext(profileID: profile, isEphemeral: true))
        try await load(privateEngine, "/set", title: "set")
        try await load(privateEngine, "/read", title: "cookie:private")
        try await load(engine(profile: profile), "/read", title: "cookie:none")
    }

    // parity: boosts.inject
    func testABoostStylesThePageAndRunsItsScriptInItsOwnWorld() async throws {
        server.route("/boost", .html("""
        <!doctype html><html><head><title>boost-pending</title><script>
        function check(n) {
          var css = getComputedStyle(document.body).backgroundColor;
          var js = document.documentElement.dataset.rearcBoost;
          var world = typeof rearcBoostSecret === 'undefined' ? 'isolated' : 'leaked';
          if (js === 'js' && css === 'rgb(1, 2, 3)') { document.title = 'boost-ok:' + world; return; }
          if (n > 200) { document.title = 'boost-fail:' + js + ':' + css + ':' + world; return; }
          setTimeout(function () { check(n + 1); }, 25);
        }
        window.addEventListener('load', function () { check(0); });
        </script></head><body><h1>boost</h1></body></html>
        """))
        let boost = BoostRuntimeEntry(
            packageID: UUID(),
            order: 0,
            hostScope: [BoostHostRule(host: "127.0.0.1", hostMatch: .exact, pathPrefix: "/boost", schemes: ["http"])],
            css: "body { background: rgb(1, 2, 3) !important; }",
            cssRules: [BoostCSSRule(id: "bg", css: "body { background: rgb(1, 2, 3) !important; }")],
            js: "globalThis.rearcBoostSecret = 'isolated'; document.documentElement.dataset.rearcBoost = 'js';",
            scriptUserEnabled: true
        )
        let engine = engine()
        engine.installBoosts([boost])
        engine.load(server.url("/boost"))
        try await wait("the boost's verdict") { engine.webView.title?.hasPrefix("boost-pending") == false && engine.webView.title?.isEmpty == false }
        XCTAssertEqual(engine.webView.title, "boost-ok:isolated")
    }

    // parity: prompts.dialogs
    func testAnAlertWaitsForTheShellsAnswer() async throws {
        server.route("/alert", .page(title: "before", body: "<script>alert('hello from the page'); document.title = 'after';</script>"))
        let engine = engine()
        engine.load(server.url("/alert"))
        try await wait("the alert to reach the page prompts") { engine.pagePrompts.dialog != nil }
        XCTAssertEqual(engine.pagePrompts.dialog?.request.message, "hello from the page")
        XCTAssertEqual(engine.pagePrompts.dialog?.request.kind, .alert)
        XCTAssertNotEqual(engine.webView.title, "after", "the page waits while the alert is up")
        engine.pagePrompts.answerDialog(accept: true)
        try await wait("the page to go on after the alert") { engine.webView.title == "after" }
    }

    // parity: find.count
    func testFindCountsMatchesAndSteps() async throws {
        server.route("/find", .page(title: "find", body: "<p>needle one</p><p>Needle two</p><p>needle three</p>"))
        let engine = engine()
        try await load(engine, "/find", title: "find")
        var events: [FindInPageEvent] = []
        engine.onFindEvent = { events.append($0) }
        let session = try XCTUnwrap(engine.startFind("needle", matchCase: false, forward: true))
        try await wait("the first find result") { events.contains { $0.sessionID == session && $0.reason == .result } }
        XCTAssertEqual(events.last?.matchCount, 3)
        XCTAssertEqual(events.last?.activeOrdinal, 1)
        XCTAssertTrue(engine.findNext(forward: true))
        try await wait("the second match") { events.last?.activeOrdinal == 2 }
        engine.stopFind(.clearSelection)
        XCTAssertEqual(events.last?.reason, .stopped)
    }

    // parity: downloads.attachment
    func testAnAttachmentIsSavedToTheDownloadsFolder() async throws {
        server.route("/file") { _ in
            WebKitFixtureServer.Response(type: "application/octet-stream",
                                         headers: ["Content-Disposition": "attachment; filename=\"report.bin\""],
                                         body: Data(repeating: 7, count: 4096))
        }
        server.route("/a", .page(title: "page A", body: "<a id='dl' href='/file'>file</a>"))
        let downloads = DownloadsController(fileURL: nil)
        let folder = scratch.appendingPathComponent("Downloads", isDirectory: true)
        downloads.setDirectory(folder)
        let engine = engine()
        engine.downloadCenter = downloads.webKit
        try await load(engine, "/a", title: "page A")
        engine.load(server.url("/file"))
        try await wait("the download to finish") { downloads.records.first?.state == .complete }
        let record = try XCTUnwrap(downloads.records.first)
        XCTAssertEqual(URL(fileURLWithPath: record.targetPath).lastPathComponent, "report.bin")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: record.targetPath)).count, 4096)
        XCTAssertEqual(engine.webView.title, "page A", "the page that started the download stays")
    }

    // parity: zoom.page
    func testPageZoomAppliesToTheView() async throws {
        server.route("/a", .page(title: "page A"))
        let engine = engine()
        try await load(engine, "/a", title: "page A")
        engine.setZoomFactor(1.5)
        XCTAssertEqual(engine.zoomFactor, 1.5)
        XCTAssertEqual(engine.webView.pageZoom, 1.5)
    }

    // parity: peek.shift-click
    func testAShiftClickedLinkGoesToPeekAndThePageStays() async throws {
        server.route("/a", .page(title: "page A", body: "<a id='link' href='/b'>to B</a>"))
        server.route("/b", .page(title: "page B"))
        let engine = engine()
        var peeked: [URL] = []
        engine.linkPeekHandler = { peeked.append($0) }
        try await load(engine, "/a", title: "page A")
        _ = try await engine.webView.evaluateJavaScript("""
        document.getElementById('link').dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, shiftKey: true })); true
        """)
        try await wait("the link to reach Peek") { !peeked.isEmpty }
        XCTAssertEqual(peeked, [server.url("/b")])
        XCTAssertEqual(engine.webView.title, "page A")
    }

    // parity: media.state
    func testThePageProbeReportsAPlayingVideosTitle() async throws {
        server.route("/a", .page(title: "page A", body: """
        <video id='v' muted></video><script>
        navigator.mediaSession.metadata = new MediaMetadata({ title: 'Song', artist: 'Band' });
        </script>
        """))
        let engine = engine()
        var states: [WebMediaState] = []
        let subscription = engine.mediaStatePublisher.sink { states.append($0) }
        defer { subscription.cancel() }
        try await load(engine, "/a", title: "page A")
        try await wait("a media report with the track") { states.last?.title == "Song" }
        XCTAssertEqual(states.last?.artist, "Band")
        XCTAssertEqual(states.last?.isPlaying, false)
    }
}
