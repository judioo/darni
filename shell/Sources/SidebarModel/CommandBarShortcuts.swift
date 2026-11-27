import Foundation

/// What a command row shows at its right (owner, 2026-11-27): the keys that
/// run the command now, or a quiet "No shortcut".
public enum CommandBarShortcutHint: Equatable, Sendable {
    case keys(String)
    /// `settable`: Settings › Shortcuts lists the command's binding, so the
    /// person can give it keys there (the row offers Set Shortcut…).
    case none(settable: Bool)

    public static let noShortcut = "No shortcut"

    public var text: String {
        switch self {
        case .keys(let keys): return keys
        case .none: return Self.noShortcut
        }
    }

    /// The row's tooltip.
    public var help: String {
        switch self {
        case .keys(let keys): return "Shortcut: \(keys)"
        case .none(settable: true): return "No shortcut. Set one in Settings › Shortcuts."
        case .none(settable: false): return "No shortcut"
        }
    }

    /// What VoiceOver reads after the title.
    public var accessibilityText: String {
        switch self {
        case .keys(let keys): return "Shortcut \(keys)"
        case .none: return Self.noShortcut
        }
    }
}

extension CommandBarSearch.Result {
    /// A command row's hint; nil for search, page and tab rows.
    public var shortcutHint: CommandBarShortcutHint? {
        guard kind == .command else { return nil }
        if let keys = keyEquivalent, !keys.isEmpty { return .keys(keys) }
        return .none(settable: shortcutID != nil)
    }
}

/// Which Settings › Shortcuts binding (`ArcShortcuts` id) runs each
/// command-bar command, so its row shows the keys as set now, a rebound key
/// included, and says so when there are none. Only commands whose binding
/// does the same thing as the command are listed (checked against the
/// menus in ShellMenus and ReArcApp); the rest keep the keys of a menu item
/// with the same title, if any (`MenuCommandSearch.Index.registeredKeys`).
public enum CommandBarShortcuts {
    public static let bindingIDs: [String: String] = [
        "new-tab": "newTab",
        // ⌘W runs the Tabs menu's Close Tab (Archive Tab in Today).
        "close-tab": "archiveTab",
        "reopen-closed-tab": "reopenLastClosedTab",
        "pin-tab": "pinTab",
        "unpin-tab": "pinTab",
        "toggle-sidebar": "showSidebar",
        "toggle-mini-sidebar": "toggleMiniSidebar",
        // Add Split View is side by side (`addSplitView(orientation: .horizontal)`).
        "split-right": "addSplitView",
        "next-tab": "selectNextTab",
        "previous-tab": "selectPreviousTab",
        "peek-at-url": "peekAtURL",
        "open-little-arc": "showLittleArc",
        "print-page": "printPage",
        "new-easel": "newEasel",
        "new-note": "newNote",
        // Arc's Capture (⇧⌘2): drag a region or click an element.
        "capture-area": "capturePage",
        "open-library": "viewLibrary",
        "find-in-page": "find",
        "show-downloads": "viewDownloads",
        "browser-history": "viewHistory",
        "go-back": "goBack",
        "go-forward": "goForward",
        "reload-page": "reloadPage",
        "reload-ignoring-cache": "forceReloadPage",
        "stop-loading": "stopLoading",
        "copy-url": "copyCurrentURL",
        "copy-url-markdown": "copyCurrentURLMarkdown",
        "copy-quote": "copyCurrentURLAsQuote",
        "next-space": "focusNextSpace",
        "previous-space": "focusPreviousSpace",
        "clear-unpinned-tabs": "clearExplore",
    ]

    /// The binding that runs `command`: the table's, or for Switch to a
    /// space, ⌃1…⌃9 by the space's place in the active profile (the Spaces
    /// menu's order). `spaceIndex` maps a space to that place.
    public static func bindingID(for command: AppCommand, spaceIndex: (Space.ID) -> Int?) -> String? {
        if let id = bindingIDs[command.id] { return id }
        if case .switchToSpace(let spaceID) = command.action, let index = spaceIndex(spaceID), index < 9 {
            return "goToSpace\(index + 1)"
        }
        return nil
    }

    /// The keys `command`'s row shows: its binding's chord as set now (none
    /// when unbound), else a same-titled menu item's keys (`menuKeys`, by
    /// normalized title).
    public static func keys(for bindingID: String?, title: String, overrides: ShortcutOverrides,
                            menuKeys: [String: String]) -> String? {
        if let bindingID { return overrides.chord(for: bindingID)?.display }
        let keys = menuKeys[MenuCommandSearch.normalized(title)]
        return keys?.isEmpty == false ? keys : nil
    }
}
