import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Build 1164 (2026-11-22): Settings › Profiles had no search engine pop-up on
/// an ordinary launch, only a "Search Settings…" button that opened Chromium's
/// stock settings page ("About Chromium", "AI in Chrome"). The pane now has
/// Darni's pop-up for each profile, and nothing in the shell opens that page.
final class ProfilesSearchEngineTests: XCTestCase {
    /// An engine's per-profile lists, as Chromium's `search_engines` gives them.
    private final class EngineLists: SearchEngineSettings {
        var lists: [Profile.ID: [SearchEngineChoice]] = [:]
        var defaults: [Profile.ID: String] = [:]
        var managed: Set<Profile.ID> = []
        func engines(for profileID: Profile.ID) -> [SearchEngineChoice] { lists[profileID] ?? [] }
        func defaultEngine(for profileID: Profile.ID) -> String? { defaults[profileID] }
        func setDefaultEngine(_ id: String, for profileID: Profile.ID) { defaults[profileID] = id }
        func isEditable(for profileID: Profile.ID) -> Bool { !managed.contains(profileID) }
    }

    private static let engines = [
        SearchEngineChoice(id: "1", name: "Google"), SearchEngineChoice(id: "2", name: "DuckDuckGo"), SearchEngineChoice(id: "3", name: "Ecosia"),
    ]

    // MARK: Settings › Profiles: the search engine pop-up

    func testTheProfilesPaneOffersEachProfilesEnginesAndSetsThatProfilesDefault() throws {
        let model = Build1164TestSupport.makeModel()
        let home = model.store.activeProfileID
        let work = try XCTUnwrap(model.saveProfile(ProfileDraft(name: "Work"), id: nil, selecting: false)).id
        let source = EngineLists()
        source.lists = [home: Self.engines, work: Array(Self.engines.prefix(2))]
        source.defaults = [home: "1", work: "2"]
        model.searchEngineSettings = source

        let homeRow = try XCTUnwrap(ProfileSearchEngineRow(model: model, profileID: home))
        XCTAssertEqual(homeRow.options.map(\.name), ["Google", "DuckDuckGo", "Ecosia"], "the pop-up lists the profile's engines")
        XCTAssertEqual(homeRow.selection, "1")
        XCTAssertTrue(homeRow.isEditable)
        let workRow = try XCTUnwrap(ProfileSearchEngineRow(model: model, profileID: work))
        XCTAssertEqual(workRow.options.map(\.name), ["Google", "DuckDuckGo"], "each profile has its own list")
        XCTAssertEqual(workRow.selection, "2")

        // As the pop-up's binding sets it.
        model.setDefaultSearchEngine("3", for: home)
        XCTAssertEqual(source.defaults, [home: "3", work: "2"], "choosing an engine sets that profile's default and no other's")
        XCTAssertEqual(ProfileSearchEngineRow(model: model, profileID: home)?.selection, "3")
        XCTAssertEqual(ProfileSearchEngineRow(model: model, profileID: work)?.selection, "2")

        // A list still loading, and a default managed by policy: shown, not changeable.
        source.lists[work] = []
        XCTAssertEqual(ProfileSearchEngineRow(model: model, profileID: work)?.isEditable, false)
        source.managed = [home]
        XCTAssertEqual(ProfileSearchEngineRow(model: model, profileID: home)?.isEditable, false)
    }

    /// The pane's box for a profile, laid out off screen and read through
    /// accessibility: a pop-up named "Search engine", and no button to the
    /// engine's own settings.
    func testTheProfilesPaneShowsThePopUpAndNoWayToChromiumsSearchSettings() throws {
        let model = Build1164TestSupport.makeModel()
        let home = try XCTUnwrap(model.store.profiles.first)
        let source = EngineLists()
        source.lists = [home.id: Self.engines]
        source.defaults = [home.id: "2"]
        model.searchEngineSettings = source

        let labels = Build1164TestSupport.accessibilityTexts(of: VStack(spacing: 8) {
            ProfileSearchEngineGroup(model: model, profile: home)
            SettingsGroup { DownloadLocationRow(downloads: model.downloads) }
        }.frame(width: 520), size: NSSize(width: 520, height: 160))
        XCTAssertTrue(labels.contains(ProfileSearchEngineGroup.label), "no pop-up named Search engine in \(labels)")
        XCTAssertTrue(labels.contains("DuckDuckGo"), "the pop-up shows the profile's default in \(labels)")
        XCTAssertTrue(labels.contains("Change…"), "Download location has Darni's own chooser in \(labels)")
        for stock in ["Search Settings…", "Manage search", "Download Settings…", "More Settings…"] {
            XCTAssertFalse(labels.contains(stock), "\(stock) opened Chromium's stock settings page")
        }
        XCTAssertFalse(labels.contains { $0.hasPrefix("/") }, "the download folder is named, not located: \(labels)")
    }

    // MARK: No route to Chromium's stock settings

    func testNoMenuItemLeadsToChromiumsSettings() {
        let model = Build1164TestSupport.makeModel()
        let groups = ShellMenus.importing(model) + ShellMenus.browserPages(model) + ShellMenus.printing(model) + ShellMenus.capture(model)
            + ShellMenus.documents(model) + ShellMenus.library(model) + ShellMenus.downloads(model) + ShellMenus.sidebarItems(model)
        let titles = groups.flatMap { $0 }.map(\.title)
        for gone in ["Import from Safari or Firefox…", "Clear Browsing Data…", "Site Settings…", "Search Settings…"] {
            XCTAssertFalse(titles.contains(gone), gone)
        }
        XCTAssertEqual(ShellMenus.importing(model).flatMap { $0 }.map(\.title),
                       ["Import from Arc, Chrome or Brave…", "Import Bookmarks from HTML File…"])
        // A page the shell is asked to open by address goes through the same refusal.
        let tabs = model.store.displayTabs().map(\.id)
        model.openPageInNewTab(URL(string: "chrome://settings/search")!, title: "Search")
        XCTAssertEqual(model.store.displayTabs().map(\.id), tabs)
    }
}
