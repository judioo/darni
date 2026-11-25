import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

private final class ChoosingMenus: PageContextMenuPresenting {
    var choice: PageContextMenuItem?

    func present(_ plan: PageContextMenuPlan, at point: CGPoint, in view: NSView?, completion: @escaping (PageContextMenuItem?) -> Void) {
        completion(choice)
    }
}

/// A router that leaves Copy Link Address to the protocol's default.
private final class PlainRouter: PageLinkRouting {
    var navigationSchemes: NavigationURLPolicy.EngineSchemes = .chromium
    func openLinkInNewTab(_ url: URL, from prompts: PagePromptCenter) {}
    func openLinkInNewWindow(_ url: URL, from prompts: PagePromptCenter) {}
    func openBrowserWindow(from prompts: PagePromptCenter) {}
    func openLinkInLittleArc(_ url: URL, from prompts: PagePromptCenter) {}
    func openLinkInNewSplit(_ url: URL, from prompts: PagePromptCenter) {}
    func openLinkInPrivateWindow(_ url: URL, from prompts: PagePromptCenter) {}
    func searchWeb(for text: String, from prompts: PagePromptCenter) {}
    func imageSearchProvider(for prompts: PagePromptCenter) -> SearchProvider? { nil }
    func revealPage(of prompts: PagePromptCenter) {}
    func openSiteSettings(origin: String, from prompts: PagePromptCenter) {}
}

/// Copy clean links: every way the shell copies a link gives it without
/// trackers, on the model's pasteboard, and each obeys Settings › Advanced
/// "Copy links without trackers".
final class CleanLinkCopyTests: XCTestCase {
    private let tracked = URL(string: "https://shop.test/item/9?utm_source=news&size=m&fbclid=abc#reviews")!
    private let clean = "https://shop.test/item/9?size=m#reviews"
    private let cleanToast = "Copied a clean link without trackers"

    private func makeModel() -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-clean-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-clean-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-clean-links-\(UUID().uuidString)")!
        model.linkPasteboard = NSPasteboard(name: NSPasteboard.Name("rearc-clean-\(UUID().uuidString)"))
        model.copiesCleanLinks = true
        return model
    }

    private func copied(_ model: BrowserViewModel) -> String? { model.linkPasteboard.string(forType: .string) }

    private func commandC(_ flags: NSEvent.ModifierFlags = .command, characters: String = "c", keyCode: UInt16 = 8) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    /// A window that is never shown, with a field that has the keyboard and `text` in it.
    private func makeField(placeholder: String, text: String) throws -> (NSWindow, NSTextView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 380, height: 24))
        field.placeholderString = placeholder
        field.stringValue = text
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the field's editor has the keyboard")
        editor.selectAll(nil)
        return (window, editor)
    }

    // MARK: The paths that already cleaned (through the one helper now)

    func testCopyURLItsFormatsAndTheSidebarsCopyLink() {
        let model = makeModel()
        let tab = model.store.addTab(kind: .today, title: "Item", url: tracked)
        let other = model.store.addTab(kind: .today, title: "Other", url: URL(string: "https://other.test/?gclid=1")!)
        model.store.selectTab(tab.id)
        model.copyURL()
        XCTAssertEqual(copied(model), clean)
        XCTAssertEqual(model.toast?.message, cleanToast)
        model.copyURL(format: .markdown)
        XCTAssertEqual(copied(model), "[Item](\(clean))")
        // The sidebar row's and a split pane toolbar's Copy Link name their tab.
        model.copyURL(of: other.id)
        XCTAssertEqual(copied(model), "https://other.test/")
        XCTAssertEqual(model.lastCopiedLinkText, "https://other.test/")
    }

    func testASelectionsLinks() {
        let model = makeModel()
        let a = model.store.addTab(kind: .today, title: "A", url: tracked)
        let b = model.store.addTab(kind: .today, title: "B", url: URL(string: "https://b.test/?id=2")!)
        model.copyLinks(of: [a.id, b.id])
        XCTAssertEqual(copied(model), "\(clean)\nhttps://b.test/?id=2")
        XCTAssertEqual(model.toast?.message, PageLinkCopyFormat.multipleConfirmation(cleaned: true))
    }

    // MARK: The paths that copied the link as it was

    func testASplitsCopyLinksAndItsPanesCopyLink() throws {
        let model = makeModel()
        let left = model.store.addTab(kind: .today, title: "Left", url: tracked)
        let right = model.store.addTab(kind: .today, title: "Right", url: URL(string: "https://r.test/a?msclkid=9")!)
        let split = try XCTUnwrap(model.store.splitTab(right.id, with: left.id))
        model.copySplitLinks(split.id, markdown: false)
        XCTAssertEqual(Set(try XCTUnwrap(copied(model)).components(separatedBy: "\n")), [clean, "https://r.test/a"])
        XCTAssertEqual(model.toast?.message, PageLinkCopyFormat.multipleConfirmation(cleaned: true))
        model.copySplitLinks(split.id, markdown: true)
        XCTAssertEqual(Set(try XCTUnwrap(copied(model)).components(separatedBy: "\n")), ["[Left](\(clean))", "[Right](https://r.test/a)"])
        // The pane's own Copy Link (row menu and pane toolbar).
        model.copyURL(of: right.id)
        XCTAssertEqual(copied(model), "https://r.test/a")

        model.linkPasteboard.clearContents()
        model.copySplitLinks(UUID(), markdown: false)
        XCTAssertNil(copied(model), "no such split: nothing is copied")
    }

    func testTheArchivesCopyLink() throws {
        let model = makeModel()
        let tab = model.openInNewTab(tracked)
        model.archiveTab(tab.id)
        let record = try XCTUnwrap(model.store.archivedTabs.first { $0.tab.id == tab.id })
        // What ArchiveView's Copy Link runs.
        model.copyLink(record.tab.url)
        XCTAssertEqual(copied(model), clean)
        XCTAssertEqual(model.toast?.message, cleanToast)
    }

    func testCopyLinkSaysSoOnlyWhenItRemovedSomething() {
        let model = makeModel()
        model.copyLink(URL(string: "https://a.test/p?id=4#top")!)
        XCTAssertEqual(copied(model), "https://a.test/p?id=4#top", "a link with no trackers is copied as it is")
        XCTAssertNil(model.toast, "and nothing is said, as before")
        model.copyLink(tracked)
        XCTAssertEqual(model.toast?.message, cleanToast)
        XCTAssertEqual(model.toast?.action, .share(URL(string: clean)!), "the toast shares the clean link")
    }

    func testAPeeksCopyLink() {
        let model = makeModel()
        model.peekCopyLink()
        XCTAssertNil(copied(model), "no Peek: nothing is copied")
        model.peekSession = BrowserViewModel.PeekSession(url: tracked, title: "Item", engineID: UUID(), profileID: model.store.activeProfileID)
        model.peekCopyLink()
        XCTAssertEqual(copied(model), clean)
        XCTAssertEqual(model.toast?.message, cleanToast)
    }

    /// The owner's report (2026-11-25): with a Peek open, ⇧⌘C copied the tab under
    /// it. The copy commands take the page in front: the Peek's.
    func testTheCopyCommandsTakeThePeeksPageNotTheTabUnderIt() {
        let model = makeModel()
        let window = SidebarWindowID()
        model.store.registerWindow(window)
        model.windowBecameKey(window)
        let tab = model.store.addTab(kind: .today, title: "Compare", url: URL(string: "https://darni.test/compare")!)
        model.store.selectTab(tab.id)
        model.peekSession = BrowserViewModel.PeekSession(url: tracked, title: "Item", engineID: UUID(),
                                                         profileID: model.store.activeProfileID, windowID: window)
        model.copyURL(format: .plain)
        XCTAssertEqual(copied(model), clean, "the Peek's page, cleaned")
        model.copyURL(format: .markdown)
        XCTAssertEqual(copied(model), "[Item](\(clean))")

        // The Peek closed: the tab's own link again.
        model.peekSession = nil
        model.copyURL(format: .plain)
        XCTAssertEqual(copied(model), "https://darni.test/compare")
        // A Peek shown in another window does not take the key window's copy.
        let other = SidebarWindowID()
        model.store.registerWindow(other)
        model.peekSession = BrowserViewModel.PeekSession(url: tracked, title: "Item", engineID: UUID(),
                                                         profileID: model.store.activeProfileID, windowID: other)
        model.copyURL(format: .plain)
        XCTAssertEqual(copied(model), "https://darni.test/compare")
    }

    /// A Peek that followed a link copies where it is now, not where it opened.
    @MainActor func testAPeekThatFollowedALinkCopiesWhereItIsNow() async throws {
        let server = try WebKitFixtureServer()
        server.route("/first", .page(title: "First"))
        server.route("/second", .page(title: "Second"))
        let model = makeModel()
        let window = SidebarWindowID()
        model.store.registerWindow(window)
        model.windowBecameKey(window)
        let profile = model.store.activeProfileID
        let (id, engine) = model.engineHost.ephemeralEngine(profileID: profile)
        model.peekSession = BrowserViewModel.PeekSession(url: server.url("/first"), title: "First", engineID: id,
                                                         profileID: profile, windowID: window)
        let followed = URL(string: server.url("/second").absoluteString + "?utm_source=peek&page=2")!
        engine.load(followed)
        let deadline = Date().addingTimeInterval(10)
        while engine.currentURL?.path != "/second" && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(engine.currentURL?.path, "/second", "the Peek's page followed the link")
        let expected = server.url("/second").absoluteString + "?page=2"
        model.peekCopyLink()
        XCTAssertEqual(copied(model), expected)
        model.linkPasteboard.clearContents()
        model.copyURL(format: .plain)
        XCTAssertEqual(copied(model), expected)
        server.stop()
    }

    /// Peek › Copy Link's toast is drawn on the Peek's card, not on the
    /// window's card under the Peek (where it was dimmed and mostly hidden).
    func testAPeeksCopyLinkToastsOnThePeekNotUnderIt() {
        let model = makeModel()
        let first = SidebarWindowID(), second = SidebarWindowID()
        model.store.registerWindow(first)
        model.store.registerWindow(second)
        model.windowBecameKey(first)
        model.peekSession = BrowserViewModel.PeekSession(url: tracked, title: "Item", engineID: UUID(),
                                                         profileID: model.store.activeProfileID, windowID: first)
        XCTAssertTrue(model.showsPeek(in: first))
        model.peekCopyLink()
        XCTAssertEqual(copied(model), clean)
        XCTAssertNil(model.cardToast(in: first), "nothing under the Peek")
        let shown = try? XCTUnwrap(model.peekToast(in: first))
        XCTAssertEqual(shown?.message, cleanToast)
        XCTAssertEqual(shown?.id, model.toast?.id)
        XCTAssertEqual(shown?.placement, .belowToolbar, "centred under the Peek's address line")
        XCTAssertEqual(shown?.action, .share(URL(string: clean)!))
        XCTAssertNil(model.peekToast(in: second))
        XCTAssertNil(model.cardToast(in: second), "another window draws no toast while not key")

        // The Peek closed: the window's toast is on its card again, where it was.
        model.peekSession = nil
        XCTAssertNil(model.peekToast(in: first))
        XCTAssertEqual(model.cardToast(in: first)?.id, model.toast?.id)
        XCTAssertEqual(model.cardToast(in: first)?.placement, .corner)
    }

    func testTheCommandBarRowsCopyURL() {
        let model = makeModel()
        let row = CommandBarSearch.Result(id: "h1", kind: .history, title: "Item", destinationURL: tracked)
        XCTAssertTrue(CommandBarSearch.rowActions(for: row).contains(.copyURL))
        model.performCommandBarRowAction(.copyURL, on: row)
        XCTAssertEqual(copied(model), clean)
        XCTAssertEqual(model.toast?.message, cleanToast)
    }

    func testALittleDarnisCopyLinkToastsInItsOwnWindow() {
        let model = makeModel()
        let record = model.openLittleArc(url: tracked)
        // What the Little Darni toolbar's Copy Link runs.
        model.copyLink(tracked, littleArc: record.id)
        XCTAssertEqual(copied(model), clean)
        XCTAssertEqual(model.littleArcToast?.windowID, record.id)
        XCTAssertEqual(model.littleArcToast?.toast.message, cleanToast)
        XCTAssertNil(model.toast, "not on the browser window behind it")
    }

    // MARK: The page menu's Copy Link Address

    func testCopyLinkAddressIsTheShellsWhenTheLinkHasTrackers() {
        let model = makeModel()
        let prompts = PagePromptCenter()
        prompts.router = model
        let menus = ChoosingMenus()
        prompts.contextMenus = menus
        let trackedLink = PageContextMenuParams(linkURL: tracked.absoluteString, pageURL: "https://a.test/")
        let plan = PageContextMenuPlan.plan(for: trackedLink, options: prompts.contextMenuOptions(
            canGoBack: false, canGoForward: false, canViewSource: false, canInspect: false))
        XCTAssertTrue(plan.items.contains(.copyLink))

        var forEngine: [PageContextMenuItem?] = []
        menus.choice = .copyLink
        prompts.showContextMenu(plan, params: trackedLink, at: .zero) { forEngine.append($0) }
        XCTAssertEqual(copied(model), clean)
        XCTAssertEqual(forEngine, [nil], "the engine only dismisses its menu: it must not copy the link with its trackers afterwards")
        XCTAssertEqual(model.toast?.message, cleanToast)

        // No trackers: the engine copies, as it always did, and the shell writes nothing.
        model.linkPasteboard.clearContents()
        let plainLink = PageContextMenuParams(linkURL: "https://a.test/p?id=4", pageURL: "https://a.test/")
        prompts.showContextMenu(plan, params: plainLink, at: .zero) { forEngine.append($0) }
        XCTAssertEqual(forEngine.last, .copyLink)
        XCTAssertNil(copied(model))
        for other in ["mailto:someone@a.test?utm_source=x", "javascript:void(0)", ""] {
            XCTAssertFalse(prompts.performShellItem(.copyLink, params: PageContextMenuParams(linkURL: other)), other)
        }
        XCTAssertNil(copied(model))
    }

    func testCopyLinkAddressToastsWhereThePageIs() {
        let model = makeModel()
        let prompts = PagePromptCenter()
        prompts.router = model
        let params = PageContextMenuParams(linkURL: tracked.absoluteString)

        prompts.role = .privateWindow
        XCTAssertTrue(prompts.performShellItem(.copyLink, params: params))
        XCTAssertEqual(copied(model), clean)
        XCTAssertNil(model.toast, "a private window has no toast; the browser window's would show behind it")

        let record = model.openLittleArc(url: URL(string: "https://little.test/")!)
        model.keyLittleArcID = record.id
        prompts.role = .littleArc
        XCTAssertTrue(prompts.performShellItem(.copyLink, params: params))
        XCTAssertEqual(model.littleArcToast?.toast.message, cleanToast)
        XCTAssertNil(model.toast)

        prompts.role = .peek
        XCTAssertTrue(prompts.performShellItem(.copyLink, params: params))
        XCTAssertEqual(model.toast?.message, cleanToast)
    }

    func testCopyLinkAddressStaysTheEnginesWithoutABrowserModel() {
        let prompts = PagePromptCenter()
        let params = PageContextMenuParams(linkURL: tracked.absoluteString)
        XCTAssertFalse(prompts.performShellItem(.copyLink, params: params), "no router")
        let router = PlainRouter()
        prompts.router = router
        XCTAssertFalse(prompts.performShellItem(.copyLink, params: params), "a router that copies nothing")
    }

    // MARK: ⌘C in an address field

    func testCommandCOnAWholeAddressCopiesTheCleanLink() throws {
        let model = makeModel()
        let barPlaceholder = CommandBarOverlay.placeholder(text: tracked.absoluteString, siteSearch: nil)
        for placeholder in [barPlaceholder, AddressFieldCopy.littleArcPlaceholder, AddressFieldCopy.privateWindowPlaceholder] {
            let (window, editor) = try makeField(placeholder: placeholder, text: tracked.absoluteString)
            XCTAssertEqual(AddressFieldCopy.cleanLink(for: commandC(), firstResponder: editor), clean, placeholder)
            model.linkPasteboard.clearContents()
            XCTAssertTrue(model.handleAddressFieldCopy(commandC(), in: window), placeholder)
            XCTAssertEqual(copied(model), clean, placeholder)
            XCTAssertEqual(model.toast?.message, cleanToast)
            XCTAssertEqual(editor.string, tracked.absoluteString, "the field keeps its text")
        }
    }

    func testCommandCStaysTheFieldsOwnOtherwise() throws {
        let model = makeModel()
        let bar = CommandBarOverlay.placeholder(text: "", siteSearch: nil)
        let (window, editor) = try makeField(placeholder: bar, text: tracked.absoluteString)
        func takes(_ event: NSEvent) -> Bool { model.handleAddressFieldCopy(event, in: window) }

        // Part of the address: what is selected is what is copied.
        editor.setSelectedRange(NSRange(location: 8, length: 9))
        XCTAssertFalse(takes(commandC()))
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length - 1))
        XCTAssertFalse(takes(commandC()))
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(takes(commandC()), "nothing selected")

        // Other keys on the whole address.
        editor.selectAll(nil)
        XCTAssertFalse(takes(commandC([.command, .shift])), "⇧⌘C is Copy URL's")
        XCTAssertFalse(takes(commandC([.command, .option])))
        XCTAssertFalse(takes(commandC(.command, characters: "x", keyCode: 7)), "Cut stays the field's")
        XCTAssertFalse(takes(commandC(.command, characters: "v", keyCode: 9)))
        XCTAssertFalse(takes(commandC([], characters: "c")), "a typed c")
        XCTAssertTrue(takes(commandC([.command, .capsLock])), "Caps Lock changes nothing")
        XCTAssertEqual(copied(model), clean)
        model.linkPasteboard.clearContents()

        // Text that is no link with trackers.
        for text in ["https://a.test/p?id=4", "darni clean links utm_source=x", "shop.test/item/9?utm_source=news", ">copy url"] {
            editor.string = text
            editor.selectAll(nil)
            XCTAssertFalse(takes(commandC()), text)
        }
        XCTAssertNil(copied(model), "none of them wrote to the pasteboard")

        // Any other field of the shell, whatever it holds (a search engine's address with its own "ref").
        for placeholder in ["Name", "Type a command…", "Search ChatGPT…", ""] {
            let (other, _) = try makeField(placeholder: placeholder, text: tracked.absoluteString)
            XCTAssertFalse(model.handleAddressFieldCopy(commandC(), in: other), placeholder)
        }
        let (plain, _) = try makeField(placeholder: bar, text: tracked.absoluteString)
        XCTAssertTrue(plain.makeFirstResponder(nil))
        XCTAssertFalse(model.handleAddressFieldCopy(commandC(), in: plain), "the field no longer has the keyboard")
        XCTAssertFalse(model.handleAddressFieldCopy(commandC()), "no window")
    }

    // MARK: The setting

    func testEveryPathCopiesTheLinkAsItIsWhenTheSettingIsOff() throws {
        let model = makeModel()
        model.copiesCleanLinks = false
        XCTAssertFalse(CleanLinksPreference.isEnabled(in: model.externalLinkDefaults), "the switch is remembered")
        let raw = tracked.absoluteString

        let tab = model.store.addTab(kind: .today, title: "Item", url: tracked)
        let right = model.store.addTab(kind: .today, title: "Right", url: tracked)
        model.store.selectTab(tab.id)
        model.copyURL()
        XCTAssertEqual(copied(model), raw)
        XCTAssertEqual(model.toast?.message, "Copied Current URL")
        model.copyURL(format: .markdown)
        XCTAssertEqual(copied(model), "[Item](\(raw))")
        model.copyLinks(of: [tab.id])
        XCTAssertEqual(copied(model), raw)
        let split = try XCTUnwrap(model.store.splitTab(right.id, with: tab.id))
        model.copySplitLinks(split.id, markdown: false)
        XCTAssertEqual(copied(model), "\(raw)\n\(raw)")
        model.copyLink(tracked)
        XCTAssertEqual(copied(model), raw)
        model.peekSession = BrowserViewModel.PeekSession(url: tracked, title: "Item", engineID: UUID(), profileID: model.store.activeProfileID)
        model.peekCopyLink()
        XCTAssertEqual(copied(model), raw)
        model.performCommandBarRowAction(.copyURL, on: CommandBarSearch.Result(id: "h1", kind: .history, title: "Item", destinationURL: tracked))
        XCTAssertEqual(copied(model), raw)

        // The page menu's link is the engine's again, and ⌘C the field's.
        model.linkPasteboard.clearContents()
        let prompts = PagePromptCenter()
        prompts.router = model
        XCTAssertFalse(prompts.performShellItem(.copyLink, params: PageContextMenuParams(linkURL: raw)))
        let (window, _) = try makeField(placeholder: AddressFieldCopy.littleArcPlaceholder, text: raw)
        XCTAssertFalse(model.handleAddressFieldCopy(commandC(), in: window))
        XCTAssertNil(copied(model))

        model.copiesCleanLinks = true
        XCTAssertTrue(CleanLinksPreference.isEnabled(in: model.externalLinkDefaults))
        model.copyURL(of: tab.id)
        XCTAssertEqual(copied(model), clean)
    }
}
