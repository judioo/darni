import AppKit
import Foundation
import Observation
import SidebarModel

/// Dark mode for websites outside the setting itself: whether this engine
/// has it, Darni's appearance, and the sites with a choice of their own.
///
/// The sites are kept as history is (security, 2026-11-24): in a file beside
/// the sidebar's, by profile, never in the app's defaults and never synced.
/// A launch with another data folder neither reads nor writes the person's.
@Observable
final class WebsiteDarkModeController {
    static let settingLabel = "Dark mode for websites"
    static let settingDetail = "Sites with a dark theme of their own use it. Other sites are darkened, and their photos and videos stay as they are. A site can differ: see its site controls beside the address."

    /// An engine with the dark mode call is attached. False on WebKit and on
    /// a Chromium engine from before the call: the setting and the site
    /// controls row are then hidden.
    private(set) var isAvailable = false
    private(set) var sites: WebsiteDarkModeSites
    /// Darni's own appearance, which is the Mac's ("When Darni is dark").
    private(set) var appIsDark: Bool

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private(set) var engineSync: WebsiteDarkModeEngineSync?
    @ObservationIgnored fileprivate var appearanceObservation: NSKeyValueObservation?
    /// Whether a tab's engine is one the setting reaches (a Chromium tab);
    /// nil: every engine of this shell is.
    @ObservationIgnored var covers: ((any WebEngine) -> Bool)?
    /// What the engine holds for a tab's page now; nil without one.
    @ObservationIgnored var isDarkInEngine: ((any WebEngine) -> Bool?)?
    /// The engine's history query for a profile or a container
    /// (`WebsiteDarkModeHistory.Query`); nil without one.
    @ObservationIgnored var historyQuery: WebsiteDarkModeHistory.Query?
    /// The pages that can delete history right now (Chromium's settings and
    /// History pages), each with the profile whose sites it can orphan.
    @ObservationIgnored fileprivate var historyPages: [HistoryPage: Profile.ID] = [:]
    @ObservationIgnored fileprivate var historyTimer: Timer?
    /// Profiles whose sites are being checked against their history (the
    /// check's token and start), and those to check once more when that ends.
    @ObservationIgnored fileprivate var historyChecksRunning: [Profile.ID: (token: UUID, started: Date)] = [:]
    @ObservationIgnored fileprivate var historyChecksWanted: Set<Profile.ID> = []
    /// A check whose engine has not answered for this long is given up: the
    /// next check replaces it, and its late answer is ignored. Without this a
    /// query the engine never answers would stop every later check.
    static let historyCheckTimeout: TimeInterval = 60

    /// A tab or a Little Arc window that shows a page.
    enum HistoryPage: Hashable {
        case tab(Tab.ID)
        case littleArc(LittleArcWindow.ID)
    }

    /// How often the sites are checked while such a page is open: the
    /// engine does not say when "Clear Browsing Data" has run.
    static let historyCheckInterval: TimeInterval = 10

    var historyPagesForTesting: [HistoryPage: Profile.ID] { historyPages }
    var historyTimerIsRunning: Bool { historyTimer != nil }

    init(fileURL: URL?) {
        self.fileURL = fileURL
        sites = fileURL.map(WebsiteDarkModeSites.load(from:)) ?? WebsiteDarkModeSites()
        appIsDark = Self.currentAppearanceIsDark
    }

    static var currentAppearanceIsDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    fileprivate func attach(engine: WebsiteDarkModeEngine, state: @escaping (Profile.ID) -> WebsiteDarkMode.EngineState) {
        engineSync = WebsiteDarkModeEngineSync(engine: engine, state: state)
        isAvailable = true
    }

    /// False when it already was.
    fileprivate func setAppIsDark(_ dark: Bool) -> Bool {
        guard appIsDark != dark else { return false }
        appIsDark = dark
        return true
    }

    /// One change to the sites, saved when it changed something.
    @discardableResult
    func change(_ change: (inout WebsiteDarkModeSites) -> Bool) -> Bool {
        var next = sites
        guard change(&next) else { return false }
        sites = next
        save()
        return true
    }

    /// Profiles were deleted: the sites they had a choice for go with them.
    func profilesDeleted(_ profiles: [Profile.ID]) {
        _ = change { sites in profiles.reduce(false) { sites.removeProfile($1) || $0 } }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try sites.save(to: fileURL)
        } catch {
            StandardError.write("[ReArc] could not save \(fileURL.lastPathComponent): \(error.localizedDescription)\n")
        }
    }
}

/// Dark mode for websites (engine patch `tab/105`, ABI 1.73). The setting is
/// the app's (Settings › General); a site's own choice is its profile's. The
/// engine is told each profile's state when the profile loads and whenever
/// the setting, Darni's appearance or a site's choice changes, and it reads
/// that state at every navigation. Open tabs follow without a reload.
///
/// All of it waits for `attachWebsiteDarkMode`: without an engine that has
/// the call nothing is shown and nothing is sent. WebKit tabs are not
/// covered: they follow the Mac's appearance as before.
extension BrowserViewModel {
    /// The Chromium shell, at ready, when the engine has the call.
    func attachWebsiteDarkMode(engine: WebsiteDarkModeEngine) {
        guard !websiteDarkMode.isAvailable else { return }
        // A profile deleted while this build did not run keeps no sites.
        let known = store.profiles.map(\.id)
        if !known.isEmpty { _ = websiteDarkMode.change { $0.keepOnly(profiles: known) } }
        websiteDarkMode.attach(engine: engine) { [weak self] profile in
            self?.websiteDarkModeEngineState(for: profile) ?? WebsiteDarkMode.EngineState(dark: false)
        }
        if let app = NSApp {
            _ = websiteDarkMode.setAppIsDark(WebsiteDarkModeController.currentAppearanceIsDark)
            websiteDarkMode.appearanceObservation = app.observe(\.effectiveAppearance) { [weak self] _, _ in
                DispatchQueue.main.async { self?.setWebsiteDarkModeAppearance(isDark: WebsiteDarkModeController.currentAppearanceIsDark) }
            }
        }
    }

    /// Darni's appearance changed (the Mac went dark or light).
    func setWebsiteDarkModeAppearance(isDark: Bool) {
        if websiteDarkMode.setAppIsDark(isDark) { websiteDarkModeStateChanged() }
    }

    /// What the engine is told for a shell profile. A container's is its parent's.
    func websiteDarkModeEngineState(for profile: Profile.ID) -> WebsiteDarkMode.EngineState {
        WebsiteDarkMode.engineState(setting: websiteDarkModeSetting, appIsDark: websiteDarkMode.appIsDark,
                                    sites: websiteDarkMode.sites.choices(for: store.owningProfileID(of: profile)))
    }

    /// A persistent engine profile finished loading: it gets its state
    /// before any tab exists. Private windows follow their profile in the
    /// engine and get no call.
    /// Its sites are then checked against its history: what went while Darni
    /// did not look (a quit right after Clear Browsing Data, visits Chromium
    /// let expire) takes its sites with it now.
    func websiteDarkModeProfileOpened(engineProfile: UInt64, profile: Profile.ID) {
        websiteDarkMode.engineSync?.profileOpened(engineProfile: engineProfile, profile: profile)
        checkWebsiteDarkModeSitesAgainstHistory(profile: profile)
    }

    /// After any sidebar change: a profile that is gone (deleted here, or by
    /// a sync merge) keeps no sites.
    func websiteDarkModeProfilesChanged() {
        guard websiteDarkMode.isAvailable else { return }
        let known = store.profiles.map(\.id)
        if !known.isEmpty { _ = websiteDarkMode.change { $0.keepOnly(profiles: known) } }
    }

    func websiteDarkModeProfileClosed(engineProfile: UInt64) {
        websiteDarkMode.engineSync?.profileClosed(engineProfile: engineProfile)
    }

    /// The setting, the appearance or a site's choice changed: the engine is told at once.
    func websiteDarkModeStateChanged() {
        websiteDarkMode.engineSync?.stateChanged()
    }

    // MARK: Site Control Center

    /// The host the panel's row is about: the site the panel was drawn for,
    /// not the tab's address by now (the tab may be on its next page).
    private static func websiteDarkModeHost(_ site: SiteControlCenter.Site) -> String? {
        WebsiteDarkModeSites.host(for: URL(string: site.origin))
    }

    /// The panel's "Dark mode on this site" row; nil when this engine has no
    /// dark mode, or the tab is one it does not reach (a WebKit tab).
    func websiteDarkModeRow(for engine: any WebEngine, site: SiteControlCenter.Site) -> SiteControlCenter.SettingRow? {
        guard websiteDarkMode.isAvailable, websiteDarkMode.covers?(engine) ?? true,
              let profileID = engine.pagePrompts.profileID, let host = Self.websiteDarkModeHost(site) else { return nil }
        return SiteControlCenter.websiteDarkModeRow(
            setting: websiteDarkModeSetting,
            appIsDark: websiteDarkMode.appIsDark,
            choice: websiteDarkMode.sites.choice(forHost: host, profile: store.owningProfileID(of: profileID)),
            isPrivate: engine.pagePrompts.privateSession != nil
        )
    }

    // MARK: The sites and the profile's history (security DM-1)

    /// A tab or Little Arc window of `profile` committed `url`. While it is
    /// on a page that can delete history (Chromium's settings, where Clear
    /// Browsing Data is, or its History page) the profile's sites are
    /// checked against its history every few seconds, and once more when
    /// the page is left or closed.
    func websiteDarkModePageCommitted(_ page: WebsiteDarkModeController.HistoryPage, profile: Profile.ID, url: URL?) {
        guard websiteDarkMode.isAvailable else { return }
        if WebsiteDarkModeHistory.canDeleteHistory(pageURL: url) {
            websiteDarkMode.historyPages[page] = store.owningProfileID(of: profile)
            guard websiteDarkMode.historyTimer == nil else { return }
            websiteDarkMode.historyTimer = Timer.scheduledTimer(withTimeInterval: WebsiteDarkModeController.historyCheckInterval, repeats: true) { [weak self] timer in
                guard let self else { return timer.invalidate() }
                self.websiteDarkModeHistoryTick()
            }
        } else if let left = websiteDarkMode.historyPages.removeValue(forKey: page) {
            checkWebsiteDarkModeSitesAgainstHistory(profile: left)
            stopWebsiteDarkModeHistoryTimerIfIdle()
        }
    }

    /// The timer's turn: every profile with such a page is checked. A page
    /// that was closed or unloaded since is checked a last time.
    func websiteDarkModeHistoryTick() {
        for (page, profile) in websiteDarkMode.historyPages {
            let isOpen: Bool
            switch page {
            case .tab(let id):
                isOpen = store.tab(withID: id).map { engineHost.engine(forTabID: id, profileID: profileID(for: $0)) != nil } ?? false
            case .littleArc(let id):
                isOpen = store.littleArcWindow(withID: id) != nil
            }
            if !isOpen { websiteDarkMode.historyPages[page] = nil }
            checkWebsiteDarkModeSitesAgainstHistory(profile: profile)
        }
        stopWebsiteDarkModeHistoryTimerIfIdle()
    }

    private func stopWebsiteDarkModeHistoryTimerIfIdle() {
        guard websiteDarkMode.historyPages.isEmpty else { return }
        websiteDarkMode.historyTimer?.invalidate()
        websiteDarkMode.historyTimer = nil
    }

    /// Drops the choice of every site of `profile` that its history no
    /// longer has, in the profile's own storage or a container's. A site is
    /// kept when a storage has a page of it, and when one cannot say. A
    /// private window never gets here: it writes no choice and has no history.
    func checkWebsiteDarkModeSitesAgainstHistory(profile: Profile.ID, now: Date = Date()) {
        let owner = store.owningProfileID(of: profile)
        guard websiteDarkMode.isAvailable, let query = websiteDarkMode.historyQuery else { return }
        let asked = websiteDarkMode.sites.choices(for: owner)
        guard !asked.isEmpty else { return }
        if let running = websiteDarkMode.historyChecksRunning[owner],
           now.timeIntervalSince(running.started) < WebsiteDarkModeController.historyCheckTimeout {
            websiteDarkMode.historyChecksWanted.insert(owner)
            return
        }
        let token = UUID()
        websiteDarkMode.historyChecksRunning[owner] = (token, now)
        let storages = [owner] + store.containers(of: owner).map(\.id)
        // A reader of its own: what it reads of the history lives as long as this check.
        let reader = WebsiteDarkModeHistory.Reader(query: query)
        WebsiteDarkModeHistory.hostsWithoutVisits(asked.keys.sorted(), storages: storages, ask: reader.ask) { [weak self] gone in
            // A check given up for a newer one: its answer may be stale.
            guard let self, self.websiteDarkMode.historyChecksRunning[owner]?.token == token else { return }
            self.websiteDarkMode.historyChecksRunning[owner] = nil
            // A choice made or changed while the history was asked was made on a page just visited: it stays.
            let now = self.websiteDarkMode.sites.choices(for: owner)
            let dropped = gone.filter { now[$0] != nil && now[$0] == asked[$0] }
            if self.websiteDarkMode.change({ $0.removeHosts(dropped, profile: owner) }) {
                self.websiteDarkModeStateChanged()
            }
            if self.websiteDarkMode.historyChecksWanted.remove(owner) != nil {
                self.checkWebsiteDarkModeSitesAgainstHistory(profile: owner)
            }
        }
    }

    /// The row's menu: the site's own choice, or nil for the setting again.
    /// Nothing is written from a private window.
    func setWebsiteDarkMode(_ choice: WebsiteDarkModeSiteChoice?, forSiteOf engine: any WebEngine, site: SiteControlCenter.Site) {
        guard websiteDarkMode.isAvailable, engine.pagePrompts.privateSession == nil,
              let profileID = engine.pagePrompts.profileID, let host = Self.websiteDarkModeHost(site) else { return }
        let profile = store.owningProfileID(of: profileID)
        guard websiteDarkMode.change({ $0.set(choice, forHost: host, profile: profile) }) else { return }
        websiteDarkModeStateChanged()
    }
}
