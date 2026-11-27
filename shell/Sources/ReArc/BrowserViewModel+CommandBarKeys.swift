import AppKit
import SidebarModel

/// The command bar owns its keys while it is open (`CommandBarKeys`): Tab
/// enters a site search, takes the inline completion or moves into the Tab
/// Groups chips, and never moves focus out of the bar or reaches the page.
/// In the chips the arrows, Return and Esc are the chips'. The field keeps
/// the keyboard all along, so typing still goes into it.
///
/// The app's key monitor asks here before the field sees the key
/// (`installTabSwitcherMonitor`): AppKit would otherwise give Tab to the next
/// key view. Every other key reaches the field as before, and with the
/// field focused none of them can reach the page or the sidebar. ⌘ shortcuts
/// keep their menu items: ⌘A, ⌘C, ⌘V, ⌘X and ⌘Z edit the field, the others
/// (⌘T, ⌘L, ⌘W, ⌘1…9 and the rest) act as they do without the bar.
extension BrowserViewModel {

    /// What the key rules read: what Tab would take, and the chips on show.
    var commandBarKeyState: CommandBarKeys.State {
        let rows = commandBarTabGroups
        return CommandBarKeys.State(
            offersSiteSearch: commandBarSiteSearchSuggestion != nil,
            hasInlineCompletion: !(commandBarInlineSuffix ?? "").isEmpty,
            fieldIsEmpty: commandBarText.isEmpty,
            chips: rows.isEmpty ? nil : commandBarTabGroupLayout,
            highlightedChip: commandBarTabGroupHighlight.flatMap { id in rows.firstIndex { $0.id == id } }
        )
    }

    /// Does what `key` means in the bar now. False: the key is the field's
    /// and the list's, as it was before the bar had chips.
    @discardableResult
    func performCommandBarKey(_ key: CommandBarKeys.Key) -> Bool {
        guard isCommandBarPresented else { return false }
        switch CommandBarKeys.action(for: key, in: commandBarKeyState) {
        case .enterSiteSearch:
            enterCommandBarSiteSearch()
        case .acceptCompletion:
            acceptCommandBarInlineCompletion()
        case .highlightChip(let index):
            let rows = commandBarTabGroups
            commandBarTabGroupHighlight = rows.indices.contains(index) ? rows[index].id : nil
        case .leaveChips:
            commandBarTabGroupHighlight = nil
        case .addHighlightedGroup:
            if let id = commandBarTabGroupHighlight { addTabGroupToActiveSpace(id) }
        case .consume:
            break
        case .passToBar:
            return false
        }
        return true
    }

    /// The key monitor's turn: true when the key was the bar's and goes no
    /// further. Tab is taken whatever it does, with ⇧, ⌃ or ⌥ too (⌃Tab's
    /// switcher is off while the bar is open, and AppKit would move focus on
    /// it). The arrows, Return and Esc are taken only while the keyboard is in
    /// the chips. Any other key costs nothing here: typing is not slowed.
    func handleCommandBarKey(_ event: NSEvent) -> Bool {
        guard isCommandBarPresented, event.type == .keyDown else { return false }
        let isTab = Self.isCommandBarTab(event)
        let key = Self.commandBarKey(for: event)
        guard isTab || (key != nil && commandBarTabGroupHighlight != nil), commandBarOwnsKeys(in: event.window) else { return false }
        // An input method that is composing keeps its keys: Tab and the arrows pick a candidate.
        if (event.window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
        guard let key else { return isTab }
        let completes = key == .tab && CommandBarKeys.action(for: key, in: commandBarKeyState) == .acceptCompletion
        let taken = performCommandBarKey(key)
        if completes { placeCommandBarCaretAtEnd(in: event.window) }
        return taken || isTab
    }

    /// Tab, alone or with ⇧, ⌃ or ⌥. ⌘Tab is the system's.
    static func isCommandBarTab(_ event: NSEvent) -> Bool {
        event.keyCode == 48 && !event.modifierFlags.contains(.command)
    }

    /// The bar's key for an event, or nil when the event is not one of them
    /// (⌃Tab and ⌥Tab among them: kept by the bar, and they do nothing).
    static func commandBarKey(for event: NSEvent) -> CommandBarKeys.Key? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.keyCode {
        case 48:
            guard flags.isSubset(of: .shift) else { return nil }
            return flags.contains(.shift) ? .backTab : .tab
        // Return and the keypad's Enter, with any of its routing modifiers.
        case 36, 76: return .return
        case 53: return flags.isEmpty ? .escape : nil
        case 123: return flags.isEmpty ? .left : nil
        case 124: return flags.isEmpty ? .right : nil
        case 125: return flags.isEmpty ? .down : nil
        case 126: return flags.isEmpty ? .up : nil
        default: return nil
        }
    }

    /// Whether a key pressed in `window` is the open bar's: the window shows
    /// the bar, and no other text field in it has the keyboard (a sheet, a
    /// panel and a popover are other windows).
    func commandBarOwnsKeys(in window: NSWindow?) -> Bool {
        guard isCommandBarPresented, tabGroupEditor == nil, let window,
              !(window is NSPanel), window.attachedSheet == nil,
              let field = CommandBarOverlay.field(
                  in: window, placeholder: CommandBarOverlay.placeholder(text: commandBarText, siteSearch: commandBarSiteSearch,
                                                                         peek: commandBarURLIntent == .peek)
              ) else { return false }
        guard let editor = window.firstResponder as? NSTextView else { return true }
        return editor.delegate === field
    }

    /// After Tab took the completion: the caret goes to the end of the new
    /// text, as after Right Arrow. The field takes the text on a later turn
    /// of the main queue, so this waits for it, a bounded number of turns.
    private func placeCommandBarCaretAtEnd(in window: NSWindow?, attempts: Int = 5) {
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, self.isCommandBarPresented, let editor = window?.firstResponder as? NSTextView else { return }
            guard editor.string == self.commandBarText else {
                if attempts > 1 { self.placeCommandBarCaretAtEnd(in: window, attempts: attempts - 1) }
                return
            }
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
    }
}
