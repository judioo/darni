import XCTest
@testable import ReArc
@testable import SidebarModel

/// The two ends of scripts/check-reader-engine.sh, which runs the reader's
/// page scripts in a real Chromium with nothing on screen. Both tests are
/// skipped in an ordinary `swift test`.
final class ReaderEngineAnswerTests: XCTestCase {
    /// Writes the real scripts and the fixture pages for the engine check to serve and run.
    func testWriteTheScriptsAndFixturesForTheEngineCheck() throws {
        guard let path = ProcessInfo.processInfo.environment["DARNI_READER_DUMP_DIR"] else {
            throw XCTSkip("only for scripts/check-reader-engine.sh")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(try ReaderScripts.detection().utf8).write(to: directory.appendingPathComponent("detection.js"))
        try Data(try ReaderScripts.extraction().utf8).write(to: directory.appendingPathComponent("extraction.js"))
        try Data(SelfTestReaderFixture.articleHTML.utf8).write(to: directory.appendingPathComponent("article.html"))
        try Data(SelfTestReaderFixture.plainHTML.utf8).write(to: directory.appendingPathComponent("plain.html"))
        try Data(SelfTestReaderFixture.hostileHTML.utf8).write(to: directory.appendingPathComponent("hostile.html"))
        try SelfTestReaderFixture.picturePNG.write(to: directory.appendingPathComponent("picture.png"))
    }

    /// What Chromium answered goes through the same checks as any answer, and gives the same reader.
    func testAnswersFromTheEngineGiveTheSameReader() throws {
        guard let path = ProcessInfo.processInfo.environment["DARNI_READER_ENGINE_ANSWERS"] else {
            throw XCTSkip("only for scripts/check-reader-engine.sh")
        }
        func answer(_ name: String) throws -> (url: URL, json: String) {
            let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent(name))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
            return (try XCTUnwrap(URL(string: try XCTUnwrap(object["url"]))), try XCTUnwrap(object["answer"]))
        }
        let good = try answer("article.json")
        let article = try ReaderExtraction.article(json: good.json, pageURL: good.url, images: .loadedByPage)
        XCTAssertEqual(article.title, SelfTestReaderFixture.articleTitle)
        XCTAssertEqual(article.byline, SelfTestReaderFixture.articleByline)
        XCTAssertEqual(article.siteName, SelfTestReaderFixture.articleSite)
        XCTAssertEqual(article.readingMinutes, 2)
        XCTAssertEqual(article.imagesShown, 1)
        XCTAssertEqual(article.imagesWithheld, 0)
        let body = ReaderHTML.fragment(for: article.body)
        let origin = "\(good.url.scheme!)://\(good.url.host!):\(good.url.port!)"
        for expected in ["<h2>The inspector</h2>", "<blockquote><p>A light that is noticed has usually failed.</p></blockquote>",
                         "<li>Wicks trimmed at dusk</li>", "<th>Nights of fog</th>", "<td>42</td>", "<code>wind: W light\nvisibility: good</code>",
                         "<img src=\"\(origin)\(SelfTestReaderFixture.picturePath)\" alt=\"The lamp room\" width=\"16\" height=\"16\"",
                         "<a href=\"\(origin)\(SelfTestReaderFixture.plainPath)\" rel=\"noreferrer noopener\">the archive</a>"] {
            XCTAssertTrue(body.contains(expected), "missing \(expected) in \(body)")
        }
        XCTAssertFalse(body.contains("Copyright"))

        let bad = try answer("hostile.json")
        let hostile = try ReaderExtraction.article(json: bad.json, pageURL: bad.url, images: .loadedByPage)
        let written = ReaderHTML.fragment(for: hostile.body)
        XCTAssertTrue(written.contains(SelfTestReaderFixture.hostileMarker))
        XCTAssertTrue(written.contains("a javascript link"))
        for forbidden in ["<script", "onerror", "onclick", "onload", "javascript:", "srcset", "<svg", "<iframe", "<form", "<style", "beacon", "="] {
            XCTAssertFalse(written.contains(forbidden), "the article as written has \(forbidden): \(written)")
        }
        for node in hostile.body {
            node.forEachElement { element in
                XCTAssertNil(element.href, "a link of the hostile page came across")
                XCTAssertNil(element.src, "a picture of the hostile page came across")
            }
        }
        XCTAssertFalse(ReaderHTML.document(for: hostile, appearance: ReaderAppearance()).contains("<script"))
    }
}
