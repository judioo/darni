import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// The command bar owns its keys (`BrowserViewModel+CommandBarKeys`): Tab
/// takes the completion or moves into the Tab Groups chips and never leaves
/// the bar, and in the chips the arrows, Return and Esc are the chips'. The
/// window tests host the bar in a borderless window far off screen, never
/// ordered in, as `CommandBarHighlightReturnTests` does.
@MainActor
final class CommandBarKeysShellTests: XCTestCase {
    private func url(_ host: String) -> URL { URL(string: "https://\(host)/")! }

    /// Home (active) and Work in one profile, tab groups on, no network.
    private func makeModel() -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Home", sortRank: "a")])
        store.addSpace(name: "Work")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-barkeys-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.externalLinkDefaults = UserDefaults(suiteName: "CommandBarKeysShellTests.\(UUID().uuidString)")!
        let services = WebKitCommandBarServices(defaults: UserDefaults(suiteName: "rearc-barkeys-\(UUID())")!)
        services.preference.suggestionsEnabled = false
        model.commandBarServices = services
        model.commandBarCollapseHold = 0
        model.tabGroupsEnabled = true
        return model
    }

    /// `names` as groups of the Work space, which the Home space can add.
    @discardableResult
    private func addGroups(_ names: [String], to model: BrowserViewModel) -> [TabGroup.ID] {
        let work = model.store.spaces.first { $0.name == "Work" }!.id
        return names.map { name in
            let row = model.store.createTabGroup(name: name, in: work)!
            _ = model.store.addTab(toGroup: row.groupID, title: name, url: url("\(row.groupID.uuidString).test"))
            return row.groupID
        }
    }

    private func visitPostHog(_ model: BrowserViewModel) {
        for _ in 0 ..< 3 {
            model.visitHistory.recordVisit(url: url("posthog.com"), title: "PostHog", at: Date().addingTimeInterval(-3600),
                                           profileID: model.store.activeProfileID)
        }
    }

    // MARK: Tab

    func testTabTakesTheInlineCompletion() {
        let model = makeModel()
        visitPostHog(model)
        model.newTab()
        model.commandBarText = "post"
        XCTAssertEqual(model.commandBarInlineSuffix, "hog.com")
        XCTAssertNil(model.commandBarSiteSearchSuggestion)

        XCTAssertTrue(model.performCommandBarKey(.tab))
        XCTAssertEqual(model.commandBarText, "posthog.com")
        XCTAssertTrue(model.isCommandBarPresented)

        // Nothing left to take: Tab is still the bar's, and changes nothing.
        XCTAssertTrue(model.performCommandBarKey(.tab))
        XCTAssertTrue(model.performCommandBarKey(.backTab))
        XCTAssertEqual(model.commandBarText, "posthog.com")
    }

    func testTabStillEntersAnOfferedSiteSearch() throws {
        let model = makeModel()
        let cwc = ChromiumKeywordsReader.Row(name: "cushwake", keyword: "cwc", template: "https://www.cushmanwakefield.ae/search?q={searchTerms}")
        XCTAssertEqual(model.importSiteSearches([cwc], from: "arc/Default", into: model.store.activeProfileID), 1)
        model.newTab()
        model.commandBarText = "cwc"
        XCTAssertNotNil(model.commandBarSiteSearchSuggestion)
        XCTAssertTrue(model.performCommandBarKey(.tab))
        XCTAssertEqual(model.commandBarSiteSearch?.name, "cushwake")
        XCTAssertEqual(model.commandBarText, "")
    }

    func testTabIsNotTheBarsWhileItIsClosed() {
        let model = makeModel()
        XCTAssertFalse(model.performCommandBarKey(.tab))
        XCTAssertFalse(model.commandBarOwnsKeys(in: nil))
    }

    // MARK: The chips

    func testTabMovesIntoTheChipsAndTheArrowsReturnAndEscAreTheirs() throws {
        let model = makeModel()
        let groups = addGroups(["Alpha", "Beta", "Gamma"], to: model)
        model.newTab()
        XCTAssertEqual(model.commandBarTabGroups.map(\.id), groups, "by name")
        XCTAssertNil(model.commandBarTabGroupHighlight)
        XCTAssertFalse(model.performCommandBarKey(.right), "outside the chips the arrows are the field's")
        XCTAssertFalse(model.performCommandBarKey(.return))

        XCTAssertTrue(model.performCommandBarKey(.tab))
        XCTAssertEqual(model.commandBarTabGroupHighlight, groups[0])
        XCTAssertTrue(model.performCommandBarKey(.right))
        XCTAssertEqual(model.commandBarTabGroupHighlight, groups[1])
        XCTAssertTrue(model.performCommandBarKey(.tab))
        XCTAssertEqual(model.commandBarTabGroupHighlight, groups[2])
        XCTAssertTrue(model.performCommandBarKey(.left))
        XCTAssertTrue(model.performCommandBarKey(.backTab))
        XCTAssertEqual(model.commandBarTabGroupHighlight, groups[0])

        // Esc goes back to the field and the bar stays open.
        XCTAssertTrue(model.performCommandBarKey(.escape))
        XCTAssertNil(model.commandBarTabGroupHighlight)
        XCTAssertTrue(model.isCommandBarPresented)
        XCTAssertFalse(model.performCommandBarKey(.escape), "the next Esc is the bar's own: it closes")

        // Return adds the highlighted group to the space on screen.
        XCTAssertTrue(model.performCommandBarKey(.tab))
        XCTAssertTrue(model.performCommandBarKey(.right))
        XCTAssertTrue(model.performCommandBarKey(.return))
        XCTAssertFalse(model.isCommandBarPresented)
        XCTAssertEqual(SidebarTree.tabGroups(model.store.content(for: model.store.activeSpaceID).today).map(\.groupID), [groups[1]])
        XCTAssertNil(model.commandBarTabGroupHighlight)
    }

    func testTypingLeavesTheChips() {
        let model = makeModel()
        addGroups(["Alpha", "Beta"], to: model)
        model.newTab()
        XCTAssertTrue(model.performCommandBarKey(.tab))
        XCTAssertNotNil(model.commandBarTabGroupHighlight)
        model.commandBarText = "a"
        XCTAssertNil(model.commandBarTabGroupHighlight, "the chips fold away and the key went into the field")
        XCTAssertTrue(model.commandBarTabGroups.isEmpty)
        model.commandBarText = ""
        XCTAssertNil(model.commandBarTabGroupHighlight)
    }

    func testTheLastLinesDownArrowAndTheFirstLinesUpArrowLeaveTheChips() {
        let model = makeModel()
        addGroups((1 ... 12).map { "Monitoring \($0)" }, to: model)
        model.newTab()
        model.commandBarWidth = 420
        let layout = model.commandBarTabGroupLayout
        XCTAssertGreaterThan(layout.lineCount, 1)
        XCTAssertTrue(model.performCommandBarKey(.tab))
        XCTAssertTrue(model.performCommandBarKey(.up))
        XCTAssertNil(model.commandBarTabGroupHighlight)
        XCTAssertTrue(model.performCommandBarKey(.tab))
        XCTAssertTrue(model.performCommandBarKey(.down))
        XCTAssertEqual(model.commandBarTabGroupHighlight, model.commandBarTabGroups[layout.lines[1][0]].id)
    }

    // MARK: The layout on screen

    func testTwentyGroupsFitInThreeLinesOfTheBarAndALongNameIsCut() {
        let model = makeModel()
        addGroups((1 ... 20).map { "Group \($0)" }, to: model)
        model.newTab()
        let rows = model.commandBarTabGroups
        XCTAssertEqual(rows.count, 20)
        let layout = CommandBarTabGroupsMetrics.layout(rows: rows, barWidth: CommandBarOverlay.arcWidth)
        XCTAssertLessThanOrEqual(layout.lineCount, 3, "twenty short names across the 765 pt bar")
        XCTAssertFalse(layout.scrolls)
        XCTAssertEqual(model.commandBarTabGroupsRoom, CommandBarTabGroupsMetrics.height(layout))

        let long = TabGroupCommandBarRow(id: UUID(), name: String(repeating: "Very long group name ", count: 6), color: .blue, tabCount: 3)
        let cut = CommandBarTabGroupsMetrics.layout(rows: [long], barWidth: CommandBarOverlay.arcWidth)
        XCTAssertEqual(cut.chips[0].width, cut.metrics.maxChipWidth)
        XCTAssertGreaterThan(Double(CommandBarTabGroupsMetrics.naturalWidth(of: long)), cut.metrics.maxChipWidth)

        // A named group shows its count beside the name; an unnamed one is named by it.
        XCTAssertEqual(TabGroupCommandBarRow(id: UUID(), name: "Work", color: .red, tabCount: 3).chipCount, "3")
        XCTAssertNil(TabGroupCommandBarRow(id: UUID(), name: "3 Tabs", color: .red, tabCount: 3).chipCount)
    }

    func testTheSectionTakesNoRoomWithoutGroupsAndStopsGrowingAtThreeLines() {
        let none = CommandBarTabGroupsMetrics.layout(rows: [], barWidth: 765)
        XCTAssertEqual(CommandBarTabGroupsMetrics.height(none), 0)
        func rows(_ count: Int) -> [TabGroupCommandBarRow] {
            (0 ..< count).map { TabGroupCommandBarRow(id: UUID(), name: "Group number \($0)", color: .green, tabCount: 2) }
        }
        let one = CommandBarTabGroupsMetrics.height(CommandBarTabGroupsMetrics.layout(rows: rows(1), barWidth: 765))
        let many = CommandBarTabGroupsMetrics.layout(rows: rows(60), barWidth: 765)
        XCTAssertGreaterThan(one, 0)
        XCTAssertTrue(many.scrolls)
        XCTAssertEqual(CommandBarTabGroupsMetrics.height(many),
                       one + CGFloat(2 * (many.metrics.chipHeight + many.metrics.lineSpacing)), "three lines, then it scrolls inside")
    }

    // MARK: In a window

    private func spin(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    /// The bar in an offscreen window, its field holding the keyboard.
    private func hostBar(_ model: BrowserViewModel) throws -> (NSWindow, NSTextField, NSTextView) {
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: CommandBarContainer(model: model, width: CommandBarOverlay.arcWidth)
            .environment(\.themeChrome, ThemeChromeColors(theme: .arcDefault, dark: false)))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        spin()
        let field = try XCTUnwrap(CommandBarOverlay.field(in: window, placeholder: "Search or Enter URL…"))
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        return (window, field, editor)
    }

    func testTabInTheFieldCompletesWithTheCaretAtTheEndAndFocusStaysInTheBar() throws {
        let model = makeModel()
        visitPostHog(model)
        model.newTab()
        let (window, field, editor) = try hostBar(model)
        defer { window.close() }
        editor.insertText("post", replacementRange: NSRange(location: NSNotFound, length: 0))
        spin()
        XCTAssertEqual(model.commandBarText, "post")
        XCTAssertEqual(model.commandBarInlineSuffix, "hog.com")
        XCTAssertTrue(model.commandBarOwnsKeys(in: window))

        // The app's key monitor asks the model before the field sees the key.
        XCTAssertTrue(model.handleCommandBarKey(try key(48, "\t", in: window)), "Tab goes no further")
        spin()
        XCTAssertEqual(model.commandBarText, "posthog.com")
        XCTAssertEqual(field.stringValue, "posthog.com")
        XCTAssertTrue(field.currentEditor() === window.firstResponder, "focus is still in the bar's field")
        let now = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertEqual(now.selectedRange(), NSRange(location: 11, length: 0), "the caret is at the end")

        // Tab again, ⇧Tab, ⌃Tab and ⌥Tab: nothing to do, and still the bar's.
        XCTAssertTrue(model.handleCommandBarKey(try key(48, "\t", in: window)))
        XCTAssertTrue(model.handleCommandBarKey(try key(48, "\u{19}", .shift, in: window)))
        XCTAssertTrue(model.handleCommandBarKey(try key(48, "\t", .control, in: window)))
        XCTAssertTrue(model.handleCommandBarKey(try key(48, "\t", .option, in: window)))
        XCTAssertFalse(model.handleCommandBarKey(try key(48, "\t", .command, in: window)), "⌘Tab is the system's")
        spin()
        XCTAssertEqual(model.commandBarText, "posthog.com")
        XCTAssertTrue(field.currentEditor() === window.firstResponder)

        // An input method composing in the field keeps Tab for its candidates.
        let composing = try XCTUnwrap(field.currentEditor() as? NSTextView)
        composing.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(composing.hasMarkedText())
        XCTAssertFalse(model.handleCommandBarKey(try key(48, "\t", in: window)))
        composing.unmarkText()

        // Keys that are not the bar's to take go on to the field: letters, the arrows, Return, Esc.
        XCTAssertFalse(model.handleCommandBarKey(try key(0, "a", in: window)))
        XCTAssertFalse(model.handleCommandBarKey(try key(124, String(UnicodeScalar(NSRightArrowFunctionKey)!), in: window)))
        XCTAssertFalse(model.handleCommandBarKey(try key(36, "\r", in: window)))
        XCTAssertFalse(model.handleCommandBarKey(try key(53, "\u{1b}", in: window)))
    }

    func testTabThroughTheFieldItselfAlsoStaysInTheBar() throws {
        // Without the key monitor (it is installed by the browser window): the field's own handler keeps Tab.
        let model = makeModel()
        visitPostHog(model)
        model.newTab()
        let (window, field, editor) = try hostBar(model)
        defer { window.close() }
        editor.insertText("post", replacementRange: NSRange(location: NSNotFound, length: 0))
        spin()
        window.sendEvent(try key(48, "\t", in: window))
        spin()
        XCTAssertEqual(model.commandBarText, "posthog.com")
        XCTAssertTrue(field.currentEditor() != nil && field.currentEditor() === window.firstResponder, "focus did not move on")
        window.sendEvent(try key(48, "\t", in: window))
        window.sendEvent(try key(48, "\u{19}", .shift, in: window))
        spin()
        XCTAssertTrue(field.currentEditor() != nil && field.currentEditor() === window.firstResponder)
    }

    func testInTheChipsTheMonitorTakesTheArrowsReturnAndEsc() throws {
        let model = makeModel()
        let groups = addGroups(["Alpha", "Beta"], to: model)
        model.newTab()
        let (window, field, _) = try hostBar(model)
        defer { window.close() }

        XCTAssertTrue(model.handleCommandBarKey(try key(48, "\t", in: window)))
        XCTAssertEqual(model.commandBarTabGroupHighlight, groups[0])
        XCTAssertTrue(model.handleCommandBarKey(try key(124, String(UnicodeScalar(NSRightArrowFunctionKey)!), in: window)))
        XCTAssertEqual(model.commandBarTabGroupHighlight, groups[1])
        XCTAssertFalse(model.handleCommandBarKey(try key(0, "a", in: window)), "a letter still goes into the field")
        XCTAssertTrue(model.handleCommandBarKey(try key(53, "\u{1b}", in: window)))
        XCTAssertNil(model.commandBarTabGroupHighlight)
        XCTAssertTrue(model.isCommandBarPresented, "Esc left the chips, not the bar")
        XCTAssertTrue(field.currentEditor() === window.firstResponder)

        XCTAssertTrue(model.handleCommandBarKey(try key(48, "\t", in: window)))
        XCTAssertTrue(model.handleCommandBarKey(try key(36, "\r", in: window)))
        XCTAssertFalse(model.isCommandBarPresented)
        XCTAssertEqual(SidebarTree.tabGroups(model.store.content(for: model.store.activeSpaceID).today).map(\.groupID), [groups[0]])
    }

    func testAnotherFieldOrAnotherWindowKeepsItsOwnTab() throws {
        let model = makeModel()
        model.newTab()
        let (window, _, _) = try hostBar(model)
        defer { window.close() }
        XCTAssertTrue(model.commandBarOwnsKeys(in: window))

        // A window that does not show the bar (Settings, say).
        let other = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 300, height: 200),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        let plain = NSTextField(string: "")
        other.contentView = plain
        other.makeFirstResponder(plain)
        XCTAssertFalse(model.commandBarOwnsKeys(in: other))
        XCTAssertFalse(model.handleCommandBarKey(try key(48, "\t", in: other)), "its Tab moves between its own fields")

        // Another text field with the keyboard in the bar's window (a row being renamed).
        let rename = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        window.contentView?.addSubview(rename)
        window.makeFirstResponder(rename)
        XCTAssertFalse(model.commandBarOwnsKeys(in: window))

        // A group's editor is open: its popover has the keyboard.
        window.makeFirstResponder(nil)
        XCTAssertTrue(model.commandBarOwnsKeys(in: window), "nothing else types: the bar's")
        model.tabGroupEditor = TabGroupEditorRequest(anchorID: UUID(), groupID: UUID())
        XCTAssertFalse(model.commandBarOwnsKeys(in: window))
    }
}
