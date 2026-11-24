import XCTest
@testable import SidebarModel

/// Dark mode for websites: how the setting, Darni's appearance and a site's
/// own choice decide a page, what is kept and where, what the site controls
/// row says, and what the engine is told (engine patch tab/105, ABI 1.73).
final class WebsiteDarkModeTests: XCTestCase {
    private let profile = UUID()
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-dark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "rearc-dark-\(UUID().uuidString)")! }

    // MARK: The setting

    func testTheSettingIsOffUntilItIsChosenAndAnUnknownValueReadsAsOff() {
        let defaults = defaults()
        XCTAssertEqual(WebsiteDarkModeSetting.load(from: defaults), .off, "an install that never saw the setting")
        XCTAssertNil(defaults.object(forKey: WebsiteDarkModeSetting.defaultsKey), "reading writes nothing")
        for setting in WebsiteDarkModeSetting.allCases {
            setting.save(to: defaults)
            XCTAssertEqual(WebsiteDarkModeSetting.load(from: defaults), setting)
        }
        defaults.set("sepia", forKey: WebsiteDarkModeSetting.defaultsKey)
        XCTAssertEqual(WebsiteDarkModeSetting.load(from: defaults), .off, "a later build's value")
        defaults.set(true, forKey: WebsiteDarkModeSetting.defaultsKey)
        XCTAssertEqual(WebsiteDarkModeSetting.load(from: defaults), .off, "not a string")
        XCTAssertEqual(WebsiteDarkModeSetting.defaultsKey, "rearc.websiteDarkMode")
        XCTAssertEqual(WebsiteDarkModeSetting.allCases.map(\.title), ["Off (default)", "When Darni is dark", "Always"])
    }

    func testTheSettingWithDarnisAppearance() {
        XCTAssertFalse(WebsiteDarkModeSetting.off.isDark(appIsDark: false))
        XCTAssertFalse(WebsiteDarkModeSetting.off.isDark(appIsDark: true), "Off is off whatever the Mac looks like")
        XCTAssertFalse(WebsiteDarkModeSetting.followAppearance.isDark(appIsDark: false))
        XCTAssertTrue(WebsiteDarkModeSetting.followAppearance.isDark(appIsDark: true))
        XCTAssertTrue(WebsiteDarkModeSetting.always.isDark(appIsDark: false))
        XCTAssertTrue(WebsiteDarkModeSetting.always.isDark(appIsDark: true))
    }

    func testASitesOwnChoiceWinsOverTheSettingAndTheAppearance() {
        for setting in WebsiteDarkModeSetting.allCases {
            for appIsDark in [false, true] {
                XCTAssertTrue(WebsiteDarkMode.isDark(setting: setting, appIsDark: appIsDark, choice: .on), "\(setting) \(appIsDark)")
                XCTAssertFalse(WebsiteDarkMode.isDark(setting: setting, appIsDark: appIsDark, choice: .off), "\(setting) \(appIsDark)")
                XCTAssertEqual(WebsiteDarkMode.isDark(setting: setting, appIsDark: appIsDark, choice: nil),
                               setting.isDark(appIsDark: appIsDark), "no choice follows the setting")
            }
        }
    }

    // MARK: The sites

    func testASiteIsThePagesHostWholeAndOnlyAWebsiteHasOne() {
        func host(_ text: String) -> String? { WebsiteDarkModeSites.host(for: URL(string: text)) }
        XCTAssertEqual(host("https://www.Example.com/a?b#c"), "www.example.com", "lower case, and www. is part of it")
        XCTAssertEqual(host("http://example.com:8080/"), "example.com", "no port")
        XCTAssertEqual(host("https://user:secret@example.com/"), "example.com", "no credentials")
        XCTAssertEqual(host("http://127.0.0.1:9000/x"), "127.0.0.1")
        XCTAssertEqual(host("http://localhost/"), "localhost")
        XCTAssertEqual(host("http://[::1]:8000/"), "[::1]", "as a URL writes an IPv6 host")
        XCTAssertEqual(host("https://bücher.example/"), "xn--bcher-kva.example", "punycode, as the engine has it")
        XCTAssertNil(host("file:///Users/someone/page.html"))
        XCTAssertNil(host("about:blank"))
        XCTAssertNil(host("chrome://settings/"))
        XCTAssertNil(host("chrome-extension://abcdefghijklmnopabcdefghijklmnop/popup.html"))
        XCTAssertNil(host("data:text/html,hello"))
        XCTAssertNil(WebsiteDarkModeSites.host(for: nil))
        XCTAssertTrue(WebsiteDarkModeSites.isHost("a-b_c.example"))
        for bad in ["", "Example.com", "exa mple.com", "example.com/path", "https://example.com", "ex\u{e9}mple.com", String(repeating: "a", count: 254)] {
            XCTAssertFalse(WebsiteDarkModeSites.isHost(bad), bad)
        }
    }

    func testChoicesAreKeptPerProfileAndForgottenWhenSetBackToTheSetting() {
        var sites = WebsiteDarkModeSites()
        let other = UUID()
        XCTAssertTrue(sites.set(.on, forHost: "news.example", profile: profile))
        XCTAssertFalse(sites.set(.on, forHost: "news.example", profile: profile), "the same choice changes nothing")
        XCTAssertTrue(sites.set(.off, forHost: "bank.example", profile: profile))
        XCTAssertTrue(sites.set(.off, forHost: "news.example", profile: other))
        XCTAssertFalse(sites.set(.on, forHost: "Not A Host", profile: profile))
        XCTAssertEqual(sites.choice(forHost: "news.example", profile: profile), .on)
        XCTAssertEqual(sites.choice(forHost: "news.example", profile: other), .off, "another profile's own")
        XCTAssertNil(sites.choice(forHost: "www.news.example", profile: profile), "a host is matched whole")
        XCTAssertEqual(sites.choices(for: profile), ["news.example": .on, "bank.example": .off])

        XCTAssertTrue(sites.set(nil, forHost: "news.example", profile: profile))
        XCTAssertFalse(sites.set(nil, forHost: "news.example", profile: profile))
        XCTAssertNil(sites.choice(forHost: "news.example", profile: profile))
        XCTAssertTrue(sites.set(nil, forHost: "bank.example", profile: profile))
        XCTAssertEqual(sites.scopes.keys.sorted(), [other.uuidString], "a profile with no site left is not named")

        XCTAssertTrue(sites.removeProfile(other))
        XCTAssertFalse(sites.removeProfile(other))
        XCTAssertTrue(sites.isEmpty)
    }

    func testAProfileTakesNoMoreSitesThanTheEngineDoes() {
        var sites = WebsiteDarkModeSites()
        for index in 0..<WebsiteDarkModeSites.maxHostsPerChoice {
            XCTAssertTrue(sites.set(.on, forHost: "s\(index).example", profile: profile))
        }
        XCTAssertFalse(sites.set(.on, forHost: "one-more.example", profile: profile))
        XCTAssertTrue(sites.set(.off, forHost: "one-more.example", profile: profile), "the other list has room")
        XCTAssertTrue(sites.set(.off, forHost: "s0.example", profile: profile), "a change of mind frees a place")
        XCTAssertTrue(sites.set(.on, forHost: "one-more.example", profile: profile))
    }

    func testProfilesThatAreGoneLoseTheirSites() {
        var sites = WebsiteDarkModeSites()
        let gone = UUID()
        sites.set(.on, forHost: "a.example", profile: profile)
        sites.set(.on, forHost: "b.example", profile: gone)
        XCTAssertTrue(sites.keepOnly(profiles: [profile]))
        XCTAssertFalse(sites.keepOnly(profiles: [profile]))
        XCTAssertEqual(sites.scopes.keys.sorted(), [profile.uuidString])
    }

    func testTheFileHoldsTheSitesByProfileAndIsRemovedWhenNoneIsLeft() throws {
        let file = directory.appendingPathComponent(WebsiteDarkModeSites.fileName)
        XCTAssertEqual(WebsiteDarkModeSites.fileName, "WebsiteDarkMode.json")
        XCTAssertTrue(WebsiteDarkModeSites.load(from: file).isEmpty, "no file: no site")
        var sites = WebsiteDarkModeSites()
        try sites.save(to: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing to keep: no file is made")

        sites.set(.on, forHost: "news.example", profile: profile)
        sites.set(.off, forHost: "bank.example", profile: profile)
        try sites.save(to: file)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["scopes"] as? [String: [String: String]], [profile.uuidString: ["news.example": "on", "bank.example": "off"]])
        XCTAssertEqual(WebsiteDarkModeSites.load(from: file), sites)

        sites.set(nil, forHost: "news.example", profile: profile)
        sites.set(nil, forHost: "bank.example", profile: profile)
        try sites.save(to: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "no site left: nothing says which sites had a choice")
    }

    func testAFileFromALaterBuildIsReadForWhatThisBuildKnows() throws {
        let file = directory.appendingPathComponent(WebsiteDarkModeSites.fileName)
        let later: [String: Any] = [
            "version": 2,
            "tint": ["news.example": "sepia"],
            "scopes": [
                profile.uuidString: ["news.example": "on", "bank.example": "off", "paper.example": "sepia", "Not A Host": "on"],
                "not-a-profile": ["x.example": "on"],
                UUID().uuidString: ["only.example": "sepia"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: later).write(to: file)
        let sites = WebsiteDarkModeSites.load(from: file)
        XCTAssertEqual(sites.scopes, [profile.uuidString: ["news.example": .on, "bank.example": .off]])

        try Data("not json".utf8).write(to: file)
        XCTAssertTrue(WebsiteDarkModeSites.load(from: file).isEmpty, "an unreadable file is an empty record, never a crash")
        try Data(#"{"scopes": 7}"#.utf8).write(to: file)
        XCTAssertTrue(WebsiteDarkModeSites.load(from: file).isEmpty)
        try Data(#"[]"#.utf8).write(to: file)
        XCTAssertTrue(WebsiteDarkModeSites.load(from: file).isEmpty)
    }

    // MARK: The engine

    func testTheEngineIsToldWhetherPagesAreDarkAndWhichHostsDiffer() {
        let sites: [String: WebsiteDarkModeSiteChoice] = ["z.example": .on, "a.example": .on, "m.example": .off]
        XCTAssertEqual(WebsiteDarkMode.engineState(setting: .off, appIsDark: true, sites: sites),
                       .init(dark: false, darkHosts: ["a.example", "z.example"], lightHosts: ["m.example"]))
        XCTAssertEqual(WebsiteDarkMode.engineState(setting: .always, appIsDark: false, sites: sites),
                       .init(dark: true, darkHosts: ["a.example", "z.example"], lightHosts: ["m.example"]),
                       "a choice that says what the setting says is sent too: it holds when the setting changes")
        XCTAssertEqual(WebsiteDarkMode.engineState(setting: .followAppearance, appIsDark: true, sites: [:]), .init(dark: true))
        XCTAssertEqual(WebsiteDarkMode.engineState(setting: .followAppearance, appIsDark: false, sites: [:]), .init(dark: false))
    }

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

    func testTheEngineHearsOfAProfileAtItsLoadAndThenOnlyOfChanges() {
        let engine = RecordingEngine()
        let other = UUID()
        var states: [UUID: WebsiteDarkMode.EngineState] = [:]
        let sync = WebsiteDarkModeEngineSync(engine: engine) { states[$0] ?? .init(dark: false) }

        sync.profileOpened(engineProfile: 0, profile: profile)
        sync.profileOpened(engineProfile: 4, profile: profile)
        XCTAssertEqual(engine.take(), [], "the state an engine starts with is not sent: an install that never uses the setting makes no call")

        states[profile] = .init(dark: true)
        sync.stateChanged()
        XCTAssertEqual(engine.take(), ["4 dark on[] off[]"])
        sync.stateChanged()
        XCTAssertEqual(engine.take(), [], "nothing changed")

        states[profile] = .init(dark: true, lightHosts: ["bank.example"])
        states[other] = .init(dark: false, darkHosts: ["news.example"])
        sync.profileOpened(engineProfile: 9, profile: other)
        XCTAssertEqual(engine.take(), ["4 dark on[] off[bank.example]", "9 light on[news.example] off[]"])

        states[profile] = .init(dark: false)
        sync.stateChanged()
        XCTAssertEqual(engine.take(), ["4 light on[] off[]"], "back to nothing is said, once")

        // The engine forgets a profile it unloads: the next load is told again.
        sync.profileClosed(engineProfile: 9)
        sync.stateChanged()
        XCTAssertEqual(engine.take(), [])
        sync.profileOpened(engineProfile: 12, profile: other)
        XCTAssertEqual(engine.take(), ["12 light on[news.example] off[]"])
    }

    // MARK: The site controls row

    func testTheRowSaysWhatThePageIsAndOffersTheOtherChoices() {
        func row(_ setting: WebsiteDarkModeSetting, dark appIsDark: Bool = false, _ choice: WebsiteDarkModeSiteChoice?, isPrivate: Bool = false) -> SiteControlCenter.SettingRow {
            SiteControlCenter.websiteDarkModeRow(setting: setting, appIsDark: appIsDark, choice: choice, isPrivate: isPrivate)
        }
        let off = row(.off, nil)
        XCTAssertEqual(off.kind, .websiteDarkMode)
        XCTAssertEqual(off.title, "Dark mode on this site")
        XCTAssertEqual(off.state, "Off")
        XCTAssertEqual(off.symbol, "moon")
        XCTAssertFalse(off.isBlocked)
        XCTAssertEqual(off.actions, [.darkModeOnForSite], "one action is a click")

        let always = row(.always, nil)
        XCTAssertEqual(always.state, "On")
        XCTAssertEqual(always.symbol, "moon.fill")
        XCTAssertEqual(always.actions, [.darkModeOffForSite])

        XCTAssertEqual(row(.followAppearance, dark: true, nil).state, "On")
        XCTAssertEqual(row(.followAppearance, dark: false, nil).state, "Off")

        let on = row(.off, .on)
        XCTAssertEqual(on.state, "On for this site")
        XCTAssertEqual(on.symbol, "moon.fill")
        XCTAssertEqual(on.actions, [.darkModeOffForSite, .darkModeDefaultForSite])

        let never = row(.always, .off)
        XCTAssertEqual(never.state, "Off for this site")
        XCTAssertEqual(never.symbol, "moon")
        XCTAssertEqual(never.actions, [.darkModeOnForSite, .darkModeDefaultForSite])

        let privateWindow = row(.always, .off, isPrivate: true)
        XCTAssertEqual(privateWindow.state, "Off for this site", "a private window reads its profile's choice")
        XCTAssertEqual(privateWindow.actions, [], "and writes none")

        XCTAssertEqual(SiteControlCenter.SettingAction.darkModeOnForSite.title, "Turn On for This Site")
        XCTAssertEqual(SiteControlCenter.SettingAction.darkModeOffForSite.title, "Turn Off for This Site")
        XCTAssertEqual(SiteControlCenter.SettingAction.darkModeDefaultForSite.title, "Use the Setting for All Websites")
    }

    func testTheRowSitsUnderBlockingAndIsAbsentWithoutAnEngineThatHasIt() {
        let dark = SiteControlCenter.websiteDarkModeRow(setting: .always, appIsDark: false, choice: nil, isPrivate: false)
        let blocking = SiteControlCenter.contentBlockingRow(settings: .newProfile, pageURL: URL(string: "https://news.example/"),
                                                            blockedCount: 2, listsAvailable: true, isPrivate: false)
        func kinds(contentBlocking: SiteControlCenter.SettingRow?, websiteDarkMode: SiteControlCenter.SettingRow?) -> [SiteControlCenter.SettingRow.Kind] {
            SiteControlCenter.settingRows(contentBlocking: contentBlocking, websiteDarkMode: websiteDarkMode, permissions: [],
                                          permissionsInEngine: true, autoPiP: .enabled, autoPiPEnabled: true).map(\.kind)
        }
        XCTAssertEqual(kinds(contentBlocking: blocking, websiteDarkMode: dark), [.contentBlocking, .websiteDarkMode, .autoPictureInPicture])
        XCTAssertEqual(kinds(contentBlocking: nil, websiteDarkMode: dark), [.websiteDarkMode, .autoPictureInPicture])
        XCTAssertEqual(kinds(contentBlocking: blocking, websiteDarkMode: nil), [.contentBlocking, .autoPictureInPicture], "the panel is as it was")
    }
}
