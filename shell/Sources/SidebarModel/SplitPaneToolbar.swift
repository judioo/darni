import Foundation

/// Arc's split view toolbars (SPLIT-VIEW §3.1): with "URL in toolbar" on,
/// every pane is its own card with its own row (back, forward, its address,
/// a close ✕). Only the focused pane's row adds reload, the site controls,
/// the extensions and the split view menu; focusing another pane moves them.
public struct SplitPaneToolbarLayout: Equatable {
    /// One pane's row.
    public struct Row: Equatable {
        public var tabID: Tab.ID
        /// The focused pane: reload, site controls, extensions, split menu.
        public var isActive: Bool
        /// The row starts at the card's top-left corner (the traffic lights
        /// with the sidebar on the right; the sidebar toggle on the left).
        public var isAtLeadingCorner: Bool
        /// The row ends at the card's top-right corner (the sidebar toggle
        /// with the sidebar on the right).
        public var isAtTrailingCorner: Bool
    }

    public private(set) var rows: [Row]

    /// The panes on screen in order (all of them, or the expanded one).
    public init(visiblePanes: [Tab.ID], focus: Tab.ID, orientation: SplitLayoutOrientation) {
        let active = visiblePanes.contains(focus) ? focus : visiblePanes.first
        let last = visiblePanes.count - 1
        rows = visiblePanes.enumerated().map { index, id in
            let topRow = orientation == .vertical ? index == 0 : true
            return Row(
                tabID: id,
                isActive: id == active,
                isAtLeadingCorner: topRow && (orientation == .vertical || index == 0),
                isAtTrailingCorner: topRow && (orientation == .vertical ? index == 0 : index == last)
            )
        }
    }

    public init(split: SplitViewItem, visiblePanes: [Tab]) {
        self.init(visiblePanes: visiblePanes.map(\.id), focus: split.focusTabID, orientation: split.orientation)
    }

    /// The pane whose row carries the site controls, extensions and split menu.
    public var controlsPane: Tab.ID? { rows.first(where: \.isActive)?.tabID }

    public func row(for tabID: Tab.ID) -> Row? { rows.first { $0.tabID == tabID } }

    /// Rows show with "URL in toolbar" on, as the single strip does; HTML
    /// fullscreen shows only the page. With the toolbar off (Arc: the URL in
    /// the sidebar) the panes have no rows and the sidebar's address follows
    /// the focused pane.
    public static func showsRows(urlInToolbar: Bool, pageFullscreen: Bool) -> Bool {
        urlInToolbar && !pageFullscreen
    }

    /// A click in a pane focuses it; nil when it already has focus or is not
    /// in the split (nothing to change, so nothing re-renders).
    public static func focusChange(clicked tabID: Tab.ID, in split: SplitViewItem) -> Tab.ID? {
        guard tabID != split.focusTabID, split.tabs.contains(where: { $0.id == tabID }) else { return nil }
        return tabID
    }

    /// A pane row's address: the host without `www.` (Arc draws it darker)
    /// and the rest of the URL without its scheme. Nil for a blank page. A
    /// port stays with the host (`localhost:3000`): without it two local
    /// servers look the same. The card toolbar shows the two parts side by side.
    ///
    /// Spoofing (security AG-01): the host is cut from the left, so its registrable domain
    /// always shows (`PageOrigin.shortenedHost`) and a long host under an attacker's domain
    /// cannot show only a trusted-looking start; an IPv6 address keeps its brackets. The rest
    /// is decoded for reading, except control, invisible and direction characters and
    /// whitespace, which stay percent-encoded: a right-to-left override or a run of spaces
    /// cannot reorder or push away what follows.
    public static func addressParts(_ url: URL?) -> (host: String, rest: String)? {
        guard let url, url.absoluteString != "about:blank" else { return nil }
        // `blob:` carries its origin's address: its host is shortened from the left like any
        // other, so a long host under an attacker's domain still shows that domain.
        if url.scheme?.lowercased() == "blob", let inner = URL(string: String(url.absoluteString.dropFirst("blob:".count))),
           inner.host()?.isEmpty == false, let parts = addressParts(inner) {
            return ("blob:" + parts.host, parts.rest)
        }
        guard let host = url.host(), !host.isEmpty else {
            // No host (`about:blank#…`, `blob:`, `data:`, `file:`, `view-source:`): the first
            // part never truncates, so it is the scheme and what follows up to a `?` or `#`,
            // at most `hostLimit` characters; the page-chosen rest goes to the part that
            // truncates (security AG-01, hostless addresses).
            let whole = url.absoluteString
            let cut = whole.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? whole.endIndex
            let head = String(whole[..<cut].prefix(hostLimit))
            return (head, readable(String(whole.dropFirst(head.count))))
        }
        var bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if bareHost.contains(":") { bareHost = "[\(bareHost)]" }
        if let port = url.port { bareHost += ":\(port)" }
        if !bareHost.hasPrefix("[") { bareHost = PageOrigin.shortenedHost(bareHost, limit: hostLimit) }
        var rest = readable(url.path(percentEncoded: false))
        if rest == "/" { rest = "" }
        if let query = url.query(percentEncoded: false), !query.isEmpty { rest += "?" + readable(query) }
        return (bareHost, rest)
    }

    /// Characters past which the host is shortened, from the left.
    static let hostLimit = 40

    /// `text` with control, format (bidirectional, zero-width), separator and other
    /// whitespace characters percent-encoded as UTF-8. Every address line that shows a
    /// decoded path or query uses it (here, and the Peek's `PeekAddress`).
    public static func readable(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator, .unassigned, .surrogate, .privateUse:
                for byte in String(scalar).utf8 { out += String(format: "%%%02X", byte) }
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
