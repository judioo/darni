import Foundation

/// Settings › General › Dark mode for websites. Off, as before this setting,
/// leaves every page as it is: a site's own dark theme follows the Mac's
/// appearance and nothing is darkened. The other two make pages dark, always
/// or while Darni itself is dark.
///
/// A dark page is told to prefer the dark scheme, so a site with its own
/// dark theme uses it, and a site without one is darkened by the engine as
/// it is painted (Chromium's Auto Dark Mode; engine patch `tab/105`).
/// Photographs and videos are left alone.
///
/// The setting is this Mac's, in the app's defaults. A build from before it
/// never reads the key.
public enum WebsiteDarkModeSetting: String, CaseIterable, Sendable {
    case off, followAppearance, always

    public static let defaultsKey = "rearc.websiteDarkMode"

    public var title: String {
        switch self {
        case .off: return "Off (default)"
        case .followAppearance: return "When Darni is dark"
        case .always: return "Always"
        }
    }

    /// A value this build does not know (a later build's) reads as Off.
    public static func load(from defaults: UserDefaults) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .off
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    /// Whether pages are dark with no word about their site.
    public func isDark(appIsDark: Bool) -> Bool {
        switch self {
        case .off: return false
        case .followAppearance: return appIsDark
        case .always: return true
        }
    }
}

/// "Dark mode on this site" in the site controls: no choice follows the
/// setting, `on` is dark whatever the setting says, `off` never is.
public enum WebsiteDarkModeSiteChoice: String, Codable, Sendable {
    case on, off
}

/// The sites with a choice of their own, per profile. They name sites the
/// person went to, so they are kept as history is: in a file beside the
/// sidebar's (`WebsiteDarkMode.json` in the data folder), by profile, never
/// in the app's defaults and never synced. A private window reads its
/// profile's choices and writes none.
///
/// A site is a page's host as its address has it, whole: `example.com` is
/// not `www.example.com`. That is how the engine matches a page
/// (`ReArcProfileSetWebsiteDarkMode`), and how zoom is kept.
public struct WebsiteDarkModeSites: Equatable, Sendable {
    public static let fileName = "WebsiteDarkMode.json"
    /// The engine takes this many hosts in each of its two lists.
    public static let maxHostsPerChoice = 10_000

    public var version = 1
    /// Profile (its UUID) → host → choice.
    public private(set) var scopes: [String: [String: WebsiteDarkModeSiteChoice]] = [:]

    public init() {}

    /// The host a page's choice is kept under; nil for a page that is not a
    /// website (about:, file:, the engine's own pages, an extension's).
    public static func host(for url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.encodedHost?.lowercased(),
              isHost(host) else { return nil }
        return host
    }

    /// What the engine accepts as a host: lower-case letters, digits, "-",
    /// ".", "_", and the brackets and colons of an IPv6 literal.
    public static func isHost(_ host: String) -> Bool {
        !host.isEmpty && host.utf8.count <= 253 && host.utf8.allSatisfy { byte in
            (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || [0x2D, 0x2E, 0x5F, 0x5B, 0x5D, 0x3A].contains(byte)
        }
    }

    public func choice(forHost host: String, profile: Profile.ID) -> WebsiteDarkModeSiteChoice? {
        scopes[profile.uuidString]?[host]
    }

    public func choices(for profile: Profile.ID) -> [String: WebsiteDarkModeSiteChoice] {
        scopes[profile.uuidString] ?? [:]
    }

    /// Sets or, with nil, forgets a site's choice. False when nothing
    /// changed: the same choice, a name that is not a host, or a profile
    /// that already has as many sites with that choice as the engine takes.
    @discardableResult
    public mutating func set(_ choice: WebsiteDarkModeSiteChoice?, forHost host: String, profile: Profile.ID) -> Bool {
        let scope = profile.uuidString
        guard Self.isHost(host), scopes[scope]?[host] != choice else { return false }
        if let choice {
            let count = scopes[scope]?.values.filter { $0 == choice }.count ?? 0
            guard count < Self.maxHostsPerChoice else { return false }
            scopes[scope, default: [:]][host] = choice
        } else {
            scopes[scope]?[host] = nil
            if scopes[scope]?.isEmpty == true { scopes[scope] = nil }
        }
        return true
    }

    /// A profile was deleted: its sites go with it.
    @discardableResult
    public mutating func removeProfile(_ profile: Profile.ID) -> Bool {
        scopes.removeValue(forKey: profile.uuidString) != nil
    }

    /// Profiles that are gone (deleted while this build did not run, or by a
    /// build that does not know this file) lose their sites.
    @discardableResult
    public mutating func keepOnly(profiles: [Profile.ID]) -> Bool {
        let known = Set(profiles.map(\.uuidString))
        let before = scopes.count
        scopes = scopes.filter { known.contains($0.key) }
        return scopes.count != before
    }

    public var isEmpty: Bool { scopes.isEmpty }
}

extension WebsiteDarkModeSites: Codable {
    enum CodingKeys: String, CodingKey { case version, scopes }

    /// Total: a file a later build wrote is read for what this build knows.
    /// A choice it does not know and a name that is not a host are dropped,
    /// and nothing else in the file is lost by that alone (the next save
    /// writes what was read).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        let raw = (try? c.decode([String: [String: String]].self, forKey: .scopes)) ?? [:]
        for (scope, sites) in raw where UUID(uuidString: scope) != nil {
            var kept: [String: WebsiteDarkModeSiteChoice] = [:]
            for (host, value) in sites {
                guard Self.isHost(host), let choice = WebsiteDarkModeSiteChoice(rawValue: value) else { continue }
                kept[host] = choice
            }
            if !kept.isEmpty { scopes[scope] = kept }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(scopes.mapValues { $0.mapValues(\.rawValue) }, forKey: .scopes)
    }

    /// A missing or unreadable file is an empty record.
    public static func load(from url: URL) -> WebsiteDarkModeSites {
        guard let data = try? Data(contentsOf: url) else { return WebsiteDarkModeSites() }
        return (try? JSONDecoder().decode(WebsiteDarkModeSites.self, from: data)) ?? WebsiteDarkModeSites()
    }

    /// With no site left the file is removed: nothing remains to say which
    /// sites once had a choice.
    public func save(to url: URL) throws {
        if isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// How the setting, Darni's appearance and a site's choice decide a page.
public enum WebsiteDarkMode {
    /// A page of a site: its own choice first, else the setting.
    public static func isDark(setting: WebsiteDarkModeSetting, appIsDark: Bool, choice: WebsiteDarkModeSiteChoice?) -> Bool {
        switch choice {
        case .on?: return true
        case .off?: return false
        case nil: return setting.isDark(appIsDark: appIsDark)
        }
    }

    /// What the engine is told for a profile (`ReArcProfileSetWebsiteDarkMode`):
    /// whether pages are dark, and the hosts that differ, sorted. A choice
    /// that says what the setting already says is sent all the same: it
    /// holds when the setting or the appearance changes.
    public struct EngineState: Equatable, Sendable {
        public var dark: Bool
        public var darkHosts: [String]
        public var lightHosts: [String]

        public init(dark: Bool, darkHosts: [String] = [], lightHosts: [String] = []) {
            self.dark = dark
            self.darkHosts = darkHosts
            self.lightHosts = lightHosts
        }
    }

    public static func engineState(setting: WebsiteDarkModeSetting, appIsDark: Bool,
                                   sites: [String: WebsiteDarkModeSiteChoice]) -> EngineState {
        EngineState(
            dark: setting.isDark(appIsDark: appIsDark),
            darkHosts: sites.filter { $0.value == .on }.keys.sorted(),
            lightHosts: sites.filter { $0.value == .off }.keys.sorted()
        )
    }
}

// MARK: - The site controls row

extension SiteControlCenter {
    public static let websiteDarkModeTitle = "Dark mode on this site"

    /// The panel's "Dark mode on this site" row. Its state says what the
    /// page is now and whether that is the site's own choice; its menu holds
    /// the other two of Default, On and Off. In a private window the row
    /// only reports: a site visited there is never written down.
    public static func websiteDarkModeRow(setting: WebsiteDarkModeSetting, appIsDark: Bool,
                                          choice: WebsiteDarkModeSiteChoice?, isPrivate: Bool) -> SettingRow {
        let dark = WebsiteDarkMode.isDark(setting: setting, appIsDark: appIsDark, choice: choice)
        let state: String
        let actions: [SettingAction]
        switch choice {
        case .on?:
            state = "On for this site"
            actions = [.darkModeOffForSite, .darkModeDefaultForSite]
        case .off?:
            state = "Off for this site"
            actions = [.darkModeOnForSite, .darkModeDefaultForSite]
        case nil:
            state = dark ? "On" : "Off"
            actions = [dark ? .darkModeOffForSite : .darkModeOnForSite]
        }
        return SettingRow(kind: .websiteDarkMode, title: websiteDarkModeTitle, state: state,
                          symbol: dark ? "moon.fill" : "moon", isBlocked: false, actions: isPrivate ? [] : actions)
    }
}

// MARK: - The engine

/// The engine's dark mode call (engine/docs/C-ABI.md "Dark mode for
/// websites (ABI 1.73)"), as a seam: the Chromium shell implements it over
/// the C ABI, a test with a recorder. Profiles are the engine's own profile
/// IDs, never an off-the-record one: private windows follow their profile.
public protocol WebsiteDarkModeEngine: AnyObject {
    /// `ReArcProfileSetWebsiteDarkMode`: replaces what the profile was told.
    func setWebsiteDarkMode(engineProfile: UInt64, state: WebsiteDarkMode.EngineState)
}

/// Keeps the engine at the shell's state. The engine holds it in memory
/// only, so every profile is told when it loads, before any of its tabs
/// exist, and again whenever its state changes: the setting, Darni's
/// appearance, or a site's choice. Open tabs follow without a reload.
///
/// A profile is told nothing while its state is the one an engine starts
/// with (not dark, no site): an install that never uses the setting makes
/// no call at all.
public final class WebsiteDarkModeEngineSync {
    private let engine: WebsiteDarkModeEngine
    /// The state for a shell profile (a container's is its parent's).
    private let state: (Profile.ID) -> WebsiteDarkMode.EngineState
    /// Loaded engine profiles and the shell profile each takes its state from.
    private var profiles: [UInt64: Profile.ID] = [:]
    private var applied: [UInt64: WebsiteDarkMode.EngineState] = [:]

    public init(engine: WebsiteDarkModeEngine, state: @escaping (Profile.ID) -> WebsiteDarkMode.EngineState) {
        self.engine = engine
        self.state = state
    }

    public func profileOpened(engineProfile: UInt64, profile: Profile.ID) {
        guard engineProfile != 0 else { return }
        profiles[engineProfile] = profile
        applied[engineProfile] = nil
        apply()
    }

    public func profileClosed(engineProfile: UInt64) {
        profiles[engineProfile] = nil
        applied[engineProfile] = nil
    }

    /// The setting, the appearance or a site's choice may have changed.
    public func stateChanged() {
        apply()
    }

    private func apply() {
        for (engineProfile, profile) in profiles.sorted(by: { $0.key < $1.key }) {
            let wanted = state(profile)
            guard (applied[engineProfile] ?? WebsiteDarkMode.EngineState(dark: false)) != wanted else { continue }
            engine.setWebsiteDarkMode(engineProfile: engineProfile, state: wanted)
            applied[engineProfile] = wanted
        }
    }
}
