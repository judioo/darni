import AppKit
import SidebarModel

/// Peek at URL… (File menu, ⇧⌘P, and the command bar's command): the bar in
/// Peek mode. What is typed opens in a Peek; with nothing typed, a link on
/// the pasteboard is the first row, so ⇧⌘P then Return peeks a copied link.
extension BrowserViewModel {
    /// ⇧⌘P: opens the bar in Peek mode; pressed again while it shows, the bar
    /// closes, as ⌘L does.
    func peekAtURL() {
        if isCommandBarPresented, commandBarURLIntent == .peek {
            dismissCommandBar()
            return
        }
        openCommandBar(target: nil, text: "")
        beginPeekAtURL()
        commandBarFocusRequest += 1
    }

    /// The open bar turns to Peek mode (the shortcut, or the bar's own command).
    func beginPeekAtURL() {
        commandBarURLIntent = .peek
        commandBarText = ""
        commandBarHighlightedIndex = 0
        commandBarError = nil
        offerCopiedLink()
    }

    /// Looks for a link on `linkPasteboard`. A pasteboard the app may read
    /// freely is read now; the general one, which can ask the person, is only
    /// checked for a link (no alert), and read when the row is picked.
    func offerCopiedLink() {
        commandBarCopiedLink = nil
        let board = linkPasteboard
        guard !copiedLinkReadAsks(board) else {
            let changeCount = board.changeCount
            let detect = copiedLinkDetect
            Task { @MainActor [weak self] in
                guard await detect(board), let self, self.isCommandBarPresented, self.commandBarURLIntent == .peek,
                      self.commandBarCopiedLink == nil, board.changeCount == changeCount else { return }
                self.commandBarCopiedLink = .detected
            }
            return
        }
        commandBarCopiedLink = CommandBarCopiedLink.link(from: board.string(forType: .string), engine: engineHost.navigationSchemes)
            .map(CommandBarCopiedLink.Offer.link)
    }

    /// Return (or a click) on the copied link's row, with nothing typed: the
    /// link opens in a Peek. False when the bar is not there.
    func submitCopiedLinkPeek() -> Bool {
        guard commandBarText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let offer = commandBarCopiedLink else { return false }
        let url = offer.url ?? CommandBarCopiedLink.link(from: linkPasteboard.string(forType: .string),
                                                          engine: engineHost.navigationSchemes)
        guard let url else {
            // The pasteboard changed, or reading it was refused.
            commandBarCopiedLink = nil
            commandBarError = "The copied text is not a link"
            return true
        }
        showPeek(url: url)
        dismissCommandBar()
        return true
    }

    /// macOS 15.4 and later ask before an app reads another app's copy from
    /// the general pasteboard, unless the person always allows it.
    static func pasteboardReadAsks(_ board: NSPasteboard) -> Bool {
        guard #available(macOS 15.4, *) else { return false }
        switch board.accessBehavior {
        case .alwaysAllow: return false
        default: return true
        }
    }

    /// Whether the first pasteboard item is a probable web URL, read without
    /// the system's paste alert. Never when the person always denies reading.
    static func pasteboardHasLink(_ board: NSPasteboard) async -> Bool {
        guard #available(macOS 15.4, *), board.accessBehavior != .alwaysDeny else { return false }
        let found = try? await board.detectedPatterns(for: [\NSPasteboard.DetectedValues.probableWebURL])
        return found?.contains(\NSPasteboard.DetectedValues.probableWebURL) ?? false
    }
}
