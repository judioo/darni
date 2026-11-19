import XCTest
@testable import SidebarModel

/// A boost's scope with the engine's site names (CONTENT-BLOCKING.md §9,
/// security BO-01): a scope that is a public suffix is refused and matches
/// nothing, a new boost is for the page's real site, and without an answer
/// the rules are what they were.
final class BoostScopeSiteNamesTests: XCTestCase {
    /// Chromium's answers for the names these tests use.
    private let names = SiteNames { host in
        let sites = ["someone.web.app", "example.co.uk", "school.edu.au", "club.or.jp", "example.com", "amazonaws.com"]
        let suffixes = ["web.app", "co.uk", "edu.au", "or.jp", "com", "github.io", "blogspot.co.uk"]
        if suffixes.contains(host) { return #"{"host":"\#(host)","registrable":false,"suffix":true}"# }
        if host == "localhost" { return #"{"host":"localhost","registrable":false,"suffix":false}"# }
        if host.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) { return #"{"host":"\#(host)","registrable":true,"suffix":false}"# }
        if let site = sites.first(where: { host == $0 || host.hasSuffix("." + $0) }) { return #"{"host":"\#(site)","registrable":true,"suffix":false}"# }
        // Any other name under a suffix: the suffix and one label more.
        if let suffix = suffixes.first(where: { host.hasSuffix("." + $0) }) {
            let label = host.dropLast(suffix.count + 1).split(separator: ".").last ?? ""
            return #"{"host":"\#(label).\#(suffix)","registrable":true,"suffix":false}"#
        }
        return nil
    }

    private func rule(_ host: String, _ match: BoostHostMatch = .registrable) -> BoostHostRule {
        BoostHostRule(host: host, hostMatch: match)
    }

    // MARK: A scope that is a suffix is refused

    /// A boost from a file names its own scope and can carry a script.
    func testAScopeThatIsAPublicSuffixIsRefusedForEitherKindOfMatch() {
        for suffix in ["web.app", "edu.au", "or.jp", "github.io", "blogspot.co.uk", "co.uk", "com"] {
            XCTAssertFalse(BoostScopeMatcher.validateRule(rule(suffix), names: names), suffix)
            XCTAssertFalse(BoostScopeMatcher.validateRule(rule(suffix, .exact), names: names), "\(suffix), exact")
        }
        // The guess alone lets most of them through: that is the fault.
        XCTAssertTrue(BoostScopeMatcher.validateRule(rule("web.app"), names: nil))
        XCTAssertTrue(BoostScopeMatcher.validateRule(rule("edu.au"), names: nil))
        XCTAssertTrue(BoostScopeMatcher.validateRule(rule("or.jp"), names: nil))
    }

    func testARegistrableRuleMustNameASite() {
        for site in ["someone.web.app", "example.co.uk", "school.edu.au", "club.or.jp", "example.com"] {
            XCTAssertTrue(BoostScopeMatcher.validateRule(rule(site), names: names), site)
        }
        XCTAssertFalse(BoostScopeMatcher.validateRule(rule("www.example.com"), names: names), "a host of a site is not the site")
        XCTAssertTrue(BoostScopeMatcher.validateRule(rule("www.example.com", .exact), names: names))
        XCTAssertFalse(BoostScopeMatcher.validateRule(rule("localhost"), names: names), "a name with no suffix is not a registrable domain")
        XCTAssertTrue(BoostScopeMatcher.validateRule(rule("localhost", .exact), names: names))
        XCTAssertFalse(BoostScopeMatcher.validateRule(rule("203.0.113.7"), names: names), "an address is one host, never a site of hosts")
        XCTAssertTrue(BoostScopeMatcher.validateRule(rule("203.0.113.7", .exact), names: names))
        // The names this build refused before the engine could answer stay refused.
        XCTAssertFalse(BoostScopeMatcher.validateRule(rule("amazonaws.com"), names: names))
        // What the guess got wrong the other way: a real site it took for a host of `edu.au`.
        XCTAssertFalse(BoostScopeMatcher.validateRule(rule("school.edu.au"), names: nil))
    }

    func testWithoutAnAnswerTheRulesAreTheGuessAsBefore() {
        XCTAssertTrue(BoostScopeMatcher.validateRule(rule("example.com"), names: nil))
        XCTAssertFalse(BoostScopeMatcher.validateRule(rule("github.io"), names: nil))
        XCTAssertFalse(BoostScopeMatcher.validateRule(rule("com"), names: nil))
        XCTAssertFalse(BoostScopeMatcher.validateRule(rule("www.example.com"), names: nil))
        XCTAssertTrue(BoostScopeMatcher.validateRule(rule("unknown.test"), names: names), "a name the engine has no answer for")
        XCTAssertTrue(BoostScopeMatcher.matches(rule: rule("unknown.test"), url: URL(string: "https://www.unknown.test/")!, names: names))
        XCTAssertEqual(BoostScopeMatcher.defaultRule(forPage: URL(string: "https://www.unknown.test/")!, names: names), rule("unknown.test"))
    }

    // MARK: A new boost is for the page's site

    func testANewBoostIsForThePagesRealSite() {
        func scope(_ page: String) -> BoostHostRule? { BoostScopeMatcher.defaultRule(forPage: URL(string: page)!, names: names) }
        XCTAssertEqual(scope("https://someone.web.app/x"), rule("someone.web.app"))
        XCTAssertEqual(scope("https://www.school.edu.au/"), rule("school.edu.au"))
        XCTAssertEqual(scope("https://shop.example.co.uk/"), rule("example.co.uk"))
        XCTAssertEqual(scope("http://203.0.113.7/"), BoostHostRule(host: "203.0.113.7", hostMatch: .exact, schemes: ["http"]))
        XCTAssertNil(scope("https://github.io/"), "a page on a suffix itself: a suffix is never a scope")
        XCTAssertNil(scope("http://localhost/"), "no boost on a name with no suffix, as before")
        // The guess: all of web.app, and all of edu.au.
        XCTAssertEqual(BoostScopeMatcher.defaultRule(forPage: URL(string: "https://someone.web.app/x")!, names: nil), rule("web.app"))
        XCTAssertEqual(BoostScopeMatcher.defaultRule(forPage: URL(string: "https://www.school.edu.au/")!, names: nil), rule("edu.au"))
        for page in ["https://someone.web.app/x", "https://www.school.edu.au/", "https://shop.example.co.uk/", "http://203.0.113.7/"] {
            let made = scope(page)
            XCTAssertTrue(made.map { BoostScopeMatcher.validateRule($0, names: names) } ?? false, "\(page): the scope a new boost gets is a valid one")
            XCTAssertTrue(made.map { BoostScopeMatcher.matches(rule: $0, url: URL(string: page)!, names: names) } ?? false, "\(page): and it matches its own page")
        }
    }

    // MARK: Matching

    /// A boost already scoped to a suffix by the old guess stops running on
    /// every site under it. That narrows it without asking, which is the
    /// safe direction.
    func testARuleMatchesOnlyPagesOfItsRealSite() {
        func matches(_ scope: String, _ page: String, _ names: SiteNames?) -> Bool {
            BoostScopeMatcher.matches(rule: rule(scope), url: URL(string: page)!, names: names)
        }
        XCTAssertTrue(matches("web.app", "https://someone.web.app/", nil), "the guess: one boost, every site under web.app")
        XCTAssertTrue(matches("web.app", "https://another.web.app/", nil))
        XCTAssertFalse(matches("web.app", "https://someone.web.app/", names))
        XCTAssertFalse(matches("web.app", "https://another.web.app/", names))
        XCTAssertFalse(matches("web.app", "https://web.app/", names), "nor the suffix's own page: it is not one site")
        XCTAssertTrue(matches("someone.web.app", "https://someone.web.app/", names))
        XCTAssertTrue(matches("someone.web.app", "https://a.someone.web.app/", names))
        XCTAssertFalse(matches("someone.web.app", "https://another.web.app/", names))
        XCTAssertTrue(matches("example.co.uk", "https://www.example.co.uk/", names))
        XCTAssertFalse(matches("edu.au", "https://www.school.edu.au/", names))
        XCTAssertTrue(matches("school.edu.au", "https://www.school.edu.au/", names))
        // A suffix scope matches nothing even where the engine has no answer for the page.
        XCTAssertFalse(matches("or.jp", "https://unknown.or.jp.invalid-answer/", names))
        let silentAboutPages = SiteNames { $0 == "web.app" ? #"{"host":"web.app","registrable":false,"suffix":true}"# : nil }
        XCTAssertFalse(matches("web.app", "https://someone.web.app/", silentAboutPages))
        // Exact rules and addresses do not ask.
        XCTAssertTrue(BoostScopeMatcher.matches(rule: rule("www.example.com", .exact), url: URL(string: "https://www.example.com/")!, names: names))
        XCTAssertFalse(BoostScopeMatcher.matches(rule: rule("www.example.com", .exact), url: URL(string: "https://example.com/")!, names: names))
        XCTAssertTrue(BoostScopeMatcher.matches(scope: [rule("other.test"), rule("example.com")], url: URL(string: "https://m.example.com/")!, names: names))
    }

    /// An installed boost whose scope is a suffix is not active: the same
    /// check that refuses it from a file leaves it out of what runs.
    func testAnInstalledBoostScopedToASuffixIsNoLongerValid() {
        XCTAssertFalse(BoostScopeMatcher.validateRule(rule("or.jp"), names: names))
        XCTAssertTrue(BoostScopeMatcher.validateRule(rule("club.or.jp"), names: names))
    }

    // MARK: The library's row

    /// A boost whose scope is refused stays as the person left it and does
    /// not run. Its row says so, and why.
    func testABoostWhoseScopeIsRefusedSaysSoOnItsRow() {
        XCTAssertNil(BoostLibraryListing.scopeNote([rule("example.com")], names: names))
        XCTAssertNil(BoostLibraryListing.scopeNote([], names: names))
        XCTAssertEqual(BoostLibraryListing.scopeNote([rule("example.com"), rule("web.app")], names: names),
                       "Not running: web.app is shared by many unrelated sites. Make this boost again on the one site it is for.")
        XCTAssertEqual(BoostLibraryListing.scopeNote([rule("www.example.com")], names: names),
                       "Not running: www.example.com is not a site a boost can be for. Make this boost again on the site it is for.")
        // Without the engine's list the guess takes web.app for a site: no line, and the boost runs as before.
        XCTAssertNil(BoostLibraryListing.scopeNote([rule("web.app")], names: nil))
    }

    /// The scope comes from a file or from sync. Text that is not a plain
    /// host never goes into ReArc's own warning, and a long one is cut.
    func testTheRowsNoteNamesOnlyAPlainHost() {
        let other = "Not running: its scope is not a site a boost can be for. Make this boost again on the site it is for."
        // Each is refused as a site rule (three labels are no registrable domain to the guess) and is not a plain host.
        for text in ["www.evil.test\nReArc update required", "www.evil.test\u{202E}gpj.exe", "www.a b.test", "<b>x</b>.evil.test", "www.evil.test ",
                     "www.ex\u{0430}mple.test", "www.*.test"] {
            XCTAssertFalse(BoostScopeMatcher.validateRule(rule(text), names: names), text.debugDescription)
            XCTAssertEqual(BoostLibraryListing.scopeNote([rule(text)], names: names), other, text.debugDescription)
        }
        // A suffix with a trailing dot is still a suffix to the engine, and still not a plain host here.
        XCTAssertEqual(BoostLibraryListing.scopeNote([rule("web.app.")], names: names),
                       "Not running: its scope is shared by many unrelated sites. Make this boost again on the one site it is for.")
        let long = "www.\(String(repeating: "a", count: 60)).example.com"
        let note = BoostLibraryListing.scopeNote([rule(long)], names: names)
        XCTAssertEqual(note, "Not running: …example.com is not a site a boost can be for. Make this boost again on the site it is for.")
        XCTAssertFalse(note?.contains(String(repeating: "a", count: 41)) ?? true)
    }

    // MARK: A rule stored with an international name (security BO-02)

    /// What holds today, before anything about such rules is tightened.
    ///
    /// A page's address comes from the engine with its host in ASCII form
    /// (`xn--…`). A rule stored in Unicode form therefore matches no page,
    /// and one in ASCII form matches: requiring a plain ASCII host of a rule
    /// that comes in would stop no boost that runs now.
    func testARuleStoredInUnicodeFormMatchesNoPageToday() throws {
        let page = try XCTUnwrap(URL(string: "https://www.xn--bcher-kva.example/a"))
        let unicode = rule("b\u{FC}cher.example"), ascii = rule("xn--bcher-kva.example")
        for names in [nil, self.names] as [SiteNames?] {
            XCTAssertFalse(BoostScopeMatcher.matches(rule: unicode, url: page, names: names))
            XCTAssertTrue(BoostScopeMatcher.matches(rule: ascii, url: page, names: names))
        }
        // The rule check takes both today, and a new boost on the page gets the ASCII form.
        XCTAssertTrue(BoostScopeMatcher.validateRule(unicode, names: nil))
        XCTAssertTrue(BoostScopeMatcher.validateRule(ascii, names: nil))
        XCTAssertEqual(BoostScopeMatcher.defaultRule(forPage: page, names: nil)?.host, "xn--bcher-kva.example")
        XCTAssertEqual(ContentBlockingHost.normalized("b\u{FC}cher.example"), "xn--bcher-kva.example", "what a rule that comes in would be stored as")
    }

    /// A site typed with an international name is a third form. Foundation
    /// gives a URL made from such text a percent-encoded host, neither the
    /// Unicode nor the ASCII form, and that is what the library stores as
    /// the new boost's scope. It matches no page: a fault that is there
    /// today, and the same normalising would mend it.
    func testASiteTypedWithAnInternationalNameGetsAScopeThatMatchesNothingToday() throws {
        let typed = try XCTUnwrap(BoostLibraryListing.siteURL(from: "b\u{FC}cher.example"))
        XCTAssertEqual(typed.host()?.lowercased(), "b%c3%bccher.example")
        let scope = try XCTUnwrap(BoostScopeMatcher.defaultRule(forPage: typed, names: nil))
        XCTAssertEqual(scope.host, "b%c3%bccher.example")
        let page = try XCTUnwrap(URL(string: "https://xn--bcher-kva.example/"))
        XCTAssertFalse(BoostScopeMatcher.matches(rule: scope, url: page, names: nil))
        XCTAssertFalse(ContentBlockingHost.isHost(scope.host), "not a plain host: a rule check that asked for one would refuse it")
    }
}
