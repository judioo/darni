import XCTest
@testable import SidebarModel

/// Chromium's stock settings page (chrome://settings and every page under it:
/// "About Chromium", "AI in Chrome", Chromium's own shortcuts) is never shown:
/// no page, command, site panel item, autofill row or source line of the shell
/// leads to it. Found on build 1164, where Settings › Profiles' "Search
/// Settings…" opened it.
final class StockSettingsRouteTests: XCTestCase {
    private let everyEngine = NavigationURLPolicy.EngineSchemes.chromium.union(.dailyWebUI).union(.creditsWebUI)

    private func url(_ string: String) -> URL { URL(string: string)! }

    func testNoInternalPageIsAStockSettingsPage() {
        XCTAssertEqual(Set(BrowserInternalPage.allCases), [.credits, .version, .history, .downloads, .passwords, .extensions])
        for page in BrowserInternalPage.allCases {
            XCTAssertFalse(BrowserInternalPage.isStockSettings(page.url), "\(page.rawValue) opens \(page.url.absoluteString)")
            XCTAssertNotEqual(page.url.host(), "settings", page.rawValue)
        }
        for stock in ["chrome://settings", "chrome://settings/", "chrome://settings/search", "CHROME://SETTINGS/privacy",
                      "chrome://settings/content/siteDetails?site=https://a.test", "chrome://settings/clearBrowserData"] {
            XCTAssertTrue(BrowserInternalPage.isStockSettings(url(stock)), stock)
        }
        for other in ["chrome://password-manager/passwords", "chrome://extensions/shortcuts", "chrome://version", "chrome://history/",
                      "https://settings.example/", "https://example.com/settings/search", "file:///settings"] {
            XCTAssertFalse(BrowserInternalPage.isStockSettings(url(other)), other)
        }
    }

    /// A menu, a Settings row or a prompt's link opens its page through this check.
    func testTheShellOpensNoStockSettingsPageOfItsOwnAccord() {
        for stock in ["chrome://settings", "chrome://settings/search", "chrome://settings/payments", "chrome://settings/addresses",
                      "chrome://settings/clearBrowserData", "chrome://settings/importData", "chrome://settings/content/notifications"] {
            XCTAssertTrue(NavigationURLPolicy.allows(url(stock), engine: everyEngine), "the engine itself admits \(stock)")
            XCTAssertFalse(NavigationURLPolicy.allowsShellRoute(url(stock), engine: everyEngine), stock)
        }
        for page in BrowserInternalPage.allCases {
            XCTAssertTrue(NavigationURLPolicy.allowsShellRoute(page.url, engine: everyEngine), page.rawValue)
        }
        XCTAssertTrue(NavigationURLPolicy.allowsShellRoute(url("chrome://extensions/shortcuts"), engine: everyEngine))
        XCTAssertTrue(NavigationURLPolicy.allowsShellRoute(url("chrome://password-manager/passwords"), engine: everyEngine))
        XCTAssertTrue(NavigationURLPolicy.allowsShellRoute(url("https://example.com/"), engine: []))
        XCTAssertFalse(NavigationURLPolicy.allowsShellRoute(url("chrome://flags"), engine: everyEngine), "still what the engine admits")
    }

    func testNoCommandOpensAStockSettingsPage() {
        let store = SidebarStore.sample()
        store.addTab(kind: .today, title: "Example", url: url("https://example.com"))
        let context = CommandBarContext(store: store, isSidebarVisible: true, closedTabStack: store.closedTabStack, navigationSchemes: everyEngine)
        let commands = AppCommandRegistry.all(in: context)
        XCTAssertFalse(commands.isEmpty)
        for command in commands {
            if case .openBrowserPage(let page) = command.action {
                XCTAssertFalse(BrowserInternalPage.isStockSettings(page.url), "\(command.id) opens \(page.url.absoluteString)")
            }
        }
        // The commands that opened its pages are gone, by ID and by what the person reads.
        let gone = ["browser-settings", "privacy-settings", "site-settings", "clear-browsing-data", "import-browser-data",
                    "search-engine-settings", "download-settings", "payment-settings", "notification-settings"]
        XCTAssertTrue(Set(commands.map(\.id)).isDisjoint(with: gone))
        let titles = Set(commands.map(\.title))
        for title in ["Settings", "Privacy and Security Settings", "Site Settings", "Clear Browsing Data…", "Import from Safari or Firefox…",
                      "Search Engine Settings", "Download Settings", "Payment Methods", "Notification Settings"] {
            XCTAssertFalse(titles.contains(title), title)
        }
        // What stays: Chromium's pages that are not its settings.
        XCTAssertTrue(commands.contains { $0.action == .openBrowserPage(.passwords) })
        XCTAssertTrue(commands.contains { $0.action == .openBrowserPage(.extensions) })
        for query in [">settings", ">search engine", ">clear browsing", ">privacy", ">payment"] {
            for result in CommandBarSearch.results(for: query, in: store, navigationSchemes: everyEngine) {
                if case .openBrowserPage(let page) = result.commandAction {
                    XCTAssertFalse(BrowserInternalPage.isStockSettings(page.url), "\(query) offers \(page.url.absoluteString)")
                }
            }
        }
    }

    /// The site panel on Chromium: no row, ⋯ menu item or footer leads to
    /// Chromium's per-site settings page.
    func testTheSitePanelHasNoWayToChromiumsSiteSettings() {
        let menu = SiteControlCenter.moreMenu(zoomPercent: 100, boosts: [], shellClearsSiteData: false)
        XCTAssertEqual(menu.flatMap { $0 }.map(\.title), ["Zoom 100%", "Zoom In", "Zoom Out", "Actual Size"])
        for connection in [SiteControlCenter.Connection.secure, .insecure, .dangerous, .unknown] {
            XCTAssertNil(SiteControlCenter.footer(connection, certificateAvailable: false).action, "\(connection)")
        }
        let entry = SitePermissionStore.Entry(decision: .deny, remembered: true, date: Date())
        let rows = SiteControlCenter.settingRows(permissions: [(type: .camera, entry: entry)], permissionsInEngine: true,
                                                 autoPiP: .enabled, autoPiPEnabled: true)
        XCTAssertEqual(rows.first?.kind, .permission(PermissionType.camera.key))
        XCTAssertFalse(rows.flatMap(\.actions).map(\.title).contains { $0.contains("Site Settings") })
        XCTAssertEqual(rows.first?.actions, [])
    }

    /// Autofill's list: "Manage addresses…" and "Manage payment methods…"
    /// opened chrome://settings/addresses and /payments. Passwords keep theirs
    /// (the password manager is its own page).
    func testAutofillListsNoManageRowForAStockSettingsPage() {
        let engineRows = [
            AutofillSuggestionRow(id: 0, value: "1 Main Street"),
            AutofillSuggestionRow(id: 1, value: "2 Side Street"),
            AutofillSuggestionRow(id: 2, value: "", kind: .separator, isAcceptable: false),
            AutofillSuggestionRow(id: 3, value: "Manage addresses…", icon: "settings", kind: .manage),
        ]
        for product in [AutofillProduct.address, .creditCard, .iban, .autocomplete, .datalist] {
            let rows = AutofillPopup.rowsWithoutStockSettings(engineRows, product: product)
            XCTAssertEqual(rows.map(\.id), [0, 1], "product \(product.rawValue): the fill rows keep the engine's indexes")
            XCTAssertFalse(rows.contains { $0.kind == .manage || $0.kind == .separator }, "product \(product.rawValue)")
        }
        XCTAssertEqual(AutofillPopup.rowsWithoutStockSettings(engineRows, product: .password), engineRows,
                       "Manage passwords… opens the password manager, not Chromium's settings")
        // A divider between fill rows stays; none is left first, last or doubled.
        let mixed = [
            AutofillSuggestionRow(id: 0, value: "", kind: .manage),
            AutofillSuggestionRow(id: 1, value: "", kind: .separator, isAcceptable: false),
            AutofillSuggestionRow(id: 2, value: "Visa"),
            AutofillSuggestionRow(id: 3, value: "", kind: .separator, isAcceptable: false),
            AutofillSuggestionRow(id: 4, value: "", kind: .separator, isAcceptable: false),
            AutofillSuggestionRow(id: 5, value: "Amex"),
            AutofillSuggestionRow(id: 6, value: "", kind: .separator, isAcceptable: false),
        ]
        XCTAssertEqual(AutofillPopup.rowsWithoutStockSettings(mixed, product: .creditCard).map(\.id), [2, 3, 5])
        let plain = [AutofillSuggestionRow(id: 0, value: "one"), AutofillSuggestionRow(id: 1, value: "two")]
        XCTAssertEqual(AutofillPopup.rowsWithoutStockSettings(plain, product: .datalist), plain)
    }

    /// Every line of shell source outside a comment: none holds the address
    /// of Chromium's settings, so no menu, action or constant can open it.
    func testNoShellSourceLineHoldsTheStockSettingsAddress() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources", isDirectory: true)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 200, "the shell's sources were not found at \(sources.path)")
        let address = "chrome://" + BrowserInternalPage.stockSettingsHost
        var found: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() where line.lowercased().contains(address) {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                found.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(found, [], "shell code names Chromium's stock settings page")
    }
}
