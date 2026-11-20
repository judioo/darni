import Foundation

/// The ⌃Tab switcher's strip of cards: how many fit, how large they are and
/// which ones show (Arc's `ModalItemSwitcher`, measured on the 2026-11-20
/// recording at 2×).
///
/// Arc's panel holds five cards of 182 × 158 pt, each a 158 × 105 pt
/// thumbnail over a favicon and a title, inside 15 pt of padding. Arc lists
/// five tabs and no more. Darni's list is longer (`recentTabSwitcherItems`),
/// so the strip shows up to five and slides to keep the highlighted card in
/// view. A narrow window first shrinks the cards, then shows fewer.
public struct TabSwitcherLayout: Equatable, Sendable {
    /// One card's slot at full size; the highlight fills it.
    public static let cellWidth = 182.0
    /// Below this a thumbnail says too little: show fewer cards instead.
    public static let minimumCellWidth = 132.0
    /// Arc's count.
    public static let maximumVisible = 5
    /// Between the panel's edge and the first card's slot.
    public static let panelPadding = 15.0
    /// Between a slot's edge and its thumbnail.
    public static let thumbnailInset = 12.0
    /// Thumbnail width over height (158 × 105 pt).
    public static let thumbnailAspect = 1.5
    /// Thumbnail to title, and the title's line.
    public static let titleGap = 13.0
    public static let titleHeight = 16.0
    /// The panel never touches the window's edge.
    public static let windowMargin = 20.0

    public let itemCount: Int
    public let visibleCount: Int
    public let cellWidth: Double

    public init(itemCount: Int, availableWidth: Double) {
        self.itemCount = max(itemCount, 0)
        let room = availableWidth - 2 * (Self.windowMargin + Self.panelPadding)
        var visible = max(1, min(self.itemCount, Self.maximumVisible))
        while visible > 1, room / Double(visible) < Self.minimumCellWidth { visible -= 1 }
        visibleCount = visible
        cellWidth = (min(Self.cellWidth, max(room / Double(visible), Self.minimumCellWidth))).rounded(.down)
    }

    public var thumbnailWidth: Double { cellWidth - 2 * Self.thumbnailInset }
    public var thumbnailHeight: Double { (thumbnailWidth / Self.thumbnailAspect).rounded() }
    public var cellHeight: Double {
        Self.thumbnailInset + thumbnailHeight + Self.titleGap + Self.titleHeight + Self.thumbnailInset
    }
    public var stripWidth: Double { cellWidth * Double(visibleCount) }
    public var panelWidth: Double { stripWidth + 2 * Self.panelPadding }
    public var panelHeight: Double { cellHeight + 2 * Self.panelPadding }

    /// The first card on show so that card `index` is visible, moving the
    /// strip as little as possible from where it was (`previous`). Stepping
    /// forward slides one card at a time. Wrapping from the last card to the
    /// first goes back to the start.
    public func firstVisible(showing index: Int, from previous: Int) -> Int {
        let last = max(itemCount - visibleCount, 0)
        var first = min(max(previous, 0), last)
        if index < first { first = index }
        if index >= first + visibleCount { first = index - visibleCount + 1 }
        return min(max(first, 0), last)
    }

    /// Cards hidden before and after the ones on show.
    public func hiddenBefore(first: Int) -> Int { min(max(first, 0), max(itemCount - visibleCount, 0)) }
    public func hiddenAfter(first: Int) -> Int { max(itemCount - visibleCount - hiddenBefore(first: first), 0) }
}

/// The switcher's colours. The panel is Darni's floating card, the same
/// neutral surface as the command bar (Arc's is #F7F7F7). The highlighted
/// card takes the space's colour: Arc's highlight on a green space is
/// #C5CCB0, which is the space's accent at 30 % over the card.
public enum TabSwitcherInk {
    /// The accent's share of the highlight.
    public static let selectionTint = 0.30
    /// The accent's share of a card with no thumbnail yet.
    public static let placeholderTint = 0.10

    public static func surface(dark: Bool) -> SpaceColor { CommandBarInk.surface(dark: dark) }

    public static func accent(theme: SpaceTheme, dark: Bool) -> SpaceColor {
        SpaceThemeRoles(theme: theme).semantic(dark: dark).foregroundPrimary
    }

    /// The highlighted card's fill.
    public static func selection(theme: SpaceTheme, dark: Bool) -> SpaceColor {
        surface(dark: dark).mixed(with: accent(theme: theme, dark: dark), fraction: selectionTint)
    }

    /// A card with no thumbnail: the card's surface with a little of the
    /// space's colour, under the tab's favicon.
    public static func placeholder(theme: SpaceTheme, dark: Bool) -> SpaceColor {
        surface(dark: dark).mixed(with: accent(theme: theme, dark: dark), fraction: placeholderTint)
    }

    /// The highlighted card's title, fitted to read on its fill.
    public static func selectedTitle(theme: SpaceTheme, dark: Bool) -> SpaceColor {
        let fill = selection(theme: theme, dark: dark)
        return SidebarBackdrop(darkest: fill, lightest: fill)
            .legible(CommandBarInk.primaryText(dark: dark), floor: SidebarContrast.text, lightInk: dark)
    }

    /// The other titles (Arc's are a dark grey, lighter than the highlighted one).
    public static func title(dark: Bool) -> SpaceColor {
        let ink = CommandBarInk.primaryText(dark: dark).mixed(with: surface(dark: dark), fraction: 0.25)
        let card = surface(dark: dark)
        return SidebarBackdrop(darkest: card, lightest: card).legible(ink, floor: SidebarContrast.text, lightInk: dark)
    }
}
