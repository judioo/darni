import WebKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// The reader end to end with no window: real pages from a loopback server,
/// the real extraction scripts, the real reader page. "Nothing ran" is the
/// server's word: a beacon request that must never arrive
/// (docs/FEATURE-SPECS/READER-VIEW.md §10).
@MainActor
final class ReaderWebKitTests: XCTestCase {
    private var server: WebKitFixtureServer!
    private var defaults: UserDefaults!
    private var defaultsName = ""
    private let tabID = UUID()

    override func setUp() async throws {
        server = try WebKitFixtureServer()
        routeFixture(on: server)
        defaultsName = "darni-reader-webkit-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
    }

    override func tearDown() async throws {
        server.stop()
        server = nil
        defaults.removePersistentDomain(forName: defaultsName)
        defaults = nil
    }

    // MARK: Helpers

    private func routeFixture(on server: WebKitFixtureServer) {
        for path in [SelfTestReaderFixture.articlePath, SelfTestReaderFixture.plainPath, SelfTestReaderFixture.hostilePath,
                     SelfTestReaderFixture.picturePath, SelfTestReaderFixture.beaconPath] {
            server.route(path) { request in
                let full = request.query.isEmpty ? request.path : request.path + "?" + request.query
                guard let found = SelfTestReaderFixture.response(forPathAndQuery: full) else { return .init(status: 404) }
                return .init(type: found.type, body: found.body)
            }
        }
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

    private func settle(_ seconds: Double = 1.2) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// An engine in its own non-persistent store, showing `path` of the server.
    private func engine(showing path: String) async throws -> WKEngine {
        let engine = WKEngine(context: EngineProfileContext(profileID: UUID(), isEphemeral: true))
        engine.load(server.url(path))
        try await wait("\(path) to load") { !engine.isLoading && !engine.webView.isLoading && engine.webView.url == self.server.url(path) }
        return engine
    }

    private func beacons(on server: WebKitFixtureServer? = nil) -> [String] {
        (server ?? self.server).requests(for: SelfTestReaderFixture.beaconPath)
            .compactMap { SelfTestReaderFixture.beaconID($0.path + "?" + $0.query) }
    }

    /// Waits for the reader's document, then gives what its DOM holds: every
    /// element's name and attributes, and the page's text.
    private func contents(of page: ReaderPage) async throws -> (elements: [(name: String, attributes: [String: String])], text: String) {
        var loaded = false
        page.onLoad = { loaded = true }
        try await wait("the reader's page") { loaded || !page.webView.isLoading }
        try await wait("the reader's body") { !page.webView.isLoading }
        let script = """
        JSON.stringify({text: document.body ? document.body.innerText : "", elements: Array.prototype.map.call(document.querySelectorAll("*"), function (e) {
          var a = {}; e.getAttributeNames().forEach(function (n) { a[n] = e.getAttribute(n); });
          return {name: e.namespaceURI === "http://www.w3.org/1999/xhtml" ? e.localName : e.namespaceURI + " " + e.localName, attributes: a};
        })})
        """
        let json: String
        do {
            json = try await ReaderWebKitEvaluation.evaluate(script, in: page.webView)
        } catch {
            XCTFail("reading the reader's page failed: \(type(of: error)) \(error) \((error as NSError).userInfo)")
            throw error
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let elements = (object["elements"] as? [[String: Any]] ?? []).map {
            (name: $0["name"] as? String ?? "?", attributes: $0["attributes"] as? [String: String] ?? [:])
        }
        return (elements, object["text"] as? String ?? "")
    }

    /// What Darni itself writes around the article, and the attributes each allowed element may have.
    private static let frame: [String: Set<String>] = [
        "html": ["lang", "dir", "data-font", "data-size", "data-width", "data-theme"], "head": [], "meta": ["charset", "http-equiv", "content", "name"],
        "title": [], "style": [], "body": [], "main": [], "header": [], "article": [],
    ]
    private static let allowedAttributes: [String: Set<String>] = [
        "a": ["href", "rel"], "img": ["src", "alt", "width", "height", "referrerpolicy", "decoding"],
        "td": ["colspan", "rowspan"], "th": ["colspan", "rowspan"], "ol": ["start"], "p": ["class"],
    ]

    private func assertOnlyAllowedContent(_ elements: [(name: String, attributes: [String: String])], file: StaticString = #filePath, line: UInt = #line) {
        var inArticle = false
        for element in elements {
            if element.name == "article" { inArticle = true }
            if let frameAttributes = Self.frame[element.name], !inArticle || element.name == "article" {
                XCTAssertTrue(Set(element.attributes.keys).isSubset(of: frameAttributes), "\(element)", file: file, line: line)
                continue
            }
            XCTAssertNotNil(ReaderTag(rawValue: element.name), "an element outside the allowlist: \(element)", file: file, line: line)
            let allowed = Self.allowedAttributes[element.name] ?? []
            XCTAssertTrue(Set(element.attributes.keys).isSubset(of: allowed), "an attribute outside the allowlist: \(element)", file: file, line: line)
            if inArticle { XCTAssertNil(element.attributes["class"], "\(element)", file: file, line: line) }
            for name in ["href", "src"] {
                guard let value = element.attributes[name] else { continue }
                XCTAssertTrue(value.hasPrefix("http://") || value.hasPrefix("https://"), "\(name) is not a web address: \(element)", file: file, line: line)
            }
        }
    }

    // MARK: Detection and extraction, on the fixture

    func testAnArticleIsDetectedAndAPageThatIsNotOneIsNot() async throws {
        let center = ReaderCenter(defaults: defaults)
        let article = try await engine(showing: SelfTestReaderFixture.articlePath)
        XCTAssertEqual(center.availability(for: tabID, url: article.currentURL), .unknown)
        await center.detect(tabID: tabID, url: server.url(SelfTestReaderFixture.articlePath), engine: article, retryAfter: .zero)
        XCTAssertEqual(center.availability(for: tabID, url: article.currentURL), .article)

        let other = UUID()
        let plain = try await engine(showing: SelfTestReaderFixture.plainPath)
        await center.detect(tabID: other, url: server.url(SelfTestReaderFixture.plainPath), engine: plain, retryAfter: .zero)
        XCTAssertEqual(center.availability(for: other, url: plain.currentURL), .notArticle)
        // An answer is for one address: another address in the same tab is not known yet.
        XCTAssertEqual(center.availability(for: other, url: server.url(SelfTestReaderFixture.articlePath)), .unknown)
        XCTAssertEqual(center.availability(for: other, url: URL(string: "file:///a.html")), .notArticle)
        XCTAssertEqual(center.availability(for: other, url: nil), .notArticle)
    }

    func testTheReaderShowsTheArticlesTitleBylineSiteTimeTextAndPicture() async throws {
        let center = ReaderCenter(defaults: defaults)
        let engine = try await engine(showing: SelfTestReaderFixture.articlePath)
        try await wait("the page's picture") { self.server.requests(for: SelfTestReaderFixture.picturePath).count == 1 }
        let before = try await engine.webView.evaluateJavaScript("document.documentElement.outerHTML") as? String
        let session = try await center.open(tabID: tabID, url: server.url(SelfTestReaderFixture.articlePath), engine: engine,
                                            images: .loadedByPage) { _, _ in }
        let article = session.article
        XCTAssertEqual(article.title, SelfTestReaderFixture.articleTitle)
        XCTAssertEqual(article.byline, SelfTestReaderFixture.articleByline)
        XCTAssertEqual(article.siteName, SelfTestReaderFixture.articleSite)
        XCTAssertEqual(article.language, "en")
        XCTAssertGreaterThan(article.wordCount, 250)
        XCTAssertEqual(article.readingMinutes, 2)
        XCTAssertEqual(article.imagesShown, 1)
        XCTAssertEqual(article.imagesWithheld, 0)
        let body = ReaderHTML.fragment(for: article.body)
        let picture = server.url(SelfTestReaderFixture.picturePath).absoluteString
        for expected in ["<h2>The inspector</h2>", "<blockquote><p>A light that is noticed has usually failed.</p></blockquote>",
                         "<li>Wicks trimmed at dusk</li>", "<th>Nights of fog</th>", "<td>42</td>", "<code>wind: W light\nvisibility: good</code>",
                         "<img src=\"\(picture)\" alt=\"The lamp room\" width=\"16\" height=\"16\"", "The lamp room in winter.",
                         "<a href=\"\(server.url(SelfTestReaderFixture.plainPath).absoluteString)\" rel=\"noreferrer noopener\">the archive</a>"] {
            XCTAssertTrue(body.contains(expected), "missing \(expected) in \(body)")
        }
        XCTAssertFalse(body.contains("Copyright"), "the page's footer is not the article")
        XCTAssertFalse(body.contains("Search"), "nor its navigation")

        // The page underneath is as it was: extraction worked on a copy.
        let after = try await engine.webView.evaluateJavaScript("document.documentElement.outerHTML") as? String
        XCTAssertEqual(before, after)

        let shown = try await contents(of: session.page)
        assertOnlyAllowedContent(shown.elements)
        XCTAssertTrue(shown.text.contains(SelfTestReaderFixture.articleTitle))
        XCTAssertTrue(shown.text.contains("\(SelfTestReaderFixture.articleByline) · 2 min read"))
        XCTAssertTrue(shown.text.uppercased().contains(SelfTestReaderFixture.articleSite.uppercased()))
        XCTAssertTrue(shown.text.contains("someone has added the single word"))
        // The reader's own web view loads the picture: no cookie, no referrer.
        try await wait("the reader's picture") { self.server.requests(for: SelfTestReaderFixture.picturePath).count == 2 }
        let request = try XCTUnwrap(server.requests(for: SelfTestReaderFixture.picturePath).last)
        XCTAssertNil(request.headers["cookie"])
        XCTAssertNil(request.headers["referer"])
    }

    func testWithImagesOffTheReaderAsksTheNetworkForNothing() async throws {
        let center = ReaderCenter(defaults: defaults)
        let engine = try await engine(showing: SelfTestReaderFixture.articlePath)
        try await wait("the page's picture") { self.server.requests(for: SelfTestReaderFixture.picturePath).count == 1 }
        let requests = server.requests.count
        let session = try await center.open(tabID: tabID, url: server.url(SelfTestReaderFixture.articlePath), engine: engine, images: .off) { _, _ in }
        XCTAssertTrue(session.article.imagesOff)
        XCTAssertEqual(session.article.imagesWithheld, 1)
        let shown = try await contents(of: session.page)
        XCTAssertFalse(shown.elements.contains { $0.name == "img" })
        XCTAssertTrue(shown.text.contains("Pictures are not shown in the reader in private windows and containers."))
        try await settle()
        XCTAssertEqual(server.requests.count, requests, "the reader made a request: \(server.requests.dropFirst(requests).map(\.path))")
    }

    func testAPageWithNoArticleOpensNoReader() async throws {
        let center = ReaderCenter(defaults: defaults)
        let engine = try await engine(showing: SelfTestReaderFixture.plainPath)
        do {
            _ = try await center.open(tabID: tabID, url: server.url(SelfTestReaderFixture.plainPath), engine: engine, images: .off) { _, _ in }
            XCTFail("a reader opened on a page with no article")
        } catch {
            XCTAssertEqual(error as? ReaderCenter.OpenError, .noArticle)
        }
        XCTAssertFalse(center.isShowing(tabID))
        XCTAssertEqual(center.availability(for: tabID, url: server.url(SelfTestReaderFixture.plainPath)), .notArticle)
        do {
            _ = try await center.open(tabID: tabID, url: URL(string: "file:///etc/hosts")!, engine: engine, images: .off) { _, _ in }
            XCTFail("a reader opened on a file")
        } catch {
            XCTAssertEqual(error as? ReaderCenter.OpenError, .notReadable)
        }
    }

    // MARK: Nothing from the page runs in the reader

    func testNothingFromAHostilePageRunsInTheReader() async throws {
        let center = ReaderCenter(defaults: defaults)
        let engine = try await engine(showing: SelfTestReaderFixture.hostilePath)
        // The control: in the page itself the payloads are live and the beacon arrives.
        try await wait("the page's own beacons") {
            let seen = Set(self.beacons())
            return seen.isSuperset(of: ["body-script", "img-onerror", "body-onload", "svg-onload", "iframe-srcdoc"])
        }
        try await settle()
        let requestsBefore = server.requests.count

        let session = try await center.open(tabID: tabID, url: server.url(SelfTestReaderFixture.hostilePath), engine: engine,
                                            images: .loadedByPage) { _, _ in }
        let shown = try await contents(of: session.page)
        XCTAssertTrue(shown.text.contains(SelfTestReaderFixture.hostileMarker), "the article's text is there")
        XCTAssertTrue(shown.text.contains(SelfTestReaderFixture.hostileTitle))
        XCTAssertTrue(shown.text.contains("a javascript link"), "a refused link's text stays")
        assertOnlyAllowedContent(shown.elements)
        XCTAssertFalse(shown.elements.contains { $0.name == "a" }, "no link of the hostile page is a web address: \(shown.elements.filter { $0.name == "a" })")
        let body = ReaderHTML.fragment(for: session.article.body)
        for forbidden in ["<script", "onerror", "onclick", "onload", "javascript:", "srcset", "<svg", "<iframe", "<form", "<style", "beacon", "="] {
            XCTAssertFalse(body.contains(forbidden), "the article as written has \(forbidden): \(body)")
        }
        // The site's name carried markup: it is shown as the text it is.
        XCTAssertFalse(ReaderHTML.document(for: session.article, appearance: center.appearance).contains("<script"))
        XCTAssertTrue(shown.text.uppercased().contains("HARBOUR <SCRIPT>"), shown.text)
        // Clicking through every element fires nothing either (no handler came across).
        _ = try await ReaderWebKitEvaluation.evaluate(
            "Array.prototype.forEach.call(document.querySelectorAll('article *'), function (e) { if (typeof e.click === 'function') e.click(); }); 'clicked'", in: session.page.webView)
        try await settle(2)
        XCTAssertEqual(server.requests.count, requestsBefore,
                       "the reader made a request: \(server.requests.dropFirst(requestsBefore).map { $0.path + "?" + $0.query })")
    }

    /// The second barrier by itself: the hostile page's own HTML, unsanitised, in the reader's web view.
    func testTheReadersWebViewRunsNoScriptEvenOnUnsanitisedMarkup() async throws {
        func hostile(for server: WebKitFixtureServer) -> String {
            SelfTestReaderFixture.hostileHTML.replacingOccurrences(of: "/reader/", with: "http://127.0.0.1:\(server.port)/reader/")
        }
        let scriptRun: Set<String> = ["body-script", "img-onerror", "body-onload", "svg-onload", "iframe-srcdoc", "details-ontoggle",
                                      "input-autofocus", "math", "template", "p-onclick", "site-name", "javascript-link", "tab-javascript-link", "data-link", "form"]
        // The control: an ordinary web view runs them.
        let control = WKWebView(frame: .zero, configuration: {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            return configuration
        }())
        control.loadHTMLString(hostile(for: server), baseURL: nil)
        try await wait("the control's beacons") { Set(self.beacons()).isSuperset(of: ["body-script", "img-onerror", "body-onload"]) }

        let quiet = try WebKitFixtureServer()
        defer { quiet.stop() }
        routeFixture(on: quiet)
        let page = ReaderPage()
        page.loadDocument(hostile(for: quiet))
        _ = try await contents(of: page)
        _ = try await ReaderWebKitEvaluation.evaluate(
            "Array.prototype.forEach.call(document.querySelectorAll('body *'), function (e) { if (typeof e.click === 'function') e.click(); }); 'clicked'", in: page.webView)
        try await settle(2)
        let ran = Set(beacons(on: quiet)).intersection(scriptRun)
        XCTAssertEqual(ran, [], "script ran in the reader's web view")
        XCTAssertFalse(beacons(on: quiet).contains("external-script"), "a script file was fetched")
        XCTAssertEqual(page.webView.url?.absoluteString, "about:blank", "the reader went nowhere")
    }

    func testTheReadersWebViewHasNoScriptNoBridgeAndNoStore() {
        let page = ReaderPage()
        let configuration = page.webView.configuration
        XCTAssertFalse(configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(configuration.userContentController.userScripts.isEmpty)
        XCTAssertFalse(configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertFalse(page.webView.allowsBackForwardNavigationGestures)
        XCTAssertFalse(ReaderPage().webView.configuration.websiteDataStore === configuration.websiteDataStore, "each reader has its own store")
    }

    // MARK: The mutation-XSS corpus

    /// Markup that has got past sanitisers before: parser round trips, raw-text
    /// elements, namespace confusion, entities. `PING` asks the server for the beacon.
    private static let corpus = [
        "<img src=x onerror=\"PING\">",
        "<svg><script>PING</script></svg>",
        "<svg onload=\"PING\"><animate onbegin=\"PING\" attributeName=x dur=1s></svg>",
        "<math><mtext><table><mglyph><style><!--</style><img title=\"--&gt;&lt;img src=1 onerror=PING&gt;\">",
        "<form><math><mtext></form><form><mglyph><style></math><img src onerror=PING>",
        "<noscript><p title=\"</noscript><img src=x onerror=PING>\">",
        "<template><script>PING</script><img src=x onerror=PING></template>",
        "<a href=\"jav&#x09;ascript:PING\">tab</a><a href=\"jav&#x0A;ascript:PING\">newline</a><a href=\"&#106;avascript:PING\">entity</a>",
        "<a href=\"javascript&colon;PING\">colon</a><a href=\"&#1;javascript:PING\">control</a><a href=\"JaVaScRiPt:PING\">case</a>",
        "<a href=\"data:text/html,<script>PING</script>\">data</a><a href=\"vbscript:PING\">vb</a>",
        "<iframe srcdoc=\"&lt;script&gt;PING&lt;/script&gt;\"></iframe><iframe src=\"javascript:PING\"></iframe>",
        "<textarea><img src=x onerror=PING></textarea><title><img src=x onerror=PING></title><xmp><img src=x onerror=PING></xmp>",
        "<details open ontoggle=\"PING\"><summary>s</summary>d</details><marquee onstart=\"PING\">m</marquee>",
        "<p style=\"background:url(BEACON)\">styled</p><style>@import \"BEACON\";</style><link rel=stylesheet href=\"BEACON\">",
        "<img srcset=\"BEACON 1x, javascript:PING 2x\"><picture><source srcset=\"BEACON\"><img alt=p></picture>",
        "<object data=\"javascript:PING\"></object><embed src=\"javascript:PING\"><object data=\"BEACON\"></object>",
        "<base href=\"javascript:PING//\"><a href=\"#\">based</a>",
        "<input autofocus onfocus=\"PING\"><button formaction=\"javascript:PING\">b</button><select onfocus=\"PING\" autofocus></select>",
        "<svg><a xlink:href=\"javascript:PING\"><text>svg link</text></a></svg><svg><use href=\"data:image/svg+xml,<svg id='x' xmlns='http://www.w3.org/2000/svg'><script>PING</script></svg>#x\"></svg>",
        "<img src=\"javascript:PING\"><img src=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' onload='PING'/>\">",
        "<table><td><a href=\"javascript:PING\">fostered</a><script>PING</script></table>",
        "<svg></p><style><a id=\"</style><img src=1 onerror=PING>\">",
        "<svg><style><img src=x onerror=PING></style></svg><math><style><img src=x onerror=PING></style></math>",
        "<meta http-equiv=\"refresh\" content=\"0;url=javascript:PING\"><meta http-equiv=\"refresh\" content=\"0;url=BEACON\">",
        "<video><source onerror=\"PING\"></video><audio src=x onerror=\"PING\"></audio><video poster=\"BEACON\"></video>",
        "<p>&lt;script&gt;PING&lt;/script&gt; &lt;img src=x onerror=PING&gt;</p>",
        "<listing>&lt;img src=x onerror=PING&gt;</listing><plaintext>&lt;img src=x onerror=PING&gt;",
        "<p title=\"&quot;&gt;&lt;img src=x onerror=PING&gt;\" id=\"&quot;&gt;&lt;script&gt;PING&lt;/script&gt;\">attributes</p>",
        "<div><p>nested<p>paragraphs<a href=\"https://ok.example/\">a<a href=\"https://ok.example/2\">nested links</a></a></div>",
        "<isindex action=\"javascript:PING\" type=image><frameset onload=\"PING\"><body onpageshow=\"PING\" onfocus=\"PING\">",
        "<a href=\"https://ok.example/\" onclick=\"PING\" onmouseover=\"PING\" target=\"_blank\" ping=\"BEACON\">a good link with bad attributes</a>",
        "<x-widget onclick=\"PING\"><span onmouseenter=\"PING\">custom</span></x-widget><SCRIPT>PING</SCRIPT><ScRiPt src=\"BEACON\"></sCrIpT>",
    ]

    private func corpus(for server: WebKitFixtureServer) -> [String] {
        let beacon = "http://127.0.0.1:\(server.port)\(SelfTestReaderFixture.beaconPath)?id=corpus"
        return Self.corpus.map { $0.replacingOccurrences(of: "PING", with: "new Image().src='\(beacon)'").replacingOccurrences(of: "BEACON", with: beacon) }
    }

    /// The tree of `html` as a page's parser makes it (the production walker over it):
    /// in a live document, where `noscript` holds text, or in an inert one, where it holds elements.
    private func tree(of html: String, in parser: WKWebView, live: Bool) async throws -> Any {
        let literal = String(data: try JSONSerialization.data(withJSONObject: [html]), encoding: .utf8)!
        let holder = live
            ? "var holder = document.createElement('div'); holder.innerHTML = \(literal)[0];"
            : "var holder = new DOMParser().parseFromString(\(literal)[0], 'text/html').documentElement;"
        let json = try await ReaderWebKitEvaluation.evaluate("(function () { \(ReaderScripts.walker) \(holder) return JSON.stringify(walk(holder, 0)); })()", in: parser)
        return try JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    private func assertAllowlisted(_ raw: Any, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let element = raw as? [String: Any] else { return }
        let name = element["t"] as? String ?? ""
        let attributes = element["a"] as? [String: String] ?? [:]
        if !["div", "html", "head", "body"].contains(name) {
            XCTAssertNil(element["ns"], "\(context): foreign \(name)", file: file, line: line)
            XCTAssertNotNil(ReaderTag(rawValue: name), "\(context): <\(name)> came back from the parser", file: file, line: line)
            XCTAssertTrue(Set(attributes.keys).isSubset(of: Self.allowedAttributes[name] ?? []), "\(context): <\(name)> has \(attributes)", file: file, line: line)
            for key in ["href", "src"] {
                if let value = attributes[key] { XCTAssertTrue(value.hasPrefix("https://"), "\(context): \(key)=\(value)", file: file, line: line) }
            }
        }
        for child in element["c"] as? [Any] ?? [] { assertAllowlisted(child, context, file: file, line: line) }
    }

    func testHostileMarkupStaysHarmlessThroughParsingSanitisingAndParsingAgain() async throws {
        let parser = WKWebView(frame: .zero, configuration: ReaderPage.makeConfiguration())
        parser.loadHTMLString("<!doctype html><title>parser</title>", baseURL: nil)
        try await wait("the parser page") { !parser.isLoading }
        let base = URL(string: "https://news.example/story")!
        let sanitiser = ReaderSanitiser(baseURL: base, images: .loadedByPage(["https://news.example/x", "https://news.example/1"]))
        var written: [String] = []
        var nodes: [ReaderNode] = []
        for (index, html) in corpus(for: server).enumerated() {
            for live in [true, false] {
                let context = "corpus \(index) (\(live ? "live" : "inert") parse)"
                let output = sanitiser.sanitise(try await tree(of: html, in: parser, live: live))
                let fragment = ReaderHTML.fragment(for: output.nodes)
                // Text may say anything: only markup counts, so escaped text is taken out first.
                let markup = fragment.replacingOccurrences(of: "&lt;", with: "").replacingOccurrences(of: "&gt;", with: "")
                for forbidden in ["<script", "<svg", "<math", "<style", "<iframe", "<object", "<embed", "<form", "<input", "<template",
                                  "<noscript", "<base", "<meta", "<link", "<textarea", "<button", "<select", "<video", "<audio"] {
                    XCTAssertFalse(markup.lowercased().contains(forbidden), "\(context): \(fragment)")
                }
                // Parse what was written again, both ways: nothing new may appear (mutation XSS).
                for again in [true, false] {
                    assertAllowlisted(try await tree(of: fragment, in: parser, live: again), "\(context), reparsed \(again ? "live" : "inert")")
                }
                written.append(fragment)
                if live { nodes += output.nodes }
            }
        }
        // And shown in the reader, all of it at once: no beacon. (The parser page above is
        // not the reader: a detached <img srcset> or <video poster> there may have asked
        // the server already, so the count is taken now.)
        try await settle()
        let before = beacons().count
        let article = ReaderArticle(sourceURL: base, title: "Corpus", siteName: "news.example", body: nodes)
        let page = ReaderPage()
        page.show(article, appearance: ReaderAppearance())
        let shown = try await contents(of: page)
        assertOnlyAllowedContent(shown.elements)
        XCTAssertTrue(shown.text.contains("a good link with bad attributes"))
        let link = shown.elements.first { $0.name == "a" && $0.attributes["href"] == "https://ok.example/" }
        XCTAssertEqual(link?.attributes.keys.sorted(), ["href", "rel"])
        _ = try await ReaderWebKitEvaluation.evaluate(
            "Array.prototype.forEach.call(document.querySelectorAll('article *:not(a)'), function (e) { if (typeof e.click === 'function') e.click(); }); 'clicked'", in: page.webView)
        try await settle(2)
        XCTAssertEqual(beacons().count, before, "a corpus payload reached the server from the reader")
        XCTAssertFalse(written.joined().isEmpty)
    }

    func testTheCorpusIsLiveInAnOrdinaryWebView() async throws {
        // The control for the test above: the same markup, unsanitised, with script on.
        let control = WKWebView(frame: .zero, configuration: {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            return configuration
        }())
        control.loadHTMLString("<!doctype html><body>" + corpus(for: server).joined(separator: "\n") + "</body>", baseURL: nil)
        try await wait("the corpus's beacons in an ordinary web view") { self.beacons().count >= 5 }
    }

    // MARK: Appearance, links, leaving

    private func sampleArticle() -> ReaderArticle {
        ReaderArticle(sourceURL: server.url(SelfTestReaderFixture.articlePath), title: "Sample", siteName: "example", body: [
            .element({
                var link = ReaderElement(.a, children: [.text("a link")])
                link.href = "https://ok.example/next?a=1"
                return ReaderElement(.p, children: [.text("Text with "), .element(link)])
            }()),
        ])
    }

    func testAChangedSettingShowsInTheOpenReaderWithoutReloadingIt() async throws {
        let center = ReaderCenter(defaults: defaults)
        let session = center.show(sampleArticle(), tabID: tabID) { _, _ in }
        _ = try await contents(of: session.page)
        func attributes() async -> [String: String] {
            await withCheckedContinuation { continuation in session.page.readAppearanceAttributes { continuation.resume(returning: $0) } }
        }
        var shown = await attributes()
        XCTAssertEqual(shown, ["data-font": "serif", "data-size": "3", "data-width": "medium", "data-theme": "auto"])
        var reloads = 0
        session.page.onLoad = { reloads += 1 }
        center.appearance = ReaderAppearance(font: .sans, size: 6, width: .narrow, theme: .dark)
        for _ in 0..<200 {
            shown = await attributes()
            if shown["data-theme"] == "dark" { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await settle(0.3)
        shown = await attributes()
        XCTAssertEqual(shown, ["data-font": "sans", "data-size": "6", "data-width": "narrow", "data-theme": "dark"])
        XCTAssertEqual(reloads, 0, "the place in the article is kept")
        // The next reader starts with it, and so does the next launch.
        XCTAssertTrue(ReaderHTML.document(for: sampleArticle(), appearance: ReaderCenter(defaults: defaults).appearance).contains("data-theme=\"dark\""))
    }

    func testAClickedLinkIsHandedToTheShellAndTheReaderGoesNowhere() async throws {
        let center = ReaderCenter(defaults: defaults)
        var links: [(URL, Bool)] = []
        let session = center.show(sampleArticle(), tabID: tabID) { links.append(($0, $1)) }
        _ = try await contents(of: session.page)
        _ = try await ReaderWebKitEvaluation.evaluate("document.querySelector('a').click(); 'clicked'", in: session.page.webView)
        try await wait("the link") { !links.isEmpty }
        XCTAssertEqual(links.first?.0.absoluteString, "https://ok.example/next?a=1")
        XCTAssertEqual(links.first?.1, false)
        XCTAssertEqual(session.page.cancelledNavigations.map(\.absoluteString), ["https://ok.example/next?a=1"])
        try await settle(0.5)
        XCTAssertEqual(session.page.webView.url?.absoluteString, "about:blank")
        XCTAssertEqual(server.requests.count, 0)
    }

    func testLeavingTheReaderLeavesThePageAsItWas() async throws {
        let center = ReaderCenter(defaults: defaults)
        let engine = try await engine(showing: SelfTestReaderFixture.articlePath)
        _ = try await engine.webView.evaluateJavaScript("window.keptState = 'typed by the person'; document.title = 'changed title'; window.scrollTo(0, 40); 1")
        let url = server.url(SelfTestReaderFixture.articlePath)
        try await center.open(tabID: tabID, url: url, engine: engine, images: .off) { _, _ in }
        XCTAssertTrue(center.isShowing(tabID))
        let requests = server.requests.count
        // Opening it again gives the same reader.
        let again = try await center.open(tabID: tabID, url: url, engine: engine, images: .off) { _, _ in }
        XCTAssertEqual(again.id, center.session(for: tabID)?.id)
        center.close(tabID: tabID)
        XCTAssertFalse(center.isShowing(tabID))
        XCTAssertNil(center.session(for: tabID))
        let state = try await engine.webView.evaluateJavaScript("window.keptState + '|' + document.title + '|' + location.href") as? String
        XCTAssertEqual(state, "typed by the person|changed title|\(url.absoluteString)")
        XCTAssertEqual(engine.currentURL, url)
        XCTAssertFalse(engine.canGoBack, "the reader added no history entry")
        XCTAssertEqual(server.requests.count, requests, "and the page was not loaded again")
    }

    func testAReaderClosesWhenItsTabShowsAnotherPageOrGoes() async throws {
        let center = ReaderCenter(defaults: defaults)
        let article = sampleArticle()
        center.show(article, tabID: tabID) { _, _ in }
        center.pageChanged(tabID: tabID, url: article.sourceURL)
        XCTAssertTrue(center.isShowing(tabID), "the same address: it stays")
        center.pageChanged(tabID: tabID, url: server.url(SelfTestReaderFixture.plainPath))
        XCTAssertFalse(center.isShowing(tabID))
        center.show(article, tabID: tabID) { _, _ in }
        center.forget(tabID: tabID)
        XCTAssertFalse(center.isShowing(tabID))
        XCTAssertEqual(center.availability(for: tabID, url: article.sourceURL), .unknown)
    }

    func testTheFixtureCountsItsBeacons() {
        SelfTestReaderFixture.resetBeacons()
        XCTAssertNil(SelfTestReaderFixture.response(forPathAndQuery: "/a"))
        XCTAssertNil(SelfTestReaderFixture.beaconID("/reader/article"))
        XCTAssertEqual(SelfTestReaderFixture.response(forPathAndQuery: "/reader/beacon?id=body-script")?.type, "image/gif")
        _ = SelfTestReaderFixture.response(forPathAndQuery: "/reader/beacon?x=1&id=body-script")
        _ = SelfTestReaderFixture.response(forPathAndQuery: "/reader/beacon")
        XCTAssertEqual(SelfTestReaderFixture.beaconCounts, ["body-script": 2, "unnamed": 1])
        XCTAssertEqual(SelfTestReaderFixture.beaconTotal, 3)
        SelfTestReaderFixture.resetBeacons()
        XCTAssertEqual(SelfTestReaderFixture.beaconTotal, 0)
        XCTAssertNotNil(SelfTestReaderFixture.response(forPathAndQuery: SelfTestReaderFixture.articlePath))
        XCTAssertEqual(SelfTestReaderFixture.response(forPathAndQuery: SelfTestReaderFixture.picturePath)?.type, "image/png")
    }
}
