import XCTest
@testable import SidebarModel

/// Chromium's stock settings (chrome://settings and the pages under it) shows
/// "About Chromium" and "AI in Chrome", which Darni should never show. Some
/// jobs have no Darni screen yet, so their routes stay (never regress): each
/// is listed here with its reason, and in docs/STOCK-SETTINGS-ROUTES.md as the
/// to-do. A route that is not listed fails. The search engine and the
/// download location have Darni's own rows and route there no more (build
/// 1164's "Search Settings…" opened it).
final class StockSettingsRouteTests: XCTestCase {
    private struct Kept {
        let address: String
        /// The shell's page for it; nil for an address built for a site or sent by the engine.
        let page: BrowserInternalPage?
        /// The engine names the address (autofill's Manage…): it is in no shell source line.
        var fromEngine = false
        let reason: String
    }

    /// Every stock settings page the shell may still open, and why.
    private static let kept: [Kept] = [
        Kept(address: "chrome://settings/clearBrowserData", page: .clearBrowsingData,
             reason: "Clear Browsing Data: no Darni UI yet, and the engine ABI has no call for it"),
        Kept(address: "chrome://settings/content/siteDetails", page: nil,
             reason: "a site's Site Settings… and Cookies and Site Data…: the site panel cannot clear one site's data"),
        Kept(address: "chrome://settings/content", page: .siteSettings,
             reason: "Site Settings: no Darni list of every site's permissions"),
        Kept(address: "chrome://settings/privacy", page: .privacy,
             reason: "Privacy and Security: no Darni screen for cookies or the Safe Browsing level"),
        Kept(address: "chrome://settings/payments", page: .payments,
             reason: "Payment Methods, and autofill's Manage payment methods…: no Darni UI for saved cards"),
        Kept(address: "chrome://settings/contactInfo", page: nil, fromEngine: true,
             reason: "autofill's Manage addresses…: no Darni UI for saved addresses"),
        Kept(address: "chrome://settings/autofill", page: nil, fromEngine: true,
             reason: "autofill's Manage… for its other products: no Darni autofill settings"),
        Kept(address: "chrome://settings/content/notifications", page: .notifications,
             reason: "Notifications: no Darni list of sites allowed to notify"),
        Kept(address: "chrome://settings/importData", page: .importData,
             reason: "Import from Safari or Firefox…: Darni's importer reads Arc, Chrome and Brave only"),
        Kept(address: "chrome://settings", page: .settings,
             reason: "More Settings…: everything Chromium has a setting for and Darni does not"),
    ]

    /// What Darni has replaced: the shell opens these from nowhere.
    private static let replaced = ["chrome://settings/search", "chrome://settings/searchEngines", "chrome://settings/downloads"]

    private let everyEngine = NavigationURLPolicy.EngineSchemes.chromium.union(.dailyWebUI).union(.creditsWebUI)

    private func url(_ string: String) -> URL { URL(string: string)! }

    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testEveryStockSettingsPageIsListedWithItsReason() {
        let listed = Dictionary(uniqueKeysWithValues: Self.kept.compactMap { entry in entry.page.map { ($0, entry) } })
        for page in BrowserInternalPage.allCases where BrowserInternalPage.isStockSettings(page.url) {
            guard let entry = listed[page] else {
                XCTFail("\(page.rawValue) opens \(page.url.absoluteString), a page of Chromium's stock settings that is not listed: "
                    + "give Darni its own screen, or list it here and in docs/STOCK-SETTINGS-ROUTES.md with the reason")
                continue
            }
            XCTAssertEqual(page.url.absoluteString, entry.address, page.rawValue)
        }
        for (page, entry) in listed {
            XCTAssertTrue(BrowserInternalPage.allCases.contains(page))
            XCTAssertEqual(page.url.absoluteString, entry.address, "\(page.rawValue) is listed for another address")
        }
        XCTAssertEqual(Set(Self.kept.map(\.address)).count, Self.kept.count, "an address listed twice")
        for entry in Self.kept {
            XCTAssertTrue(BrowserInternalPage.isStockSettings(url(entry.address)), entry.address)
            XCTAssertGreaterThan(entry.reason.count, 30, "\(entry.address) needs its reason")
        }
        // The pages that are not Chromium's settings need no entry.
        for page in [BrowserInternalPage.credits, .version, .history, .downloads, .passwords, .extensions] {
            XCTAssertFalse(BrowserInternalPage.isStockSettings(page.url), page.rawValue)
        }
    }

    /// Every line of shell source outside a comment that holds a settings
    /// address: the address is a listed one. A new route (a constant, a menu
    /// action, a link) with an unlisted address fails here.
    func testEveryStockSettingsAddressInTheShellsSourceIsListed() throws {
        let sources = repository.appendingPathComponent("shell/Sources", isDirectory: true)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 200, "the shell's sources were not found at \(sources.path)")
        let pattern = try NSRegularExpression(pattern: "chrome://settings[A-Za-z0-9/_-]*", options: [.caseInsensitive])
        var found: [String: [String]] = [:]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let range = NSRange(line.startIndex..., in: line)
                for match in pattern.matches(in: line, range: range) {
                    var address = String(line[Range(match.range, in: line)!])
                    while address.hasSuffix("/") { address.removeLast() }
                    found[address, default: []].append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        let listed = Set(Self.kept.map(\.address))
        for (address, places) in found.sorted(by: { $0.key < $1.key }) where !listed.contains(address) {
            XCTFail("\(address) (\(places.joined(separator: ", "))) is a page of Chromium's stock settings that is not listed: "
                + "give Darni its own screen, or list it here and in docs/STOCK-SETTINGS-ROUTES.md with the reason")
        }
        for address in Self.replaced {
            XCTAssertNil(found[address], "\(address) has Darni's own UI: the shell must not route there")
        }
        // A listed route nothing opens any more should leave the list (and the document).
        for entry in Self.kept where !entry.fromEngine {
            XCTAssertNotNil(found[entry.address], "\(entry.address) is listed and no shell source opens it")
        }
    }

    /// The default search engine and the download location are Darni's own
    /// (Settings › Profiles): no page, no command and no shell route leads to
    /// Chromium's pages for them.
    func testSearchEngineAndDownloadsNeverRouteToStockSettings() {
        XCTAssertEqual(BrowserInternalPage.replacedStockSettingsPaths, ["/search", "/searchEngines", "/downloads"])
        let listed = Set(Self.kept.map(\.address))
        for address in Self.replaced {
            XCTAssertFalse(listed.contains(address), address)
            XCTAssertFalse(BrowserInternalPage.allCases.contains { $0.url.absoluteString == address }, address)
            XCTAssertTrue(BrowserInternalPage.isReplacedStockSettings(url(address)), address)
            XCTAssertTrue(NavigationURLPolicy.allows(url(address), engine: everyEngine), "the engine itself admits \(address)")
            XCTAssertFalse(NavigationURLPolicy.allowsShellRoute(url(address), engine: everyEngine), address)
        }
        for variant in ["chrome://settings/search/", "CHROME://SETTINGS/downloads", "chrome://settings/searchEngines?q=x"] {
            XCTAssertFalse(NavigationURLPolicy.allowsShellRoute(url(variant), engine: everyEngine), variant)
        }
        XCTAssertFalse(BrowserInternalPage.isReplacedStockSettings(url("chrome://downloads/")), "Chromium's downloads page is not a settings page")
        XCTAssertFalse(BrowserInternalPage.isReplacedStockSettings(url("https://example.com/search")))

        // The two commands lead to Darni's Profiles pane, on either engine.
        let store = SidebarStore.sample()
        for schemes in [NavigationURLPolicy.EngineSchemes([]), everyEngine] {
            let context = CommandBarContext(store: store, isSidebarVisible: true, closedTabStack: store.closedTabStack, navigationSchemes: schemes)
            let commands = AppCommandRegistry.all(in: context)
            for id in ["search-engine-settings", "download-settings"] {
                let command = commands.first { $0.id == id }
                XCTAssertEqual(command?.action, .showSettings(.profiles), id)
                XCTAssertEqual(command?.isEnabled(in: context), true, id)
            }
        }
    }

    /// Never regress: what Darni cannot do yet stays reachable, through the
    /// shell's own routes and from the command bar.
    func testEveryKeptRouteStaysReachable() {
        for entry in Self.kept {
            XCTAssertTrue(NavigationURLPolicy.allowsShellRoute(url(entry.address), engine: everyEngine), entry.address)
            XCTAssertFalse(BrowserInternalPage.isReplacedStockSettings(url(entry.address)), entry.address)
        }
        XCTAssertEqual(BrowserInternalPage.siteDetailsURL(origin: "https://a.test:8443")?.absoluteString,
                       "chrome://settings/content/siteDetails?site=https://a.test:8443")
        let store = SidebarStore.sample()
        let context = CommandBarContext(store: store, isSidebarVisible: true, closedTabStack: store.closedTabStack, navigationSchemes: everyEngine)
        let commands = AppCommandRegistry.all(in: context)
        let expected: [String: BrowserInternalPage] = [
            "browser-settings": .settings, "privacy-settings": .privacy, "site-settings": .siteSettings,
            "clear-browsing-data": .clearBrowsingData, "import-browser-data": .importData,
            "payment-settings": .payments, "notification-settings": .notifications,
        ]
        for (id, page) in expected {
            let command = commands.first { $0.id == id }
            XCTAssertEqual(command?.action, .openBrowserPage(page), id)
            XCTAssertEqual(command?.isEnabled(in: context), true, id)
        }
        // The site panel on Chromium: Cookies and Site Data… and Site Settings…, and the footer badge.
        let menu = SiteControlCenter.moreMenu(zoomPercent: 100, boosts: [], shellClearsSiteData: false, siteSettingsAvailable: true)
        XCTAssertEqual(menu.last, [.cookiesAndSiteData, .siteSettings])
        XCTAssertEqual(SiteControlCenter.footer(.secure, certificateAvailable: false, siteSettingsAvailable: true).action, .openSiteSettings)
    }

    /// The to-do document names every kept route, and the replaced ones.
    func testTheToDoDocumentListsEveryKeptRoute() throws {
        let document = try String(contentsOf: repository.appendingPathComponent("docs/STOCK-SETTINGS-ROUTES.md"), encoding: .utf8)
        for entry in Self.kept {
            XCTAssertTrue(document.contains("`\(entry.address)`"), "docs/STOCK-SETTINGS-ROUTES.md does not list \(entry.address)")
        }
        for address in Self.replaced {
            XCTAssertTrue(document.contains("`\(address)`"), "docs/STOCK-SETTINGS-ROUTES.md does not say \(address) is replaced")
        }
        let keptSection = try XCTUnwrap(document.components(separatedBy: "## Replaced").first)
        for address in Self.replaced {
            XCTAssertFalse(keptSection.contains("`\(address)`"), "\(address) is listed as kept")
        }
    }
}
