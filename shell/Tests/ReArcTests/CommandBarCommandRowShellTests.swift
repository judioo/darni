import AppKit
import SwiftUI
import XCTest
@testable import ReArc
import SidebarModel

/// Command rows in the shell (owner, 2026-11-27): their keys follow
/// Settings › Shortcuts while the bar is open, Set Shortcut… opens the pane
/// on that binding, the bindings agree with the menus that run them, and the
/// rows draw a low light of the space's colour, quieter than the selection.
@MainActor
final class CommandBarCommandRowShellTests: XCTestCase {
    private func makeModel() -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-command-rows-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-command-rows-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-command-rows-links-\(UUID().uuidString)")!
        model.shortcutOverrides = ShortcutOverrides()
        return model
    }

    // MARK: Keys follow Settings › Shortcuts

    func testTheRowsKeysFollowSettingsWhileTheBarIsOpen() throws {
        let model = makeModel()
        model.commandBarText = ">peek at"
        func peek() -> CommandBarSearch.Result? { model.commandBarResults.first { $0.commandID == "peek-at-url" } }
        XCTAssertEqual(peek()?.shortcutHint, .keys("⇧⌘P"))
        model.shortcutOverrides.unbind("peekAtURL")
        XCTAssertEqual(peek()?.shortcutHint, .none(settable: true), "the cached rows were rebuilt")
        model.shortcutOverrides.set(ShortcutChord(.character("k"), [.option, .command]), for: "peekAtURL")
        XCTAssertEqual(peek()?.shortcutHint, .keys("⌥⌘K"))
        model.shortcutOverrides.reset("peekAtURL")
        XCTAssertEqual(peek()?.shortcutHint, .keys("⇧⌘P"))
    }

    // MARK: Set Shortcut…

    func testSetShortcutOpensShortcutsSettingsListingThatBinding() throws {
        let model = makeModel()
        var presented: [SettingsPane?] = []
        model.presentSettings = { presented.append($0) }
        model.commandBarText = ">peek at"
        let row = try XCTUnwrap(model.commandBarResults.first { $0.commandID == "peek-at-url" })
        XCTAssertEqual(CommandBarSearch.rowActions(for: row), [.setShortcut])
        model.performCommandBarRowAction(.setShortcut, on: row)
        XCTAssertEqual(presented, [.shortcuts])
        XCTAssertEqual(model.settingsPane, .shortcuts)
        let query = try XCTUnwrap(model.shortcutsPaneQuery)
        XCTAssertEqual(query, "Peek at URL…")
        XCTAssertEqual(model.shortcutOverrides.rows(matching: query).map(\.id), ["peekAtURL"], "the pane lists that one row")
        XCTAssertEqual(model.commandBarText, "", "the bar closed")
    }

    func testSetShortcutDoesNothingWithoutABinding() {
        let model = makeModel()
        var presented: [SettingsPane?] = []
        model.presentSettings = { presented.append($0) }
        let row = CommandBarSearch.Result(id: "cmd-x", kind: .command, title: "Appearance: Dark", subtitle: "Command")
        XCTAssertEqual(CommandBarSearch.rowActions(for: row), [])
        model.performCommandBarRowAction(.setShortcut, on: row)
        XCTAssertEqual(presented, [])
        XCTAssertNil(model.shortcutsPaneQuery)
    }

    func testCopyURLStillNeedsAnAddress() {
        let model = makeModel()
        model.linkPasteboard = NSPasteboard(name: NSPasteboard.Name("rearc-command-rows-\(UUID().uuidString)"))
        model.performCommandBarRowAction(.copyURL, on: CommandBarSearch.Result(id: "s", kind: .search, title: "peek"))
        XCTAssertNil(model.linkPasteboard.string(forType: .string))
    }

    // MARK: The bindings agree with the menus

    /// Each command's binding is the one its menu item's keys stand for, so
    /// the row never shows keys that run something else. The rest are
    /// ReArcApp's own buttons (⌘T, ⌘W, ⇧⌘T, ⌘S, ⌥⌘N), checked by their
    /// default keys in CommandBarCommandRowTests.
    func testEachMappedBindingIsTheOneItsMenuItemRuns() throws {
        let model = makeModel()
        let groups = ShellMenus.navigation(model) + ShellMenus.find(model) + ShellMenus.peek(model) + ShellMenus.documents(model)
            + ShellMenus.tabNavigation(model) + ShellMenus.split(model) + ShellMenus.printing(model) + ShellMenus.capture(model)
            + [ShellMenus.miniSidebar(model)] + ShellMenus.downloads(model) + ShellMenus.browserPages(model)
            + ShellMenus.spaces(model) + ShellMenus.copyLink(model) + ShellMenus.sidebarItems(model) + ShellMenus.library(model)
        let items = groups.flatMap { $0 }.filter { !$0.isAlternate }
        let menuTitles: [String: String] = [
            "peek-at-url": "Peek at URL…", "go-back": "Back", "go-forward": "Forward", "reload-page": "Reload Page",
            "reload-ignoring-cache": "Reload Ignoring Cache", "stop-loading": "Stop Loading", "find-in-page": "Find…",
            "new-note": "New Note", "new-easel": "New Easel", "next-tab": "Next Tab", "previous-tab": "Previous Tab",
            "split-right": "Add Split View", "print-page": "Print…", "capture-area": "Capture",
            "toggle-mini-sidebar": "Show Mini Sidebar", "show-downloads": "Show Downloads", "browser-history": "History",
            "next-space": "Next Space", "previous-space": "Previous Space", "copy-url": "Copy URL",
            "copy-url-markdown": "Copy URL as Markdown", "copy-quote": "Copy URL as Quote", "pin-tab": "Pin/Unpin Tab",
            "unpin-tab": "Pin/Unpin Tab", "clear-unpinned-tabs": "Clear Unpinned Tabs", "open-library": "View Library",
        ]
        let appButtons: Set<String> = ["new-tab", "close-tab", "reopen-closed-tab", "toggle-sidebar", "open-little-arc"]
        XCTAssertEqual(Set(menuTitles.keys).union(appButtons), Set(CommandBarShortcuts.bindingIDs.keys), "every mapping is checked")
        for (command, title) in menuTitles {
            let item = try XCTUnwrap(items.first { $0.title == title }, title)
            XCTAssertEqual(item.arcShortcut?.id, CommandBarShortcuts.bindingIDs[command], "\(command) → \(title)")
        }
        // ⌃1…⌃9 are the Spaces menu's first nine spaces, as Switch to … rows say.
        let space = try XCTUnwrap(items.first { $0.title == "Space 1" })
        XCTAssertEqual(space.arcShortcut?.id, "goToSpace1")
    }

    // MARK: The low light, drawn

    func testCommandRowsDrawALowLightQuieterThanTheSelection() throws {
        for dark in [false, true] {
            let chrome = ThemeChromeColors(theme: .arcDefault, dark: dark)
            let results: [CommandBarSearch.Result] = [
                .init(id: "search", kind: .search, title: "peek", subtitle: "www.google.com"),
                .init(id: "cmd", kind: .command, title: "Appearance: Dark", subtitle: "Command"),
                .init(id: "suggest", kind: .suggestion, title: "peekaboo", subtitle: "www.google.com"),
                .init(id: "cmd2", kind: .command, title: "Peek at URL…", subtitle: "Command", keyEquivalent: "⇧⌘P",
                      shortcutID: "peekAtURL"),
            ]
            let bar = CommandBarOverlay(text: .constant("peek"), results: results, highlightedIndex: 0, onMoveHighlight: { _ in },
                                        onSelectResult: { _ in }, onSubmit: {}, onCancel: {})
                .environment(\.themeChrome, chrome)
            let height = CommandBarOverlay.fieldHeight + 1 + CommandBarOverlay.listHeight(rows: results.count)
            let rep = try render(bar, size: NSSize(width: CommandBarOverlay.arcWidth, height: height), dark: dark)
            // Inside each row, left of its icon, at its middle.
            func sample(_ row: Int) throws -> [CGFloat] {
                let y = CommandBarOverlay.fieldHeight + 1 + CommandBarOverlay.listTopPadding
                    + CGFloat(row) * (CommandBarOverlay.rowHeight + CommandBarOverlay.rowSpacing) + CommandBarOverlay.rowHeight / 2
                let scale = CGFloat(rep.pixelsWide) / rep.size.width
                let color = try XCTUnwrap(rep.colorAt(x: Int((CommandBarOverlay.rowInset + 5) * scale), y: Int(y * scale)))
                return [color.redComponent, color.greenComponent, color.blueComponent]
            }
            func distance(_ a: [CGFloat], _ b: [CGFloat]) -> CGFloat { zip(a, b).map { abs($0 - $1) }.max() ?? 0 }
            let selected = try sample(0), command = try sample(1), suggestion = try sample(2), keyed = try sample(3)
            let card = CommandBarInk.surface(dark: dark)
            XCTAssertLessThan(distance(suggestion, [card.red, card.green, card.blue].map { CGFloat($0) }), 0.02,
                              "a suggestion sits on the bare card (dark \(dark))")
            XCTAssertGreaterThan(distance(command, suggestion), 0.02, "a command row is tinted (dark \(dark))")
            XCTAssertLessThan(distance(command, keyed), 0.01, "every command row the same (dark \(dark))")
            XCTAssertGreaterThan(distance(selected, suggestion), distance(command, suggestion) * 2,
                                 "the selection is the strongest (dark \(dark))")
            XCTAssertGreaterThan(command[2], command[0], "the default space's blue (dark \(dark))")
        }
    }

    func testTheRowStyleFollowsIncreaseContrast() {
        let accent = ThemeChromeColors(theme: .arcDefault, dark: false).commandBarFill
        let normal = CommandRowStyle.inks(accent: accent, dark: false, increasedContrast: false)
        let increased = CommandRowStyle.inks(accent: accent, dark: false, increasedContrast: true)
        XCTAssertNil(normal.edge)
        XCTAssertNotNil(increased.edge)
        XCTAssertNotEqual(normal.fill, increased.fill)
        XCTAssertEqual(normal.fill, CommandBarInk.commandRowFill(accent: accent, dark: false))
    }

    func testTheTooltipSaysTheShortcutOrThatThereIsNone() {
        let bound = CommandBarSearch.Result(id: "a", kind: .command, title: "Peek at URL…", keyEquivalent: "⇧⌘P", shortcutID: "peekAtURL")
        let unbound = CommandBarSearch.Result(id: "b", kind: .command, title: "Peek at URL…", shortcutID: "peekAtURL")
        let none = CommandBarSearch.Result(id: "c", kind: .command, title: "Appearance: Dark")
        let search = CommandBarSearch.Result(id: "d", kind: .search, title: "peek")
        XCTAssertEqual(CommandBarResultRow.help(for: bound, instantLinks: false), "Shortcut: ⇧⌘P")
        XCTAssertEqual(CommandBarResultRow.help(for: unbound, instantLinks: false), "No shortcut. Set one in Settings › Shortcuts.")
        XCTAssertEqual(CommandBarResultRow.help(for: none, instantLinks: false), "No shortcut")
        XCTAssertEqual(CommandBarResultRow.help(for: search, instantLinks: false),
                       CommandBarResultRow.modifierHelp(for: .search, instantLinks: false))
    }

    // MARK: Offscreen rendering (never on screen)

    private func render<V: View>(_ view: V, size: NSSize, dark: Bool) throws -> NSBitmapImageRep {
        let window = OffscreenWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.close() }
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(size)
        for _ in 0 ..< 2 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
}
