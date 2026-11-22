import Foundation

/// Chromium-owned pages the shell routes to instead of reimplementing them,
/// where Arc shows Chrome's own pages. Version needs `trustedWebUI`; history,
/// downloads, passwords and extensions need `dailyWebUI` as well (ABI 1.14
/// `webui_daily_pages`). Credits requires `creditsWebUI` (ABI 1.52
/// `webui_credits`).
///
/// No case is a `chrome://settings` page, and none may be added: that page
/// is Chromium's stock settings (About Chromium, AI in Chrome, Chromium's own
/// shortcuts), which Darni never shows. What it held has Darni's own UI
/// (Settings › Profiles' search engine and download location, the site
/// panel) or no route yet (`StockSettingsRouteTests`).
public enum BrowserInternalPage: String, CaseIterable, Hashable, Sendable {
    /// Static licences page; requires `creditsWebUI` (ABI 1.52).
    case credits
    case version
    case history
    case downloads
    case passwords
    case extensions

    /// The host of Chromium's stock settings pages, which no route may open.
    public static let stockSettingsHost = "settings"

    public var url: URL {
        switch self {
        case .credits: return URL(string: "chrome://credits")!
        case .version: return URL(string: "chrome://version")!
        case .history: return URL(string: "chrome://history/")!
        case .downloads: return URL(string: "chrome://downloads/")!
        case .passwords: return URL(string: "chrome://password-manager/")!
        case .extensions: return URL(string: "chrome://extensions/")!
        }
    }

    public var title: String {
        switch self {
        case .credits: return "Credits"
        case .version: return "About Chromium Engine"
        case .history: return "History"
        case .downloads: return "Downloads"
        case .passwords: return "Passwords"
        case .extensions: return "Extensions"
        }
    }

    /// Whether an engine with `engine` admission can open this page.
    public func isAvailable(engine: NavigationURLPolicy.EngineSchemes) -> Bool {
        NavigationURLPolicy.allows(url, engine: engine)
    }

    /// Chrome's singleton-tab rule: an open tab on the same WebUI host is reused.
    public func isShown(by url: URL) -> Bool {
        url.scheme?.lowercased() == "chrome" && url.host()?.lowercased() == self.url.host()
    }

    /// Whether `url` is one of Chromium's stock settings pages.
    public static func isStockSettings(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "chrome" && url.host()?.lowercased() == stockSettingsHost
    }
}
