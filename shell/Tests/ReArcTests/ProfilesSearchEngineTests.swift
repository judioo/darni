import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Build 1164 (2026-11-22): Settings › Profiles had no search engine pop-up on
/// an ordinary launch, only a "Search Settings…" button that opened Chromium's
/// stock settings page ("About Chromium", "AI in Chrome"). The pane now has
/// Darni's pop-up for each profile, and the search and download settings no
/// longer lead to Chromium's pages.
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
        for stock in ["Search Settings…", "Manage search", "Download Settings…"] {
            XCTAssertFalse(labels.contains(stock), "\(stock) opened Chromium's stock settings page")
        }
        XCTAssertFalse(labels.contains { $0.hasPrefix("/") }, "the download folder is named, not located: \(labels)")
    }

    // MARK: The command bar's Search Engine Settings and Download Settings

    /// They opened chrome://settings/search and /downloads; now Darni's own
    /// Profiles pane, where the pop-up and the Download location row are.
    func testTheSearchAndDownloadCommandsOpenDarnisProfilesPane() {
        let model = Build1164TestSupport.makeModel()
        var shown: [SettingsPane?] = []
        model.presentSettings = { shown.append($0) }
        let tabs = model.store.displayTabs().map(\.id)
        let context = CommandBarContext(store: model.store, isSidebarVisible: true, closedTabStack: ClosedTabStack())
        for id in ["search-engine-settings", "download-settings"] {
            let command = AppCommandRegistry.all(in: context).first { $0.id == id }
            XCTAssertEqual(command?.action, .showSettings(.profiles), id)
            guard let action = command?.action else { continue }
            XCTAssertNil(model.executeCommand(action, commandID: id), id)
        }
        XCTAssertEqual(shown, [.profiles, .profiles])
        XCTAssertEqual(model.settingsPane, .profiles)
        XCTAssertEqual(model.store.displayTabs().map(\.id), tabs, "no tab opens: the settings are Darni's window")
    }
}
