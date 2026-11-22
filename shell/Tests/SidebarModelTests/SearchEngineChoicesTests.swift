import XCTest
@testable import SidebarModel

/// ABI 1.46 `search_engines`: the Settings pop-up's list of default-search choices.
final class SearchEngineChoicesTests: XCTestCase {
    private let google = SearchEngineChoices.Engine(id: 2, name: "Google", keyword: "google.com",
                                                    searchTemplate: "https://www.google.com/search?q=%s",
                                                    isDefault: true, isPrepopulated: true)
    private let ddg = SearchEngineChoices.Engine(id: 7, name: "DuckDuckGo", keyword: "duckduckgo.com",
                                                 searchTemplate: "https://duckduckgo.com/?q=%s", isPrepopulated: true)

    func testCurrentIsTheDefaultRow() {
        XCTAssertEqual(SearchEngineChoices(engines: [ddg, google]).current?.id, 2)
        XCTAssertNil(SearchEngineChoices(engines: []).current)
    }

    func testSelectingMovesTheDefault() {
        let after = SearchEngineChoices(engines: [google, ddg]).selecting(7)
        XCTAssertEqual(after.current?.id, 7)
        XCTAssertEqual(after.engines.filter(\.isDefault).count, 1)
    }

    func testSelectingAnUnknownOrLockedEngineChangesNothing() {
        let choices = SearchEngineChoices(engines: [google, ddg])
        XCTAssertEqual(choices.selecting(99), choices)
        var locked = ddg
        locked.canMakeDefault = false
        let lockedChoices = SearchEngineChoices(engines: [google, locked])
        XCTAssertEqual(lockedChoices.selecting(7), lockedChoices)
    }

    func testAManagedDefaultIsNotEditable() {
        XCTAssertTrue(SearchEngineChoices(engines: [google, ddg]).isEditable)
        var g = google, d = ddg
        g.canMakeDefault = false
        d.canMakeDefault = false
        XCTAssertFalse(SearchEngineChoices(engines: [g, d], isManaged: true).isEditable)
        XCTAssertFalse(SearchEngineChoices(engines: [google], isManaged: true).isEditable, "policy wins over row flags")
    }

    // MARK: Chromium's flags (found on screen 2026-11-22)

    /// A profile's list as `ReArcSearchListEngines` gives it: `can_make_default`
    /// is `TemplateURLService::CanMakeDefault`, false for the default itself.
    private func engineList(defaultID: Int64) -> SearchEngineChoices {
        let names: [(Int64, String)] = [(2, "Google"), (5, "Brave"), (3, "Microsoft Bing"), (7, "DuckDuckGo"), (9, "Яндекс")]
        return SearchEngineChoices(engines: names.map { id, name in
            SearchEngineChoices.Engine(id: id, name: name, keyword: "\(id).test", searchTemplate: "https://\(id).test/?q=%s",
                                       isDefault: id == defaultID, isPrepopulated: true, canMakeDefault: id != defaultID)
        })
    }

    func testThePopUpOffersTheDefaultThoughItCannotBeMadeDefault() {
        let list = engineList(defaultID: 2)
        XCTAssertEqual(list.current?.canMakeDefault, false, "Chromium's flag for the default itself")
        XCTAssertEqual(list.offered.map(\.name), ["Google", "Brave", "Microsoft Bing", "DuckDuckGo", "Яндекс"])
        XCTAssertTrue(list.isEditable)
    }

    /// The pop-up listed Google ✓, Brave, Bing, DuckDuckGo, Яндекс; after
    /// DuckDuckGo was chosen Google was gone until the next launch.
    func testChangingTheDefaultKeepsEveryEngineOfferedInItsPlace() {
        let before = engineList(defaultID: 2)
        let after = before.selecting(7)
        XCTAssertEqual(after.current?.name, "DuckDuckGo")
        XCTAssertEqual(after.offered.map(\.name), before.offered.map(\.name), "the old default keeps its place in the pop-up")
        XCTAssertEqual(after, engineList(defaultID: 7), "the flags are the ones the engine reports with DuckDuckGo as the default")

        // And back, through the pop-up: the old default can be chosen again.
        let back = after.selecting(2)
        XCTAssertEqual(back, before)
        // Every engine in turn: none is ever lost.
        var list = before
        for id: Int64 in [5, 3, 7, 9, 2, 9, 5] {
            list = list.selecting(id)
            XCTAssertEqual(list.current?.id, id)
            XCTAssertEqual(list.offered.map(\.id), before.offered.map(\.id), "after choosing \(id)")
        }
    }

    func testChoosingTheDefaultAgainOrUnderPolicyChangesNothing() {
        let list = engineList(defaultID: 2)
        XCTAssertEqual(list.selecting(2), list, "the default cannot be made default: nothing to do")
        var managed = list
        managed.isManaged = true
        XCTAssertEqual(managed.selecting(7), managed, "policy holds the default")
    }

    func testAnEngineThatCanNeverBeTheDefaultIsNotOffered() {
        // One Chromium lists and refuses as a default (no replaceable search URL, say): never the default, never offered.
        var list = engineList(defaultID: 2)
        list.engines[1].canMakeDefault = false
        XCTAssertEqual(list.offered.map(\.name), ["Google", "Microsoft Bing", "DuckDuckGo", "Яндекс"])
        XCTAssertEqual(list.selecting(5), list)
        XCTAssertEqual(list.selecting(7).offered.map(\.name), ["Google", "Microsoft Bing", "DuckDuckGo", "Яндекс"])
    }

    func testAnEngineBecomesACommandBarProvider() {
        let provider = SearchEngineChoices.provider(ddg)
        XCTAssertEqual(provider.name, "DuckDuckGo")
        XCTAssertEqual(provider.searchURL(for: "arc browser")?.absoluteString, "https://duckduckgo.com/?q=arc%20browser")
        XCTAssertNil(provider.suggestTemplate)
    }
}
