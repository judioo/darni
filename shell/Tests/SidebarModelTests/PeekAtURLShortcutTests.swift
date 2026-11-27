import XCTest
@testable import SidebarModel

/// Darni's ⇧⌘P (Peek at URL…) in the shortcut table, and the copied link
/// that Peek mode offers (owner, 2026-11-27).
final class PeekAtURLShortcutTests: XCTestCase {
    // MARK: The binding

    func testShiftCommandPIsPeekAtURLWebsiteFirst() throws {
        let binding = try XCTUnwrap(ArcShortcuts.binding(for: .character("p"), modifiers: [.shift, .command]))
        XCTAssertEqual(binding.id, "peekAtURL")
        XCTAssertEqual(binding.title, "Peek at URL…")
        XCTAssertEqual(binding.display, "⇧⌘P")
        XCTAssertEqual(binding.priority, .websiteFirst)
        XCTAssertTrue(ArcShortcuts.reArcIDs.contains("peekAtURL"), "Darni's own: Arc has no key for Peek at URL")
        XCTAssertEqual(ArcShortcuts.binding(for: .character("p"), modifiers: .command)?.id, "printPage", "⌘P is still Print")
    }

    /// The clash check: no other default, shadowed or not, has ⇧⌘P; macOS
    /// keeps nothing there; it sits after Open Command Bar, as in the File menu.
    func testNothingElseHasShiftCommandP() throws {
        let sharing = ArcShortcuts.all.filter { $0.key == .character("p") && $0.modifiers == [.shift, .command] }
        XCTAssertEqual(sharing.map(\.id), ["peekAtURL"])
        XCTAssertFalse(ArcShortcuts.shadowed.contains { $0.id == "peekAtURL" })
        XCTAssertNil(SystemShortcuts.owner(of: ShortcutChord(.character("p"), [.shift, .command])))
        let ids = ArcShortcuts.all.map(\.id)
        let bar = try XCTUnwrap(ids.firstIndex(of: "addressBar"))
        XCTAssertEqual(ids[bar + 1], "peekAtURL")
        // Arc's Peek Email (⇧⌘E) and Open Little Arc or Peek in… (⌘O) keep their keys.
        XCTAssertEqual(ArcShortcuts.binding(for: .character("e"), modifiers: [.shift, .command])?.id, "peekEmail")
        XCTAssertEqual(ArcShortcuts.binding(for: .character("o"), modifiers: .command)?.id, "openTabIn")
    }

    func testSettingsListsItAndAMovedKeyFollows() throws {
        var overrides = ShortcutOverrides()
        let row = try XCTUnwrap(overrides.rows(matching: "Peek at URL").first)
        XCTAssertEqual(row.id, "peekAtURL")
        XCTAssertEqual(row.chipText, "⇧⌘P")
        XCTAssertEqual(row.conflicts, [])
        let chord = ShortcutChord(.character("k"), [.option, .command])
        overrides.set(chord, for: "peekAtURL")
        XCTAssertEqual(overrides.effectiveChord(forDefault: ShortcutChord(.character("p"), [.shift, .command])), chord)
        XCTAssertEqual(overrides.binding(for: chord.key, modifiers: chord.modifiers)?.priority, .websiteFirst)
    }

    // MARK: The copied link

    func testALinkIsOneWebAddressAndNothingElse() {
        func link(_ text: String?) -> String? { CommandBarCopiedLink.link(from: text)?.absoluteString }
        XCTAssertEqual(link("https://a.test/x?y=1#z"), "https://a.test/x?y=1#z")
        XCTAssertEqual(link("  http://a.test/  \n"), "http://a.test/", "the spaces and newline a copy brings are trimmed")
        XCTAssertEqual(link("example.org/a"), "https://example.org/a", "a bare address, as the bar takes it")
        XCTAssertEqual(link("http://localhost:8080/x"), "http://localhost:8080/x")
        XCTAssertNil(link(nil))
        XCTAssertNil(link(""))
        XCTAssertNil(link("red pandas"), "words are a search, not a copied link")
        XCTAssertNil(link("see https://a.test/x"))
        XCTAssertNil(link("https://a.test/x\nhttps://b.test/y"), "several lines")
        XCTAssertNil(link("someone@example.org"))
        XCTAssertNil(link("mailto:someone@example.org"))
        XCTAssertNil(link("javascript:alert(1)"))
        XCTAssertNil(link("file:///etc/hosts"))
        XCTAssertNil(link("ftp://a.test/x"))
        XCTAssertNil(link("readme"))
        XCTAssertNil(link(".hidden"))
        XCTAssertNil(link("https://" + String(repeating: "a", count: 9_000) + ".test/"), "too long to be a copied link")
    }

    func testTheRowCarriesTheLinkWhenItIsKnown() {
        let url = URL(string: "https://a.test/x")!
        let known = CommandBarCopiedLink.result(.link(url))
        XCTAssertEqual(known.id, CommandBarCopiedLink.rowID)
        XCTAssertEqual(known.kind, .openURL)
        XCTAssertEqual(known.title, "Peek Copied Link")
        XCTAssertEqual(known.subtitle, "https://a.test/x")
        XCTAssertEqual(known.destinationURL, url)
        let detected = CommandBarCopiedLink.result(.detected)
        XCTAssertNil(detected.subtitle)
        XCTAssertNil(detected.destinationURL)
        XCTAssertEqual(CommandBarCopiedLink.Offer.detected.url, nil)
    }

    // MARK: Command rows show their menu keys

    func testRegisteredCommandRowsTakeTheirMenuItemsKeys() throws {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let menu = [
            MenuCommand(id: "0/3:File › Peek at URL…", title: "Peek at URL…", path: "File › Peek at URL…", keyEquivalent: "⇧⌘P"),
            MenuCommand(id: "0/4:File › New Note", title: "New Note", path: "File › New Note", keyEquivalent: "⌃⇧N",
                        isEnabled: false),
        ]
        let catalog = [
            AppCommand(id: "peek-at-url", title: "Peek at URL…", action: .peekAtURL),
            AppCommand(id: "new-note", title: "New Note", action: .newNote),
            AppCommand(id: "new-easel", title: "New Easel", action: .newEasel),
        ]
        let results = CommandBarSearch.results(for: ">", in: store, commandCatalog: catalog, menuCommands: menu)
        XCTAssertEqual(results.first { $0.commandID == "peek-at-url" }?.keyEquivalent, "⇧⌘P")
        XCTAssertNil(results.first { $0.commandID == "new-note" }?.keyEquivalent, "a disabled menu item lends no keys")
        XCTAssertNil(results.first { $0.commandID == "new-easel" }?.keyEquivalent, "no menu item, no keys")
        XCTAssertEqual(results.filter { $0.title == "Peek at URL…" }.count, 1)
        let blended = CommandBarSearch.results(for: "peek at", in: store, commandCatalog: catalog, menuCommands: menu)
        XCTAssertEqual(blended.first { $0.commandID == "peek-at-url" }?.keyEquivalent, "⇧⌘P")
    }
}
