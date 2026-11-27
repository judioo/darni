import Foundation

/// Peek at URL… with a link on the pasteboard: the bar's first row peeks it,
/// so ⇧⌘P then Return peeks a copied link (owner, 2026-11-27).
///
/// On macOS 15.4 and later, reading the general pasteboard without a paste
/// can ask the person ("Darni would like to paste from …"). The shell then
/// only detects that a link is there (no alert) and offers the row without
/// the address; the text is read when the person picks the row.
public enum CommandBarCopiedLink {
    /// What the bar knows about the copied link.
    public enum Offer: Equatable, Sendable {
        /// Read already (a pasteboard the app may read freely).
        case link(URL)
        /// The system saw a link; its text is read when the row is picked.
        case detected

        public var url: URL? {
            if case .link(let url) = self { return url }
            return nil
        }
    }

    public static let rowID = "peek-copied-link"
    public static let title = "Peek Copied Link"
    /// Longer text is not a link someone copied to peek at.
    static let maximumLength = 8_192

    /// The web link in copied text: one http(s) URL, or a bare address
    /// ("example.com/a"), with nothing else around it. Nil for words, several
    /// lines, other schemes and addresses the engine does not open.
    public static func link(from text: String?, engine: NavigationURLPolicy.EngineSchemes = []) -> URL? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength,
              !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        let candidate: URL?
        if let url = URL(string: trimmed), url.scheme != nil, trimmed.contains("://") {
            candidate = url
        } else if trimmed.contains("."), !trimmed.hasPrefix("."), !trimmed.contains("@") {
            candidate = URL(string: "https://\(trimmed)")
        } else {
            candidate = nil
        }
        guard let url = candidate, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(), !host.isEmpty, host.contains(".") || host == "localhost",
              NavigationURLPolicy.allows(url, engine: engine) else { return nil }
        return url
    }

    /// The row: the link's address beside the title when it is known.
    public static func result(_ offer: Offer) -> CommandBarSearch.Result {
        CommandBarSearch.Result(
            id: rowID,
            kind: .openURL,
            title: title,
            subtitle: offer.url?.absoluteString,
            destinationURL: offer.url
        )
    }
}
