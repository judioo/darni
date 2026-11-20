import CryptoKit
import XCTest
import SidebarModel
@testable import ReArc

/// The self-test's blocking fixture (CONTENT-BLOCKING.md §8, security CB-02):
/// its two hosts against the lists in the repository, the resolver rule that
/// answers them from the loopback fixture server, what the page reports, and
/// the cold launch's arguments. The self-test itself needs the screen and an
/// engine with `tab/095`; these parts of it do not.
final class SelfTestBlockingFixtureTests: XCTestCase {
    private static let shellDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func builtInBundle() throws -> VerifiedBlocklist {
        try BlocklistVerifier.verify(directory: Self.shellDirectory.appendingPathComponent("Resources/Blocklists", isDirectory: true),
                                     source: .builtIn, publicKeys: BlocklistSigningKey.compiledIn, engine: nil).get()
    }

    /// A signed bundle with these lists: (id, level, rules as JSON text).
    private func bundle(_ lists: [(id: String, level: Int, rules: String)]) throws -> VerifiedBlocklist {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-blocking-fixture-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("rules"), withIntermediateDirectories: true)
        var entries: [[String: Any]] = []
        for list in lists {
            let data = Data(list.rules.utf8)
            try data.write(to: directory.appendingPathComponent("rules/\(list.id).json"))
            entries.append(["id": list.id, "title": list.id, "level": list.level,
                            "rules": ["path": "rules/\(list.id).json", "sha256": BlocklistVerifier.sha256(of: data)]])
        }
        let manifest = try JSONSerialization.data(withJSONObject: ["format": 1, "version": "202611180900", "lists": entries], options: [.sortedKeys])
        let key = Curve25519.Signing.PrivateKey()
        try manifest.write(to: directory.appendingPathComponent("manifest.json"))
        try Data(try key.signature(for: manifest).base64EncodedString().utf8).write(to: directory.appendingPathComponent("manifest.json.sig"))
        return try BlocklistVerifier.verify(directory: directory, source: .downloaded, publicKeys: [key.publicKey.rawRepresentation], engine: nil).get()
    }

    private func hostRule(_ host: String, action: String = "block", extra: String = "") -> String {
        #"{"id":1,"priority":1,"action":{"type":"\#(action)"},"condition":{"requestDomains":["other.test","\#(host)"]\#(extra)}}"#
    }

    // MARK: The hosts and the lists

    /// The lists in the repository block the tracker's host from Trackers
    /// only and the ad's host from Ads and trackers, and except neither. A
    /// list update that changes this fails here, before a self-test run does.
    func testTheFixturesHostsAreInTheBuiltInLists() throws {
        let bundle = try builtInBundle()
        XCTAssertEqual(SelfTestBlockingFixture.blockingLevel(of: SelfTestBlockingFixture.trackerHost, in: bundle), 1)
        XCTAssertEqual(SelfTestBlockingFixture.blockingLevel(of: SelfTestBlockingFixture.adHost, in: bundle), 2)
        XCTAssertEqual(SelfTestBlockingFixture.problems(in: bundle), [])
        XCTAssertNil(SelfTestBlockingFixture.blockingLevel(of: "127.0.0.1", in: bundle), "the fixture's own page is on no list")
        XCTAssertNil(SelfTestBlockingFixture.blockingLevel(of: "localhost", in: bundle))
    }

    func testAHostsLevelIsTheLowestLevelOfAListThatBlocksAllOfIt() throws {
        let tracker = SelfTestBlockingFixture.trackerHost, ad = SelfTestBlockingFixture.adHost
        let fits = try bundle([("privacy", 1, "[\(hostRule(tracker, extra: #","domainType":"thirdParty""#))]"),
                               ("ads", 2, "[\(hostRule(ad)),\(hostRule(tracker))]"),
                               ("regional", 0, "[\(hostRule(ad))]")])
        XCTAssertEqual(SelfTestBlockingFixture.blockingLevel(of: tracker, in: fits), 1)
        XCTAssertEqual(SelfTestBlockingFixture.blockingLevel(of: "cdn.\(tracker)", in: fits), 1, "a list's host covers its subdomains")
        XCTAssertEqual(SelfTestBlockingFixture.blockingLevel(of: ad, in: fits), 2, "a regional list is on at no level")
        XCTAssertEqual(SelfTestBlockingFixture.problems(in: fits), [])

        // A rule with a further condition does not block every request to the host.
        let narrowed = try bundle([("privacy", 1, "[\(hostRule(tracker, extra: #","resourceTypes":["image"]"#))]"),
                                   ("ads", 2, "[\(hostRule(ad, extra: #","initiatorDomains":["news.test"]"#))]")])
        XCTAssertNil(SelfTestBlockingFixture.blockingLevel(of: tracker, in: narrowed))
        XCTAssertNil(SelfTestBlockingFixture.blockingLevel(of: ad, in: narrowed))
        XCTAssertEqual(SelfTestBlockingFixture.problems(in: narrowed).count, 2)
    }

    func testAListUpdateThatMovesOrExceptsAHostIsAProblem() throws {
        let tracker = SelfTestBlockingFixture.trackerHost, ad = SelfTestBlockingFixture.adHost
        // The ad's host moved into a tracker list: Trackers only would block it too.
        let moved = try bundle([("privacy", 1, "[\(hostRule(tracker)),\(hostRule(ad))]"), ("ads", 2, "[\(hostRule(ad))]")])
        XCTAssertEqual(SelfTestBlockingFixture.problems(in: moved),
                       ["\(ad) is blocked from level 1 in bundle 202611180900, not from 2 (Ads and trackers)"])
        // The tracker's host is gone.
        let dropped = try bundle([("privacy", 1, "[]"), ("ads", 2, "[\(hostRule(ad))]")])
        XCTAssertEqual(SelfTestBlockingFixture.problems(in: dropped),
                       ["\(tracker) is blocked from level none in bundle 202611180900, not from 1 (Trackers only)"])
        // An exception names a host, as a domain or in a pattern.
        let excepted = try bundle([("privacy", 1, "[\(hostRule(tracker)),\(hostRule(tracker, action: "allow"))]"),
                                   ("ads", 2, #"[\#(hostRule(ad)),{"id":2,"priority":2,"action":{"type":"allow"},"condition":{"urlFilter":"||\#(ad)/ok/"}}]"#)])
        XCTAssertEqual(SelfTestBlockingFixture.problems(in: excepted),
                       ["privacy has an exception that names \(tracker)", "ads has an exception that names \(ad)"])
    }

    // MARK: The resolver rule

    /// Chromium takes the first rule that matches a name, so the fixture's
    /// hosts come before the rule that fails every other name; nothing else resolves.
    func testTheSelfTestAnswersOnlyItsOwnHostsFromLoopback() throws {
        let arguments = ChromiumLaunchArguments.selfTestArguments(["ReArc", "--user-data-dir=/tmp/x"])
        let rules = try XCTUnwrap(arguments.first { $0.hasPrefix("--host-resolver-rules=") })
        XCTAssertEqual(arguments.filter { $0.hasPrefix("--host-resolver-rules=") }.count, 1)
        let entries = rules.dropFirst("--host-resolver-rules=".count).components(separatedBy: ", ")
        XCTAssertEqual(entries, ["MAP \(SelfTestBlockingFixture.trackerHost) 127.0.0.1", "MAP \(SelfTestBlockingFixture.adHost) 127.0.0.1",
                                 "MAP \(SelfTestBlockingFixture.siteHost) 127.0.0.1",
                                 "MAP * ~NOTFOUND", "EXCLUDE 127.0.0.1", "EXCLUDE localhost"])
        // The page's own site sits under a suffix the shell's guess does not know: the guess is the suffix.
        XCTAssertEqual(SelfTestBlockingFixture.siteHost, "rearc_selftest.azurewebsites.net")
        // A label nobody can register there: should the resolver switches be lost, no stranger's page loads.
        XCTAssertTrue(SelfTestBlockingFixture.siteHost.split(separator: ".")[0].contains("_"))
        XCTAssertNotNil(URL(string: "http://\(SelfTestBlockingFixture.siteHost):8123/blocking?run=1")?.host())
        XCTAssertNotNil(SiteControlCenter.site(for: URL(string: "http://\(SelfTestBlockingFixture.siteHost):8123/blocking?run=1")))
        XCTAssertEqual(BoostScopeMatcher.registrableDomain(SelfTestBlockingFixture.siteHost), SelfTestBlockingFixture.siteSuffix)
        // Whole names, no wildcard: a subdomain of any still fails to resolve.
        for host in [SelfTestBlockingFixture.trackerHost, SelfTestBlockingFixture.adHost, SelfTestBlockingFixture.siteHost] {
            XCTAssertFalse(host.contains("*"))
            XCTAssertNotNil(ContentBlockingHost.normalized(host))
        }
        XCTAssertNotEqual(SelfTestBlockingFixture.trackerHost, SelfTestBlockingFixture.adHost)
    }

    // MARK: The page

    func testThePageAsksBothHostsOnTheFixturesPortAndNamesItsLoad() {
        let html = SelfTestBlockingFixture.pageHTML
        XCTAssertTrue(html.contains("request('tracker', '\(SelfTestBlockingFixture.trackerHost)');"))
        XCTAssertTrue(html.contains("request('ad', '\(SelfTestBlockingFixture.adHost)');"))
        XCTAssertTrue(html.contains("'http://' + host + ':' + location.port + '/blocking/' + name + '.js?run=' + run"))
        XCTAssertEqual(SelfTestBlockingFixture.pageURL(base: "http://127.0.0.1:5123", run: 7).absoluteString, "http://127.0.0.1:5123/blocking?run=7")
        XCTAssertEqual(SelfTestBlockingFixture.trackerScriptPath, "/blocking/tracker.js")
        XCTAssertEqual(SelfTestBlockingFixture.adScriptPath, "/blocking/ad.js")
    }

    func testTheVerdictIsReadFromTheTitleOfOneLoad() {
        typealias Verdict = SelfTestBlockingFixture.Verdict
        XCTAssertEqual(Verdict(title: "blocking:run=3:tracker=blocked,ad=loaded"), Verdict(run: 3, trackerBlocked: true, adBlocked: false))
        XCTAssertEqual(Verdict(title: "blocking:run=12:tracker=loaded,ad=blocked"), Verdict(run: 12, trackerBlocked: false, adBlocked: true))
        XCTAssertEqual(Verdict(title: "blocking:run=0:ad=blocked,tracker=blocked"), Verdict(run: 0, trackerBlocked: true, adBlocked: true))
        XCTAssertEqual(Verdict(run: 1, trackerBlocked: true, adBlocked: false).text, "tracker blocked, ad loaded")
        for title in [nil, "", "blocking-pending", "blocking:run=3:tracker=blocked", "blocking:run=x:tracker=blocked,ad=blocked",
                      "blocking:run=3:tracker=maybe,ad=blocked", "blocking:tracker=blocked,ad=blocked", "ReArc Selftest A",
                      "blocking:run=3:tracker=blocked,tracker=loaded"] {
            XCTAssertNil(Verdict(title: title), title ?? "nil")
        }
    }

    func testTheServerCountsARequestUnderItsLoad() {
        XCTAssertTrue(SelfTestBlockingFixture.scriptRequest("/blocking/tracker.js?run=4").map { $0.isTracker && $0.run == 4 } ?? false)
        XCTAssertTrue(SelfTestBlockingFixture.scriptRequest("/blocking/ad.js?x=1&run=9").map { !$0.isTracker && $0.run == 9 } ?? false)
        XCTAssertTrue(SelfTestBlockingFixture.scriptRequest("/blocking/ad.js").map { !$0.isTracker && $0.run == 0 } ?? false)
        XCTAssertNil(SelfTestBlockingFixture.scriptRequest("/blocking?run=4"), "the page itself is not one of the two requests")
        XCTAssertNil(SelfTestBlockingFixture.scriptRequest("/blocking/other.js?run=4"))
        XCTAssertNil(SelfTestBlockingFixture.scriptRequest("/a"))
    }

    // MARK: The blocked list's page

    /// The lists in the repository block the pixel's path at Trackers only
    /// and the tag's at Ads and trackers, each by its path alone, so the
    /// self-test's list has one site with both tags.
    func testTheListPagesPathsAreInTheBuiltInLists() throws {
        XCTAssertEqual(SelfTestBlockingFixture.listProblems(in: try builtInBundle()), [])
        let moved = try bundle([("privacy", 2, #"[{"id":1,"priority":1,"action":{"type":"block"},"condition":{"urlFilter":"/1pixel.php"}}]"#),
                                ("ads", 2, #"[{"id":1,"priority":1,"action":{"type":"block"},"condition":{"urlFilter":"/88/tag.min.js","domainType":"firstParty"}}]"#)])
        XCTAssertEqual(SelfTestBlockingFixture.listProblems(in: moved).count, 2, "a path that moved level, and a rule with another condition")
    }

    func testTheListPageAsksNamesThatAreNotOneSiteAndNamesItsLoad() {
        typealias Verdict = SelfTestBlockingFixture.ListVerdict
        let html = SelfTestBlockingFixture.listPageHTML
        XCTAssertTrue(html.contains("'http://' + host + ':' + location.port + path + '?run=' + run"))
        XCTAssertTrue(html.contains("pixel('localhost', 0);") && html.contains("pixel('localhost', 1);") && html.contains("tag('localhost');"))
        XCTAssertTrue(html.contains("pixel('co.uk', 0);"))
        XCTAssertTrue(html.contains("address(host, '/1pixel.php', n)") && html.contains("address(host, '/88/tag.min.js', 0)"))
        // Neither name is one site: the list shows both, and neither gets Allow.
        XCTAssertFalse(ContentBlockingSiteAllow.isOneSite(SelfTestBlockingFixture.listHost))
        XCTAssertFalse(ContentBlockingSiteAllow.isOneSite(SelfTestBlockingFixture.listSuffixHost))
        XCTAssertEqual(SelfTestBlockingFixture.listPageURL(base: "http://127.0.0.1:5123", run: 7).absoluteString, "http://127.0.0.1:5123/blocking/list?run=7")
        XCTAssertEqual(SelfTestBlockingFixture.listPageURL(base: "http://127.0.0.1:5123", run: 8, mode: .quiet).absoluteString,
                       "http://127.0.0.1:5123/blocking/list?run=8&quiet=1")
        XCTAssertEqual(SelfTestBlockingFixture.listPageURL(base: "http://127.0.0.1:5123", run: 9, mode: .cap).absoluteString,
                       "http://127.0.0.1:5123/blocking/list?run=9&cap=1")
        XCTAssertEqual(Verdict(title: "blocked-list:run=3:failed=4"), Verdict(run: 3, failed: 4))
        XCTAssertEqual(Verdict(title: "blocked-list:run=4:failed=0"), Verdict(run: 4))
        XCTAssertEqual(Verdict(title: "blocked-list:run=5:quiet"), Verdict(run: 5, quiet: true))
        for title in [nil, "", "blocked-list-pending", "blocked-list:run=3:failed=-1", "blocked-list:run=3:failed=", "blocked-list:run=x:quiet",
                      "blocked-list:run=3:pixels=1", "blocking:run=3:tracker=blocked,ad=blocked"] {
            XCTAssertNil(Verdict(title: title), title ?? "nil")
        }
        XCTAssertEqual(SelfTestBlockingFixture.listRequestIsTag("/1pixel.php?run=4&n=1"), false)
        XCTAssertEqual(SelfTestBlockingFixture.listRequestIsTag("/88/tag.min.js?run=9&n=0"), true)
        XCTAssertNil(SelfTestBlockingFixture.listRequestIsTag("/blocking/list?run=4"), "the page itself is not one of its requests")
        XCTAssertNil(SelfTestBlockingFixture.scriptRequest("/1pixel.php?run=4"), "and the first fixture's counts are its own")
    }

    // MARK: The frame's page

    /// The lists in the repository block the tracker's host for every asker,
    /// the host itself included: that is what left an allowed site blocked
    /// in its own frame. A list update that narrows the rule to third
    /// parties fails here, before the self-test's frame step does.
    func testTheFramePagesHostIsBlockedEvenWhenItAsksItself() throws {
        XCTAssertEqual(SelfTestBlockingFixture.frameProblems(in: try builtInBundle()), [])
        let tracker = SelfTestBlockingFixture.trackerHost
        let thirdPartyOnly = try bundle([("privacy", 1, "[\(hostRule(tracker, extra: #","domainType":"thirdParty""#))]"), ("ads", 2, "[\(hostRule(tracker))]")])
        XCTAssertEqual(SelfTestBlockingFixture.frameProblems(in: thirdPartyOnly),
                       ["no list of level 1 in bundle 202611180900 blocks \(tracker) for every asker, the host itself included"])
        XCTAssertEqual(SelfTestBlockingFixture.frameProblems(in: try bundle([("privacy", 1, "[\(hostRule(tracker))]")])), [])
    }

    func testTheFramePageEmbedsTheHostAndTheFrameAsksItsOwnHost() {
        typealias Verdict = SelfTestBlockingFixture.FrameVerdict
        let page = SelfTestBlockingFixture.framePageHTML, inner = SelfTestBlockingFixture.frameInnerHTML
        XCTAssertTrue(page.contains("frame.src = 'http://\(SelfTestBlockingFixture.trackerHost):' + location.port + '/blocking/frame/inner?run=' + run;"))
        XCTAssertTrue(inner.contains("script.src = '/blocking/tracker.js?run=' + run;"), "a path alone: the frame's own host")
        XCTAssertFalse(inner.contains("http://"), "the frame names no other host")
        XCTAssertEqual(SelfTestBlockingFixture.framePageURL(base: "http://127.0.0.1:5123", run: 7).absoluteString, "http://127.0.0.1:5123/blocking/frame?run=7")
        // The server counts the frame's script as the tracker's request of that load, and neither page as a request.
        XCTAssertTrue(SelfTestBlockingFixture.scriptRequest("/blocking/tracker.js?run=7").map { $0.isTracker && $0.run == 7 } ?? false)
        XCTAssertNil(SelfTestBlockingFixture.scriptRequest("/blocking/frame?run=7"))
        XCTAssertNil(SelfTestBlockingFixture.scriptRequest("/blocking/frame/inner?run=7"))
        XCTAssertEqual(Verdict(title: "blocked-frame:run=7:frame=blocked", run: 7), .frameBlocked)
        XCTAssertEqual(Verdict(title: "blocked-frame:run=7:inner=blocked", run: 7), .innerBlocked)
        XCTAssertEqual(Verdict(title: "blocked-frame:run=7:inner=loaded", run: 7), .innerLoaded)
        for title in [nil, "", "blocked-frame-pending", "blocked-frame:run=6:inner=loaded", "blocked-frame:run=7:inner=maybe",
                      "blocked-frame:run=7", "blocked-list:run=7:quiet", "blocked-frame:run=77:inner=loaded"] {
            XCTAssertNil(Verdict(title: title, run: 7), title ?? "nil")
        }
        for message in ["rearc-frame-script-loaded", "rearc-frame-script-blocked"] {
            XCTAssertTrue(page.contains("'\(message)'") && inner.contains("'\(message)'"), message)
        }
    }

    /// More sites than a list holds, each a site of its own to the engine,
    /// under a name that is whole in no file: the page joins it from two
    /// pieces, and the self-test looks for it on disk afterwards.
    func testTheCapPageAsksMoreSitesThanAListHoldsUnderANameItNeverSpellsOut() {
        XCTAssertGreaterThan(SelfTestBlockingFixture.listCapSites, ContentBlockingBlockedList.maxEntries)
        let html = SelfTestBlockingFixture.listPageHTML
        XCTAssertTrue(html.contains("n < \(SelfTestBlockingFixture.listCapSites); n++) pixel('rearc-blocked-' + 'cap-' + n + '.test', n);"))
        XCTAssertEqual("rearc-blocked-" + "cap-", SelfTestBlockingFixture.listCapMarker)
        XCTAssertFalse(html.contains(SelfTestBlockingFixture.listCapMarker))
        XCTAssertTrue(ContentBlockingSiteAllow.isOneSite(SelfTestBlockingFixture.listCapMarker + "0.test"))
    }

    // MARK: The cold launch

    func testTheColdLaunchIsTheSelfTestWithItsFlagAndAProfileOfItsOwn() {
        let parent = ["/Apps/ReArc.app/Contents/MacOS/ReArc", "--rearc-selftest", "--user-data-dir=/tmp/parent", "--enable-logging"]
        let child = SelfTestBlockingFixture.coldLaunchArguments(from: parent, userDataDir: "/tmp/cold")
        XCTAssertEqual(child, ["--rearc-selftest", "--enable-logging", "--rearc-selftest-cold-blocking", "--user-data-dir=/tmp/cold",
                               "--rearc-selftest-cold-step=restore"])
        XCTAssertEqual(SelfTestBlockingFixture.coldStep(child), .restore)
        XCTAssertTrue(SelfTestBlockingFixture.isColdLaunch(child))
        XCTAssertFalse(SelfTestBlockingFixture.isColdLaunch(parent))
        XCTAssertEqual(ChromiumLaunchArguments.userDataDir(in: ["ReArc"] + child), "/tmp/cold", "never the profile the self-test's own engine holds")
        // A cold launch never starts another.
        XCTAssertEqual(SelfTestBlockingFixture.coldLaunchArguments(from: ["ReArc"] + child, userDataDir: "/tmp/again")
            .filter { $0 == SelfTestBlockingFixture.coldLaunchFlag }.count, 1)
        // It is a self-test launch to the option parser: the engine is Chromium, and a release
        // bundle takes it only under verification, on a new profile.
        let options = EngineLaunchOptions.parse(arguments: ["ReArc"] + child, environment: [:])
        XCTAssertTrue(options.selfTest)
        XCTAssertNil(options.bench)
    }

    func testAColdLaunchStepCarriesItsListsFolderUpdateAndKeyAndDropsTheLastOnes() throws {
        let parent = ["/Apps/ReArc.app/Contents/MacOS/ReArc", "--rearc-selftest", "--user-data-dir=/tmp/parent"]
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let child = SelfTestBlockingFixture.coldLaunchArguments(from: parent, userDataDir: "/tmp/cold", step: .takeover,
                                                                lists: "/tmp/lists", update: "/tmp/update", listsKey: key)
        XCTAssertEqual(SelfTestBlockingFixture.coldStep(child), .takeover)
        XCTAssertEqual(SelfTestBlockingFixture.value(of: SelfTestBlockingFixture.coldListsFlag, in: child), "/tmp/lists")
        XCTAssertEqual(SelfTestBlockingFixture.value(of: SelfTestBlockingFixture.coldUpdateFlag, in: child), "/tmp/update")
        XCTAssertEqual(SelfTestBlockingFixture.coldListsKey(child), key)
        XCTAssertNil(SelfTestBlockingFixture.coldListsKey(parent + [SelfTestBlockingFixture.coldListsKeyFlag + key.base64EncodedString()]),
                     "the key is read only in the cold launch")
        // The next launch from a cold launch's arguments names only its own.
        let next = SelfTestBlockingFixture.coldLaunchArguments(from: ["ReArc"] + child, userDataDir: "/tmp/cold", step: .off)
        XCTAssertEqual(SelfTestBlockingFixture.coldStep(next), .off)
        XCTAssertNil(SelfTestBlockingFixture.value(of: SelfTestBlockingFixture.coldListsFlag, in: next))
        XCTAssertNil(SelfTestBlockingFixture.coldListsKey(next))
        XCTAssertEqual(next.filter { $0.hasPrefix(SelfTestBlockingFixture.coldStepFlag) }.count, 1)
        XCTAssertNil(SelfTestBlockingFixture.coldStep(["--rearc-selftest-cold-step=later"]), "an unknown step is no step")
    }

    /// Security review (CB-02 point 3): a key the self-test makes to sign a
    /// second bundle is a second lists key. A bundle people get trusts the
    /// compiled-in keys alone, which are the key file's.
    func testABundlePeopleGetTrustsOnlyTheCompiledInListsKeys() throws {
        let compiled = BlocklistSigningKey.compiledIn
        let text = try String(contentsOf: Self.shellDirectory.appendingPathComponent("scripts/blocklists/blocklists-public-key.txt"), encoding: .utf8)
        XCTAssertEqual(compiled, BlocklistSigningKey.parseAll(text), "the compiled-in keys are the key file's")
        let testKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        XCTAssertEqual(SelfTestBlockingFixture.trustedListsKeys(compiledIn: compiled, selfTestKey: testKey, shipped: true), compiled,
                       "a shipped bundle never trusts a self-test key")
        XCTAssertEqual(SelfTestBlockingFixture.trustedListsKeys(compiledIn: compiled, selfTestKey: nil, shipped: false), compiled)
        XCTAssertEqual(SelfTestBlockingFixture.trustedListsKeys(compiledIn: compiled, selfTestKey: Data(count: 31), shipped: false), compiled)
        XCTAssertEqual(SelfTestBlockingFixture.trustedListsKeys(compiledIn: compiled, selfTestKey: testKey, shipped: false), compiled + [testKey])
    }

    func testTheReadyMarkerIsReadPerBlockerFromEitherPreferencesFile() throws {
        let ids = SelfTestBlockingFixture.blockerIDs
        func prefs(_ entries: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["extensions": ["settings": entries]])
        }
        let secure = try prefs([ids[1]: ["rearc_ready_bundle": "202611190857", "location": 5], ids[0]: ["location": 5]])
        let plain = try prefs(["abcdefghijklmnopabcdefghijklmnop": ["rearc_ready_bundle": "202611180857"]])
        XCTAssertEqual(SelfTestBlockingFixture.readyMarkers(inPreferences: [plain, secure]), [nil, "202611190857"])
        XCTAssertEqual(SelfTestBlockingFixture.readyMarkers(inPreferences: [Data("not json".utf8)]), [nil, nil])
        XCTAssertEqual(SelfTestBlockingFixture.readyMarkers(inPreferences: []), [nil, nil])
    }

    /// Every cold launch is the same shell profile, so on a used user data
    /// folder the engine opens the folder the first launch adopted. A profile
    /// with a new ID gets a named folder of its own there: such a launch met
    /// nothing of the last session's blocker, and "the same profile again"
    /// passed without testing it.
    func testColdLaunchesShareOneEngineProfile() {
        let id = SelfTestBlockingFixture.coldProfileID
        XCTAssertEqual(SidebarStore(defaultProfileID: id).profiles.map(\.id), [id])
        XCTAssertEqual(SidebarStore(defaultProfileID: id).spaces.map(\.profileID), [id])
        let engine = ChromiumProfileStoragePlan.Engine(canOpenDirectory: true, startupDirectory: ChromiumProfileStorageMap.defaultDirectory)
        func plan(_ profile: UUID, _ map: ChromiumProfileStorageMap) -> ChromiumProfileStoragePlan {
            ChromiumProfileStoragePlan.plan(for: profile, map: map, legacyOwner: profile, engine: engine, namedDirectoryExists: { _ in false })
        }
        var map = ChromiumProfileStorageMap()
        XCTAssertEqual(plan(id, map), .adoptDefault)
        map.recordDirectory(ChromiumProfileStorageMap.defaultDirectory, for: id)
        XCTAssertEqual(plan(id, map), .directory(ChromiumProfileStorageMap.defaultDirectory))
        let other = UUID()
        let key = ChromiumProfileKey.storageKey(for: other)
        XCTAssertEqual(plan(other, map), .named(key))
        let folder = ChromiumProfileStoragePlan.namedDirectoryName(forKey: key)
        XCTAssertEqual(SelfTestBlockingFixture.namedProfileFolders(in: ["Default", folder, "System Profile", "ReArc Blocker"]), [folder])
        XCTAssertEqual(SelfTestBlockingFixture.namedProfileFolders(in: ["Default", "ReArc Blocker", "Local State"]), [])
    }
}
