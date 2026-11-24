import XCTest
@testable import ReArc
@testable import SidebarModel

/// The reader's URL rule, its handling of the extraction script's answer, its
/// settings, and the pinned Readability files (docs/FEATURE-SPECS/READER-VIEW.md).
final class ReaderModelTests: XCTestCase {
    private let base = URL(string: "https://news.example/world/story.html?id=7")!

    // MARK: URLs

    func testOnlyWebAddressesResolve() {
        XCTAssertEqual(ReaderURLPolicy.resolve("https://a.example/x?y=1#z", base: base, use: .link), "https://a.example/x?y=1#z")
        XCTAssertEqual(ReaderURLPolicy.resolve("HTTP://A.example/x", base: base, use: .link), "http://A.example/x")
        XCTAssertEqual(ReaderURLPolicy.resolve("../img/a b.png", base: base, use: .image), "https://news.example/img/a%20b.png")
        XCTAssertEqual(ReaderURLPolicy.resolve("  /top\n", base: base, use: .link), "https://news.example/top")
        XCTAssertEqual(ReaderURLPolicy.resolve("//cdn.example/p.jpg", base: base, use: .image), "https://cdn.example/p.jpg")
        // A scheme-looking path is a path on the article's own site, not a scheme.
        XCTAssertEqual(ReaderURLPolicy.resolve("./javascript:alert(1)", base: base, use: .link), "https://news.example/world/javascript:alert(1)")
    }

    func testEveryOtherSchemeIsRefusedForLinksAndImages() {
        let refused = [
            "javascript:alert(1)", "JAVASCRIPT:alert(1)", "jav\tascript:alert(1)", "j\na\rv\tascript:alert(1)", " \u{0B}javascript:alert(1)",
            "data:text/html;base64,PHNjcmlwdD4=", "data:image/png;base64,AAAA", "blob:https://news.example/uuid", "file:///Users/x/secret",
            "chrome://settings/", "chrome-untrusted://x/", "chrome-extension://id/a.html", "devtools://devtools/", "view-source:https://a.example/",
            "about:blank", "about:srcdoc", "rearc://x", "darni://x", "mailto:a@b.example", "tel:1", "sms:1", "ftp://a.example/", "ws://a.example/",
            "wss://a.example/", "filesystem:https://a.example/temporary/x", "intent://x", "x-apple.systempreferences:", "vbscript:x",
            "https://user@a.example/", "https://user:pass@a.example/", "https:///nohost", "http://", "https:\\\\a.example", "\\\\a.example\\share",
            "https://a.example/\u{7F}", String(repeating: "a", count: ReaderURLPolicy.maxLength + 1),
        ]
        for raw in refused {
            XCTAssertNil(ReaderURLPolicy.resolve(raw, base: base, use: .link), raw.debugDescription)
            XCTAssertNil(ReaderURLPolicy.resolve(raw, base: base, use: .image), raw.debugDescription)
        }
    }

    func testWhatResolvesStartsWithItsSchemeAndHasNoMarkupCharacters() {
        for raw in ["https://a.example/\"onmouseover=\"alert(1)", "https://a.example/<script>", "https://a.example/a'b", "/x y\"z", "https://a.example/`x`"] {
            guard let resolved = ReaderURLPolicy.resolve(raw, base: base, use: .link) else { continue }
            XCTAssertTrue(resolved.hasPrefix("https://"), resolved)
            for character in "\"'<>` \\" { XCTAssertFalse(resolved.contains(character), "\(raw) -> \(resolved)") }
        }
    }

    func testNothingResolvesAgainstAPageThatIsNotAWebPage() {
        for page in ["file:///a.html", "data:text/html,x", "about:blank", "chrome://settings"] {
            XCTAssertNil(ReaderURLPolicy.resolve("https://a.example/", base: URL(string: page)!, use: .link), page)
            XCTAssertFalse(ReaderURLPolicy.isReadable(URL(string: page)))
        }
        XCTAssertTrue(ReaderURLPolicy.isReadable(base))
        XCTAssertFalse(ReaderURLPolicy.isReadable(nil))
    }

    func testALinkFromTheReaderMustBeAnOrdinaryWebAddress() {
        XCTAssertTrue(ReaderLinkRule.allows(URL(string: "https://a.example/x")!))
        XCTAssertTrue(ReaderLinkRule.allows(URL(string: "http://a.example/x")!))
        for refused in ["javascript:alert(1)", "data:text/html,x", "file:///etc/passwd", "chrome://settings", "about:blank", "view-source:https://a.example/",
                        "https://user:pw@a.example/", "mailto:a@b.example", "blob:https://a.example/1"] {
            XCTAssertFalse(ReaderLinkRule.allows(URL(string: refused)!), refused)
        }
    }

    func testPrivateWindowsAndContainersLoadNoImages() {
        XCTAssertEqual(ReaderImageRule.mode(isPrivate: false, isContainer: false), .loadedByPage)
        XCTAssertEqual(ReaderImageRule.mode(isPrivate: true, isContainer: false), .off)
        XCTAssertEqual(ReaderImageRule.mode(isPrivate: false, isContainer: true), .off)
        XCTAssertEqual(ReaderImageRule.mode(isPrivate: true, isContainer: true), .off)
    }

    // MARK: The extraction script's answer

    private let paragraph = String(repeating: "The keeper trimmed the wick at dusk and wrote the wind in his ledger. ", count: 4)

    private func answer(_ change: (inout [String: Any]) -> Void = { _ in }) -> String {
        var object: [String: Any] = [
            "ok": true, "title": "  The   Keeper\nof Skerry Light ", "byline": "Marit Halvorsen", "siteName": "The Coastal Review",
            "lang": "en", "dir": "ltr", "loaded": ["https://news.example/img/lamp.jpg"],
            "content": readerElement("div", ["id": "readability-page-1"], [
                readerElement("p", [:], [paragraph]),
                readerElement("img", ["src": "/img/lamp.jpg", "alt": "The lamp"]),
                readerElement("img", ["src": "/img/not-loaded.jpg"]),
                readerElement("script", [:], ["alert(1)"]),
            ]),
        ]
        change(&object)
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    func testAnArticleIsMadeFromAGoodAnswer() throws {
        let article = try ReaderExtraction.article(json: answer(), pageURL: base, images: .loadedByPage)
        XCTAssertEqual(article.title, "The Keeper of Skerry Light")
        XCTAssertEqual(article.byline, "Marit Halvorsen")
        XCTAssertEqual(article.siteName, "The Coastal Review")
        XCTAssertEqual(article.language, "en")
        XCTAssertFalse(article.isRightToLeft)
        XCTAssertEqual(article.sourceURL, base)
        XCTAssertEqual(article.imagesShown, 1)
        XCTAssertEqual(article.imagesWithheld, 1)
        XCTAssertFalse(article.imagesOff)
        XCTAssertEqual(article.wordCount, 56)
        XCTAssertEqual(article.readingMinutes, 1)
        let written = ReaderHTML.fragment(for: article.body)
        XCTAssertTrue(written.hasPrefix("<p>The keeper trimmed"))
        XCTAssertTrue(written.contains("<img src=\"https://news.example/img/lamp.jpg\" alt=\"The lamp\""))
        XCTAssertFalse(written.contains("not-loaded"))
        XCTAssertFalse(written.contains("alert"))
        XCTAssertEqual(ReaderHTML.imageNote(for: article), "1 picture is not shown: the page had not loaded it.")
    }

    func testWithImagesOffNoneIsShownWhateverThePageLoaded() throws {
        let article = try ReaderExtraction.article(json: answer(), pageURL: base, images: .off)
        XCTAssertEqual(article.imagesShown, 0)
        XCTAssertEqual(article.imagesWithheld, 2)
        XCTAssertTrue(article.imagesOff)
        XCTAssertFalse(ReaderHTML.fragment(for: article.body).contains("<img"))
        XCTAssertFalse(ReaderHTML.document(for: article, appearance: ReaderAppearance()).contains("img-src"))
    }

    func testTheLoadedListCannotAdmitAURLThatIsNotAWebAddress() throws {
        let json = answer {
            $0["loaded"] = ["javascript:alert(1)", "data:image/png;base64,AAAA", 7, ["x"], "https://news.example/img/lamp.jpg"]
            $0["content"] = readerElement("div", [:], [
                readerElement("p", [:], [self.paragraph]),
                readerElement("img", ["src": "javascript:alert(1)"]), readerElement("img", ["src": "data:image/png;base64,AAAA"]),
            ])
        }
        let article = try ReaderExtraction.article(json: json, pageURL: base, images: .loadedByPage)
        XCTAssertEqual(article.imagesShown, 0)
        XCTAssertFalse(ReaderHTML.fragment(for: article.body).contains("<img"))
    }

    func testMetadataIsPlainTextWithLimitsAndFallsBackToTheHost() throws {
        let article = try ReaderExtraction.article(json: answer {
            $0["title"] = NSNull()
            $0["byline"] = String(repeating: "b", count: 900)
            $0["siteName"] = ["not", "text"]
            $0["lang"] = "en\"><script>"
            $0["dir"] = "RTL"
        }, pageURL: URL(string: "https://www.news.example/a")!, images: .off)
        XCTAssertEqual(article.title, "news.example")
        XCTAssertEqual(article.siteName, "news.example")
        XCTAssertEqual(article.byline?.count, ReaderExtraction.maxBylineLength)
        XCTAssertNil(article.language)
        XCTAssertTrue(article.isRightToLeft)
        XCTAssertEqual(ReaderExtraction.plain(" a\u{0}\tb \n c ", limit: 10), "a b c")
        XCTAssertNil(ReaderExtraction.plain("  \n ", limit: 10))
        XCTAssertEqual(ReaderExtraction.language("pt-BR"), "pt-BR")
        XCTAssertNil(ReaderExtraction.language("en US"))
    }

    func testAnswersThatAreNotAnArticleThrow() {
        func error(_ json: String, url: URL? = nil) -> ReaderExtractionError? {
            do {
                _ = try ReaderExtraction.article(json: json, pageURL: url ?? base, images: .off)
                return nil
            } catch {
                return error as? ReaderExtractionError
            }
        }
        XCTAssertEqual(error("{\"ok\":false,\"reason\":\"no-article\"}"), .noArticle)
        XCTAssertEqual(error("not json"), .malformed)
        XCTAssertEqual(error("[]"), .malformed)
        XCTAssertEqual(error("{\"ok\":\"yes\"}"), .malformed)
        XCTAssertEqual(error(answer { $0["ok"] = 1 }), .malformed, "1 is not true")
        XCTAssertEqual(error("{\"ok\":true}"), .malformed)
        XCTAssertEqual(error(answer { $0["content"] = readerElement("p", [:], ["too short"]) }), .noArticle)
        XCTAssertEqual(error(answer { $0["content"] = readerElement("script", [:], [self.paragraph]) }), .noArticle, "only script: nothing is left")
        XCTAssertEqual(error(answer(), url: URL(string: "file:///a.html")), .notReadable)
        XCTAssertEqual(error(answer(), url: URL(string: "chrome://settings")), .notReadable)
    }

    func testTheDetectionAnswerIsYesOnlyWhenItSaysSo() {
        XCTAssertTrue(ReaderExtraction.looksLikeArticle(json: "{\"article\":true}"))
        for json in ["{\"article\":false}", "{\"article\":\"true\"}", "{\"article\":1}", "{}", "true", "", "[true]", "{\"article\":null}"] {
            XCTAssertFalse(ReaderExtraction.looksLikeArticle(json: json), json)
        }
    }

    func testReadingTime() {
        XCTAssertEqual(ReaderExtraction.readingMinutes(words: 0), 1)
        XCTAssertEqual(ReaderExtraction.readingMinutes(words: 230), 1)
        XCTAssertEqual(ReaderExtraction.readingMinutes(words: 231), 2)
        XCTAssertEqual(ReaderExtraction.readingMinutes(words: 2300), 10)
        XCTAssertEqual(ReaderExtraction.readingMinutes(words: 0, cjkCharacters: 1500), 3)
        let count = ReaderExtraction.wordCount(of: "one two  three\nfour 灯台の光 다섯")
        XCTAssertEqual(count.words, 4)
        XCTAssertEqual(count.cjk, 6)
    }

    // MARK: Settings

    private func scratchDefaults() -> UserDefaults {
        let name = "darni-reader-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testAppearanceIsKeptAcrossLaunches() {
        let defaults = scratchDefaults()
        XCTAssertEqual(ReaderAppearanceStore(defaults: defaults).load(), ReaderAppearance(), "nothing stored: the defaults")
        XCTAssertEqual(ReaderAppearance(), ReaderAppearance(font: .serif, size: 3, width: .medium, theme: .auto))
        let center = ReaderCenter(defaults: defaults)
        center.appearance.font = .sans
        center.appearance = center.appearance.resized(by: 2)
        center.appearance.width = .wide
        center.appearance.theme = .sepia
        XCTAssertEqual(defaults.string(forKey: "rearc.reader.font"), "sans")
        XCTAssertEqual(defaults.integer(forKey: "rearc.reader.textSize"), 5)
        XCTAssertEqual(defaults.string(forKey: "rearc.reader.width"), "wide")
        XCTAssertEqual(defaults.string(forKey: "rearc.reader.theme"), "sepia")
        XCTAssertEqual(ReaderCenter(defaults: defaults).appearance, ReaderAppearance(font: .sans, size: 5, width: .wide, theme: .sepia))
    }

    func testAValueThisBuildDoesNotKnowReadsAsTheDefaultAndIsLeftAlone() {
        let defaults = scratchDefaults()
        defaults.set("slab", forKey: ReaderAppearanceStore.fontKey)       // a newer build's font
        defaults.set(12, forKey: ReaderAppearanceStore.sizeKey)           // out of this build's range
        defaults.set(7, forKey: ReaderAppearanceStore.widthKey)           // the wrong type
        defaults.set("midnight", forKey: ReaderAppearanceStore.themeKey)
        let center = ReaderCenter(defaults: defaults)
        XCTAssertEqual(center.appearance, ReaderAppearance())
        center.appearance.theme = .dark
        XCTAssertEqual(defaults.string(forKey: ReaderAppearanceStore.themeKey), "dark")
        XCTAssertEqual(defaults.string(forKey: ReaderAppearanceStore.fontKey), "slab", "a setting not changed keeps what the other build stored")
        XCTAssertEqual(defaults.integer(forKey: ReaderAppearanceStore.sizeKey), 12)
    }

    func testTextSizeStaysInItsRange() {
        var appearance = ReaderAppearance()
        for _ in 0..<20 { appearance = appearance.resized(by: 1) }
        XCTAssertEqual(appearance.size, 7)
        XCTAssertFalse(appearance.canGrow)
        for _ in 0..<20 { appearance = appearance.resized(by: -1) }
        XCTAssertEqual(appearance.size, 1)
        XCTAssertFalse(appearance.canShrink)
    }

    // MARK: The pinned Readability files

    func testTheVendoredFilesAreThePinnedOnes() throws {
        for (file, hash) in [(ReaderScripts.readabilityFile, ReaderScripts.readabilitySHA256), (ReaderScripts.readerableFile, ReaderScripts.readerableSHA256)] {
            let url = try XCTUnwrap(ReaderScripts.resourceURL(file), "\(file) is not in the app's resources")
            XCTAssertEqual(ReaderScripts.sha256(try Data(contentsOf: url)), hash, "\(file) is not upstream's file at the pinned revision")
            XCTAssertNoThrow(try ReaderScripts.vendored(file, sha256: hash))
            XCTAssertThrowsError(try ReaderScripts.vendored(file, sha256: String(repeating: "0", count: 64)), "a changed file is not run") {
                XCTAssertEqual($0 as? ReaderScripts.LoadError, .hashMismatch(file))
            }
        }
        XCTAssertThrowsError(try ReaderScripts.vendored("Missing.js", sha256: "")) { XCTAssertEqual($0 as? ReaderScripts.LoadError, .missing("Missing.js")) }
    }

    func testTheRecordNamesTheSameVersionRevisionHashesAndLicence() throws {
        let record = try String(contentsOf: try XCTUnwrap(ReaderScripts.resourceURL("README.md")), encoding: .utf8)
        for expected in [ReaderScripts.upstreamVersion, ReaderScripts.upstreamRevision, ReaderScripts.readabilitySHA256, ReaderScripts.readerableSHA256, "Apache-2.0"] {
            XCTAssertTrue(record.contains(expected), expected)
        }
        let licence = try String(contentsOf: try XCTUnwrap(ReaderScripts.resourceURL("LICENSE.md")), encoding: .utf8)
        XCTAssertTrue(licence.contains("Apache License, Version 2.0"))
    }

    func testTheScriptsWrapUpstreamAndAnswerWithJSONText() throws {
        let extraction = try ReaderScripts.extraction(), detection = try ReaderScripts.detection()
        XCTAssertTrue(extraction.hasPrefix("(function () {\nvar module;\n"))
        XCTAssertTrue(extraction.contains("document.cloneNode(true)"), "Readability works on a copy: the page is not changed")
        XCTAssertTrue(extraction.contains("function Readability(doc, options)"))
        XCTAssertTrue(detection.contains("function isProbablyReaderable("))
        XCTAssertLessThan(extraction.utf8.count, 1024 * 1024, "the engine takes at most 1 MiB of script")
        for script in [extraction, detection] {
            XCTAssertFalse(script.contains("fetch("), "the scripts ask the network for nothing")
            XCTAssertFalse(script.contains("XMLHttpRequest"))
            XCTAssertFalse(script.contains("rearcPostMessage"), "and post no page message")
        }
    }
}
