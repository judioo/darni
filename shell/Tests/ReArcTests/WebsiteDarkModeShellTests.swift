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
}
