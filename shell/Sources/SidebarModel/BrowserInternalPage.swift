import Foundation

/// Chromium-owned pages the shell routes to instead of reimplementing them,
/// where Arc shows Chrome's own pages. The ones under `chrome://settings` are
/// Chromium's stock settings: each stays only until Darni has its own screen
/// for the job (docs/STOCK-SETTINGS-ROUTES.md; `StockSettingsRouteTests` lists
/// every one with its reason, and a new one fails there). The default search
/// engine and the download location have Darni's own rows in Settings ›
/// Profiles and no page here. Settings and version need
/// `trustedWebUI`; history, downloads, passwords and extensions need
/// `dailyWebUI` as well (ABI 1.14 `webui_daily_pages`). Credits requires
/// `creditsWebUI` (ABI 1.52 `webui_credits`).
public enum BrowserInternalPage: String, CaseIterable, Hashable, Sendable {
    case settings
    case privacy
    case siteSettings
    case clearBrowsingData
    /// Chromium's Import Bookmarks and Settings dialog (Arc ARC_ImportFeature).
    case importData
    /// Static licences page; requires `creditsWebUI` (ABI 1.52).
    case credits
    case version
    case history
    case downloads
    case passwords
    case extensions
    /// Settings window rows (ARC-RECORDING-2026-11-06 §6.3): subpages of the
    /// admitted `settings` host, so they need `trustedWebUI` only.
    case payments
    case notifications

    public var url: URL {
        switch self {
        case .settings: return URL(string: "chrome://settings")!
        case .privacy: return URL(string: "chrome://settings/privacy")!
        case .siteSettings: return URL(string: "chrome://settings/content")!
        case .clearBrowsingData: return URL(string: "chrome://settings/clearBrowserData")!
        case .importData: return URL(string: "chrome://settings/importData")!
        case .credits: return URL(string: "chrome://credits")!
        case .version: return URL(string: "chrome://version")!
        case .history: return URL(string: "chrome://history/")!
        case .downloads: return URL(string: "chrome://downloads/")!
        case .passwords: return URL(string: "chrome://password-manager/")!
        case .extensions: return URL(string: "chrome://extensions/")!
        case .payments: return URL(string: "chrome://settings/payments")!
        case .notifications: return URL(string: "chrome://settings/content/notifications")!
        }
    }

    public var title: String {
        switch self {
        case .settings: return "Settings"
        case .privacy: return "Privacy and Security"
        case .siteSettings: return "Site Settings"
        case .clearBrowsingData: return "Clear Browsing Data"
        case .importData: return "Import Browser Data"
        case .credits: return "Credits"
        case .version: return "About Chromium Engine"
        case .history: return "History"
        case .downloads: return "Downloads"
        case .passwords: return "Passwords"
        case .extensions: return "Extensions"
        case .payments: return "Payment Methods"
        case .notifications: return "Notifications"
        }
    }

    /// Whether an engine with `engine` admission can open this page.
    public func isAvailable(engine: NavigationURLPolicy.EngineSchemes) -> Bool {
        NavigationURLPolicy.allows(url, engine: engine)
    }

    /// Chromium's per-site page (permissions and their reset) for a serialized origin.
    public static func siteDetailsURL(origin: String) -> URL? {
        var components = URLComponents(string: "chrome://settings/content/siteDetails")
        components?.queryItems = [URLQueryItem(name: "site", value: origin)]
        return components?.url
    }

    /// The host of Chromium's stock settings pages.
    public static let stockSettingsHost = "settings"

    /// Stock settings pages Darni has replaced with its own UI, which the shell
    /// never opens again: the search engine pages (Settings › Profiles' pop-up)
    /// and the downloads page (its Download location row).
    public static let replacedStockSettingsPaths: Set<String> = ["/search", "/searchEngines", "/downloads"]

    /// Whether `url` is one of Chromium's stock settings pages.
    public static func isStockSettings(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "chrome" && url.host()?.lowercased() == stockSettingsHost
    }

    /// Whether `url` is a stock settings page Darni has its own UI for.
    public static func isReplacedStockSettings(_ url: URL) -> Bool {
        guard isStockSettings(url) else { return false }
        var path = url.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return replacedStockSettingsPaths.contains(path)
    }

    /// Chrome's singleton-tab rule: an open tab on the same WebUI host is reused.
    public func isShown(by url: URL) -> Bool {
        url.scheme?.lowercased() == "chrome" && url.host()?.lowercased() == self.url.host()
    }
}
