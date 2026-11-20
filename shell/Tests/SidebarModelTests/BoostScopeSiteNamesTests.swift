import XCTest
@testable import SidebarModel

/// A boost's scope with the engine's site names (CONTENT-BLOCKING.md §9,
/// security BO-01): a scope that is a public suffix is refused and matches
/// nothing, a new boost is for the page's real site, and without an answer
/// the rules are what they were.
final class BoostScopeSiteNamesTests: XCTestCase {
    /// Chromium's answers for the names these tests use.
    private let names = SiteNames.standIn(
        suffixes: ["web.app", "co.uk", "edu.au", "or.jp", "com", "github.io", "blogspot.co.uk"],
        sites: ["someone.web.app", "example.co.uk", "school.edu.au", "club.or.jp", "example.com", "amazonaws.com"],
        unsuffixed: ["localhost"], addresses: true)

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

    /// A site typed with an international name was a third form: Foundation
    /// gives a URL made from such text a percent-encoded host, neither the
    /// Unicode nor the ASCII form, and that was stored as the new boost's
    /// scope and matched no page. The library now takes the host in the form
    /// a page's host has.
    func testASiteTypedWithAnInternationalNameGetsAScopeThatMatchesItsPages() throws {
        let typed = try XCTUnwrap(BoostLibraryListing.siteURL(from: "B\u{FC}cher.example"))
        XCTAssertEqual(typed.absoluteString, "https://xn--bcher-kva.example/")
        let scope = try XCTUnwrap(BoostScopeMatcher.defaultRule(forPage: typed, names: nil))
        XCTAssertEqual(scope.host, "xn--bcher-kva.example")
        XCTAssertTrue(BoostScopeMatcher.matches(rule: scope, url: try XCTUnwrap(URL(string: "https://www.xn--bcher-kva.example/a")), names: nil))
        // What the library took before is still taken, and what it refused is still refused.
        XCTAssertEqual(BoostLibraryListing.siteURL(from: "github.com")?.absoluteString, "https://github.com/")
        XCTAssertEqual(BoostLibraryListing.siteURL(from: " https://X.com/a?b ")?.absoluteString, "https://x.com/")
        for refused in ["", "localhost", "two words.test", "exa$mple.test", "http://[::1]/"] {
            XCTAssertNil(BoostLibraryListing.siteURL(from: refused), refused)
        }
    }

    // MARK: A rule that comes in (security BO-02)

    func testARuleThatComesInIsAPlainHostInAsciiFormOrNothing() {
        XCTAssertEqual(BoostScopeMatcher.incomingRule(rule("b\u{FC}cher.example"))?.host, "xn--bcher-kva.example")
        XCTAssertEqual(BoostScopeMatcher.incomingRule(rule("www.example.com", .exact)), rule("www.example.com", .exact), "an exact host keeps its www.")
        XCTAssertEqual(BoostScopeMatcher.incomingRule(rule("203.0.113.7", .exact))?.host, "203.0.113.7")
        let path = BoostHostRule(host: "Example.com", hostMatch: .registrable, pathPrefix: "/a", schemes: ["http"])
        XCTAssertEqual(BoostScopeMatcher.incomingRule(path), BoostHostRule(host: "example.com", hostMatch: .registrable, pathPrefix: "/a", schemes: ["http"]))
        XCTAssertEqual(BoostScopeMatcher.incomingRule(rule(" evil.test "))?.host, "evil.test", "space around a name is not part of it")
        for text in ["evil.test\nDarni update required", "evil.test\u{202E}gpj.exe", "a b.test", "*.test", "exa%6dple.test", "a.test:80", "a.test/x", ""] {
            XCTAssertNil(BoostScopeMatcher.incomingRule(rule(text)), text.debugDescription)
        }
    }

    /// A boost file: its rules are stored in ASCII form, and a file with a
    /// rule that is not a plain host is refused whole.
    func testABoostFilesRulesAreTakenInAsPlainHosts() throws {
        func file(_ host: String) throws -> Data {
            try BoostInterchange.exportJSON(BoostPackage.newStyle(name: "Tidy", hostScope: [rule(host)], css: "p { color: red; }"))
        }
        guard case .success(let taken) = BoostInterchange.importJSON(try file("b\u{FC}cher.example")) else { return XCTFail("an international name is taken") }
        XCTAssertEqual(taken.manifest.hostScope.map(\.host), ["xn--bcher-kva.example"])
        XCTAssertTrue(BoostScopeMatcher.matches(scope: taken.manifest.hostScope, url: try XCTUnwrap(URL(string: "https://xn--bcher-kva.example/")), names: nil))
        guard case .success(let plain) = BoostInterchange.importJSON(try file("example.com")) else { return XCTFail("a plain host is taken") }
        XCTAssertEqual(plain.manifest.hostScope.map(\.host), ["example.com"])
        for text in ["evil.test\nDarni update required", "evil.test\u{202E}gpj.exe", "a b.test"] {
            XCTAssertEqual(BoostInterchange.importJSON(try file(text)), .failure(.validationFailed([.invalidHostRule])), text.debugDescription)
        }
    }

    /// A rule that is already stored is left as it is, whatever its text,
    /// so no installed boost is dropped. Its lines in the library and in
    /// the approval sheets show it cleaned.
    func testAStoredRulesHostIsShownCleaned() {
        XCTAssertEqual(BoostLibraryListing.displayHost("example.com"), "example.com")
        XCTAssertEqual(BoostLibraryListing.displayHost("evil.test\nDarni update required"), "evil.test Darni update required")
        XCTAssertEqual(BoostLibraryListing.displayHost("evil.test\u{202E}gpj.exe"), "evil.testgpj.exe")
        XCTAssertEqual(BoostLibraryListing.displayHost("a\u{200B}b.test   x"), "ab.test x")
        let long = BoostLibraryListing.displayHost(String(repeating: "word ", count: 40))
        XCTAssertLessThanOrEqual(long.count, 60)
        let host = "www.\(String(repeating: "a", count: 60)).example.com"
        XCTAssertEqual(BoostLibraryListing.displayHost(host), "…\(String(repeating: "a", count: 60)).example.com",
                       "a plain host is cut from the left, its site and the label before it kept")
        XCTAssertEqual(BoostLibraryListing.describe(rule("evil.test\nx")), "evil.test x and subdomains, https")
        XCTAssertEqual(BoostLibraryListing.summary(["evil.test\nx", "b.test"]), "evil.test x and 1 more")
        XCTAssertEqual(BoostLibraryListing.summary([]), "No sites")
        // The stored rule itself still passes the rule check, as before.
        XCTAssertTrue(BoostScopeMatcher.validateRule(rule("evil.test\nx"), names: nil))
    }

    // MARK: A file's script boost scoped to a suffix is switched off (security BO-01)

    func testAFilesScriptBoostScopedToASuffixIsSwitchedOffAndOthersAreLeft() throws {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        func add(_ name: String, _ host: String, script: Bool, imported: Bool) throws -> UUID {
            var package = script
                ? BoostPackage.newScript(name: name, hostScope: [rule(host)], js: "document.title = 'x';", css: "")
                : BoostPackage.newStyle(name: name, hostScope: [rule(host)], css: "p { color: red; }")
            package.provenance = BoostProvenance(imported: imported)
            XCTAssertNil(store.addBoost(package, enabled: true), name)
            return package.manifest.id
        }
        let fileScriptSuffix = try add("From a file", "web.app", script: true, imported: true)
        let ownScriptSuffix = try add("My own", "web.app", script: true, imported: false)
        let fileStyleSuffix = try add("Style from a file", "web.app", script: false, imported: true)
        let fileScriptSite = try add("File, one site", "example.com", script: true, imported: true)
        func isOn(_ id: UUID) -> Bool { store.boostLibrary().installation(for: id)?.enabled == true }

        XCTAssertEqual(store.switchOffFileScriptBoostsScopedToASuffix(names: nil), [], "without the engine's list nothing is touched")
        XCTAssertTrue(isOn(fileScriptSuffix))

        XCTAssertEqual(store.switchOffFileScriptBoostsScopedToASuffix(names: names), ["From a file"])
        XCTAssertFalse(isOn(fileScriptSuffix), "not the person's code, and it ran on every site under web.app")
        XCTAssertTrue(isOn(ownScriptSuffix), "the person's own boost keeps its switch, and its row says it is not running")
        XCTAssertTrue(isOn(fileStyleSuffix), "no script")
        XCTAssertTrue(isOn(fileScriptSite), "one site")
        XCTAssertEqual(store.switchOffFileScriptBoostsScopedToASuffix(names: names), [], "nothing left to switch off")

        // Switched on again, it goes off at the next launch for as long as its scope is a suffix.
        store.setBoostInstallationEnabled(packageID: fileScriptSuffix, enabled: true)
        XCTAssertEqual(store.switchOffFileScriptBoostsScopedToASuffix(names: names), ["From a file"])
    }
}
