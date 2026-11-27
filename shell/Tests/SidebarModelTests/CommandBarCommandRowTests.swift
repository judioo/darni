import XCTest
@testable import SidebarModel

/// Command rows stand apart from web search (owner, 2026-11-27: "The custom
/// menu items are almost indistinguishable from web search … indicate that a
/// shortcut key hasn't been defined"): their kind and hint, the keys as set
/// in Settings › Shortcuts, their low-light inks, and the best command moving
/// up behind the search when the typed words start its title.
final class CommandBarCommandRowTests: XCTestCase {
    private let google = URL(string: "https://www.google.com/search?q=peek")!

    private func store(spaces: [String] = ["Main"]) -> SidebarStore {
        SidebarStore(spaces: spaces.enumerated().map { Space(name: $1, sortRank: "a\($0)") })
    }

    /// The owner's screenshot: "peek" with four Google suggestions.
    private func peekLive() -> CommandBarLiveResults {
        CommandBarLiveResults(query: "peek", suggestions: ["peek", "peeky blinders", "peekaboo", "peek a boo", "peeks"].map {
            SearchSuggestion(text: $0, destinationURL: URL(string: "https://www.google.com/search?q=\($0.replacingOccurrences(of: " ", with: "+"))")!)
        }, classification: .search(google))
    }

    private let peekCatalog = [
        AppCommand(id: "peek-at-url", title: "Peek at URL…", keywords: ["peek", "url"], action: .peekAtURL),
        AppCommand(id: "space-appearance-dark", title: "Appearance: Dark", keywords: ["dark", "peek"], action: .setSpaceAppearance(.dark)),
        AppCommand(id: "external-links-activeSpace", title: "Open External Links in the Current Space",
                   keywords: ["external", "peek"], action: .setExternalLinkDestination(.activeSpace)),
    ]

    // MARK: Row kinds

    func testOnlyCommandRowsCarryAShortcutHint() {
        let results = CommandBarSearch.results(for: "peek", in: store(), commandCatalog: peekCatalog, live: peekLive())
        XCTAssertEqual(results.first?.kind, .search)
        XCTAssertEqual(results.filter { $0.kind == .suggestion }.count, 4)
        XCTAssertEqual(Set(results.filter { $0.kind == .command }.compactMap(\.commandID)),
                       ["peek-at-url", "space-appearance-dark", "external-links-activeSpace"])
        for row in results {
            XCTAssertEqual(row.shortcutHint != nil, row.kind == .command, row.title)
        }
    }

    // MARK: Shortcut text

    func testABoundCommandShowsItsKeys() throws {
        let results = CommandBarSearch.results(for: ">peek", in: store(), commandCatalog: peekCatalog)
        let peek = try XCTUnwrap(results.first { $0.commandID == "peek-at-url" })
        XCTAssertEqual(peek.shortcutID, "peekAtURL")
        XCTAssertEqual(peek.keyEquivalent, "⇧⌘P")
        XCTAssertEqual(peek.shortcutHint, .keys("⇧⌘P"))
        XCTAssertEqual(peek.shortcutHint?.text, "⇧⌘P")
        XCTAssertEqual(peek.shortcutHint?.help, "Shortcut: ⇧⌘P")
    }

    func testAKeyChangedInSettingsIsTheKeyShown() throws {
        var overrides = ShortcutOverrides()
        overrides.set(ShortcutChord(.character("k"), [.option, .command]), for: "peekAtURL")
        // The menu snapshot is not what decides: the binding as set now is.
        let menu = [MenuCommand(id: "0/3:File › Peek at URL…", title: "Peek at URL…", path: "File › Peek at URL…", keyEquivalent: "⇧⌘P")]
        let results = CommandBarSearch.results(for: ">peek", in: store(), commandCatalog: peekCatalog, menuCommands: menu,
                                               shortcuts: overrides)
        XCTAssertEqual(results.first { $0.commandID == "peek-at-url" }?.shortcutHint, .keys("⌥⌘K"))
    }

    func testAnUnboundCommandSaysNoShortcutAndWhereToSetOne() throws {
        var overrides = ShortcutOverrides()
        overrides.unbind("peekAtURL")
        let results = CommandBarSearch.results(for: ">peek", in: store(), commandCatalog: peekCatalog, shortcuts: overrides)
        let peek = try XCTUnwrap(results.first { $0.commandID == "peek-at-url" })
        XCTAssertNil(peek.keyEquivalent)
        XCTAssertEqual(peek.shortcutHint, .none(settable: true))
        XCTAssertEqual(peek.shortcutHint?.text, "No shortcut")
        XCTAssertEqual(peek.shortcutHint?.help, "No shortcut. Set one in Settings › Shortcuts.")
        XCTAssertEqual(CommandBarSearch.rowActions(for: peek), [.setShortcut])
    }

    func testACommandWithNoBindingSaysNoShortcut() throws {
        let results = CommandBarSearch.results(for: ">peek", in: store(), commandCatalog: peekCatalog)
        for id in ["space-appearance-dark", "external-links-activeSpace"] {
            let row = try XCTUnwrap(results.first { $0.commandID == id })
            XCTAssertNil(row.shortcutID, id)
            XCTAssertEqual(row.shortcutHint, .none(settable: false), id)
            XCTAssertEqual(row.shortcutHint?.text, "No shortcut")
            XCTAssertEqual(row.shortcutHint?.help, "No shortcut", "nothing to point at: Settings › Shortcuts does not list it")
            XCTAssertEqual(CommandBarSearch.rowActions(for: row), [], id)
        }
    }

    func testACommandWithoutABindingKeepsASameTitledMenuItemsKeys() throws {
        let catalog = [AppCommand(id: "browser-downloads", title: "Downloads", action: .openBrowserPage(.downloads))]
        let menu = [MenuCommand(id: "3/1:View › Downloads", title: "Downloads", path: "View › Downloads", keyEquivalent: "⌥⌘L")]
        let row = try XCTUnwrap(CommandBarSearch.results(for: ">downloads", in: store(), commandCatalog: catalog, menuCommands: menu)
            .first { $0.commandID == "browser-downloads" })
        XCTAssertNil(row.shortcutID)
        XCTAssertEqual(row.shortcutHint, .keys("⌥⌘L"))
    }

    func testMenuRowsSayNoShortcutToo() throws {
        let menu = [
            MenuCommand(id: "5/2:Window › Task Manager", title: "Task Manager", path: "Window › Task Manager", keyEquivalent: ""),
            MenuCommand(id: "5/3:Window › Minimize", title: "Minimize", path: "Window › Minimize", keyEquivalent: "⌘M"),
        ]
        let results = CommandBarSearch.results(for: ">", in: store(), commandCatalog: [], menuCommands: menu)
        XCTAssertEqual(results.first { $0.title == "Task Manager" }?.shortcutHint, .none(settable: false))
        XCTAssertEqual(results.first { $0.title == "Minimize" }?.shortcutHint, .keys("⌘M"))
    }

    func testSwitchingToASpaceShowsItsControlNumber() throws {
        let store = store(spaces: (1 ... 10).map { "Space \($0)" })
        let results = CommandBarSearch.results(for: ">switch to space", in: store)
        let second = try XCTUnwrap(results.first { $0.title == "Switch to Space 2" })
        XCTAssertEqual(second.shortcutID, "goToSpace2")
        XCTAssertEqual(second.shortcutHint, .keys("⌃2"))
        let tenth = try XCTUnwrap(results.first { $0.title == "Switch to Space 10" })
        XCTAssertEqual(tenth.shortcutHint, .none(settable: false), "⌃1…⌃9 only")
        var overrides = ShortcutOverrides()
        overrides.set(ShortcutChord(.character("2"), [.option, .control]), for: "goToSpace2")
        XCTAssertEqual(CommandBarSearch.results(for: ">switch to space 2", in: store, shortcuts: overrides)
            .first { $0.title == "Switch to Space 2" }?.shortcutHint, .keys("⌃⌥2"))
    }

    func testEveryMappedCommandAndBindingExists() {
        let ids = Set(AppCommandRegistry.staticCommands(in: CommandBarContext(store: store(), isSidebarVisible: true,
                                                                              closedTabStack: ClosedTabStack())).map(\.id))
        for (command, binding) in CommandBarShortcuts.bindingIDs {
            XCTAssertTrue(ids.contains(command), "\(command) is a command")
            XCTAssertNotNil(ArcShortcuts.binding(id: binding), "\(binding) is a Settings › Shortcuts binding")
            XCTAssertFalse(ArcShortcuts.shadowed.contains { $0.id == binding }, "\(binding)'s keys run it, not another item")
        }
        // The keys these show by default, as in the menus.
        let defaults = ShortcutOverrides()
        let expected = ["new-tab": "⌘T", "close-tab": "⌘W", "reopen-closed-tab": "⇧⌘T", "pin-tab": "⌘D", "toggle-sidebar": "⌘S",
                        "toggle-mini-sidebar": "⇧⌘S", "split-right": "⌃⇧=", "next-tab": "⌥⌘↓", "peek-at-url": "⇧⌘P",
                        "open-little-arc": "⌥⌘N", "capture-area": "⇧⌘2", "find-in-page": "⌘F", "show-downloads": "⇧⌘J",
                        "go-back": "⌘[", "copy-url": "⇧⌘C", "next-space": "⌥⌘→", "clear-unpinned-tabs": "⇧⌘K"]
        for (command, keys) in expected {
            XCTAssertEqual(CommandBarShortcuts.bindingIDs[command].flatMap { defaults.chord(for: $0)?.display }, keys, command)
        }
    }

    func testHintWording() {
        XCTAssertEqual(CommandBarShortcutHint.keys("⌘T").text, "⌘T")
        XCTAssertEqual(CommandBarShortcutHint.keys("⌘T").accessibilityText, "Shortcut ⌘T")
        XCTAssertEqual(CommandBarShortcutHint.none(settable: true).accessibilityText, "No shortcut")
        XCTAssertEqual(CommandBarRowAction.setShortcut.title, "Set Shortcut…")
        XCTAssertEqual(CommandBarRowAction.setShortcut.systemImage, "keyboard")
    }

    // MARK: Ranking

    func testTheBestCommandComesStraightAfterTheSearchWhenItsTitleStartsWithTheText() {
        let results = CommandBarSearch.results(for: "peek", in: store(), commandCatalog: peekCatalog, live: peekLive())
        XCTAssertEqual(results.map(\.kind), [.search, .command, .suggestion, .suggestion, .suggestion, .suggestion, .command, .command])
        XCTAssertEqual(results[0].title, "peek", "the typed search stays first")
        XCTAssertEqual(results[1].commandID, "peek-at-url")
        XCTAssertEqual(results.filter { $0.id == "cmd-peek-at-url" }.count, 1, "moved, not copied")
        // "peek at u": whole words, the last cut short.
        XCTAssertEqual(CommandBarSearch.results(for: "Peek at U", in: store(), commandCatalog: peekCatalog)[1].commandID, "peek-at-url")
    }

    func testTheCommandComesBeforeHistoryToo() {
        let history = VisitHistory(records: [VisitRecord(url: URL(string: "https://peek.example/")!, title: "Peek Example", visitCount: 9,
                                                         firstVisit: Date(), lastVisit: Date())])
        let results = CommandBarSearch.results(for: "peek", in: store(), history: history, commandCatalog: peekCatalog)
        XCTAssertEqual(results.prefix(3).map(\.kind), [.search, .command, .history])
    }

    /// Two suggestions for `query`, so a command that did not move up sits after them.
    private func live(_ query: String, classification: InputClassification) -> CommandBarLiveResults {
        CommandBarLiveResults(query: query, suggestions: ["one", "two"].map {
            SearchSuggestion(text: "\(query) \($0)", destinationURL: URL(string: "https://www.google.com/search?q=\($0)")!)
        }, classification: classification)
    }

    func testCommandsStayLaterWhenTheTextIsNotTheStartOfTheTitle() {
        // "dark" is inside "Appearance: Dark"; "pee" is too short; "eek" is mid-word.
        for query in ["dark", "pee", "eek", "url"] {
            let results = CommandBarSearch.results(for: query, in: store(), commandCatalog: peekCatalog,
                                                   live: live(query, classification: .search(google)))
            XCTAssertEqual(results.prefix(3).map(\.kind), [.search, .suggestion, .suggestion], query)
            XCTAssertTrue(results.dropFirst(3).allSatisfy { $0.kind == .command }, query)
        }
    }

    func testATypedAddressKeepsItsOpenRowFirstAndNoCommandMovesUp() {
        let catalog = [AppCommand(id: "peek-at-url", title: "Peek.com Tools", action: .peekAtURL)]
        let results = CommandBarSearch.results(for: "peek.com", in: store(), commandCatalog: catalog,
                                               live: live("peek.com", classification: .url(URL(string: "https://peek.com/")!)))
        XCTAssertEqual(results.map(\.kind), [.openURL, .suggestion, .suggestion, .command])
    }

    func testOpenTabsStillLeadAndTheCommandFollowsTheSearch() {
        let store = store()
        _ = store.addTab(kind: .today, title: "Peek Docs", url: URL(string: "https://docs.test/peek")!)
        let results = CommandBarSearch.results(for: "peek", in: store, commandCatalog: peekCatalog)
        XCTAssertEqual(results.prefix(3).map(\.kind), [.openTab, .search, .command])
    }

    func testPromotionRule() {
        XCTAssertTrue(CommandBarSearch.isTitlePrefixMatch("peek", title: "Peek at URL…"))
        XCTAssertTrue(CommandBarSearch.isTitlePrefixMatch("peek  at", title: "Peek at URL…"))
        XCTAssertTrue(CommandBarSearch.isTitlePrefixMatch("new tab", title: "New Tab"))
        XCTAssertFalse(CommandBarSearch.isTitlePrefixMatch("new", title: "New Tab"), "three letters")
        XCTAssertFalse(CommandBarSearch.isTitlePrefixMatch("dark", title: "Appearance: Dark"))
        XCTAssertFalse(CommandBarSearch.isTitlePrefixMatch("peek at x", title: "Peek at URL…"))
        XCTAssertFalse(CommandBarSearch.isTitlePrefixMatch("", title: "Peek at URL…"))
    }

    // MARK: Low light

    private let accents = ["#858AFF", "#2731FF", "#AE9D8D", "#579F8F", "#C17C82", "#F2C94C", "#1D4ED8", "#E5E5E5", "#111111"]
        .compactMap { SpaceColor(hex: $0) }

    func testCommandRowsAreTintedQuieterThanTheSelectionAndStillRead() {
        for accent in accents {
            let selection = CommandBarInk.selectionFill(accent)
            for dark in [false, true] {
                let card = CommandBarInk.surface(dark: dark)
                for increased in [false, true] {
                    let label = "\(accent.hex) dark \(dark) contrast \(increased)"
                    let fill = CommandBarInk.commandRowFill(accent: selection, dark: dark, increasedContrast: increased)
                    XCTAssertNotEqual(fill.hex, card.hex, label)
                    XCTAssertGreaterThan(selection.contrast(with: card), fill.contrast(with: card), "the selection stays the strongest: \(label)")
                    XCTAssertGreaterThanOrEqual(CommandBarInk.commandPrimaryText(accent: selection, dark: dark, increasedContrast: increased)
                        .contrast(with: fill), SidebarContrast.text, label)
                    XCTAssertGreaterThanOrEqual(CommandBarInk.commandSecondaryText(accent: selection, dark: dark, increasedContrast: increased)
                        .contrast(with: fill), SidebarContrast.text, label)
                    XCTAssertGreaterThanOrEqual(CommandBarInk.commandGlyph(accent: selection, dark: dark, increasedContrast: increased)
                        .contrast(with: fill), SidebarContrast.glyph, label)
                }
                XCTAssertGreaterThanOrEqual(CommandBarInk.commandRowEdge(accent: selection, dark: dark)
                    .contrast(with: CommandBarInk.commandRowFill(accent: selection, dark: dark, increasedContrast: true)),
                    SidebarContrast.glyph, "\(accent.hex) dark \(dark)")
            }
        }
    }

    /// A tint people can see: a clear step in OKLab from the card, and
    /// Increase Contrast a larger one.
    func testTheTintIsVisibleAndIncreaseContrastDeepensIt() {
        func distance(_ a: SpaceColor, _ b: SpaceColor) -> Double {
            let (x, y) = (a.oklab, b.oklab)
            return ((x.l - y.l) * (x.l - y.l) + (x.a - y.a) * (x.a - y.a) + (x.b - y.b) * (x.b - y.b)).squareRoot()
        }
        let selection = CommandBarInk.accentFill(theme: .arcDefault, dark: false)
        for dark in [false, true] {
            let card = CommandBarInk.surface(dark: dark)
            let accent = dark ? CommandBarInk.accentFill(theme: .arcDefault, dark: true) : selection
            let normal = distance(CommandBarInk.commandRowFill(accent: accent, dark: dark), card)
            let increased = distance(CommandBarInk.commandRowFill(accent: accent, dark: dark, increasedContrast: true), card)
            XCTAssertGreaterThan(normal, 0.02, "dark \(dark)")
            XCTAssertGreaterThan(increased, normal * 1.6, "dark \(dark)")
        }
        XCTAssertLessThan(CommandBarInk.commandTintFraction(dark: false), CommandBarInk.commandTintFraction(dark: false, increasedContrast: true))
        XCTAssertLessThan(CommandBarInk.commandTintFraction(dark: true), CommandBarInk.commandTintFraction(dark: true, increasedContrast: true))
    }
}
