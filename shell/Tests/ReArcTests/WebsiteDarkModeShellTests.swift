import XCTest
@testable import ReArc
@testable import SidebarModel

/// Dark mode for websites in the shell: what the engine is told and when,
/// the site controls row, and where a site's choice is kept. The engine is a
/// recorder. Security's conditions for tab/105 are tested here: the sites
/// are in a file of the data folder by profile, never in the app's defaults
/// or the sidebar's file, and a build or engine without the feature reads
/// and changes none of it.
@MainActor
final class WebsiteDarkModeShellTests: XCTestCase {
    private final class RecordingEngine: WebsiteDarkModeEngine {
        var calls: [String] = []
        func setWebsiteDarkMode(engineProfile: UInt64, state: WebsiteDarkMode.EngineState) {
            calls.append("\(engineProfile) \(state.dark ? "dark" : "light") on[\(state.darkHosts.joined(separator: ","))] off[\(state.lightHosts.joined(separator: ","))]")
        }
        func take() -> [String] {
            defer { calls = [] }
            return calls
        }
    }

    private var directory: URL!
    private var defaultsName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-dark-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaultsName = "rearc-dark-shell-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)!
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: directory)
    }

    private var sidebarFile: URL { directory.appendingPathComponent("sidebar.json") }
    private var sitesFile: URL { directory.appendingPathComponent(WebsiteDarkModeSites.fileName) }

    private func launch() -> BrowserViewModel {
        let model = BrowserViewModel(
            persistence: SidebarFilePersistence(fileURL: sidebarFile),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-dark-unload-\(UUID().uuidString)")!
        model.externalLinkDefaults = defaults
        model.websiteDarkModeSetting = .off
        return model
    }

    private func page(_ model: BrowserViewModel, _ address: String) throws -> (engine: any WebEngine, site: SiteControlCenter.Site) {
        let url = try XCTUnwrap(URL(string: address))
        let tab = model.store.addTab(kind: .today, title: "Page", url: url)
        return (model.engineHost.engine(for: tab, profileID: model.profileID(for: tab)), try XCTUnwrap(SiteControlCenter.site(for: url)))
    }

    private func darkRow(_ model: BrowserViewModel, _ page: (engine: any WebEngine, site: SiteControlCenter.Site)) throws -> SiteControlCenter.SettingRow {
        try XCTUnwrap(model.siteControlSettingRows(for: page.engine, site: page.site).first { $0.kind == .websiteDarkMode })
    }

    // MARK: Without the engine's call

    func testWithoutAnEngineThatHasItNothingIsShownSentOrWritten() throws {
        // What a later build left: the setting in the defaults and a site in the file.
        defaults.set(WebsiteDarkModeSetting.always.rawValue, forKey: WebsiteDarkModeSetting.defaultsKey)
        let profile = UUID()
        var kept = WebsiteDarkModeSites()
        kept.set(.on, forHost: "news.example", profile: profile)
        try kept.save(to: sitesFile)
        let bytes = try Data(contentsOf: sitesFile)

        let model = launch()
        XCTAssertFalse(model.websiteDarkMode.isAvailable)
        let news = try page(model, "https://news.example/story")
        XCTAssertNil(model.websiteDarkModeRow(for: news.engine, site: news.site))
        XCTAssertFalse(model.siteControlSettingRows(for: news.engine, site: news.site).contains { $0.kind == .websiteDarkMode }, "the panel is as it was")
        model.setWebsiteDarkMode(.off, forSiteOf: news.engine, site: news.site)
        model.websiteDarkModeStateChanged()
        model.setWebsiteDarkModeAppearance(isDark: true)
        XCTAssertEqual(try Data(contentsOf: sitesFile), bytes, "the file is not touched: an unknown profile's site is still there for the build that knows it")
    }

    // MARK: The setting and the engine

    func testTheSettingAndDarnisAppearanceReachTheEngineAtOnce() throws {
        let model = launch()
        let engine = RecordingEngine()
        model.attachWebsiteDarkMode(engine: engine)
        XCTAssertTrue(model.websiteDarkMode.isAvailable)
        let profile = model.store.profiles[0].id
        model.websiteDarkModeProfileOpened(engineProfile: 4, profile: profile)
        XCTAssertEqual(engine.take(), [], "Off, the default: the engine is told nothing")

        model.websiteDarkModeSetting = .always
        XCTAssertEqual(engine.take(), ["4 dark on[] off[]"])
        XCTAssertEqual(defaults.string(forKey: WebsiteDarkModeSetting.defaultsKey), "always", "the setting is the app's: its defaults")
        model.websiteDarkModeSetting = .always
        XCTAssertEqual(engine.take(), [])

        model.setWebsiteDarkModeAppearance(isDark: false)
        model.websiteDarkModeSetting = .followAppearance
        XCTAssertEqual(engine.take(), ["4 light on[] off[]"], "Darni is light")
        model.setWebsiteDarkModeAppearance(isDark: true)
        XCTAssertEqual(engine.take(), ["4 dark on[] off[]"], "the Mac went dark: open tabs follow")
        model.setWebsiteDarkModeAppearance(isDark: true)
        XCTAssertEqual(engine.take(), [])
        model.setWebsiteDarkModeAppearance(isDark: false)
        XCTAssertEqual(engine.take(), ["4 light on[] off[]"])

        model.websiteDarkModeSetting = .off
        model.setWebsiteDarkModeAppearance(isDark: true)
        XCTAssertEqual(engine.take(), [], "Off does not follow the appearance")
    }

    // MARK: The site controls row

    func testTheRowSetsASitesOwnChoiceAndTheEngineHearsIt() throws {
        let model = launch()
        let engine = RecordingEngine()
        model.attachWebsiteDarkMode(engine: engine)
        let news = try page(model, "https://www.news.example/story?id=1")
        let profile = model.store.owningProfileID(of: try XCTUnwrap(news.engine.pagePrompts.profileID))
        model.websiteDarkModeProfileOpened(engineProfile: 4, profile: profile)

        var row = try darkRow(model, news)
        XCTAssertEqual(row.state, "Off")
        XCTAssertEqual(row.actions, [.darkModeOnForSite])
        model.performSiteSetting(.darkModeOnForSite, on: row, engine: news.engine, site: news.site)
        XCTAssertEqual(engine.take(), ["4 light on[www.news.example] off[]"], "the engine has it before the next navigation")
        XCTAssertEqual(model.websiteDarkMode.sites.choice(forHost: "www.news.example", profile: profile), .on)

        row = try darkRow(model, news)
        XCTAssertEqual(row.state, "On for this site")
        XCTAssertEqual(row.actions, [.darkModeOffForSite, .darkModeDefaultForSite])
        model.performSiteSetting(.darkModeOffForSite, on: row, engine: news.engine, site: news.site)
        XCTAssertEqual(engine.take(), ["4 light on[] off[www.news.example]"])
        model.websiteDarkModeSetting = .always
        XCTAssertEqual(engine.take(), ["4 dark on[] off[www.news.example]"])
        XCTAssertEqual(try darkRow(model, news).state, "Off for this site", "the site's choice holds when the setting changes")

        // Another site of the profile follows the setting; another host of the same name is another site.
        let other = try page(model, "https://news.example/")
        XCTAssertEqual(try darkRow(model, other).state, "On")

        row = try darkRow(model, news)
        model.performSiteSetting(.darkModeDefaultForSite, on: row, engine: news.engine, site: news.site)
        XCTAssertEqual(engine.take(), ["4 dark on[] off[]"])
        XCTAssertEqual(try darkRow(model, news).state, "On")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sitesFile.path), "no site with a choice: no file")

        // Actions of other rows do nothing to this one.
        model.performSiteSetting(.allow, on: row, engine: news.engine, site: news.site)
        model.performSiteSetting(.turnOffBlockingForSite, on: row, engine: news.engine, site: news.site)
        XCTAssertEqual(engine.take(), [])
    }

    func testTheRowIsAboutTheSiteThePanelWasDrawnFor() throws {
        let model = launch()
        let engine = RecordingEngine()
        model.attachWebsiteDarkMode(engine: engine)
        let news = try page(model, "https://news.example/story")
        let profile = model.store.owningProfileID(of: try XCTUnwrap(news.engine.pagePrompts.profileID))
        model.websiteDarkModeProfileOpened(engineProfile: 4, profile: profile)
        let row = try darkRow(model, news)
        // The tab is on another page by the click (a panel drawn for one site, a tab that
        // moved on): what is written is for the site the panel showed.
        let drawn = try XCTUnwrap(SiteControlCenter.site(for: URL(string: "https://drawn.example/page")))
        model.performSiteSetting(.darkModeOnForSite, on: row, engine: news.engine, site: drawn)
        XCTAssertEqual(model.websiteDarkMode.sites.choices(for: profile), ["drawn.example": .on])
    }

    func testAPrivateWindowReadsItsProfilesChoiceAndWritesNone() throws {
        let model = launch()
        let engine = RecordingEngine()
        model.attachWebsiteDarkMode(engine: engine)
        let news = try page(model, "https://news.example/story")
        let profile = model.store.owningProfileID(of: try XCTUnwrap(news.engine.pagePrompts.profileID))
        model.websiteDarkModeProfileOpened(engineProfile: 4, profile: profile)
        model.setWebsiteDarkMode(.on, forSiteOf: news.engine, site: news.site)
        _ = engine.take()
        let saved = try Data(contentsOf: sitesFile)

        news.engine.pagePrompts.privateSession = UUID()
        defer { news.engine.pagePrompts.privateSession = nil }
        let row = try darkRow(model, news)
        XCTAssertEqual(row.state, "On for this site")
        XCTAssertEqual(row.actions, [], "the row only reports")
        model.performSiteSetting(.darkModeOffForSite, on: row, engine: news.engine, site: news.site)
        model.setWebsiteDarkMode(nil, forSiteOf: news.engine, site: news.site)
        let bank = try page(model, "https://bank.example/")
        bank.engine.pagePrompts.privateSession = UUID()
        defer { bank.engine.pagePrompts.privateSession = nil }
        model.setWebsiteDarkMode(.on, forSiteOf: bank.engine, site: bank.site)
        XCTAssertEqual(engine.take(), [])
        XCTAssertEqual(try Data(contentsOf: sitesFile), saved, "a site visited in a private window is never written down")
    }

    func testATabTheSettingDoesNotReachHasNoRow() throws {
        let model = launch()
        model.attachWebsiteDarkMode(engine: RecordingEngine())
        let news = try page(model, "https://news.example/")
        XCTAssertNotNil(model.websiteDarkModeRow(for: news.engine, site: news.site))
        model.websiteDarkMode.covers = { _ in false }  // a WebKit tab in the Chromium shell
        XCTAssertNil(model.websiteDarkModeRow(for: news.engine, site: news.site))
    }

    // MARK: Where the sites are kept (security, tab/105)

    func testASitesChoiceIsInTheProfilesFileAndNowhereElse() throws {
        let model = launch()
        model.attachWebsiteDarkMode(engine: RecordingEngine())
        let news = try page(model, "https://secret-interest.example/story")
        let profile = model.store.owningProfileID(of: try XCTUnwrap(news.engine.pagePrompts.profileID))
        func sidebar() throws -> NSDictionary {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(model.store.makeSnapshot())) as? NSDictionary)
        }
        let sidebarBefore = try sidebar()
        model.setWebsiteDarkMode(.on, forSiteOf: news.engine, site: news.site)
        model.websiteDarkModeSetting = .always

        // The file beside the sidebar's, by profile.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sitesFile)) as? [String: Any])
        XCTAssertEqual(json["scopes"] as? [String: [String: String]], [profile.uuidString: ["secret-interest.example": "on"]])
        XCTAssertEqual(sitesFile.deletingLastPathComponent(), sidebarFile.deletingLastPathComponent())

        // Not the app's defaults: they hold the setting and no site.
        let domain = defaults.persistentDomain(forName: defaultsName) ?? [:]
        XCTAssertEqual(domain[WebsiteDarkModeSetting.defaultsKey] as? String, "always")
        XCTAssertFalse("\(domain)".contains("secret-interest"), "no site in the defaults")

        // Not the sidebar's file, which is what syncs: it is byte for byte what it was.
        XCTAssertEqual(try sidebar(), sidebarBefore, "nothing new in the sidebar file: no field on a synced record")
        model.persistence.flush()
        if let sidebar = try? String(contentsOf: sidebarFile, encoding: .utf8) {
            XCTAssertFalse(sidebar.contains("secret-interest.example\":\"on"))
            XCTAssertFalse(sidebar.contains("websiteDarkMode"))
        }
    }

    func testTheChoicesAreReadAtTheNextLaunchAndToldToTheEngineAtProfileLoad() throws {
        var model = launch()
        model.attachWebsiteDarkMode(engine: RecordingEngine())
        let news = try page(model, "https://news.example/story")
        let profile = model.store.owningProfileID(of: try XCTUnwrap(news.engine.pagePrompts.profileID))
        model.setWebsiteDarkMode(.off, forSiteOf: news.engine, site: news.site)
        model.persistence.flush()

        model = launch()
        XCTAssertEqual(model.websiteDarkMode.sites.choices(for: profile), ["news.example": .off])
        let engine = RecordingEngine()
        model.attachWebsiteDarkMode(engine: engine)
        model.websiteDarkModeProfileOpened(engineProfile: 7, profile: profile)
        XCTAssertEqual(engine.take(), ["7 light on[] off[news.example]"], "before any of the profile's tabs exist")
    }

    func testADeletedProfilesSitesGoWithIt() throws {
        let model = launch()
        model.attachWebsiteDarkMode(engine: RecordingEngine())
        let work = model.store.addProfile(name: "Work")
        let kept = model.store.profiles[0].id
        XCTAssertNotEqual(work.id, kept)
        var sites = model.websiteDarkMode.sites
        XCTAssertTrue(sites.isEmpty)
        let news = try page(model, "https://news.example/")
        model.setWebsiteDarkMode(.on, forSiteOf: news.engine, site: news.site)
        model.websiteDarkMode.profilesDeleted([])
        sites = model.websiteDarkMode.sites
        XCTAssertEqual(sites.scopes.count, 1)

        // A profile that is deleted while its sites are on file.
        var file = WebsiteDarkModeSites.load(from: sitesFile)
        file.set(.off, forHost: "work.example", profile: work.id)
        try file.save(to: sitesFile)
        let relaunched = launch()
        XCTAssertEqual(relaunched.websiteDarkMode.sites.scopes.count, 2)
        relaunched.websiteDarkMode.profilesDeleted([work.id])
        XCTAssertNil(relaunched.websiteDarkMode.sites.scopes[work.id.uuidString])
        XCTAssertNil(WebsiteDarkModeSites.load(from: sitesFile).scopes[work.id.uuidString], "gone from the file too")
    }

    func testSitesOfAProfileThatNoLongerExistsAreDroppedWhenTheEngineAttaches() throws {
        var model = launch()
        model.persistence.flush()
        let profile = model.store.profiles[0].id
        var file = WebsiteDarkModeSites()
        file.set(.on, forHost: "here.example", profile: profile)
        file.set(.on, forHost: "gone.example", profile: UUID())
        try file.save(to: sitesFile)

        model = launch()
        XCTAssertEqual(model.store.profiles[0].id, profile)
        XCTAssertEqual(model.websiteDarkMode.sites.scopes.count, 2, "read as it is")
        model.attachWebsiteDarkMode(engine: RecordingEngine())
        XCTAssertEqual(model.websiteDarkMode.sites.scopes, [profile.uuidString: ["here.example": .on]])
        XCTAssertEqual(WebsiteDarkModeSites.load(from: sitesFile).scopes.keys.sorted(), [profile.uuidString])
    }

    // MARK: The engine's feature

    func testTheShellUsesDarkModeOnlyWithAnEngineThatAdvertisesIt() {
        let all: (String) -> Bool = { _ in true }
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 73, hasFeature: all).websiteDarkMode)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 72, hasFeature: all).websiteDarkMode, "an engine from before the call")
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 73, hasFeature: { $0 != "website_dark_mode" }).websiteDarkMode)
        XCTAssertFalse(ChromiumCapabilities.none.websiteDarkMode)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 73, hasFeature: all).summary.contains("website_dark_mode=1"))
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 72, hasFeature: all).summary.contains("website_dark_mode=0"))
    }

    // MARK: Clear Browsing Data and deleting a profile (security DM-1)

    /// A profile's history, as the engine would answer its queries.
    private final class FakeHistory {
        /// storage -> hosts it has a page of.
        var visited: [Profile.ID: Set<String>] = [:]
        /// Every query is refused.
        var refuses = false
        /// The text search finds nothing, whatever is in the history.
        var searchIsBroken = false
        /// The hosts the list of recent pages does not reach (older visits).
        var old: Set<String> = []
        var queries = 0
        var query: WebsiteDarkModeHistory.Query {
            { [self] storage, text, reply in
                queries += 1
                guard !refuses else { return reply(nil) }
                let hosts = (visited[storage] ?? []).sorted()
                if text.isEmpty { return reply(hosts.filter { !old.contains($0) }.map { "https://\($0)/recent" }) }
                reply(searchIsBroken ? [] : hosts.filter { $0.contains(text) }.map { "https://\($0)/found" })
            }
        }
    }

    /// A model with the engine's dark mode and a history, and a profile
    /// with two sites that have a choice and a visit each.
    private func launchWithHistory() throws -> (model: BrowserViewModel, engine: RecordingEngine, history: FakeHistory, profile: Profile.ID) {
        let model = launch()
        let engine = RecordingEngine()
        let history = FakeHistory()
        model.websiteDarkMode.historyQuery = history.query
        model.attachWebsiteDarkMode(engine: engine)
        let profile = model.store.profiles[0].id
        history.visited[profile] = ["news.example", "bank.example"]
        for address in ["https://news.example/story", "https://bank.example/"] {
            let site = try page(model, address)
            model.setWebsiteDarkMode(.on, forSiteOf: site.engine, site: site.site)
        }
        model.websiteDarkModeProfileOpened(engineProfile: 4, profile: profile)
        XCTAssertEqual(model.websiteDarkMode.sites.choices(for: profile), ["news.example": .on, "bank.example": .on], "both are in the history")
        _ = engine.take()
        return (model, engine, history, profile)
    }

    func testClearBrowsingDataTakesTheSitesWhoseHistoryItCleared() throws {
        let (model, engine, history, profile) = try launchWithHistory()
        let settings = model.store.addTab(kind: .today, title: "Clear Browsing Data", url: BrowserInternalPage.clearBrowsingData.url)
        _ = model.engineHost.engine(for: settings, profileID: model.profileID(for: settings))

        // The tab shows Chromium's Clear Browsing Data: from now on the sites are checked.
        model.handleTabNavigationCommit(tabID: settings.id, url: BrowserInternalPage.clearBrowsingData.url, title: "Settings")
        XCTAssertEqual(model.websiteDarkMode.historyPagesForTesting, [.tab(settings.id): profile])
        XCTAssertTrue(model.websiteDarkMode.historyTimerIsRunning)
        model.websiteDarkModeHistoryTick()
        XCTAssertEqual(model.websiteDarkMode.sites.choices(for: profile).count, 2, "nothing was cleared yet: nothing goes")
        XCTAssertEqual(engine.take(), [])

        // "Last hour": the visit to one site goes, the other's stays.
        history.visited[profile] = ["bank.example"]
        model.websiteDarkModeHistoryTick()
        XCTAssertEqual(model.websiteDarkMode.sites.choices(for: profile), ["bank.example": .on])
        XCTAssertEqual(engine.take(), ["4 light on[bank.example] off[]"], "the engine is told at once")
        XCTAssertEqual(WebsiteDarkModeSites.load(from: sitesFile).choices(for: profile), ["bank.example": .on], "and the file")

        // "All time", and the tab goes on to another page: checked a last time, without waiting for the timer.
        history.visited[profile] = []
        model.handleTabNavigationCommit(tabID: settings.id, url: URL(string: "https://elsewhere.example/")!, title: "Elsewhere")
        XCTAssertTrue(model.websiteDarkMode.sites.isEmpty)
        XCTAssertEqual(engine.take(), ["4 light on[] off[]"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sitesFile.path), "no site left: no file that names one")
        XCTAssertEqual(model.websiteDarkMode.historyPagesForTesting, [:])
        XCTAssertFalse(model.websiteDarkMode.historyTimerIsRunning, "no such page open: nothing is asked any more")
    }

    func testAClosedSettingsTabIsCheckedOnceMore() throws {
        let (model, _, history, profile) = try launchWithHistory()
        // A tab and a Little Arc window on such pages that are gone by the timer's turn.
        model.websiteDarkModePageCommitted(.tab(UUID()), profile: profile, url: URL(string: "chrome://history")!)
        model.websiteDarkModePageCommitted(.littleArc(UUID()), profile: profile, url: BrowserInternalPage.clearBrowsingData.url)
        XCTAssertEqual(model.websiteDarkMode.historyPagesForTesting.count, 2)
        history.visited[profile] = []
        model.websiteDarkModeHistoryTick()
        XCTAssertTrue(model.websiteDarkMode.sites.isEmpty, "the history was cleared before the tab closed")
        XCTAssertEqual(model.websiteDarkMode.historyPagesForTesting, [:])
        XCTAssertFalse(model.websiteDarkMode.historyTimerIsRunning)
    }

    func testAPageThatCannotDeleteHistoryStartsNothing() throws {
        let (model, _, history, profile) = try launchWithHistory()
        history.queries = 0
        model.websiteDarkModePageCommitted(.tab(UUID()), profile: profile, url: URL(string: "https://news.example/")!)
        model.websiteDarkModePageCommitted(.tab(UUID()), profile: profile, url: URL(string: "chrome://extensions")!)
        XCTAssertEqual(model.websiteDarkMode.historyPagesForTesting, [:])
        XCTAssertFalse(model.websiteDarkMode.historyTimerIsRunning)
        XCTAssertEqual(history.queries, 0, "ordinary browsing asks the history nothing")
    }

    func testASiteIsKeptWhenTheHistoryCannotSay() throws {
        let (model, engine, history, profile) = try launchWithHistory()
        // The visit to one site is gone, but every query is refused.
        history.visited[profile] = ["bank.example"]
        history.refuses = true
        model.checkWebsiteDarkModeSitesAgainstHistory(profile: profile)
        XCTAssertEqual(model.websiteDarkMode.sites.choices(for: profile).count, 2, "a refused query is not an empty history")
        // The search finds nothing at all, not even a host that is among the recent pages: it cannot say.
        history.refuses = false
        history.searchIsBroken = true
        model.checkWebsiteDarkModeSitesAgainstHistory(profile: profile)
        XCTAssertEqual(model.websiteDarkMode.sites.choices(for: profile).count, 2, "a search that cannot find what is there deletes nothing")
        // And with no history to ask at all (an engine without the history query).
        history.searchIsBroken = false
        model.websiteDarkMode.historyQuery = nil
        model.checkWebsiteDarkModeSitesAgainstHistory(profile: profile)
        XCTAssertEqual(model.websiteDarkMode.sites.choices(for: profile).count, 2)
        XCTAssertEqual(engine.take(), [])
        // The same history, with a search that works: the site whose visit is gone goes.
        model.websiteDarkMode.historyQuery = history.query
        model.checkWebsiteDarkModeSitesAgainstHistory(profile: profile)
        XCTAssertEqual(model.websiteDarkMode.sites.choices(for: profile), ["bank.example": .on])
    }

    func testASiteVisitedLongAgoIsFoundByTheSearch() throws {
        let (model, _, history, profile) = try launchWithHistory()
        // Its visit is older than the list of recent pages reaches; other pages are newer.
        history.visited[profile] = ["news.example", "bank.example", "recent.example"]
        history.old = ["news.example", "bank.example"]
        model.checkWebsiteDarkModeSitesAgainstHistory(profile: profile)
        XCTAssertEqual(model.websiteDarkMode.sites.choices(for: profile).count, 2, "both are still in the history")
        history.visited[profile] = ["bank.example", "recent.example"]
        model.checkWebsiteDarkModeSitesAgainstHistory(profile: profile)
        XCTAssertEqual(model.websiteDarkMode.sites.choices(for: profile), ["bank.example": .on], "the one whose visit was deleted goes")
    }

    func testAnotherProfilesHistoryIsItsOwn() throws {
        let (model, _, history, profile) = try launchWithHistory()
        let work = model.store.addProfile(name: "Work")
        XCTAssertTrue(model.websiteDarkMode.change { $0.set(.off, forHost: "news.example", profile: work.id) })
        history.visited[work.id] = ["news.example"]
        history.visited[profile] = []
        model.checkWebsiteDarkModeSitesAgainstHistory(profile: profile)
        XCTAssertTrue(model.websiteDarkMode.sites.choices(for: profile).isEmpty, "this profile's history was cleared")
        XCTAssertEqual(model.websiteDarkMode.sites.choices(for: work.id), ["news.example": .off], "the other profile's was not")
    }

    func testSitesWhoseHistoryWentWhileDarniDidNotLookGoWhenTheProfileLoads() throws {
        var (model, _, _, profile) = try launchWithHistory()
        model.persistence.flush()
        XCTAssertEqual(WebsiteDarkModeSites.load(from: sitesFile).choices(for: profile).count, 2)

        // Clear Browsing Data, then a quit before the next check; the next launch.
        model = launch()
        let engine = RecordingEngine()
        let history = FakeHistory()
        history.visited[profile] = ["bank.example"]
        model.websiteDarkMode.historyQuery = history.query
        model.attachWebsiteDarkMode(engine: engine)
        XCTAssertEqual(model.websiteDarkMode.sites.choices(for: profile).count, 2, "not before the engine's profile can answer")
        model.websiteDarkModeProfileOpened(engineProfile: 9, profile: profile)
        XCTAssertEqual(model.websiteDarkMode.sites.choices(for: profile), ["bank.example": .on])
        XCTAssertEqual(engine.take(), ["9 light on[bank.example,news.example] off[]", "9 light on[bank.example] off[]"],
                       "the profile is told its sites, then the one that is left")
    }

    func testAChoiceMadeWhileTheHistoryIsAskedStays() throws {
        let (model, _, _, profile) = try launchWithHistory()
        // An engine that answers later: the queries wait here.
        var replies: [(text: String, reply: ([String]?) -> Void)] = []
        model.websiteDarkMode.historyQuery = { _, text, reply in replies.append((text, reply)) }
        model.checkWebsiteDarkModeSitesAgainstHistory(profile: profile)
        model.checkWebsiteDarkModeSitesAgainstHistory(profile: profile)
        XCTAssertEqual(replies.map(\.text), [""], "one check at a time for a profile, one query at a time")
        // While the engine answers, the person turns one of the two off: they are on that site now.
        let news = try page(model, "https://news.example/again")
        model.setWebsiteDarkMode(.off, forSiteOf: news.engine, site: news.site)
        replies[0].reply([])  // no web page in the history: both sites are without a visit
        XCTAssertEqual(model.websiteDarkMode.sites.choices(for: profile), ["news.example": .off], "the answer was about the choice before")
        // The second request runs after the first, and finds the site in the history again.
        XCTAssertEqual(replies.count, 2)
        replies[1].reply(["https://news.example/again"])
        XCTAssertEqual(model.websiteDarkMode.sites.choices(for: profile), ["news.example": .off])
    }

    func testDeletingAProfileDeletesItsSitesAndLeavesTheOthers() throws {
        let model = launch()
        let engine = RecordingEngine()
        model.attachWebsiteDarkMode(engine: engine)
        let kept = model.store.profiles[0].id
        let work = model.store.addProfile(name: "Work")
        XCTAssertTrue(model.websiteDarkMode.change { $0.set(.on, forHost: "work-intranet.example", profile: work.id) })
        XCTAssertTrue(model.websiteDarkMode.change { $0.set(.off, forHost: "news.example", profile: kept) })
        XCTAssertTrue(try String(contentsOf: sitesFile, encoding: .utf8).contains("work-intranet.example"))

        XCTAssertNil(model.deleteProfile(work.id, deletingSpaces: true))
        XCTAssertNil(model.websiteDarkMode.sites.scopes[work.id.uuidString])
        XCTAssertEqual(model.websiteDarkMode.sites.choices(for: kept), ["news.example": .off])
        let file = try String(contentsOf: sitesFile, encoding: .utf8)
        XCTAssertFalse(file.contains("work-intranet.example"), "gone from the file")
        XCTAssertFalse(file.contains(work.id.uuidString), "and the profile is not named in it")
        XCTAssertTrue(file.contains("news.example"))

        // The last profile with sites: the file goes.
        XCTAssertTrue(model.websiteDarkMode.change { $0.set(nil, forHost: "news.example", profile: kept) })
        let other = model.store.addProfile(name: "Other")
        XCTAssertTrue(model.websiteDarkMode.change { $0.set(.on, forHost: "other.example", profile: other.id) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: sitesFile.path))
        XCTAssertNil(model.deleteProfile(other.id, deletingSpaces: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sitesFile.path))
    }

    func testDeletingAProfileDeletesItsSitesWithoutAnEngineThatHasDarkMode() throws {
        // A build with the feature on an engine without it (or WebKit): the file a
        // dark-mode engine left still loses a deleted profile's sites.
        var model = launch()
        let work = model.store.addProfile(name: "Work")
        model.persistence.flush()
        var file = WebsiteDarkModeSites()
        file.set(.on, forHost: "work-intranet.example", profile: work.id)
        try file.save(to: sitesFile)

        model = launch()
        XCTAssertFalse(model.websiteDarkMode.isAvailable)
        XCTAssertNotNil(model.store.profiles.first { $0.id == work.id })
        XCTAssertNil(model.deleteProfile(work.id, deletingSpaces: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sitesFile.path))
    }

    func testAProfileThatGoesByAnotherWayKeepsNoSites() throws {
        // A sync merge takes a profile out of the store without the delete command.
        let model = launch()
        model.attachWebsiteDarkMode(engine: RecordingEngine())
        let work = model.store.addProfile(name: "Work", createInitialSpace: false)
        XCTAssertTrue(model.websiteDarkMode.change { $0.set(.on, forHost: "work-intranet.example", profile: work.id) })
        XCTAssertNil(model.store.deleteProfile(work.id, deletingSpaces: true))
        model.websiteDarkModeProfilesChanged()
        XCTAssertTrue(model.websiteDarkMode.sites.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sitesFile.path))
    }

    func testACheckTheEngineNeverAnswersDoesNotStopTheNextOnes() throws {
        let (model, _, history, profile) = try launchWithHistory()
        // An engine that takes the first query and never answers it.
        var unanswered: [([String]?) -> Void] = []
        model.websiteDarkMode.historyQuery = { _, _, reply in unanswered.append(reply) }
        let start = Date()
        model.checkWebsiteDarkModeSitesAgainstHistory(profile: profile, now: start)
        model.checkWebsiteDarkModeSitesAgainstHistory(profile: profile, now: start.addingTimeInterval(30))
        XCTAssertEqual(unanswered.count, 1, "a check still in time is waited for")

        // A minute on, the history was cleared, and the engine answers again.
        history.visited[profile] = []
        model.websiteDarkMode.historyQuery = history.query
        model.checkWebsiteDarkModeSitesAgainstHistory(profile: profile, now: start.addingTimeInterval(61))
        XCTAssertTrue(model.websiteDarkMode.sites.isEmpty, "the stuck check is given up for a new one")

        // The old answer arrives at last, saying the sites were there: it is ignored.
        XCTAssertTrue(model.websiteDarkMode.change { $0.set(.on, forHost: "news.example", profile: profile) })
        unanswered[0](["https://news.example/", "https://bank.example/"])
        XCTAssertEqual(model.websiteDarkMode.sites.choices(for: profile), ["news.example": .on])
    }
}

