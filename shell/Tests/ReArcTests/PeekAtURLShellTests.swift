import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Peek at URL… from the keyboard (owner, 2026-11-27): File › Peek at URL…
/// (⇧⌘P) opens the command bar in Peek mode; with nothing typed a copied
/// link is its first row, so ⇧⌘P then Return peeks it; the page menu's
/// "Open Link in Peek" peeks a link without the mouse's Shift-click.
final class PeekAtURLShellTests: XCTestCase {
    private func makeModel() -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-peek-url-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-peek-url-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-peek-url-links-\(UUID().uuidString)")!
        // A private pasteboard: the app may read it freely (no paste alert).
        model.linkPasteboard = NSPasteboard(name: NSPasteboard.Name("rearc-peek-url-\(UUID().uuidString)"))
        return model
    }

    private func copy(_ text: String, to model: BrowserViewModel) {
        model.linkPasteboard.clearContents()
        model.linkPasteboard.setString(text, forType: .string)
    }

    // MARK: Menu and key

    func testFileMenuHasPeekAtURLOnShiftCommandP() throws {
        let model = makeModel()
        let item = try XCTUnwrap(ShellMenus.peek(model).flatMap { $0 }.first)
        XCTAssertEqual(item.title, "Peek at URL…")
        XCTAssertEqual(item.arcShortcut?.id, "peekAtURL")
        XCTAssertEqual(item.arcShortcut?.display, "⇧⌘P")
        XCTAssertEqual(item.arcShortcut?.priority, .websiteFirst, "a page's own ⇧⌘P (a command palette) goes first")
        XCTAssertEqual(item.appKitKeyEquivalent.key, "P", "AppKit matches ⇧⌘P as \"P\" with ⌘")
        XCTAssertEqual(item.appKitKeyEquivalent.mask, .command)
        XCTAssertEqual(item.keyboardShortcut(with: ShortcutOverrides())?.key, KeyEquivalent("p"))

        // The item runs the action.
        item.action()
        XCTAssertTrue(model.isCommandBarPresented)
        XCTAssertEqual(model.commandBarURLIntent, .peek)
    }

    func testNoOtherDarniMenuItemTakesShiftCommandP() {
        let model = makeModel()
        let parts: [[[ShellMenuItem]]] = [
            ShellMenus.navigation(model), ShellMenus.reader(model), ShellMenus.find(model), ShellMenus.documents(model),
            ShellMenus.zoom(model), ShellMenus.tabNavigation(model), ShellMenus.split(model), ShellMenus.printing(model),
            ShellMenus.importing(model, chromiumImporter: true), ShellMenus.capture(model), ShellMenus.pictureInPicture(model),
            [ShellMenus.miniSidebar(model)], ShellMenus.downloads(model), ShellMenus.browserPages(model), ShellMenus.developer(model),
            ShellMenus.tabSwitcher(model), ShellMenus.tabPositions(model), ShellMenus.spaces(model), ShellMenus.copyLink(model),
            ShellMenus.sidebarItems(model), ShellMenus.littleArcs(model), ShellMenus.taskManager(model), ShellMenus.library(model),
            ShellMenus.finishSetup(model), ShellMenus.peek(model),
        ]
        let items: [ShellMenuItem] = parts.flatMap { $0 }.flatMap { $0 }
        let p = ShortcutKey.character("p")
        let shiftCommand: NSEvent.ModifierFlags = [.command, .shift]
        let onKey: [String] = items.filter { $0.shortcutKey == p && $0.modifiers == shiftCommand }.map(\.title)
        XCTAssertEqual(onKey, ["Peek at URL…"])
        // ⌘P stays Print.
        let print: [String] = items.filter { $0.shortcutKey == p && $0.modifiers == NSEvent.ModifierFlags.command }.map(\.title)
        XCTAssertEqual(print, ["Print…"])
    }

    /// While a page has focus the key goes to the page first; an unconsumed
    /// ⇧⌘P runs the menu item, a consumed one asks for a second press.
    func testShiftCommandPRoutesWebsiteFirst() throws {
        let router = ShortcutRouter()
        router.pageHasFocus = { _ in true }
        router.awaitsPageVerdicts = true
        var ran = 0
        var prompted: [String] = []
        router.performMenuKey = { _ in ran += 1; return true }
        router.onPrompt = { prompted.append($0.id) }
        let press = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                                                   windowNumber: 0, context: nil, characters: "P", charactersIgnoringModifiers: "P",
                                                   isARepeat: false, keyCode: 35))
        XCTAssertFalse(router.handleKeyDown(press), "the page sees it first")
        router.pageVerdict(keyCode: 35, modifiers: [.shift, .command], consumed: false)
        XCTAssertEqual(ran, 1, "the page did not take it: Peek at URL… runs")

        XCTAssertFalse(router.handleKeyDown(press))
        router.pageVerdict(keyCode: 35, modifiers: [.shift, .command], consumed: true)
        XCTAssertEqual(prompted, ["peekAtURL"])
        XCTAssertEqual(ShortcutRouting.promptMessage(for: try XCTUnwrap(ArcShortcuts.binding(id: "peekAtURL"))),
                       "Press ⇧⌘P again to Peek at URL…")
        XCTAssertTrue(router.handleKeyDown(press), "the second press within the prompt is the browser's")
        XCTAssertEqual(ran, 2)
    }

    // MARK: Peek mode

    func testShortcutOpensPeekModeAndAgainClosesIt() {
        let model = makeModel()
        let focus = model.commandBarFocusRequest
        model.peekAtURL()
        XCTAssertTrue(model.isCommandBarPresented)
        XCTAssertEqual(model.commandBarURLIntent, .peek)
        XCTAssertEqual(model.commandBarText, "")
        XCTAssertGreaterThan(model.commandBarFocusRequest, focus, "the field takes the keyboard")
        XCTAssertEqual(model.commandBarResults, [], "nothing copied, nothing typed: no rows")

        model.peekAtURL()
        XCTAssertFalse(model.isCommandBarPresented, "pressed again it closes, as ⌘L does")
        XCTAssertNil(model.commandBarURLIntent)
    }

    func testShortcutOverAnOpenBarTurnsItToPeekModeAndNewTabTurnsItBack() {
        let model = makeModel()
        let tab = model.store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test/")!)
        model.selectTab(tab.id)
        model.focusLocation()
        XCTAssertEqual(model.commandBarText, "https://a.test/")
        model.peekAtURL()
        XCTAssertTrue(model.isCommandBarPresented)
        XCTAssertEqual(model.commandBarURLIntent, .peek)
        XCTAssertEqual(model.commandBarText, "", "the address ⌘L filled in is gone")
        XCTAssertNil(model.commandBarTargetID, "a Peek never navigates the tab")

        model.newTab()
        XCTAssertNil(model.commandBarURLIntent, "⌘T over Peek mode is a plain new-tab bar")
        XCTAssertTrue(model.commandBarCreatesNewTab)
    }

    func testTypedAddressOpensInAPeek() {
        let model = makeModel()
        copy("https://copied.test/x", to: model)
        model.peekAtURL()
        model.commandBarText = "typed.test/page"
        XCTAssertFalse(model.commandBarResults.contains { $0.id == CommandBarCopiedLink.rowID }, "typing replaces the copied row")
        model.submitCommandBar()
        XCTAssertEqual(model.peekSession?.url.absoluteString, "https://typed.test/page")
        XCTAssertFalse(model.isCommandBarPresented)
    }

    func testPeekModeShowsItsOwnPlaceholder() {
        XCTAssertEqual(CommandBarOverlay.placeholder(text: "", siteSearch: nil, peek: true), "Peek: Search or Enter URL…")
        XCTAssertEqual(CommandBarOverlay.placeholder(text: "", siteSearch: nil), "Search or Enter URL…")
        XCTAssertTrue(AddressFieldCopy.placeholders.contains(CommandBarOverlay.peekPlaceholder),
                      "⌘C in Peek mode's field copies a clean link, as in the plain bar")
    }

    // MARK: The copied link

    func testCopiedLinkIsTheFirstRowAndReturnPeeksIt() throws {
        let model = makeModel()
        let tab = model.store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test/")!)
        model.selectTab(tab.id)
        copy("  https://copied.test/article?id=7  \n", to: model)
        model.peekAtURL()
        let row = try XCTUnwrap(model.commandBarResults.first)
        XCTAssertEqual(model.commandBarResults.count, 1)
        XCTAssertEqual(row.id, CommandBarCopiedLink.rowID)
        XCTAssertEqual(row.title, "Peek Copied Link")
        XCTAssertEqual(row.subtitle, "https://copied.test/article?id=7")
        XCTAssertEqual(model.commandBarHighlightedIndex, 0)

        model.submitCommandBar()
        XCTAssertEqual(model.peekSession?.url.absoluteString, "https://copied.test/article?id=7")
        XCTAssertFalse(model.isCommandBarPresented)
        XCTAssertNil(model.commandBarCopiedLink, "closing the bar forgets the offer")
        XCTAssertEqual(model.store.selectedTab?.url.absoluteString, "https://a.test/", "the tab under the Peek is unchanged")
        XCTAssertEqual(model.store.displayTabs().count, 1, "no tab was made")
    }

    func testTheBarsOwnPeekCommandAlsoOffersTheCopiedLink() {
        let model = makeModel()
        copy("example.org/a", to: model)
        model.newTab()
        model.commandBarText = ">peek"
        XCTAssertNil(model.executeCommand(.peekAtURL, commandID: "peek-at-url"))
        XCTAssertEqual(model.commandBarURLIntent, .peek)
        XCTAssertEqual(model.commandBarResults.first?.destinationURL?.absoluteString, "https://example.org/a")
        model.submitCommandBar()
        XCTAssertEqual(model.peekSession?.url.absoluteString, "https://example.org/a")
    }

    func testCopiedTextThatIsNotALinkOffersNothing() {
        let model = makeModel()
        copy("red pandas", to: model)
        model.peekAtURL()
        XCTAssertNil(model.commandBarCopiedLink)
        XCTAssertEqual(model.commandBarResults, [])
        model.submitCommandBar()
        XCTAssertNil(model.peekSession)
        XCTAssertEqual(model.commandBarError, "Enter a valid URL", "as before: Return on an empty Peek bar asks for an address")
        XCTAssertTrue(model.isCommandBarPresented)
    }

    /// The general pasteboard can ask the person before the app reads it
    /// (macOS 15.4+): the bar only learns that a link is there, offers the
    /// row without the address, and reads it when the row is picked.
    @MainActor
    func testAPasteboardThatAsksIsOnlyDetectedThenReadOnReturn() async throws {
        let model = makeModel()
        copy("https://asked.test/a", to: model)
        var reads = 0
        model.copiedLinkReadAsks = { _ in true }
        model.copiedLinkDetect = { _ in reads += 1; return true }
        model.peekAtURL()
        XCTAssertNil(model.commandBarCopiedLink, "nothing is read while the bar opens")
        for _ in 0..<50 where model.commandBarCopiedLink == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.commandBarCopiedLink, .detected)
        XCTAssertEqual(reads, 1)
        let row = try XCTUnwrap(model.commandBarResults.first)
        XCTAssertEqual(row.id, CommandBarCopiedLink.rowID)
        XCTAssertNil(row.subtitle, "the address is not known before the person picks the row")

        model.submitCommandBar()
        XCTAssertEqual(model.peekSession?.url.absoluteString, "https://asked.test/a")
    }

    @MainActor
    func testADetectedLinkThatIsGoneByReturnSaysSo() async throws {
        let model = makeModel()
        copy("https://asked.test/a", to: model)
        model.copiedLinkReadAsks = { _ in true }
        model.copiedLinkDetect = { _ in true }
        model.peekAtURL()
        for _ in 0..<50 where model.commandBarCopiedLink == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.commandBarCopiedLink, .detected)
        copy("no link here", to: model)  // or reading it was refused
        model.submitCommandBar()
        XCTAssertNil(model.peekSession)
        XCTAssertEqual(model.commandBarError, "The copied text is not a link")
        XCTAssertNil(model.commandBarCopiedLink)
        XCTAssertTrue(model.isCommandBarPresented)
    }

    @MainActor
    func testALateDetectionAfterTheBarClosedOffersNothing() async throws {
        let model = makeModel()
        model.copiedLinkReadAsks = { _ in true }
        var finish: CheckedContinuation<Void, Never>?
        model.copiedLinkDetect = { _ in
            await withCheckedContinuation { finish = $0 }
            return true
        }
        model.peekAtURL()
        for _ in 0..<50 where finish == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        model.dismissCommandBar()
        finish?.resume()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(model.commandBarCopiedLink)
    }

    func testThePasteboardReadRulesFollowTheSystemSetting() {
        // Named pasteboards are always readable; only the general one can ask.
        let named = NSPasteboard(name: NSPasteboard.Name("rearc-peek-url-rules-\(UUID().uuidString)"))
        XCTAssertFalse(BrowserViewModel.pasteboardReadAsks(named))
    }

    // MARK: Command bar row shows the keys

    func testThePeekCommandRowShowsItsMenuKeys() throws {
        let model = makeModel()
        let menu = [MenuCommand(id: "0/3:File › Peek at URL…", title: "Peek at URL…", path: "File › Peek at URL…", keyEquivalent: "⇧⌘P")]
        let results = CommandBarSearch.results(for: ">peek at", in: model.store, menuCommands: menu)
        let row = try XCTUnwrap(results.first { $0.commandID == "peek-at-url" })
        XCTAssertEqual(row.keyEquivalent, "⇧⌘P")
        XCTAssertFalse(results.contains { $0.menuCommandID != nil && $0.title == "Peek at URL…" }, "one row, not the menu's twin")
    }

    // MARK: Open Link in Peek (page menu)

    func testOpenLinkInPeekPeeksFromTheTabsPage() throws {
        let model = makeModel()
        let tab = model.store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test/")!)
        model.selectTab(tab.id)
        let prompts = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab)).pagePrompts
        let options = prompts.contextMenuOptions(canGoBack: false, canGoForward: false, canViewSource: false, canInspect: false)
        XCTAssertTrue(options.canOpenPeek)
        let plan = PageContextMenuPlan.plan(for: PageContextMenuParams(linkURL: "https://b.test/x", pageURL: "https://a.test/"), options: options)
        XCTAssertTrue(plan.items.contains(.openLinkInPeek))

        XCTAssertTrue(prompts.performShellItem(.openLinkInPeek, params: PageContextMenuParams(linkURL: "https://b.test/x")))
        let session = try XCTUnwrap(model.peekSession)
        XCTAssertEqual(session.url.absoluteString, "https://b.test/x")
        XCTAssertEqual(session.sourceTabID, tab.id)
        XCTAssertEqual(session.profileID, model.profileID(for: tab))
        XCTAssertEqual(model.store.selectedTabID, tab.id)
        XCTAssertEqual(model.store.displayTabs().count, 1, "no tab was made")

        // Even with the engine opening links (ABI 1.58), the Peek is the shell's.
        prompts.engineOpensLinks = true
        XCTAssertTrue(prompts.performShellItem(.openLinkInPeek, params: PageContextMenuParams(linkURL: "https://b.test/y")))
        XCTAssertEqual(model.peekSession?.url.absoluteString, "https://b.test/y")
        XCTAssertNil(ChromiumContextCommand(.openLinkInPeek), "no engine command: the shell opens the Peek")
    }

    func testNoPeekItemOutsideASidebarTabsPage() {
        let model = makeModel()
        let little = model.littleArcEngine(for: model.openLittleArc(url: URL(string: "https://b.test/")!).id)
        XCTAssertFalse(little.pagePrompts.contextMenuOptions(canGoBack: false, canGoForward: false, canViewSource: false,
                                                             canInspect: false).canOpenPeek)
        let privateWindow = model.openPrivateWindow(url: nil)
        XCTAssertFalse(privateWindow.engine.pagePrompts.contextMenuOptions(canGoBack: false, canGoForward: false, canViewSource: false,
                                                                           canInspect: false).canOpenPeek)
        // A private page's link never peeks in a sidebar profile: it opens in its own session.
        let before = model.peekSession
        model.openLinkInPeek(URL(string: "https://b.test/secret")!, from: privateWindow.engine.pagePrompts)
        XCTAssertEqual(model.peekSession?.url, before?.url)
    }
}
