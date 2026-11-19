import CryptoKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Built-in ad and tracker blocking in the shell (CONTENT-BLOCKING.md §2, §3,
/// §6): what a launch decides, the one-time offer, what the engine is told,
/// and the site controls row. The engine is a recorder; no network is used.
@MainActor
final class ContentBlockingShellTests: XCTestCase {
    private final class RecordingEngine: ContentBlockingEngine {
        var calls: [String] = []

        func setBlocklistDirectory(_ directory: URL) { calls.append("directory") }
        func setContentBlocking(engineProfile: UInt64, level: ContentBlockingLevel, enabledListIDs: [String]) {
            calls.append("level \(engineProfile) \(level.engineValue) \(enabledListIDs.joined(separator: ","))")
        }
        func setBlockingExceptions(engineProfile: UInt64, hosts: [String]) {
            calls.append("exceptions \(engineProfile) \(hosts.joined(separator: ","))")
        }
        func setOwnBlockingRules(engineProfile: UInt64, dnrRulesJSON: String) { calls.append("rules \(engineProfile)") }

        func take() -> [String] {
            defer { calls = [] }
            return calls
        }
    }

    private final class NoMirror: BlocklistFetching, @unchecked Sendable {
        private(set) var requests = 0
        func data(from url: URL, limit: Int) async throws -> Data {
            requests += 1
            throw URLError(.notConnectedToInternet)
        }
    }

    private let key = Curve25519.Signing.PrivateKey()
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-blocking-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private var sidebarFile: URL { directory.appendingPathComponent("sidebar.json") }

    /// A launch on `directory`: a first run when it holds no sidebar file.
    private func launch() -> BrowserViewModel {
        let model = BrowserViewModel(
            persistence: SidebarFilePersistence(fileURL: sidebarFile),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-blocking-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-blocking-links-\(UUID().uuidString)")!
        model.contentBlocking.fetcher = NoMirror()
        return model
    }

    /// An install from before blocking: a sidebar file an older build saved.
    private func makeExistingInstall(profiles extra: [String] = []) throws {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        extra.forEach { _ = store.addProfile(name: $0) }
        _ = store.addTab(kind: .pinned, title: "Mail", url: URL(string: "https://mail.test/")!)
        let data = try JSONEncoder().encode(store.makeSnapshot())
        XCTAssertNil(try (JSONSerialization.jsonObject(with: data) as? [String: Any])?["contentBlocking"])
        try data.write(to: sidebarFile)
    }

    /// A signed bundle as the app carries one.
    private func builtInBundle() throws -> URL {
        let bundle = directory.appendingPathComponent("App/Blocklists", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("rules"), withIntermediateDirectories: true)
        var lists: [[String: Any]] = []
        for (id, level) in [("easyprivacy", 1), ("peter-lowe", 1), ("easylist", 2)] {
            let rules = Data("[]".utf8)
            try rules.write(to: bundle.appendingPathComponent("rules/\(id).json"))
            lists.append(["id": id, "title": id, "level": level,
                          "rules": ["path": "rules/\(id).json", "sha256": BlocklistVerifier.sha256(of: rules), "count": 0]])
        }
        let manifest = try JSONSerialization.data(withJSONObject: ["format": 1, "version": "202611180900", "created": "2026-11-18T09:00:00Z",
                                                                   "min_engine": 156, "lists": lists])
        try manifest.write(to: bundle.appendingPathComponent("manifest.json"))
        try Data(key.signature(for: manifest).base64EncodedString().utf8).write(to: bundle.appendingPathComponent("manifest.json.sig"))
        return bundle
    }

    private func attach(_ model: BrowserViewModel, engine: RecordingEngine) async throws {
        model.attachContentBlocking(engine: engine, engineVersion: BlocklistEngineVersion(chromiumMajor: 156),
                                    builtInLists: try builtInBundle(), publicKeys: [key.publicKey.rawRepresentation])
        for _ in 0..<400 where !model.contentBlocking.didLoadLists { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(model.contentBlocking.didLoadLists)
    }

    private func savedRollout() throws -> [String: Any]? {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: sidebarFile)) as? [String: Any]
        return (json?["contentBlocking"] as? [String: Any])?["rollout"] as? [String: Any]
    }

    // MARK: New and existing installs

    func testANewInstallBlocksAdsAndTrackersAndIsNotOfferedAnything() async throws {
        let model = launch()
        XCTAssertTrue(model.isFirstRun)
        let engine = RecordingEngine()
        try await attach(model, engine: engine)
        XCTAssertTrue(model.contentBlocking.isAvailable)
        XCTAssertEqual(model.store.contentBlockingRollout, ContentBlockingRollout(install: .new, offerShown: true))
        XCTAssertTrue(model.store.profiles.allSatisfy { model.store.contentBlocking(for: $0.id).level == .adsAndTrackers })
        model.presentContentBlockingOfferIfDue()
        XCTAssertFalse(model.contentBlocking.showsOffer)
        XCTAssertEqual(model.contentBlocking.bundle?.version.description, "202611180900")
        XCTAssertEqual(model.contentBlocking.listsUpdatedText, "Lists last updated \(ISO8601DateFormatter().date(from: "2026-11-18T09:00:00Z")!.formatted(date: .abbreviated, time: .omitted))")

        model.contentBlockingProfileOpened(engineProfile: 4, profile: model.store.profiles[0].id)
        XCTAssertEqual(engine.take(), ["directory", "level 4 2 easyprivacy,peter-lowe,easylist", "exceptions 4 ", "rules 4"],
                       "at profile load: the level, then the exceptions, then the own rules")
    }

    func testAnExistingInstallStaysOffAndIsOfferedOnceWithTheMarkerOnDiskFirst() async throws {
        try makeExistingInstall(profiles: ["Work"])
        let model = launch()
        XCTAssertFalse(model.isFirstRun)
        let engine = RecordingEngine()
        try await attach(model, engine: engine)
        XCTAssertEqual(model.store.contentBlockingRollout.install, .existing)
        XCTAssertTrue(model.store.profiles.allSatisfy { model.store.contentBlocking(for: $0.id).level == .off }, "the upgrade changes no profile")
        model.contentBlockingProfileOpened(engineProfile: 4, profile: model.store.profiles[0].id)
        XCTAssertEqual(engine.take(), ["level 4 0 ", "exceptions 4 ", "rules 4"],
                       "an old profile opens with blocking Off, and the engine is not named the bundle: it would copy the rules")
        XCTAssertEqual(try savedRollout()?["offerShown"] as? Bool, false)
        XCTAssertFalse(model.contentBlocking.showsOffer, "not before the sidebar is up")

        model.presentContentBlockingOfferIfDue()
        XCTAssertTrue(model.contentBlocking.showsOffer)
        XCTAssertEqual(try savedRollout()?["offerShown"] as? Bool, true, "the marker is on disk while the card is up")
        model.presentContentBlockingOfferIfDue()
        model.declineContentBlockingOffer()
        XCTAssertFalse(model.contentBlocking.showsOffer)
        XCTAssertFalse(model.store.isContentBlockingOnAnywhere, "Not Now turns nothing on")
        model.presentContentBlockingOfferIfDue()
        XCTAssertFalse(model.contentBlocking.showsOffer, "the card never returns")

        // The next launch, and one after a crash with the card up, show nothing.
        let relaunched = launch()
        try await attach(relaunched, engine: RecordingEngine())
        relaunched.presentContentBlockingOfferIfDue()
        XCTAssertFalse(relaunched.contentBlocking.showsOffer)
        XCTAssertTrue(relaunched.store.profiles.allSatisfy { relaunched.store.contentBlocking(for: $0.id).level == .off })
        XCTAssertEqual(relaunched.store.contentBlocking(for: relaunched.store.addProfile(name: "Later").id).level, .adsAndTrackers)
    }

    func testTurnOnSwitchesBlockingOnAndTellsTheEngine() async throws {
        try makeExistingInstall()
        let model = launch()
        let engine = RecordingEngine()
        try await attach(model, engine: engine)
        model.contentBlockingProfileOpened(engineProfile: 4, profile: model.store.profiles[0].id)
        _ = engine.take()
        model.presentContentBlockingOfferIfDue()
        model.acceptContentBlockingOffer()
        XCTAssertFalse(model.contentBlocking.showsOffer)
        XCTAssertEqual(model.store.contentBlocking().level, .adsAndTrackers)
        XCTAssertEqual(engine.take(), ["directory", "level 4 2 easyprivacy,peter-lowe,easylist"],
                       "the bundle is named once blocking is on, before the level")
    }

    func testWithoutAnEngineThatCanBlockNothingIsDecidedShownOrFetched() throws {
        try makeExistingInstall()
        let model = launch()
        let mirror = NoMirror()
        model.contentBlocking.fetcher = mirror
        model.presentContentBlockingOfferIfDue()
        model.checkBlocklistsIfDue()
        model.checkBlocklists()
        model.contentBlockingSettingsChanged()
        XCTAssertFalse(model.contentBlocking.isAvailable)
        XCTAssertFalse(model.contentBlocking.showsOffer)
        XCTAssertFalse(model.store.contentBlockingRollout.isDecided, "a later build with blocking still makes the decision")
        XCTAssertEqual(mirror.requests, 0)

        let url = URL(string: "https://www.news.test/story")!
        let tab = model.store.addTab(kind: .today, title: "News", url: url)
        let engine = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
        let site = try XCTUnwrap(SiteControlCenter.site(for: url))
        XCTAssertNil(model.contentBlockingRow(for: engine, site: site))
        XCTAssertEqual(model.siteControlSettingRows(for: engine, site: site).map(\.kind), [.autoPictureInPicture], "the panel is as it was")
    }

    // MARK: Settings and the site controls row

    func testAChangeInSettingsReachesTheEngineAtOnce() async throws {
        let model = launch()
        let engine = RecordingEngine()
        try await attach(model, engine: engine)
        let profile = model.store.profiles[0].id
        model.contentBlockingProfileOpened(engineProfile: 4, profile: profile)
        _ = engine.take()

        model.setContentBlockingStrength(.trackersOnly, for: profile)
        XCTAssertEqual(engine.take(), ["level 4 1 easyprivacy,peter-lowe"])
        model.setContentBlockingList("easylist", enabled: true, for: profile)
        XCTAssertEqual(engine.take(), ["level 4 1 easyprivacy,peter-lowe,easylist"])
        XCTAssertTrue(model.addContentBlockingException("https://www.shop.test/cart", for: profile))
        XCTAssertFalse(model.addContentBlockingException("not a host", for: profile))
        XCTAssertEqual(engine.take(), ["exceptions 4 shop.test"])
        model.setContentBlockingOwnRules("||ads.test^", for: profile)
        XCTAssertEqual(engine.take(), ["rules 4"])
        model.removeContentBlockingException("shop.test", for: profile)
        model.setContentBlockingEnabled(false, for: profile)
        XCTAssertEqual(engine.take(), ["exceptions 4 ", "level 4 0 "])
        XCTAssertEqual(model.contentBlockingListRows.map(\.id), ["easyprivacy", "peter-lowe", "easylist"], "the lists this bundle carries")
    }

    func testTheSiteControlsRowTurnsBlockingOffAndOnForTheSite() async throws {
        let model = launch()
        let recorder = RecordingEngine()
        try await attach(model, engine: recorder)
        let url = URL(string: "https://www.news.test/story")!
        let tab = model.store.addTab(kind: .today, title: "News", url: url)
        let engine = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
        let site = try XCTUnwrap(SiteControlCenter.site(for: url))
        model.contentBlocking.blockedCount = { _ in 7 }
        model.contentBlockingProfileOpened(engineProfile: 4, profile: model.profileID(for: tab))
        _ = recorder.take()

        var rows = model.siteControlSettingRows(for: engine, site: site)
        XCTAssertEqual(rows.map(\.kind), [.contentBlocking, .autoPictureInPicture])
        XCTAssertEqual(rows[0].state, "7 blocked on this page")
        model.performSiteSetting(.turnOffBlockingForSite, on: rows[0], engine: engine, site: site)
        XCTAssertEqual(model.store.contentBlocking().exceptions, ["news.test"])
        XCTAssertEqual(recorder.take(), ["exceptions 4 news.test"], "the engine has the exception before the tab reloads")
        rows = model.siteControlSettingRows(for: engine, site: site)
        XCTAssertEqual(rows[0].state, "Off for this site")
        XCTAssertEqual(rows[0].actions, [.turnOnBlockingForSite])
        model.performSiteSetting(.turnOnBlockingForSite, on: rows[0], engine: engine, site: site)
        XCTAssertEqual(model.store.contentBlocking().exceptions, [])
        XCTAssertEqual(recorder.take(), ["exceptions 4 "])
    }

    func testTheEnginesCountCallbackRefreshesTheOpenPanel() async throws {
        let model = launch()
        try await attach(model, engine: RecordingEngine())
        let url = URL(string: "https://www.news.test/story")!
        let tab = model.store.addTab(kind: .today, title: "News", url: url)
        let engine = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
        let site = try XCTUnwrap(SiteControlCenter.site(for: url))
        var count = 3
        model.contentBlocking.blockedCount = { _ in count }
        let changed = expectation(description: "the row is read again")
        withObservationTracking {
            XCTAssertEqual(model.contentBlockingRow(for: engine, site: site)?.state, "3 blocked on this page")
        } onChange: { changed.fulfill() }
        count = 9
        model.contentBlocking.blockedCountChanged()
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(model.contentBlockingRow(for: engine, site: site)?.state, "9 blocked on this page")
    }

    /// ABI 1.66, feature `content_blocking` (C-ABI.md): without both, blocking stays hidden.
    func testTheEngineFeatureGatesBlocking() {
        let all: (String) -> Bool = { _ in true }
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 65, hasFeature: all).contentBlocking)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 66, hasFeature: all).contentBlocking)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 66, hasFeature: { $0 != "content_blocking" }).contentBlocking)
        XCTAssertFalse(ChromiumCapabilities.none.contentBlocking)
    }

    // MARK: Blocked on this page

    /// The engine's reply for the tests: the page's own site, two blocked
    /// sites, one of them on two lists, and a name that is not one site.
    private static func blockedReply(page: String = "news.test") -> String {
        blockedReplyHosts.replacingOccurrences(of: "{\"hosts\"", with: #"{"page":{"host":"\#(page)","registrable":true},"hosts""#)
    }

    private static let blockedReplyHosts = #"""
    {"hosts":[{"host":"google-analytics.com","count":1,"registrable":true,"lists":["easyprivacy"]},
              {"host":"doubleclick.net","count":3,"registrable":true,"lists":["easylist","peter-lowe"]},
              {"host":"localhost","count":1,"registrable":false,"lists":["easylist"]}],"more":0}
    """#

    func testTheRowOpensTheEnginesListOfWhatWasBlocked() async throws {
        let model = launch()
        try await attach(model, engine: RecordingEngine())
        let url = URL(string: "https://www.news.test/story")!
        let tab = model.store.addTab(kind: .today, title: "News", url: url)
        let engine = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
        let site = try XCTUnwrap(SiteControlCenter.site(for: url))
        model.contentBlocking.blockedCount = { _ in 4 }

        // An engine that only counts: the row is as before, and there is no list.
        XCTAssertEqual(model.contentBlockingRow(for: engine, site: site)?.hasBlockedList, false)
        XCTAssertNil(model.blockedList(for: engine))

        var reply: String? = Self.blockedReply()
        var reads = 0
        model.contentBlocking.blockedHosts = { _ in
            reads += 1
            return reply
        }
        XCTAssertEqual(model.contentBlockingRow(for: engine, site: site)?.hasBlockedList, true)
        XCTAssertEqual(reads, 0, "the row asks for the count only; the list is read when it is shown")
        XCTAssertEqual(model.blockedList(for: engine)?.entries, [
            .init(host: "doubleclick.net", count: 3, kinds: [.ad, .tracker]),
            .init(host: "google-analytics.com", count: 1, kinds: [.tracker]),
            .init(host: "localhost", count: 1, kinds: [.ad], canBeAllowed: false),
        ])
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(model.blockedList(for: engine)?.allowSite, "news.test", "the site Allow writes for is the engine's")
        reads = 0

        // The count callback says when the list changed: an open list is read again.
        let changed = expectation(description: "the list is read again")
        withObservationTracking { _ = model.blockedList(for: engine) } onChange: { changed.fulfill() }
        reply = #"{"hosts":[],"more":0}"#
        model.contentBlocking.blockedCountChanged()
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(model.blockedList(for: engine), ContentBlockingBlockedList())
        reply = "not the list"
        XCTAssertEqual(model.blockedList(for: engine), ContentBlockingBlockedList(), "a reply that cannot be read shows nothing")
        reply = nil
        XCTAssertEqual(model.blockedList(for: engine), ContentBlockingBlockedList())
    }

    /// Privacy (spec §3): the shell reads the list for the view and keeps no
    /// copy, so nothing of it is in the sidebar file or in a sync record.
    func testNothingOfTheBlockedListIsWrittenAnywhere() async throws {
        let model = launch()
        try await attach(model, engine: RecordingEngine())
        let url = URL(string: "https://www.news.test/story")!
        let tab = model.store.addTab(kind: .today, title: "News", url: url)
        let engine = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
        model.contentBlocking.blockedCount = { _ in 4 }
        model.contentBlocking.blockedHosts = { _ in Self.blockedReply() }
        XCTAssertEqual(model.blockedList(for: engine)?.entries.count, 3)
        model.contentBlocking.blockedCountChanged()
        model.persistence.flush()

        let saved = try String(decoding: Data(contentsOf: sidebarFile), as: UTF8.self)
        let records = String(describing: SidebarSyncProjection.extract(model.store.makeSnapshot()))
        for host in ["doubleclick.net", "google-analytics.com"] {
            XCTAssertFalse(saved.contains(host), "\(host) in the sidebar file")
            XCTAssertFalse(records.contains(host), "\(host) in a sync record")
            XCTAssertFalse(model.contentBlockingEvents.contains { $0.contains(host) }, "\(host) in the blocking log")
        }
    }

    func testAllowWritesOneOwnRuleTellsTheEngineAndRemoveTakesItBack() async throws {
        let model = launch()
        let recorder = RecordingEngine()
        try await attach(model, engine: recorder)
        let url = URL(string: "https://www.news.test/story")!
        let tab = model.store.addTab(kind: .today, title: "News", url: url)
        let engine = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
        model.contentBlockingProfileOpened(engineProfile: 4, profile: model.profileID(for: tab))
        model.setContentBlockingOwnRules("||mine.test^", for: model.profileID(for: tab))
        model.contentBlocking.blockedHosts = { _ in Self.blockedReply() }
        _ = recorder.take()

        let list = try XCTUnwrap(model.blockedList(for: engine))
        XCTAssertTrue(model.canAllowBlockedHosts(for: engine, on: list))
        let site = try XCTUnwrap(list.allowSite)
        model.setBlockedHost("doubleclick.net", allowed: true, on: site, of: engine)
        XCTAssertEqual(model.store.contentBlocking().ownRules, "||mine.test^\n@@||doubleclick.net^$domain=news.test\n")
        XCTAssertEqual(recorder.take(), ["rules 4"], "the engine has the rule before the tab reloads")
        XCTAssertEqual(model.allowedBlockedHosts(for: engine, pageSite: site), ["doubleclick.net"])

        // A name that is not one site changes nothing, tells the engine nothing, and the person is told.
        for name in ["evil.test^$important", "localhost", "co.uk"] {
            model.toast = nil
            model.setBlockedHost(name, allowed: true, on: site, of: engine)
            XCTAssertEqual(model.store.contentBlocking().ownRules, "||mine.test^\n@@||doubleclick.net^$domain=news.test\n", name)
            XCTAssertEqual(recorder.take(), [], name)
            XCTAssertEqual(model.toast?.message, ContentBlockingSiteAllow.Refusal.notOneSite.message, name)
        }

        model.setBlockedHost("doubleclick.net", allowed: false, on: site, of: engine)
        XCTAssertEqual(model.store.contentBlocking().ownRules, "||mine.test^\n")
        XCTAssertEqual(recorder.take(), ["rules 4"])
        XCTAssertEqual(model.allowedBlockedHosts(for: engine, pageSite: site), [])
    }

    /// Security BL-10: the rule is for the site the list was drawn with. The
    /// tab's address at the click may be another site's, or one the tab has
    /// not reached; the engine is asked where the tab is, and when that is
    /// not the drawn site nothing is written.
    func testAllowWritesNothingOnceTheTabHasLeftTheSiteTheListWasShownFor() async throws {
        let model = launch()
        let recorder = RecordingEngine()
        try await attach(model, engine: recorder)
        let tab = model.store.addTab(kind: .today, title: "News", url: URL(string: "https://www.news.test/story")!)
        let engine = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
        model.contentBlockingProfileOpened(engineProfile: 4, profile: model.profileID(for: tab))
        var page = "news.test"
        model.contentBlocking.blockedHosts = { _ in Self.blockedReply(page: page) }
        let drawn = try XCTUnwrap(model.blockedList(for: engine)?.allowSite)
        XCTAssertEqual(drawn, "news.test")
        _ = recorder.take()

        // The page starts a navigation as the person reaches for Allow, and it commits.
        page = "bank.test"
        model.setBlockedHost("doubleclick.net", allowed: true, on: drawn, of: engine)
        XCTAssertEqual(model.store.contentBlocking().ownRules, "", "no rule for the site the tab moved to, and none for the one it left")
        XCTAssertEqual(recorder.take(), [])
        XCTAssertEqual(model.toast?.message, ContentBlockingSiteAllow.Refusal.pageMoved.message)

        // The tab's address runs ahead of the commit: the engine still says news.test, and that is what counts.
        page = "news.test"
        model.store.updateTab(tab.id, url: URL(string: "https://bank.test/login")!)
        model.setBlockedHost("doubleclick.net", allowed: true, on: drawn, of: engine)
        XCTAssertEqual(model.store.contentBlocking().ownRules, "@@||doubleclick.net^$domain=news.test\n")

        // Remove is held to the same: not from another site's page, and not without the engine's word.
        page = "bank.test"
        model.setBlockedHost("doubleclick.net", allowed: false, on: drawn, of: engine)
        model.contentBlocking.blockedHosts = { _ in nil }
        model.setBlockedHost("doubleclick.net", allowed: false, on: drawn, of: engine)
        XCTAssertEqual(model.store.contentBlocking().ownRules, "@@||doubleclick.net^$domain=news.test\n")
    }

    /// Security BL-11: the site in the rule is the engine's name for the
    /// page, from Chromium's suffix list. On `someone.web.app` the shell's
    /// own idea of a site is `web.app`, which is every site under it.
    func testAllowOnASharedSuffixIsForThatOneSite() async throws {
        let model = launch()
        try await attach(model, engine: RecordingEngine())
        let url = URL(string: "https://someone.web.app/")!
        let tab = model.store.addTab(kind: .today, title: "App", url: url)
        let engine = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
        XCTAssertEqual(BoostScopeMatcher.registrableDomain("someone.web.app"), "web.app", "the shell's guess at this page's site")
        model.contentBlocking.blockedHosts = { _ in Self.blockedReply(page: "someone.web.app") }
        let list = try XCTUnwrap(model.blockedList(for: engine))
        XCTAssertEqual(list.allowSite, "someone.web.app")
        model.setBlockedHost("doubleclick.net", allowed: true, on: "someone.web.app", of: engine)
        XCTAssertEqual(model.store.contentBlocking().ownRules, "@@||doubleclick.net^$domain=someone.web.app\n")

        // A page the engine says is not one site has no Allow at all.
        model.contentBlocking.blockedHosts = { _ in #"{"page":{"host":"web.app","registrable":false},"hosts":[],"more":0}"# }
        let suffix = try XCTUnwrap(model.blockedList(for: engine))
        XCTAssertFalse(model.canAllowBlockedHosts(for: engine, on: suffix))
        model.setBlockedHost("google-analytics.com", allowed: true, on: "web.app", of: engine)
        XCTAssertEqual(model.store.contentBlocking().ownRules, "@@||doubleclick.net^$domain=someone.web.app\n")
    }

    func testAPrivateWindowsListHasNoAllow() async throws {
        let model = launch()
        try await attach(model, engine: RecordingEngine())
        let url = URL(string: "https://secret.test/")!
        let engine = model.engineHost.privateEngine(session: UUID(), parentProfileID: model.store.activeProfileID, shellID: UUID())
        let site = try XCTUnwrap(SiteControlCenter.site(for: url))
        model.contentBlocking.blockedCount = { _ in 4 }
        model.contentBlocking.blockedHosts = { _ in Self.blockedReply(page: "secret.test") }
        XCTAssertEqual(model.contentBlockingRow(for: engine, site: site)?.hasBlockedList, true, "a private window may look")
        let list = try XCTUnwrap(model.blockedList(for: engine))
        XCTAssertEqual(list.entries.count, 3)
        XCTAssertFalse(model.canAllowBlockedHosts(for: engine, on: list))
        model.setBlockedHost("doubleclick.net", allowed: true, on: "secret.test", of: engine)
        XCTAssertEqual(model.store.contentBlocking().ownRules, "", "nothing a private window showed is written to the profile")
    }

    /// ABI 1.69, feature `content_blocking_hosts`: without both the row shows the count alone.
    func testTheEngineFeatureGatesTheBlockedList() {
        let all: (String) -> Bool = { _ in true }
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 68, hasFeature: all).contentBlockingHosts)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 69, hasFeature: all).contentBlockingHosts)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 69, hasFeature: { $0 != "content_blocking_hosts" }).contentBlockingHosts)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 69, hasFeature: { $0 != "content_blocking" }).contentBlockingHosts,
                       "no list without blocking")
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 68, hasFeature: all).contentBlocking, "an engine that only counts still blocks")
        XCTAssertFalse(ChromiumCapabilities.none.contentBlockingHosts)
    }

    /// ABI 1.69, feature `host_sites`: the engine's public suffix list. It
    /// does not depend on blocking: boosts and address lines ask it too.
    func testTheEngineFeatureGatesTheSiteNames() {
        let all: (String) -> Bool = { _ in true }
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 68, hasFeature: all).hostSites)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 69, hasFeature: all).hostSites)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 69, hasFeature: { $0 != "host_sites" }).hostSites)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 69, hasFeature: { $0 != "content_blocking" }).hostSites)
        XCTAssertFalse(ChromiumCapabilities.none.hostSites)
    }

    func testAPrivateWindowNeverWritesItsSiteIntoTheProfile() async throws {
        let model = launch()
        try await attach(model, engine: RecordingEngine())
        let url = URL(string: "https://secret.test/")!
        let engine = model.engineHost.privateEngine(session: UUID(), parentProfileID: model.store.activeProfileID, shellID: UUID())
        let site = try XCTUnwrap(SiteControlCenter.site(for: url))
        let row = try XCTUnwrap(model.contentBlockingRow(for: engine, site: site))
        XCTAssertEqual(row.actions, [], "the row reports and does nothing")
        model.setContentBlocking(false, forSiteOf: engine, site: site)
        model.performSiteSetting(.turnOffBlockingForSite, on: row, engine: engine, site: site)
        XCTAssertEqual(model.store.contentBlocking().exceptions, [])
    }

    func testListsAreCheckedOnlyWhileBlockingIsOnSomewhere() async throws {
        try makeExistingInstall()
        let model = launch()
        let mirror = NoMirror()
        try await attach(model, engine: RecordingEngine())
        model.contentBlocking.fetcher = mirror
        model.checkBlocklists()
        model.checkBlocklistsIfDue()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(mirror.requests, 0, "Off in every profile: ReArc asks the mirror for nothing")

        model.setContentBlockingEnabled(true, for: model.store.profiles[0].id)
        for _ in 0..<400 where model.contentBlocking.lastCheck == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(mirror.requests, 1, "turning blocking on asks once")
        XCTAssertEqual(model.contentBlocking.lastCheck, .unreachable)
        XCTAssertEqual(model.contentBlocking.bundle?.source, .builtIn, "offline, the built-in lists are used")
        model.checkBlocklistsIfDue()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(mirror.requests, 1, "a failed check is not repeated within the hour")
    }
}
