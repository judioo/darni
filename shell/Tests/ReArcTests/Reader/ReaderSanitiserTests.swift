import CryptoKit
import XCTest
@testable import SidebarModel

/// A raw tree as the extraction script writes it (`ReaderSanitiser`'s input).
func readerElement(_ name: String, _ attributes: [String: String] = [:], namespace: String? = nil, _ children: [Any] = []) -> [String: Any] {
    var element: [String: Any] = ["t": name]
    if !attributes.isEmpty { element["a"] = attributes }
    if let namespace { element["ns"] = namespace }
    if !children.isEmpty { element["c"] = children }
    return element
}

/// The sanitiser: an allowlist over a tree. What is not named in `ReaderTag`
/// cannot come out, whatever goes in (docs/FEATURE-SPECS/READER-VIEW.md §5).
final class ReaderSanitiserTests: XCTestCase {
    private let base = URL(string: "https://news.example/world/story.html")!
    private let picture = "https://news.example/img/lamp.jpg"

    private func sanitise(_ raw: Any, images: ReaderImagePolicy? = nil) -> ReaderSanitiser.Output {
        ReaderSanitiser(baseURL: base, images: images ?? .loadedByPage([picture])).sanitise(raw)
    }

    private func html(_ raw: Any, images: ReaderImagePolicy? = nil) -> String {
        ReaderHTML.fragment(for: sanitise(raw, images: images).nodes)
    }

    // MARK: What is kept

    func testStructureAndTextAreKept() {
        let raw = readerElement("div", [:], [
            readerElement("h1", [:], ["Title"]),
            readerElement("p", [:], ["One ", readerElement("b", [:], ["bold"]), " and ", readerElement("i", [:], ["italic"]), "."]),
            readerElement("ul", [:], [readerElement("li", [:], ["first"]), readerElement("li", [:], ["second"])]),
            readerElement("blockquote", [:], ["quoted"]),
            readerElement("pre", [:], [readerElement("code", [:], ["let a = 1\nlet b = 2"])]),
            readerElement("hr"),
        ])
        XCTAssertEqual(html(raw), "<h2>Title</h2><p>One <strong>bold</strong> and <em>italic</em>.</p>"
            + "<ul><li>first</li><li>second</li></ul><blockquote><p>quoted</p></blockquote>"
            + "<pre>\n<code>let a = 1\nlet b = 2</code></pre><hr>")
    }

    func testAnUnknownElementIsUnwrappedAndItsTextBecomesParagraphs() {
        let raw = readerElement("section", [:], [
            "loose text ",
            readerElement("span", ["class": "x"], ["in a span"]),
            readerElement("div", [:], ["a block"]),
            readerElement("custom-widget", [:], [readerElement("p", [:], ["inside"])]),
        ])
        XCTAssertEqual(html(raw), "<p>loose text in a span</p><p>a block</p><p>inside</p>")
    }

    func testATableKeepsItsShapeAndOnlyCountsAsAttributes() {
        let raw = readerElement("table", ["onclick": "x()", "style": "color:red", "border": "1"], [
            readerElement("caption", [:], ["dropped"]),
            readerElement("thead", [:], [readerElement("tr", [:], [readerElement("th", ["colspan": "2", "onmouseover": "x()"], ["Head"])])]),
            readerElement("tbody", [:], [readerElement("tr", [:], [
                readerElement("td", ["rowspan": "3", "style": "x"], ["a"]),
                readerElement("td", ["colspan": "9999"], ["b"]),
                "stray",
            ])]),
        ])
        XCTAssertEqual(html(raw), "<table><thead><tr><th colspan=\"2\">Head</th></tr></thead>"
            + "<tbody><tr><td rowspan=\"3\">a</td><td>b</td></tr></tbody></table>")
    }

    func testAListStartAndStrayContent() {
        let raw = readerElement("ol", ["start": "4", "type": "a", "onclick": "x()"], [readerElement("li", [:], ["four"]), "stray"])
        XCTAssertEqual(html(raw), "<ol start=\"4\"><li>four</li><li>stray</li></ol>")
        XCTAssertEqual(html(readerElement("ol", ["start": "4;alert(1)"], [readerElement("li", [:], ["x"])])), "<ol><li>x</li></ol>")
    }

    func testSpacesAroundInlineElementsStay() {
        let raw = readerElement("p", [:], ["a", readerElement("em", [:], [" b "]), "c"])
        XCTAssertEqual(html(raw), "<p>a<em> b </em>c</p>")
    }

    // MARK: Links

    func testALinkIsResolvedAgainstTheArticle() {
        XCTAssertEqual(html(readerElement("a", ["href": "/other?x=1&y=2", "target": "_blank", "onclick": "x()"], ["next"])),
                       "<p><a href=\"https://news.example/other?x=1&amp;y=2\" rel=\"noreferrer noopener\">next</a></p>")
        XCTAssertEqual(html(readerElement("a", ["href": "//cdn.example/a"], ["cdn"])),
                       "<p><a href=\"https://cdn.example/a\" rel=\"noreferrer noopener\">cdn</a></p>")
    }

    func testALinkThatIsNotAWebAddressLosesItsElementAndKeepsItsText() {
        let refused = [
            "javascript:alert(1)", "JaVaScRiPt:alert(1)", "  javascript:alert(1)", "jav\tascript:alert(1)", "java\nscript:alert(1)",
            "jav\rascript:alert(1)", "\u{01}javascript:alert(1)", "javascript\u{00}:alert(1)", "data:text/html,<script>alert(1)</script>",
            "blob:https://news.example/1234", "file:///etc/passwd", "chrome://settings", "chrome-extension://abcdef/page.html",
            "view-source:https://news.example/", "about:blank", "vbscript:msgbox(1)", "rearc://settings", "darni://settings",
            "mailto:someone@example.com", "tel:+1234", "ftp://files.example/a", "https://user:secret@evil.example/", "https:\\\\evil.example\\x",
            "", "   ", "https://", "#section", "https://news.example/world/story.html#note-1",
        ]
        for href in refused {
            XCTAssertEqual(html(readerElement("a", ["href": href], ["link text"])), "<p>link text</p>", "href \(href.debugDescription)")
        }
        XCTAssertEqual(html(readerElement("a", [:], ["no href"])), "<p>no href</p>")
    }

    // MARK: Images

    func testAnImageThePageLoadedIsShownWithItsOwnAttributesOnly() {
        let raw = readerElement("img", ["src": "/img/lamp.jpg", "alt": "A \"lamp\" <b>", "width": "640", "height": "480",
                                        "onerror": "alert(1)", "onload": "alert(2)", "style": "x", "class": "c", "id": "i",
                                        "loading": "lazy", "usemap": "#m", "longdesc": "javascript:alert(3)"])
        XCTAssertEqual(html(raw), "<p><img src=\"https://news.example/img/lamp.jpg\" alt=\"A &quot;lamp&quot; &lt;b&gt;\" width=\"640\" height=\"480\""
            + " referrerpolicy=\"no-referrer\" decoding=\"async\"></p>")
    }

    func testAnImageThePageDidNotLoadIsWithheld() {
        let output = sanitise(readerElement("p", [:], ["text", readerElement("img", ["src": "https://tracker.example/pixel.gif"])]))
        XCTAssertEqual(ReaderHTML.fragment(for: output.nodes), "<p>text</p>")
        XCTAssertEqual(output.imagesWithheld, 1)
        XCTAssertEqual(output.imagesShown, 0)
    }

    func testNoImageAtAllWhenImagesAreOff() {
        let output = sanitise(readerElement("figure", [:], [
            readerElement("img", ["src": picture]), readerElement("figcaption", [:], ["The lamp"]),
        ]), images: ReaderImagePolicy.none)
        XCTAssertEqual(ReaderHTML.fragment(for: output.nodes), "<figure><figcaption>The lamp</figcaption></figure>")
        XCTAssertEqual(output.imagesWithheld, 1)
    }

    func testSrcsetIsNeverWrittenAndEveryURLInItIsChecked() {
        // The loaded picture is named only in srcset, next to URLs that must never be used.
        let raw = readerElement("img", ["src": "data:image/gif;base64,R0lGOD", "alt": "lamp",
                                        "srcset": "javascript:alert(1) 1x, https://tracker.example/b.gif 2x, /img/lamp.jpg 640w"])
        let output = html(raw)
        XCTAssertEqual(output, "<p><img src=\"https://news.example/img/lamp.jpg\" alt=\"lamp\" referrerpolicy=\"no-referrer\" decoding=\"async\"></p>")
        XCTAssertFalse(output.contains("srcset"))
        // Nothing in srcset is a loaded picture: no image.
        let none = html(readerElement("img", ["srcset": "javascript:alert(1) 1x, data:image/png;base64,AAAA 2x, https://tracker.example/b.gif 3x"]))
        XCTAssertEqual(none, "")
        XCTAssertEqual(ReaderSanitiser.srcsetURLs("a.jpg 1x, b.jpg 2x,\n c.jpg 640w , d.jpg"), ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
    }

    /// A <picture> as the extraction script writes it: the page showed the
    /// `<source>`'s 1x URL (its `currentSrc`, in "cs"); the <img>'s own src is
    /// a fallback the page never fetched.
    private func pictureElement(shown: String?, extra: [String: String] = [:]) -> [String: Any] {
        var image = readerElement("img", ["src": "/img/lamp-fallback.jpg", "alt": "lamp"].merging(extra) { $1 })
        if let shown { image["cs"] = shown }
        return readerElement("figure", [:], [
            readerElement("picture", [:], [
                readerElement("source", ["media": "(min-width: 600px)", "srcset": "/img/lamp-wide.jpg 1x, /img/lamp-wide-2x.jpg 2x"]),
                readerElement("source", ["srcset": "/img/lamp.jpg 1x, /img/lamp-2x.jpg 2x"]),
                image,
            ]),
        ])
    }

    func testAPicturesSourceThePageShowedIsShownAndNoSourceOrSrcsetIsWritten() {
        let output = sanitise(pictureElement(shown: picture))
        XCTAssertEqual(output.imagesShown, 1)
        XCTAssertEqual(output.imagesWithheld, 0)
        let markup = ReaderHTML.fragment(for: output.nodes)
        XCTAssertEqual(markup, "<figure><img src=\"https://news.example/img/lamp.jpg\" alt=\"lamp\" referrerpolicy=\"no-referrer\" decoding=\"async\"></figure>")
        for forbidden in ["srcset", "<source", "<picture", "media=", "lamp-2x", "lamp-wide", "fallback"] {
            XCTAssertFalse(markup.contains(forbidden), forbidden)
        }
    }

    func testAPicturesSourceThePageDidNotLoadIsNotTaken() {
        // The page loaded the 1x picture. Another density and another media
        // query's source are named in the tree but were never loaded.
        for shown in ["https://news.example/img/lamp-2x.jpg", "https://news.example/img/lamp-wide.jpg", "https://news.example/img/lamp-wide-2x.jpg"] {
            let output = sanitise(pictureElement(shown: shown))
            XCTAssertFalse(ReaderHTML.fragment(for: output.nodes).contains("<img"), shown)
            XCTAssertEqual(output.imagesShown, 0, shown)
            XCTAssertEqual(output.imagesWithheld, 1, shown)
        }
        // Only the img's own src and srcset, and no shown URL: the sources' URLs are never candidates.
        let fromSources = sanitise(pictureElement(shown: nil), images: .loadedByPage(["https://news.example/img/lamp-wide.jpg"]))
        XCTAssertEqual(fromSources.imagesShown, 0)
        XCTAssertEqual(fromSources.imagesWithheld, 1)
    }

    func testAShownURLIsCheckedAsSrcIsAndCannotComeFromAnAttribute() {
        // Not a web address, or with userinfo, or too long: never shown, even if listed as loaded.
        let long = "https://news.example/" + String(repeating: "a", count: 5000) + ".jpg"
        for shown in ["javascript:alert(1)", "data:image/png;base64,AAAA", "https://user:pass@news.example/img/lamp.jpg", long] {
            let output = sanitise(pictureElement(shown: shown), images: .loadedByPage([shown]))
            XCTAssertEqual(output.imagesShown, 0, String(shown.prefix(60)))
        }
        // A page's own attribute named "cs" is just an attribute: it is not the shown URL.
        let forged = sanitise(pictureElement(shown: nil, extra: ["cs": picture]))
        XCTAssertEqual(forged.imagesShown, 0)
    }

    func testAnImageURLThatIsNotAWebAddressIsNeverShownEvenIfListedAsLoaded() {
        for src in ["javascript:alert(1)", "data:image/svg+xml,<svg onload=alert(1)>", "blob:https://news.example/1", "file:///x.png", "chrome://theme/x"] {
            let output = sanitise(readerElement("img", ["src": src]), images: .loadedByPage([src]))
            XCTAssertEqual(output.nodes, [], src)
        }
    }

    // MARK: The hostile corpus (trees)

    func testScriptAndEverythingLikeItGoesWithItsContent() {
        for name in ReaderSanitiser.droppedWithContent.sorted() {
            let raw = readerElement("div", [:], [
                readerElement("p", [:], ["before"]),
                readerElement(name, ["src": "https://evil.example/x.js", "onload": "alert(1)"], [
                    "alert(document.cookie)", readerElement("p", [:], ["hidden inside"]), readerElement("img", ["src": picture]),
                ]),
                readerElement("p", [:], ["after"]),
            ])
            XCTAssertEqual(html(raw), "<p>before</p><p>after</p>", name)
        }
        for required in ["script", "style", "iframe", "object", "embed", "form", "input", "button", "select", "textarea",
                         "svg", "math", "link", "meta", "base", "template", "noscript"] {
            XCTAssertTrue(ReaderSanitiser.droppedWithContent.contains(required), required)
        }
    }

    func testForeignContentGoesWhateverItIsCalled() {
        let svg = "http://www.w3.org/2000/svg", mathml = "http://www.w3.org/1998/Math/MathML"
        let raw = readerElement("div", [:], [
            // Namespace confusion: elements with allowed names that are not HTML elements.
            readerElement("p", [:], namespace: svg, ["an svg <p>"]),
            readerElement("a", ["href": "https://ok.example/"], namespace: svg, ["an svg <a>"]),
            readerElement("img", ["src": picture], namespace: mathml),
            readerElement("svg", [:], namespace: svg, [readerElement("script", [:], namespace: svg, ["alert(1)"]), readerElement("p", [:], ["html in svg"])]),
            readerElement("math", [:], namespace: mathml, [readerElement("mtext", [:], namespace: mathml, [readerElement("img", ["src": picture, "onerror": "alert(1)"])])]),
            readerElement("p", [:], namespace: "", ["no namespace"]),
            readerElement("p", [:], ["kept"]),
        ])
        XCTAssertEqual(html(raw), "<p>kept</p>")
    }

    func testAnElementNameIsNeverWrittenFromThePage() {
        // Names that are not the allowlist's exact spelling are never output: their text stays as text.
        for name in ["SCRIPT", "Script", "scr\u{0}ipt", "script ", "p onclick=alert(1)", "img/src=x", "svg:script", "p>", "<script>", "x-script"] {
            let output = html(readerElement(name, ["onclick": "alert(1)"], ["alert(1)"]))
            XCTAssertEqual(output, "<p>alert(1)</p>", name.debugDescription)
        }
    }

    func testEventHandlersStyleAndEveryOtherAttributeGo() {
        let attributes = ["onclick": "alert(1)", "onmouseover": "alert(1)", "ONLOAD": "alert(1)", "onerror": "alert(1)", "style": "background:url(https://evil.example/)",
                          "id": "x", "class": "y", "name": "z", "contenteditable": "true", "autofocus": "", "srcdoc": "<script>alert(1)</script>",
                          "formaction": "javascript:alert(1)", "xlink:href": "javascript:alert(1)", "background": "https://evil.example/x.png",
                          "data-src": "https://evil.example/x.png", "is": "x-y", "slot": "s", "dir": "rtl", "lang": "en", "title": "t", "href": "javascript:alert(1)",
                          "src": "https://evil.example/x.js", "action": "https://evil.example/"]
        for tag in ReaderTag.allCases where tag != .img && tag != .a && !tag.isVoid {
            let child: Any = [.ul, .ol].contains(tag) ? readerElement("li", [:], ["x"]) as Any
                : tag == .table ? readerElement("tr", [:], [readerElement("td", [:], ["x"])]) as Any
                : [.thead, .tbody].contains(tag) ? readerElement("tr", [:], [readerElement("td", [:], ["x"])]) as Any
                : tag == .tr ? readerElement("td", [:], ["x"]) as Any : "x" as Any
            let output = sanitise(readerElement(tag.rawValue, attributes, [child]))
            for node in output.nodes {
                node.forEachElement { element in
                    XCTAssertNil(element.href, tag.rawValue)
                    XCTAssertNil(element.src, tag.rawValue)
                }
            }
            let written = ReaderHTML.fragment(for: output.nodes)
            XCTAssertFalse(written.contains("alert"), "\(tag.rawValue): \(written)")
            XCTAssertFalse(written.contains("evil.example"), "\(tag.rawValue): \(written)")
            XCTAssertFalse(written.contains("=\""), "\(tag.rawValue) kept an attribute: \(written)")
        }
    }

    func testMarkupInTextAndAttributesIsEscaped() {
        let raw = readerElement("p", [:], ["<script>alert(1)</script> & </p><img src=x onerror=alert(2)> \u{0}\u{1B}",
                                           readerElement("img", ["src": picture, "alt": "\"><script>alert(3)</script> ' ` &"])])
        let output = html(raw)
        XCTAssertEqual(output, "<p>&lt;script&gt;alert(1)&lt;/script&gt; &amp; &lt;/p&gt;&lt;img src=x onerror=alert(2)&gt; "
            + "<img src=\"https://news.example/img/lamp.jpg\" alt=\"&quot;&gt;&lt;script&gt;alert(3)&lt;/script&gt; &#39; &#96; &amp;\""
            + " referrerpolicy=\"no-referrer\" decoding=\"async\"></p>")
    }

    func testAnswersThatAreNotATreeGiveNothing() {
        for raw: Any in [NSNull(), 7, true, ["t": 7], ["t": ["p"]], ["c": ["text"]], [[["t": "p", "c": "not a list"]]], ["t": "p", "a": "onclick", "c": [7, NSNull(), ["x": 1]]]] {
            XCTAssertEqual(sanitise(raw).nodes, [])
        }
        XCTAssertEqual(ReaderSanitiser(baseURL: base, images: .none).sanitise(nil).nodes, [])
    }

    func testLimitsStopAHugeOrDeepTree() {
        var deep: Any = "bottom"
        for _ in 0..<2000 { deep = readerElement("blockquote", [:], [deep]) }
        let deepOutput = sanitise(deep)
        XCTAssertTrue(deepOutput.truncated)
        var depth = 0
        var nodes = deepOutput.nodes
        while case .element(let element)? = nodes.first { depth += 1; nodes = element.children }
        XCTAssertLessThanOrEqual(depth, ReaderSanitiser.Limits().maxDepth + 1)

        var sanitiser = ReaderSanitiser(baseURL: base, images: .none)
        sanitiser.limits.maxNodes = 50
        let wide = sanitiser.sanitise(readerElement("div", [:], (0..<500).map { readerElement("p", [:], ["paragraph \($0)"]) }))
        XCTAssertTrue(wide.truncated)
        XCTAssertLessThanOrEqual(wide.nodes.count, 50)

        sanitiser.limits = .init()
        sanitiser.limits.maxTextBytes = 100
        let long = sanitiser.sanitise(readerElement("p", [:], [String(repeating: "x", count: 90), String(repeating: "y", count: 90)]))
        XCTAssertTrue(long.truncated)
        XCTAssertEqual(ReaderHTML.fragment(for: long.nodes), "<p>" + String(repeating: "x", count: 90) + "</p>")
    }

    // MARK: The written page

    private func article(body: [ReaderNode] = [.element(ReaderElement(.p, children: [.text("Body")]))], imagesOff: Bool = false) -> ReaderArticle {
        ReaderArticle(sourceURL: base, title: "</title><script>alert(1)</script>", byline: "<img src=x onerror=alert(2)>",
                      siteName: "\"><script>alert(3)</script>", language: "en-GB", readingMinutes: 4, body: body,
                      imagesWithheld: imagesOff ? 2 : 0, imagesOff: imagesOff)
    }

    func testTheDocumentCarriesItsPolicyBeforeAnythingFromThePage() throws {
        let document = ReaderHTML.document(for: article(), appearance: ReaderAppearance(font: .sans, size: 5, width: .wide, theme: .sepia))
        XCTAssertTrue(document.hasPrefix("<!doctype html><html lang=\"en-GB\" dir=\"ltr\" data-font=\"sans\" data-size=\"5\" data-width=\"wide\" data-theme=\"sepia\">"
            + "<head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src &#39;none&#39;; img-src http: https:; style-src &#39;sha256-"))
        XCTAssertFalse(document.contains("<script"), "page text is never markup")
        XCTAssertTrue(document.contains("<h1>&lt;/title&gt;&lt;script&gt;alert(1)&lt;/script&gt;</h1>"))
        XCTAssertTrue(document.contains("<p class=\"meta\">&lt;img src=x onerror=alert(2)&gt; · 4 min read</p>"))
        XCTAssertTrue(document.contains("<p class=\"site\">\"&gt;&lt;script&gt;alert(3)&lt;/script&gt;</p>"))
        XCTAssertTrue(document.contains("<meta name=\"referrer\" content=\"no-referrer\">"))
        XCTAssertTrue(document.hasSuffix("<article><p>Body</p></article></main></body></html>"))
    }

    func testThePolicyNamesTheStylesheetByItsHashAndNothingElse() throws {
        let policy = ReaderHTML.contentSecurityPolicy(imagesAllowed: true)
        let document = ReaderHTML.document(for: article(), appearance: ReaderAppearance())
        let start = try XCTUnwrap(document.range(of: "<style>")), end = try XCTUnwrap(document.range(of: "</style>"))
        let sheet = String(document[start.upperBound..<end.lowerBound])
        let hash = Data(SHA256.hash(data: Data(sheet.utf8))).base64EncodedString()
        XCTAssertEqual(policy, "default-src 'none'; img-src http: https:; style-src 'sha256-\(hash)'; base-uri 'none'; form-action 'none'")
        XCTAssertFalse(policy.contains("unsafe"))
        XCTAssertFalse(policy.contains("script-src"), "script falls to default-src 'none'")
        XCTAssertFalse(policy.contains("data:"))
        XCTAssertEqual(document.components(separatedBy: "<style").count, 2, "one stylesheet")
        XCTAssertFalse(ReaderHTML.stylesheet.contains("url("), "the sheet loads nothing")
        XCTAssertFalse(ReaderHTML.stylesheet.contains("@import"))
        XCTAssertFalse(ReaderHTML.stylesheet.contains("<"))
    }

    func testWithImagesOffThePolicyAllowsNoImageAndThePageSaysSo() {
        let document = ReaderHTML.document(for: article(imagesOff: true), appearance: ReaderAppearance())
        XCTAssertEqual(ReaderHTML.contentSecurityPolicy(imagesAllowed: false).hasPrefix("default-src 'none'; style-src 'sha256-"), true)
        XCTAssertFalse(document.contains("img-src"))
        XCTAssertTrue(document.contains("<p class=\"note\">Pictures are not shown in the reader in private windows and containers.</p>"))
    }

    func testEveryAppearanceValueHasARuleInTheStylesheet() {
        for font in ReaderAppearance.Font.allCases where font != .serif { XCTAssertTrue(ReaderHTML.stylesheet.contains("html[data-font=\"\(font.rawValue)\"]")) }
        for size in ReaderAppearance.sizeRange { XCTAssertTrue(ReaderHTML.stylesheet.contains("html[data-size=\"\(size)\"]")) }
        for width in ReaderAppearance.Width.allCases where width != .medium { XCTAssertTrue(ReaderHTML.stylesheet.contains("html[data-width=\"\(width.rawValue)\"]")) }
        for theme in ReaderAppearance.Theme.allCases where theme != .light { XCTAssertTrue(ReaderHTML.stylesheet.contains("html[data-theme=\"\(theme.rawValue)\"]")) }
        XCTAssertTrue(ReaderHTML.stylesheet.contains("@media (prefers-color-scheme:dark){html[data-theme=\"auto\"]"), "Auto follows the appearance")
    }
}
