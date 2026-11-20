import Foundation

/// The welcome page the onboarding leaves in the first tab: a file in the
/// app's data folder (`WelcomePage.write`). Its address is a long `file:`
/// path through the person's home folder, so the address fields show the
/// page's name instead, as they show `settings` for Chromium's settings
/// page, and ⌘L starts with an empty field, as on a new tab. Only that one
/// file is named: any other `file:` address is shown whole.
public enum WelcomePageAddress {
    /// The page's name: its tab's title, the page's own `<title>` and what
    /// the address fields show.
    public static let title = "Welcome to \(Brand.name)"
    public static let directoryName = "Welcome"
    public static let fileName = "welcome.html"

    public static func directory(in root: URL = ShellDataLocation.root) -> URL {
        root.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Where the page is written.
    public static func fileURL(in root: URL = ShellDataLocation.root) -> URL {
        directory(in: root).appendingPathComponent(fileName)
    }

    /// Whether `url` is the welcome page's file. A `#fragment` still is; a
    /// query, a host or any other path is not.
    public static func matches(_ url: URL?, root: URL = ShellDataLocation.root) -> Bool {
        guard let url, url.isFileURL, url.query() == nil, (url.host() ?? "").isEmpty else { return false }
        return url.standardizedFileURL.path(percentEncoded: false) == fileURL(in: root).standardizedFileURL.path(percentEncoded: false)
    }

    /// What ⌘L fills the command bar with for a page: its address, or
    /// nothing for a blank page and for the welcome page.
    public static func commandBarPrefill(for url: URL, root: URL = ShellDataLocation.root) -> String {
        url.absoluteString == "about:blank" || matches(url, root: root) ? "" : url.absoluteString
    }
}
