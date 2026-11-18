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
        for id in ["easyprivacy", "peter-lowe", "easylist"] {
            let rules = Data("[]".utf8)
            try rules.write(to: bundle.appendingPathComponent("rules/\(id).json"))
            lists.append(["id": id, "title": id, "files": ["rules/\(id).json": BlocklistVerifier.sha256(of: rules)]])
        }
        let manifest = try JSONSerialization.data(withJSONObject: ["version": "202611180900", "created": "2026-11-18T09:00:00Z", "lists": lists])
        try manifest.write(to: bundle.appendingPathComponent("manifest.json"))
        try Data(key.signature(for: manifest).base64EncodedString().utf8).write(to: bundle.appendingPathComponent("manifest.json.sig"))
        return bundle
    }

    private func attach(_ model: BrowserViewModel, engine: RecordingEngine) async throws {
        model.attachContentBlocking(engine: engine, engineVersion: nil, builtInLists: try builtInBundle(), publicKey: key.publicKey.rawRepresentation)
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
        XCTAssertEqual(engine.take(), ["directory", "exceptions 4 ", "rules 4", "level 4 2 easyprivacy,peter-lowe,easylist"])
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
        XCTAssertEqual(engine.take().last, "level 4 0 ", "an old profile opens with blocking Off")
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
        XCTAssertEqual(engine.take(), ["level 4 2 easyprivacy,peter-lowe,easylist"])
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
        XCTAssertEqual(engine.take(), ["exceptions 4 ", "rules 4", "level 4 0 "])
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
