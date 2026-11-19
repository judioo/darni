import XCTest
@testable import SidebarModel

/// The shell's one place to ask for a site's name (CONTENT-BLOCKING.md §9):
/// what it asks, which answers it trusts (security BL-12), and what it
/// remembers.
final class SiteNamesTests: XCTestCase {
    /// An engine for the tests: Chromium's answers for a handful of names.
    private final class Engine {
        var asked: [String] = []
        var replies: [String: String] = [
            "www.example.co.uk": #"{"host":"example.co.uk","registrable":true,"suffix":false}"#,
            "example.co.uk": #"{"host":"example.co.uk","registrable":true,"suffix":false}"#,
            "a.someone.web.app": #"{"host":"someone.web.app","registrable":true,"suffix":false}"#,
            "web.app": #"{"host":"web.app","registrable":false,"suffix":true}"#,
            "com": #"{"host":"com","registrable":false,"suffix":true}"#,
            "localhost": #"{"host":"localhost","registrable":false,"suffix":false}"#,
            "203.0.113.7": #"{"host":"203.0.113.7","registrable":true,"suffix":false}"#,
        ]

        func names() -> SiteNames {
            SiteNames { [unowned self] host in
                asked.append(host)
                return replies[host]
            }
        }
    }

    func testTheThreeAnswersAndNoAnswer() {
        let engine = Engine()
        let names = engine.names()
        XCTAssertEqual(names.site(of: "www.example.co.uk"), SiteName(name: "example.co.uk", isOneSite: true))
        XCTAssertEqual(names.site(of: "a.someone.web.app"), SiteName(name: "someone.web.app", isOneSite: true), "one tenant of a shared suffix")
        XCTAssertEqual(names.site(of: "203.0.113.7"), SiteName(name: "203.0.113.7", isOneSite: true))
        XCTAssertEqual(names.site(of: "web.app"), SiteName(name: "web.app", isOneSite: false, isSuffix: true))
        XCTAssertEqual(names.site(of: "com"), SiteName(name: "com", isOneSite: false, isSuffix: true))
        XCTAssertEqual(names.site(of: "localhost"), SiteName(name: "localhost", isOneSite: false, isSuffix: false), "no suffix at all")
        XCTAssertNil(names.site(of: "unknown.test"), "the engine has no answer: the caller's own rule holds")
    }

    func testTheNameIsAskedInLowerCaseWithoutATrailingDotAndOnlyWhenItIsAHost() {
        let engine = Engine()
        let names = engine.names()
        XCTAssertEqual(names.site(of: "WWW.Example.CO.UK.")?.name, "example.co.uk")
        XCTAssertEqual(engine.asked, ["www.example.co.uk"])
        for text in ["", "https://example.co.uk", "example.co.uk:443", "example.co.uk/path", "a b.test", "*.example.co.uk", "[::1]", "a..b", "exa$mple.test"] {
            XCTAssertNil(names.site(of: text), text)
        }
        XCTAssertEqual(engine.asked, ["www.example.co.uk"], "nothing but a host reaches the engine")
    }

    /// Security BL-12: some plain-looking names are addresses to the engine
    /// (`1.2` is `1.0.0.2`). An answer about another name than the asked one
    /// would be a key for something the caller never showed.
    func testAnAnswerIsTakenOnlyWhenItIsTheAskedNameOrItsTail() {
        func decode(_ reply: String, _ asked: String) -> SiteName? { SiteNames.decode(reply, asked: asked) }
        XCTAssertNotNil(decode(#"{"host":"example.test","registrable":true}"#, "example.test"))
        XCTAssertNotNil(decode(#"{"host":"example.test","registrable":true}"#, "www.example.test"))
        for (reply, asked) in [
            (#"{"host":"1.0.0.2","registrable":true}"#, "1.2"),
            (#"{"host":"127.0.0.1","registrable":true}"#, "0x7f.1"),
            (#"{"host":"0.0.0.123","registrable":true}"#, "123"),
            (#"{"host":"other.test","registrable":true}"#, "example.test"),
            (#"{"host":"ample.test","registrable":true}"#, "example.test"),
            (#"{"host":"www.example.test","registrable":true}"#, "example.test"),
            (#"{"host":"EXAMPLE.test","registrable":true}"#, "example.test"),
            (#"{"host":"example.test/","registrable":true}"#, "example.test"),
            // Not one site, and yet not the asked name: no such answer exists.
            (#"{"host":"web.app","registrable":false,"suffix":true}"#, "someone.web.app"),
            // One site and a suffix at once.
            (#"{"host":"web.app","registrable":true,"suffix":true}"#, "web.app"),
            (#"{"host":"example.test"}"#, "example.test"),
            ("", "example.test"), ("[]", "example.test"), ("not json", "example.test"),
            (#"{"host":"example.test","registrable":true,"pad":""# + String(repeating: "x", count: 2000) + #""}"#, "example.test"),
        ] {
            XCTAssertNil(decode(reply, asked), "\(asked): \(reply.prefix(60))")
        }
        XCTAssertEqual(decode(#"{"host":"example.test","registrable":true,"new_key":1}"#, "example.test")?.name, "example.test", "a key this build does not know is ignored")
        XCTAssertEqual(decode(#"{"host":"localhost","registrable":false}"#, "localhost"), SiteName(name: "localhost", isOneSite: false), "an engine that does not say is not a suffix")
    }

    /// The answers are hosts of the person's pages: few are kept, the oldest
    /// goes first, and no answer is not remembered (the engine may not be
    /// ready yet).
    func testItRemembersAFewAnswersAndAsksAgainOnlyWhenItHasNone() {
        let engine = Engine()
        let names = engine.names()
        _ = names.site(of: "www.example.co.uk")
        _ = names.site(of: "WWW.example.co.uk")
        XCTAssertEqual(engine.asked.count, 1, "the second time is from memory")
        XCTAssertNil(names.site(of: "later.test"))
        engine.replies["later.test"] = #"{"host":"later.test","registrable":true}"#
        XCTAssertEqual(names.site(of: "later.test")?.name, "later.test", "no answer was not remembered")
        XCTAssertEqual(engine.asked.filter { $0 == "later.test" }.count, 2)

        for index in 0..<(SiteNames.maxRemembered + 40) {
            let host = "site\(index).test"
            engine.replies[host] = #"{"host":"\#(host)","registrable":true}"#
            XCTAssertEqual(names.site(of: host)?.name, host)
        }
        XCTAssertEqual(names.rememberedCount, SiteNames.maxRemembered)
        XCTAssertEqual(SiteNames.maxRemembered, 256)
        let before = engine.asked.count
        _ = names.site(of: "www.example.co.uk")
        XCTAssertEqual(engine.asked.count, before + 1, "the oldest answer went, and is asked again")
        _ = names.site(of: "site\(SiteNames.maxRemembered + 39).test")
        XCTAssertEqual(engine.asked.count, before + 1, "the newest is still there")
    }
}
