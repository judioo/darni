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

    fileprivate func change(_ change: (inout WebsiteDarkModeSites) -> Bool) -> Bool {
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
    func websiteDarkModeProfileOpened(engineProfile: UInt64, profile: Profile.ID) {
        websiteDarkMode.engineSync?.profileOpened(engineProfile: engineProfile, profile: profile)
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
