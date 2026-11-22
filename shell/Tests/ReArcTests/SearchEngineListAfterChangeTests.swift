import XCTest
@testable import ReArc
@testable import SidebarModel

/// Found on screen 2026-11-22 (QA build of main 2e0c72cb): Settings ›
/// Profiles' Search engine pop-up listed Google ✓, Brave, Microsoft Bing,
/// DuckDuckGo, Яндекс; after DuckDuckGo was chosen Google was gone from the
/// pop-up until the next launch. Chromium reports `can_make_default` false
/// for the current default, and the shell moved the default in its copy of
/// the list without that flag. These run the pop-up's own source
/// (`ChromiumSearchEngineSettings`) on a stand-in engine with Chromium's flags.
@MainActor
final class SearchEngineListAfterChangeTests: XCTestCase {
    /// `ReArcSearchListEngines` and `ReArcSearchSetDefaultEngine` as
    /// rearc_search_abi.cc has them: the list in a fixed order, `can_make_default`
    /// from `TemplateURLService::CanMakeDefault` (never the default itself,
    /// none under policy), a change refused for an engine that cannot be made default.
    private final class Engine: SearchEngineChoicesSource {
        var names: [(id: Int64, name: String)] = [(2, "Google"), (5, "Brave"), (3, "Microsoft Bing"), (7, "DuckDuckGo"), (9, "Яндекс")]
        var defaults: [Profile.ID: Int64] = [:]
        /// Engines Chromium lists and refuses as the default whoever asks.
        var neverDefault: Set<Int64> = []
        var managed = false
        /// Reads fail (the profile cannot be opened).
        var failsReads = false
        /// Reads wait here until `deliver` when set, as the engine's deferred callbacks do.
        var holdsReads = false
        private(set) var held: [() -> Void] = []
        private(set) var reads = 0

        func list(for profileID: Profile.ID) -> SearchEngineChoices {
            let current = defaults[profileID] ?? 2
            return SearchEngineChoices(engines: names.map { id, name in
                SearchEngineChoices.Engine(id: id, name: name, keyword: "\(id).test", searchTemplate: "https://\(id).test/?q=%s",
                                           isDefault: id == current, isPrepopulated: true,
                                           canMakeDefault: !managed && id != current && !neverDefault.contains(id))
            }, isManaged: managed)
        }

        func searchEngines(for profileID: Profile.ID, completion: @escaping (SearchEngineChoices?) -> Void) {
            reads += 1
            // The list is the engine's at the time of the read.
            let answer = failsReads ? nil : list(for: profileID)
            if holdsReads { held.append { completion(answer) } } else { completion(answer) }
        }

        func setDefaultSearchEngine(_ id: Int64, for profileID: Profile.ID, completion: @escaping (Bool) -> Void) {
            guard let row = list(for: profileID).engines.first(where: { $0.id == id }), row.canMakeDefault else { return completion(false) }
            defaults[profileID] = id
            completion(true)
        }

        /// Runs the held reads' callbacks: oldest first, or newest first when `reversed`.
        func deliver(reversed: Bool = false) {
            let callbacks = reversed ? Array(held.reversed()) : held
            held = []
            callbacks.forEach { $0() }
        }
    }

    private let all = ["Google", "Brave", "Microsoft Bing", "DuckDuckGo", "Яндекс"]
    private let profile = Profile.ID()

    /// The settings with the profile's list loaded, as the pane has it once it has been shown.
    private func loaded(_ engine: Engine) -> ChromiumSearchEngineSettings {
        let settings = ChromiumSearchEngineSettings(source: engine)
        _ = settings.engines(for: profile)
        return settings
    }

    private func names(_ settings: ChromiumSearchEngineSettings) -> [String] { settings.engines(for: profile).map(\.name) }

    func testChoosingAnotherEngineKeepsEveryEngineInThePopUp() {
        let engine = Engine()
        let settings = loaded(engine)
        XCTAssertEqual(names(settings), all)
        XCTAssertEqual(settings.defaultEngine(for: profile), "2")

        settings.setDefaultEngine("7", for: profile)
        XCTAssertEqual(settings.defaultEngine(for: profile), "7")
        XCTAssertEqual(names(settings), all, "Google, the old default, is still listed, in its place")
        XCTAssertTrue(settings.isEditable(for: profile))

        // Back to the old default from the pop-up, and on through every engine.
        for id in ["2", "5", "3", "9", "7", "2"] {
            settings.setDefaultEngine(id, for: profile)
            XCTAssertEqual(settings.defaultEngine(for: profile), id)
            XCTAssertEqual(engine.defaults[profile], Int64(id), "the engine has the choice")
            XCTAssertEqual(names(settings), all, "after choosing \(id)")
        }
    }

    /// The pop-up's own row model (`ProfileSearchEngineRow`), through the model's call the binding makes.
    func testThePopUpsRowListsTheSameEnginesAfterAChange() throws {
        let model = Build1164TestSupport.makeModel()
        let home = model.store.activeProfileID
        let engine = Engine()
        let settings = ChromiumSearchEngineSettings(source: engine)
        model.searchEngineSettings = settings
        _ = ProfileSearchEngineRow(model: model, profileID: home)
        let before = try XCTUnwrap(ProfileSearchEngineRow(model: model, profileID: home))
        XCTAssertEqual(before.options.map(\.name), all)
        XCTAssertEqual(before.selection, "2")

        model.setDefaultSearchEngine("7", for: home)
        let after = try XCTUnwrap(ProfileSearchEngineRow(model: model, profileID: home))
        XCTAssertEqual(after.selection, "7")
        XCTAssertEqual(after.options, before.options, "choosing an engine does not change the list")
        XCTAssertTrue(after.isEditable)
    }

    func testTheListIsReadFromTheEngineAgainAfterAChange() {
        let engine = Engine()
        let settings = loaded(engine)
        XCTAssertEqual(engine.reads, 1)
        engine.holdsReads = true

        settings.setDefaultEngine("7", for: profile)
        XCTAssertEqual(engine.reads, 2, "an accepted change reads the engine's list again")
        // Before that read is back the pop-up already shows the choice, with every engine.
        XCTAssertEqual(settings.defaultEngine(for: profile), "7")
        XCTAssertEqual(names(settings), all)

        // The engine's own list is what the pop-up then has: a row whose flag only the engine knows follows it.
        engine.neverDefault = [5]
        engine.holdsReads = false
        settings.setDefaultEngine("3", for: profile)
        XCTAssertEqual(names(settings), ["Google", "Microsoft Bing", "DuckDuckGo", "Яндекс"],
                       "the engine no longer offers Brave: the re-read list says so")
        XCTAssertEqual(settings.defaultEngine(for: profile), "3")
    }

    func testAReadThatFailsAfterAChangeKeepsEveryEngine() {
        let engine = Engine()
        let settings = loaded(engine)
        engine.failsReads = true
        settings.setDefaultEngine("7", for: profile)
        XCTAssertEqual(settings.defaultEngine(for: profile), "7")
        XCTAssertEqual(names(settings), all, "the shell's own reading of the change stands, the old default in it")
    }

    func testAReadOvertakenByALaterChangeIsDropped() {
        let engine = Engine()
        let settings = loaded(engine)
        engine.holdsReads = true
        settings.setDefaultEngine("7", for: profile)
        settings.setDefaultEngine("9", for: profile)
        XCTAssertEqual(settings.defaultEngine(for: profile), "9")
        // The two reads come back newest first: the older one, with DuckDuckGo as the default, must not win.
        engine.deliver(reversed: true)
        XCTAssertEqual(settings.defaultEngine(for: profile), "9")
        XCTAssertEqual(names(settings), all)
    }

    func testARefusedChangeLeavesThePopUpAsItWas() {
        let engine = Engine()
        engine.neverDefault = [5]
        let settings = loaded(engine)
        XCTAssertEqual(names(settings), ["Google", "Microsoft Bing", "DuckDuckGo", "Яндекс"])
        let reads = engine.reads
        settings.setDefaultEngine("5", for: profile)
        settings.setDefaultEngine("2", for: profile)
        settings.setDefaultEngine("not a number", for: profile)
        XCTAssertEqual(settings.defaultEngine(for: profile), "2")
        XCTAssertEqual(engine.reads, reads, "nothing changed: nothing to read again")

        // Under policy the default shows alone and cannot change.
        engine.managed = true
        let managed = loaded(engine)
        XCTAssertEqual(names(managed), ["Google"])
        XCTAssertFalse(managed.isEditable(for: profile))
        managed.setDefaultEngine("7", for: profile)
        XCTAssertEqual(managed.defaultEngine(for: profile), "2")
    }
}
