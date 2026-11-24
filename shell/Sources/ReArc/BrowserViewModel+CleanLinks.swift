import AppKit
import SidebarModel

/// Copy clean links: every link the shell copies goes through here, so each
/// one loses its tracking parameters (`LinkCleaner`) while Settings ›
/// Advanced "Copy links without trackers" is on, and all of them land on the
/// same pasteboard. Copy URL and its formats, a selection's or a split's
/// links, the archive's, a Peek's, a Little Darni's and a command bar row's
/// Copy Link, the page menu's Copy Link Address and ⌘C on a whole address.
///
/// Not links people pass on, and left as they are: a download's link and an
/// image's address (a signed address stops working without a parameter).
extension BrowserViewModel {

    /// The link as it is copied, and whether it lost trackers.
    func linkForCopying(_ url: URL) -> (url: URL, removedTrackers: Bool) {
        copiesCleanLinks ? LinkCleaner.clean(url) : (url, false)
    }

    /// The clean text for a link that has trackers; nil when it is copied as it is.
    func cleanLinkText(_ link: String) -> String? {
        copiesCleanLinks ? LinkCleaner.cleanedText(link) : nil
    }

    /// Puts copied links on the pasteboard (the self-test reads the text back).
    func writeCopiedLinks(_ text: String) {
        linkPasteboard.clearContents()
        linkPasteboard.setString(text, forType: .string)
        lastCopiedLinkText = text
    }

    /// Copy Link on something that is not the page in front (an archived tab,
    /// a Peek, a command bar row, a Little Darni window): the link alone. It
    /// says so when trackers were removed, in the Little Darni window when it is one's.
    func copyLink(_ url: URL, littleArc: LittleArcWindow.ID? = nil) {
        let (link, cleaned) = linkForCopying(url)
        writeCopiedLinks(link.absoluteString)
        if cleaned { showCleanLinkToast(sharing: link, littleArc: littleArc) }
    }

    private func showCleanLinkToast(sharing url: URL?, littleArc: LittleArcWindow.ID? = nil) {
        if let littleArc {
            showLittleArcToast(PageLinkCopyFormat.cleanConfirmation, systemImage: "checkmark.shield.fill", in: littleArc)
        } else {
            showToast(PageLinkCopyFormat.cleanConfirmation, systemImage: "checkmark.shield.fill", action: url.map { .share($0) })
        }
    }

    // MARK: - The page menu's Copy Link Address

    /// A link with trackers is the shell's to copy, clean; any other stays
    /// the engine's (false), copied as it always was.
    func copyLinkAddress(_ link: String, from prompts: PagePromptCenter) -> Bool {
        guard let clean = cleanLinkText(link) else { return false }
        writeCopiedLinks(clean)
        switch prompts.role {
        case .tab, .peek: showCleanLinkToast(sharing: URL(string: clean))
        case .littleArc: if let id = keyLittleArcID { showCleanLinkToast(sharing: nil, littleArc: id) }
        // A private window has no toast of its own; the browser window's would show behind it.
        case .privateWindow: break
        }
        return true
    }

    // MARK: - ⌘C in an address field

    /// ⌘C with the whole address selected in one of the shell's address
    /// fields copies the clean link. Part of the text, text that is no link
    /// and a link with no trackers stay the field's own copy (false).
    /// `window` is the event's own unless a test names one.
    func handleAddressFieldCopy(_ event: NSEvent, in window: NSWindow? = nil) -> Bool {
        guard copiesCleanLinks,
              let clean = AddressFieldCopy.cleanLink(for: event, firstResponder: (window ?? event.window)?.firstResponder)
        else { return false }
        writeCopiedLinks(clean)
        let littleArc = keyLittleArcID
        if littleArc != nil || keyPrivateWindow == nil { showCleanLinkToast(sharing: URL(string: clean), littleArc: littleArc) }
        return true
    }
}

/// The shell's address fields and what ⌘C copies from them. A field is told
/// by its placeholder, as the command bar's is (`CommandBarOverlay.field`).
enum AddressFieldCopy {
    static let littleArcPlaceholder = "Search or enter URL"
    static let privateWindowPlaceholder = "Search or enter address"

    static var placeholders: Set<String> {
        [CommandBarOverlay.placeholder(text: "", siteSearch: nil), littleArcPlaceholder, privateWindowPlaceholder]
    }

    /// The clean link for this key: ⌘C alone, in an address field whose text
    /// is selected from end to end and is one link with trackers. Nil leaves
    /// the key to the field.
    static func cleanLink(for event: NSEvent, firstResponder: NSResponder?) -> String? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              // The character the menu's ⌘C matches (a layout that types Latin only with ⌘ held gives it here).
              event.characters?.lowercased() == "c",
              let editor = firstResponder as? NSTextView, editor.isFieldEditor, !editor.hasMarkedText(),
              let field = editor.delegate as? NSTextField, isAddressField(field) else { return nil }
        let text = editor.string
        let selection = editor.selectedRange()
        guard selection.location == 0, selection.length > 0, selection.length == (text as NSString).length else { return nil }
        return LinkCleaner.cleanedText(text)
    }

    static func isAddressField(_ field: NSTextField) -> Bool {
        field.placeholderString.map(placeholders.contains) ?? false
    }
}
