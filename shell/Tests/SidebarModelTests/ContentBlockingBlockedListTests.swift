import XCTest
@testable import SidebarModel

/// "Blocked on this page" (CONTENT-BLOCKING.md §3): reading the engine's
/// reply as a stranger's, the cap, the tags, and the one own rule that
/// allows a host on a site.
final class ContentBlockingBlockedListTests: XCTestCase {
    private typealias List = ContentBlockingBlockedList
    private let lists = ContentBlockingLists.known

    private func json(_ hosts: [(String, Int, [String])], more: Int? = nil) -> String {
        let entries = hosts.map { host, count, lists in
            #"{"host":"\#(host)","count":\#(count),"registrable":true,"lists":[\#(lists.map { "\"\($0)\"" }.joined(separator: ","))]}"#
        }
        return #"{"hosts":[\#(entries.joined(separator: ","))]\#(more.map { #","more":\#($0)"# } ?? "")}"#
    }

    // MARK: The reply

    func testTheListIsMostBlockedFirstThenByNameWithATagFromEachList() throws {
        let list = try XCTUnwrap(List.decode(json([
            ("google-analytics.com", 1, ["easyprivacy"]),
            ("doubleclick.net", 3, ["easylist"]),
            ("adnxs.com", 1, ["peter-lowe", "easylist"]),
            ("cookie-banner.test", 1, ["easylist-cookie"]),
            ("mine.test", 2, ["_dynamic"]),
        ]), lists: lists))
        XCTAssertEqual(list.entries, [
            .init(host: "doubleclick.net", count: 3, kinds: [.ad]),
            .init(host: "mine.test", count: 2, kinds: [.ownRule]),
            .init(host: "adnxs.com", count: 1, kinds: [.ad, .tracker]),
            .init(host: "cookie-banner.test", count: 1, kinds: [.annoyance]),
            .init(host: "google-analytics.com", count: 1, kinds: [.tracker]),
        ])
        XCTAssertEqual(list.uncounted, 0)
        XCTAssertNil(list.uncountedText)
        XCTAssertEqual(list.entries[2].tagText, "Ad, Tracker")
        XCTAssertEqual(list.entries[2].spokenText, "adnxs.com, Ad, Tracker, 1 blocked")
        XCTAssertEqual(List.decode(#"{"hosts":[],"more":0}"#, lists: lists), List())
        XCTAssertTrue(List().isEmpty)
    }

    /// EasyList → Ad, EasyPrivacy → Tracker: by the level of the list in the
    /// bundle's signed manifest, then by this build's table.
    func testATagIsTheLevelOfTheListThatBlocked() {
        XCTAssertEqual(List.kind(ofList: "easyprivacy", in: lists), .tracker)
        XCTAssertEqual(List.kind(ofList: "peter-lowe", in: lists), .tracker)
        XCTAssertEqual(List.kind(ofList: "easylist", in: lists), .ad)
        XCTAssertEqual(List.kind(ofList: "easylist-germany", in: lists), .ad, "a regional list is an ad list")
        XCTAssertEqual(List.kind(ofList: "fanboy-annoyance", in: lists), .annoyance)
        XCTAssertEqual(List.kind(ofList: "_dynamic", in: lists), .ownRule)
        XCTAssertNil(List.kind(ofList: "from-the-future", in: lists))
        XCTAssertNil(List.kind(ofList: "../easylist", in: lists), "not a list ID")
        // A list the mirror added after this build: the bundle says what level it is.
        let bundle = lists + [ContentBlockingList(id: "from-the-future", title: "New", level: .trackersOnly)]
        XCTAssertEqual(List.kind(ofList: "from-the-future", in: bundle), .tracker)
        // The bundle moved a list this build knows: the signed manifest wins.
        let moved = [ContentBlockingList(id: "easylist", title: "EasyList", level: .strict)]
        XCTAssertEqual(List.kind(ofList: "easylist", in: moved), .annoyance)
        XCTAssertEqual(List.decode(json([("x.test", 1, ["from-the-future"])]), lists: lists)?.entries, [.init(host: "x.test", count: 1, kinds: [])],
                       "a site blocked by a list nobody can name is still listed, without a tag")
    }

    /// A page chooses the hosts it asks for: nothing but a host gets through.
    func testANameThatIsNoHostIsLeftOutAndOnlyCounted() throws {
        let list = try XCTUnwrap(List.decode(#"""
        {"hosts":[{"host":"ok.test","count":2,"registrable":true,"lists":["easylist"]},
                  {"host":"evil.test^$important","count":4,"lists":["easylist"]},
                  {"host":"UPPER.test","count":1},
                  {"host":"a b.test","count":1},
                  {"host":"line\nbreak.test","count":1},
                  {"host":"","count":1},
                  {"host":"zero.test","count":0},
                  {"host":"minus.test","count":-5},
                  {"host":"ok.test","count":1,"registrable":true,"lists":["easyprivacy","easylist"]}],
         "more":-3}
        """#, lists: lists))
        XCTAssertEqual(list.entries, [.init(host: "ok.test", count: 3, kinds: [.ad, .tracker])], "the same site twice is one line")
        XCTAssertEqual(list.uncounted, 8, "what was left out is still counted")
        XCTAssertEqual(list.uncountedText, "and 8 more requests")
        XCTAssertEqual(List(uncounted: 1).uncountedText, "and 1 more request")
    }

    func testAReplyThatIsNotTheListIsNoList() {
        for reply in ["", "[]", "{}", #"{"hosts":"x"}"#, #"{"hosts":[{"host":1,"count":1}]}"#, #"{"hosts":[{"host":"a.test"}]}"#, "not json"] {
            XCTAssertNil(List.decode(reply, lists: lists), reply)
        }
        XCTAssertNotNil(List.decode(#"{"hosts":[{"host":"a.test","count":1}],"new_key":true}"#, lists: lists), "a key this build does not know is ignored")
    }

    // MARK: The cap

    func testOnePageHoldsAtMostAHundredSitesAndCountsTheRest() throws {
        let hosts = (0..<150).map { ("site\($0).test", $0 < 5 ? 10 : 1, ["easylist"]) }
        let list = try XCTUnwrap(List.decode(json(hosts, more: 7), lists: lists))
        XCTAssertEqual(list.entries.count, List.maxEntries)
        XCTAssertEqual(list.entries.count, 100)
        XCTAssertEqual(list.entries.prefix(5).map(\.count), [10, 10, 10, 10, 10], "the most blocked are the ones kept")
        XCTAssertEqual(list.uncounted, 7 + 50, "the engine's own remainder and what this cut")
        XCTAssertEqual(list.entries.reduce(0) { $0 + $1.count } + list.uncounted, 5 * 10 + 145 + 7, "no blocked request is lost from the total")
    }

    func testAReplyOverTheSizeLimitIsNotRead() {
        let long = (0..<3000).map { ("a-long-enough-name-number-\($0).test", 1, ["easylist"]) }
        let reply = json(long)
        XCTAssertGreaterThan(reply.utf8.count, List.maxReplyBytes)
        XCTAssertNil(List.decode(reply, lists: lists))
        // The engine's largest honest reply fits: a hundred names of the longest length a host has.
        let label = String(repeating: "a", count: 63)
        let longest = (0..<100).map { index in
            (([String(format: "%03d", index) + String(repeating: "b", count: 58)] + Array(repeating: label, count: 3)).joined(separator: "."), 1_000_000,
             ["easylist", "easyprivacy", "peter-lowe", "fanboy-annoyance", "easylist-cookie", "_dynamic"])
        }
        XCTAssertEqual(longest[0].0.utf8.count, 253)
        let full = json(longest, more: 1_000_000)
        XCTAssertLessThanOrEqual(full.utf8.count, List.maxReplyBytes)
        XCTAssertEqual(List.decode(full, lists: lists)?.entries.count, 100)
    }

    func testANumberIsCutToWhatAPageCanReach() throws {
        let list = try XCTUnwrap(List.decode(#"{"hosts":[{"host":"a.test","count":9223372036854775807},{"host":"a.test","count":5}],"more":9223372036854775807}"#, lists: lists))
        XCTAssertEqual(list.entries.map(\.count), [1_000_000])
        XCTAssertEqual(list.uncounted, 1_000_000)
    }

    // MARK: Which lines have Allow (security BL-02)

    /// The engine says whether a name is one site, from Chromium's suffix
    /// list. This build must agree before a line gets Allow: a rule for a
    /// single label or a public suffix would allow every name under it.
    func testALineHasAllowOnlyWhenItsNameIsOneSite() throws {
        let list = try XCTUnwrap(List.decode(#"""
        {"hosts":[{"host":"doubleclick.net","count":9,"registrable":true},
                  {"host":"someone.github.io","count":8,"registrable":true},
                  {"host":"203.0.113.7","count":7,"registrable":true},
                  {"host":"co.uk","count":6,"registrable":false},
                  {"host":"localhost","count":5,"registrable":false},
                  {"host":"edu.au","count":4,"registrable":false},
                  {"host":"old-engine.test","count":3},
                  {"host":"localhost.","count":2,"registrable":true},
                  {"host":"com","count":2,"registrable":true},
                  {"host":"co.uk","count":1,"registrable":true},
                  {"host":"github.io","count":1,"registrable":true}]}
        """#, lists: lists))
        XCTAssertEqual(list.entries.filter(\.canBeAllowed).map(\.host), ["doubleclick.net", "someone.github.io", "203.0.113.7"])
        XCTAssertEqual(list.entries.map(\.host), ["doubleclick.net", "someone.github.io", "203.0.113.7", "co.uk", "localhost", "edu.au", "old-engine.test",
                                                  "com", "github.io"], "a name without Allow is still listed")
        XCTAssertEqual(list.entries.first { $0.host == "co.uk" }?.count, 7, "once the engine said no, a second entry cannot say yes")

        for host in ["doubleclick.net", "a.b.news.test", "someone.github.io", "203.0.113.7", "127.0.0.1", "example.co.uk", "xn--bcher-kva.example"] {
            XCTAssertTrue(ContentBlockingSiteAllow.isOneSite(host), host)
        }
        for host in ["localhost", "com", "wiki", "co.uk", "com.au", "github.io", "cloudfront.net", "", "a b.test", "A.test", "[::1]", "a.test."] {
            XCTAssertFalse(ContentBlockingSiteAllow.isOneSite(host), host)
        }
    }

    // MARK: One site by the engine's list (security BL-02, consistency review 7)

    /// Chromium's answers for the names of these tests.
    private let engineNames = SiteNames { host in
        let suffixes = ["web.app", "edu.au", "co.uk", "com"]
        if suffixes.contains(host) { return #"{"host":"\#(host)","registrable":false,"suffix":true}"# }
        if host == "amazonaws.com" || host == "gov.example" { return #"{"host":"\#(host)","registrable":true,"suffix":false}"# }
        guard let suffix = suffixes.first(where: { host.hasSuffix("." + $0) }) else { return nil }
        let label = host.dropLast(suffix.count + 1).split(separator: ".").last ?? ""
        return #"{"host":"\#(label).\#(suffix)","registrable":true,"suffix":false}"#
    }

    /// `isOneSite` wrapped the shell's guess, by which `web.app` and
    /// `edu.au` are one site each. It now asks the engine's list, as every
    /// other user of a site's name does, and keeps the guess for when there
    /// is no answer.
    func testOneSiteIsTheEnginesWordAndTheGuessOnlyWithoutIt() {
        for suffix in ["web.app", "edu.au"] {
            XCTAssertTrue(ContentBlockingSiteAllow.isOneSite(suffix, names: nil), "\(suffix): the guess takes it for a site")
            XCTAssertFalse(ContentBlockingSiteAllow.isOneSite(suffix, names: engineNames), "\(suffix): the engine's list does not")
        }
        for site in ["someone.web.app", "school.edu.au", "example.co.uk", "a.someone.web.app"] {
            XCTAssertTrue(ContentBlockingSiteAllow.isOneSite(site, names: engineNames), site)
        }
        // A name the guess takes for a suffix and the list knows as a site.
        XCTAssertFalse(ContentBlockingSiteAllow.isOneSite("gov.example", names: nil))
        XCTAssertTrue(ContentBlockingSiteAllow.isOneSite("gov.example", names: engineNames))
        // This build's own refusals stay, whatever the engine says: it may refuse more, never less.
        XCTAssertFalse(ContentBlockingSiteAllow.isOneSite("amazonaws.com", names: engineNames))
        XCTAssertFalse(ContentBlockingSiteAllow.isOneSite("localhost", names: engineNames))
        XCTAssertFalse(ContentBlockingSiteAllow.isOneSite("evil.test^$important", names: engineNames))
        // No answer for the name: the guess, as before.
        XCTAssertTrue(ContentBlockingSiteAllow.isOneSite("unknown.test", names: engineNames))
        XCTAssertFalse(ContentBlockingSiteAllow.isOneSite("co.uk", names: nil))
    }

    /// What that changes for Allow: a rule is never written for, nor read
    /// back for, a page site that is a suffix the guess does not know.
    func testAllowNeverWritesForASuffixTheGuessTookForASite() throws {
        var settings = ContentBlockingSettings.newProfile
        XCTAssertEqual(settings.allowHost("doubleclick.net", onSite: "web.app", names: engineNames), .noSite)
        XCTAssertEqual(settings.allowHost("web.app", onSite: "news.test", names: engineNames), .notOneSite)
        XCTAssertEqual(settings.ownRules, "")
        XCTAssertNil(ContentBlockingSiteAllow.rule(host: "doubleclick.net", site: "edu.au", names: engineNames))
        XCTAssertNotNil(ContentBlockingSiteAllow.rule(host: "doubleclick.net", site: "edu.au", names: nil), "the guess alone would have written it")
        // A line an older build could have written for the suffix is not offered as "allowed on this site".
        settings.setOwnRules("@@||doubleclick.net^$domain=web.app\n@@||web.app^$domain=someone.web.app\n@@||cdn.test^$domain=someone.web.app")
        XCTAssertEqual(settings.allowedHosts(onSite: "web.app", names: engineNames), [])
        XCTAssertEqual(settings.allowedHosts(onSite: "someone.web.app", names: engineNames), ["cdn.test"])
        XCTAssertNil(settings.allowHost("doubleclick.net", onSite: "someone.web.app", names: engineNames))
        // A reply's page and lines go through the same check.
        let list = try XCTUnwrap(List.decode(#"""
        {"page":{"host":"web.app","registrable":true},
         "hosts":[{"host":"edu.au","count":2,"registrable":true},{"host":"school.edu.au","count":1,"registrable":true}]}
        """#, lists: lists, names: engineNames))
        XCTAssertNil(list.allowSite, "an engine reply that calls a suffix registrable is not believed twice")
        XCTAssertEqual(list.entries.filter(\.canBeAllowed).map(\.host), ["school.edu.au"])
    }

    // MARK: The order while the list is open (security BL-03)

    func testAnOpenListKeepsItsLinesInPlaceAndPutsNewSitesUnderneath() throws {
        let first = try XCTUnwrap(List.decode(json([("a.test", 5, []), ("b.test", 3, []), ("c.test", 1, [])]), lists: lists))
        let shown = first.entries(keeping: []).map(\.host)
        XCTAssertEqual(shown, ["a.test", "b.test", "c.test"], "opened: most blocked first")
        // The page blocks c.test more often than the others, and asks a new host.
        let later = try XCTUnwrap(List.decode(json([("a.test", 5, []), ("b.test", 3, []), ("c.test", 40, []), ("d.test", 9, []), ("e.test", 20, [])]), lists: lists))
        XCTAssertEqual(later.entries.map(\.host), ["c.test", "e.test", "d.test", "a.test", "b.test"], "what a newly opened list would show")
        let kept = later.entries(keeping: shown)
        XCTAssertEqual(kept.map(\.host), ["a.test", "b.test", "c.test", "e.test", "d.test"], "no line moved; new sites went underneath")
        XCTAssertEqual(kept.map(\.count), [5, 3, 40, 20, 9], "counts change in place")
        // A site that is gone (the page navigated) leaves; nothing else moves.
        let after = try XCTUnwrap(List.decode(json([("c.test", 2, []), ("a.test", 1, [])]), lists: lists))
        XCTAssertEqual(after.entries(keeping: kept.map(\.host)).map(\.host), ["a.test", "c.test"])
        XCTAssertEqual(List().entries(keeping: shown), [])
    }

    // MARK: The row

    func testTheRowOffersItsListOnlyWhileSomethingIsCounted() {
        let page = URL(string: "https://www.news.test/story")
        func row(_ settings: ContentBlockingSettings, count: Int?, available: Bool = true, lists: Bool = true) -> SiteControlCenter.SettingRow {
            SiteControlCenter.contentBlockingRow(settings: settings, pageURL: page, blockedCount: count, listsAvailable: lists,
                                                 isPrivate: false, blockedListAvailable: available)
        }
        XCTAssertTrue(row(.newProfile, count: 3).hasBlockedList)
        XCTAssertFalse(row(.newProfile, count: 0).hasBlockedList)
        XCTAssertFalse(row(.newProfile, count: nil).hasBlockedList)
        XCTAssertFalse(row(.newProfile, count: 3, available: false).hasBlockedList, "an engine that only counts")
        XCTAssertFalse(row(.off, count: 3).hasBlockedList)
        XCTAssertFalse(row(.newProfile, count: 3, lists: false).hasBlockedList)
        var excepted = ContentBlockingSettings.newProfile
        excepted.setException(true, forPage: page)
        XCTAssertFalse(row(excepted, count: 3).hasBlockedList)
        // A private window's row reports, and its list is read like any other tab's.
        let privateRow = SiteControlCenter.contentBlockingRow(settings: .newProfile, pageURL: page, blockedCount: 3, listsAvailable: true,
                                                              isPrivate: true, blockedListAvailable: true)
        XCTAssertTrue(privateRow.hasBlockedList)
        XCTAssertEqual(privateRow.actions, [])
    }

    // MARK: The page's own site (security BL-10, BL-11)

    /// Allow writes for the site the engine names in the same reply as the
    /// lines, from Chromium's suffix list. The shell's own idea of a site
    /// (the last two or three labels) takes `web.app` or `edu.au` for one.
    func testThePagesSiteIsTheEnginesAndNeverCutFromAnAddressHere() throws {
        func page(_ json: String) -> List? { List.decode(#"{"page":\#(json),"hosts":[],"more":0}"#, lists: lists) }
        for site in ["someone.web.app", "school.edu.au", "club.or.jp", "x.azurewebsites.net", "news.test", "203.0.113.7"] {
            let list = try XCTUnwrap(page(#"{"host":"\#(site)","registrable":true}"#))
            XCTAssertEqual(list.pageSite, site)
            XCTAssertEqual(list.allowSite, site, "the engine's name, whole")
            var settings = ContentBlockingSettings.newProfile
            XCTAssertNil(settings.allowHost("doubleclick.net", onSite: site))
            XCTAssertEqual(settings.ownRules, "@@||doubleclick.net^$domain=\(site)\n")
        }
        // What the shell's guess would have written for those pages is a suffix: the engine
        // says such a name is not one site, and then there is no Allow.
        for suffix in ["web.app", "edu.au", "or.jp", "azurewebsites.net", "localhost", "co.uk"] {
            let list = try XCTUnwrap(page(#"{"host":"\#(suffix)","registrable":false}"#))
            XCTAssertEqual(list.pageSite, suffix)
            XCTAssertNil(list.allowSite, suffix)
        }
        // The engine said yes and this build knows better: still no.
        XCTAssertNil(page(#"{"host":"co.uk","registrable":true}"#)?.allowSite)
        XCTAssertNil(page(#"{"host":"wiki","registrable":true}"#)?.allowSite)
        XCTAssertNil(page(#"{"host":"news.test"}"#)?.allowSite, "an engine that does not say is not a yes")
        // A name that is no host is no site at all.
        for bad in [#"{"host":"news.test^$important","registrable":true}"#, #"{"host":"","registrable":true}"#, #"{"host":"[::1]","registrable":true}"#] {
            let list = try XCTUnwrap(page(bad))
            XCTAssertNil(list.pageSite)
            XCTAssertNil(list.allowSite)
        }
        XCTAssertNil(List.decode(#"{"hosts":[],"more":0}"#, lists: lists)?.pageSite, "a page that is no site")
        XCTAssertEqual(List(pageSite: nil, pageSiteIsOneSite: true).allowSite, nil)
    }

    /// An error page (bridge 0.80.0, `tab/099`): the engine names the site
    /// of the address that failed and says it is an error page. No rule
    /// between two sites is written from it. The site itself is still named,
    /// so blocking can be turned off for it there.
    func testAnErrorPageHasItsSiteAndNoAllow() throws {
        let failed = try XCTUnwrap(List.decode(#"""
        {"page":{"host":"news.test","registrable":true,"error":true},
         "hosts":[{"host":"news.test","count":1,"registrable":true,"lists":["easylist"]}],"more":0}
        """#, lists: lists))
        XCTAssertEqual(failed.pageSite, "news.test")
        XCTAssertTrue(failed.pageSiteIsOneSite)
        XCTAssertTrue(failed.pageIsError)
        XCTAssertNil(failed.allowSite, "no rule is written from an error page")
        XCTAssertEqual(failed.entries.map(\.host), ["news.test"], "what blocked the page's own request is still listed")
        let loaded = try XCTUnwrap(List.decode(#"{"page":{"host":"news.test","registrable":true,"error":false},"hosts":[]}"#, lists: lists))
        XCTAssertFalse(loaded.pageIsError)
        XCTAssertEqual(loaded.allowSite, "news.test")
        // Bridge 0.79.0 does not say: as before.
        XCTAssertEqual(List.decode(#"{"page":{"host":"news.test","registrable":true},"hosts":[]}"#, lists: lists)?.allowSite, "news.test")
        XCTAssertFalse(List(pageSite: nil, pageIsError: true).pageIsError, "no page, no error page")
    }

    // MARK: Allow on this site

    func testAllowIsOneOwnRuleForTheSiteAndConvertsToAnAllowRule() throws {
        var settings = ContentBlockingSettings.newProfile
        XCTAssertNil(settings.allowHost("doubleclick.net", onSite: "news.test"))
        XCTAssertEqual(settings.ownRules, "@@||doubleclick.net^$domain=news.test\n")
        XCTAssertEqual(settings.allowedHosts(onSite: "news.test"), ["doubleclick.net"])
        XCTAssertEqual(settings.allowedHosts(onSite: "other.test"), [], "allowed on one site only")
        XCTAssertNil(settings.allowHost("doubleclick.net", onSite: "news.test"), "allowed already")
        XCTAssertEqual(settings.ownRules, "@@||doubleclick.net^$domain=news.test\n", "and not written twice")

        let conversion = ContentBlockingRuleConverter.convert(settings.ownRules)
        XCTAssertEqual(conversion.dropped, [])
        let rule = try XCTUnwrap(conversion.rules.first)
        XCTAssertEqual(rule.action.type, "allow")
        XCTAssertEqual(rule.priority, ContentBlockingRuleConverter.Priority.allow)
        XCTAssertEqual(rule.condition.urlFilter, "||doubleclick.net^")
        XCTAssertEqual(rule.condition.initiatorDomains, ["news.test"])
        XCTAssertNil(rule.condition.resourceTypes, "requests, never the page itself")
        // And what a frame asks in a page of the site: without it the site stayed
        // blocked when it asked its own host from its own frame.
        XCTAssertEqual(conversion.rules.count, 2)
        XCTAssertEqual(conversion.rules[1].action.type, "allow")
        XCTAssertEqual(conversion.rules[1].priority, ContentBlockingRuleConverter.Priority.allow)
        XCTAssertEqual(conversion.rules[1].condition, .init(urlFilter: "||doubleclick.net^", topDomains: ["news.test"]))
        XCTAssertEqual(conversion.filters, 1)
    }

    /// The line Allow wrote in Darni 2026.1119.1080 and 2026.1120.1105 is
    /// the line it writes now: nothing stored changes, and a site allowed
    /// with those builds is covered in frames as well from this one.
    func testALineWrittenByAnEarlierBuildIsReadAsBefore() {
        let earlier = "@@||amazon-adsystem.com^$domain=timeanddate.com\n"
        var settings = ContentBlockingSettings(isEnabled: true, ownRules: earlier)
        XCTAssertEqual(settings.allowedHosts(onSite: "timeanddate.com"), ["amazon-adsystem.com"])
        XCTAssertEqual(ContentBlockingSiteAllow.rule(host: "amazon-adsystem.com", site: "timeanddate.com").map { $0 + "\n" }, earlier)
        XCTAssertNil(settings.allowHost("amazon-adsystem.com", onSite: "timeanddate.com"))
        XCTAssertEqual(settings.ownRules, earlier)
        XCTAssertEqual(ContentBlockingRuleConverter.convert(earlier).rules.map(\.condition.topDomains), [nil, ["timeanddate.com"]])
        settings.removeAllowedHost("amazon-adsystem.com", onSite: "timeanddate.com")
        XCTAssertEqual(settings.ownRules, "")
    }

    // MARK: Allowed here and still in the list

    func testASiteThatIsAllowedAndStillListedHasNoAllowAndANote() {
        typealias Entry = ContentBlockingBlockedList.Entry
        let list = ContentBlockingBlockedList(entries: [Entry(host: "t.test", count: 3, kinds: [.tracker]),
                                                        Entry(host: "amazon-adsystem.com", count: 1, kinds: [.ad])],
                                              pageSite: "timeanddate.com", pageSiteIsOneSite: true)
        XCTAssertEqual(list.stillBlocked(allowed: []), [])
        XCTAssertNil(list.stillBlockedNote(allowed: [], names: nil))
        XCTAssertNil(list.stillBlockedNote(allowed: ["elsewhere.test"], names: nil))
        XCTAssertEqual(list.stillBlocked(allowed: ["amazon-adsystem.com"]).map(\.host), ["amazon-adsystem.com"])
        XCTAssertEqual(list.stillBlockedNote(allowed: ["amazon-adsystem.com"], names: nil),
                       "amazon-adsystem.com is allowed here, but it was still blocked on this page. Reload the page to try again.")
        XCTAssertEqual(list.stillBlockedNote(allowed: ["amazon-adsystem.com", "t.test"], names: nil),
                       "2 of the sites you allowed here were still blocked on this page. Reload the page to try again.")
    }

    /// A `$important` block of the person's own comes before every
    /// exception of theirs: the line has the "Your rule" tag, and the note
    /// names that, not a reload that would change nothing.
    func testTheNoteNamesThePersonsOwnRuleWhenThatIsWhatBlocks() {
        typealias Entry = ContentBlockingBlockedList.Entry
        let own = ContentBlockingBlockedList(entries: [Entry(host: "ads.test", count: 2, kinds: [.ad, .ownRule]), Entry(host: "cdn.test", count: 1, kinds: [.ownRule])])
        XCTAssertEqual(own.stillBlockedNote(allowed: ["ads.test"], names: nil),
                       "ads.test is allowed here, but one of your own rules still blocks it. Your rules are in Settings › Profiles.")
        XCTAssertEqual(own.stillBlockedNote(allowed: ["ads.test", "cdn.test"], names: nil),
                       "2 of the sites you allowed here are still blocked by your own rules. Your rules are in Settings › Profiles.")
        let mixed = ContentBlockingBlockedList(entries: [Entry(host: "ads.test", count: 2, kinds: [.ownRule]), Entry(host: "cdn.test", count: 1, kinds: [.tracker])])
        XCTAssertEqual(mixed.stillBlockedNote(allowed: ["ads.test", "cdn.test"], names: nil),
                       "2 of the sites you allowed here were still blocked on this page. Reload the page to try again.",
                       "one of them may go with a reload: say that first")
        // The priorities behind it: an important block is above an exception, a plain block below.
        let rules = ContentBlockingRuleConverter.convert("||ads.test^$important\n||cdn.test^\n@@||ads.test^$domain=news.test").rules
        XCTAssertEqual(rules.map(\.priority), [3, 1, 2, 2])
    }

    /// Security BL-13: the button is in a line before its title shows, and a
    /// line can come under a pointer that does not move. A click acts only
    /// where the title shows. Elsewhere it shows the title and no more.
    func testAClickActsOnlyOnALineThatShowsItsButtonsTitle() {
        XCTAssertEqual(SiteControlCenter.blockedLineClick(titleShows: false), .showTitle)
        XCTAssertEqual(SiteControlCenter.blockedLineClick(titleShows: true), .perform)
    }

    /// An exception covers the names under its host, and no name that only ends alike.
    func testAnAllowedHostCoversTheNamesUnderIt() {
        typealias Entry = ContentBlockingBlockedList.Entry
        let list = ContentBlockingBlockedList(entries: [Entry(host: "s.cdn.test", count: 1, kinds: [.ad]), Entry(host: "notcdn.test", count: 1, kinds: [.ad])])
        XCTAssertEqual(list.stillBlocked(allowed: ["cdn.test"]).map(\.host), ["s.cdn.test"])
        let long = String(repeating: "a.", count: 20) + "cdn.test"
        let note = ContentBlockingBlockedList(entries: [Entry(host: long, count: 1, kinds: [.ad])]).stillBlockedNote(allowed: ["cdn.test"], names: nil)
        XCTAssertEqual(note?.hasPrefix("…"), true, "a long name is cut from the left, as in the line")
        XCTAssertEqual(note?.contains("cdn.test is allowed here"), true)
        for text in [list.stillBlockedNote(allowed: ["cdn.test"], names: nil), note] {
            XCTAssertEqual(text?.contains("—"), false)
            XCTAssertEqual(text?.contains(";"), false)
        }
    }

    func testAllowKeepsThePersonsOwnRulesAndRemoveDeletesOnlyItsLine() {
        let site = "127.0.0.1"
        var settings = ContentBlockingSettings(isEnabled: true, ownRules: "! mine\n||ads.test^")
        XCTAssertNil(settings.allowHost("adsterra.com", onSite: site))
        XCTAssertNil(settings.allowHost("cdn.test", onSite: site))
        XCTAssertEqual(settings.ownRules, "! mine\n||ads.test^\n@@||adsterra.com^$domain=127.0.0.1\n@@||cdn.test^$domain=127.0.0.1\n")
        XCTAssertEqual(settings.allowedHosts(onSite: site), ["adsterra.com", "cdn.test"])
        let converted = ContentBlockingRuleConverter.convert(settings.ownRules).rules
        XCTAssertEqual(converted.map(\.condition.initiatorDomains), [nil, ["127.0.0.1"], ["127.0.0.1"], nil, nil], "an address is a site of its own")
        XCTAssertEqual(converted.map(\.condition.topDomains), [nil, nil, nil, ["127.0.0.1"], ["127.0.0.1"]], "and a page's")

        settings.removeAllowedHost("adsterra.com", onSite: site)
        XCTAssertEqual(settings.ownRules, "! mine\n||ads.test^\n@@||cdn.test^$domain=127.0.0.1\n")
        settings.removeAllowedHost("ads.test", onSite: site)
        settings.removeAllowedHost("cdn.test", onSite: "other.test")
        XCTAssertEqual(settings.ownRules, "! mine\n||ads.test^\n@@||cdn.test^$domain=127.0.0.1\n", "a rule Allow did not write for this site stays")
        // A wider rule the person typed is theirs: it is not listed as allowed here, and Remove leaves it.
        settings.setOwnRules("@@||cdn.test^\n@@||cdn.test^$domain=127.0.0.1|other.test\n@@||cdn.test^$domain=127.0.0.1,script")
        XCTAssertEqual(settings.allowedHosts(onSite: site), [])
    }

    /// Both names come from pages. Neither may carry filter syntax into the
    /// rule, and neither may be a name that covers more than one site.
    func testANameThatIsNotOneSiteNeverReachesTheOwnRules() {
        var settings = ContentBlockingSettings.newProfile
        let notOneSite = ["evil.test^$important", "a.test,b.test", "a.test|b.test", "a.test\n||everything^", "*.test", "a.test/path", "A.test", "a.test:80",
                          " a.test", "", "a..test", "-a.test", "[::1]", "localhost", "com", "co.uk", "github.io", "wiki"]
        for name in notOneSite {
            XCTAssertEqual(settings.allowHost(name, onSite: "news.test"), .notOneSite, name)
            XCTAssertEqual(settings.allowHost("ok.test", onSite: name), .noSite, name)
            XCTAssertNil(ContentBlockingSiteAllow.rule(host: name, site: "news.test"), name)
            XCTAssertNil(ContentBlockingSiteAllow.rule(host: "ok.test", site: name), name)
            XCTAssertEqual(settings.allowedHosts(onSite: name), [], name)
        }
        XCTAssertEqual(settings.ownRules, "")
        XCTAssertEqual(ContentBlockingSiteAllow.rule(host: "xn--bcher-kva.example", site: "news.test"), "@@||xn--bcher-kva.example^$domain=news.test")
        XCTAssertEqual(ContentBlockingSiteAllow.hosts(in: "@@||evil.test^$important^$domain=news.test\n@@||^$domain=news.test\n@@||co.uk^$domain=news.test",
                                                      site: "news.test"), [])
        XCTAssertNil(settings.allowHost("ok.test", onSite: "someone.github.io"), "one tenant of a shared host is a site")
        for refusal in [ContentBlockingSiteAllow.Refusal.pageMoved, .noSite, .notOneSite, .full] { XCTAssertFalse(refusal.message.isEmpty) }
    }

    func testAllowIsRefusedWhenTheOwnRulesAreFull() {
        // The limit of rules.
        var rules = ContentBlockingSettings(isEnabled: true, ownRules: (0..<ContentBlockingRuleConverter.maxRules).map { "||ad\($0).test^" }.joined(separator: "\n"))
        let before = rules.ownRules
        XCTAssertEqual(rules.allowHost("ok.test", onSite: "news.test"), .full)
        XCTAssertEqual(rules.ownRules, before)
        // Allow is two rules. With room for one it would cover the page's own requests only,
        // and look like an Allow that failed: it is refused instead.
        var oneLeft = ContentBlockingSettings(isEnabled: true, ownRules: (0..<ContentBlockingRuleConverter.maxRules - 1).map { "||ad\($0).test^" }.joined(separator: "\n"))
        XCTAssertEqual(oneLeft.allowHost("ok.test", onSite: "news.test"), .full)
        var twoLeft = ContentBlockingSettings(isEnabled: true, ownRules: (0..<ContentBlockingRuleConverter.maxRules - 2).map { "||ad\($0).test^" }.joined(separator: "\n"))
        XCTAssertNil(twoLeft.allowHost("ok.test", onSite: "news.test"))
        let fitted = ContentBlockingRuleConverter.convert(twoLeft.ownRules)
        XCTAssertEqual(fitted.dropped, [])
        XCTAssertEqual(fitted.rules.count, ContentBlockingRuleConverter.maxRules)
        XCTAssertEqual(fitted.rules.last?.condition, .init(urlFilter: "||ok.test^", topDomains: ["news.test"]))
        XCTAssertEqual(twoLeft.allowHost("more.test", onSite: "news.test"), .full)
        // The limit of text.
        var text = ContentBlockingSettings(isEnabled: true, ownRules: "! " + String(repeating: "x", count: ContentBlockingSettings.maxOwnRulesBytes - 12))
        XCTAssertEqual(text.ownRules.utf8.count, ContentBlockingSettings.maxOwnRulesBytes - 10)
        let full = text.ownRules
        XCTAssertEqual(text.allowHost("ok.test", onSite: "news.test"), .full, "a line that does not fit is not half written")
        XCTAssertEqual(text.ownRules, full)
    }
}
