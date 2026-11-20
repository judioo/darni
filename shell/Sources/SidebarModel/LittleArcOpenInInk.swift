import Foundation

/// The colours of Little Darni's "Open in <Space> ⌘O ⌄" pill, for one target
/// space in one appearance.
///
/// Arc writes the space's name in the space's colour on a light pill. Darni
/// once did the same straight onto the tinted toolbar, and the default
/// lavender was unreadable there (QA 2026-11-08 #19), so the name went to
/// plain text beside a coloured dot. This brings the coloured name back
/// without that fault, in two steps:
///
/// 1. The pill is opaque. What the words sit on is then one known colour (two
///    with hover), not a material over whatever the window has behind it, so
///    their contrast can be worked out and tested.
/// 2. The name is the space's colour moved in lightness only, at its own hue
///    and chroma (`SidebarBackdrop.legible`), just far enough to clear 4.5:1
///    on the pill: darker on the light pill, lighter on the dark one. A colour
///    that already reads is left as it is. Lavender becomes a deeper violet,
///    yellow an olive, and a dark navy stays navy.
///
/// "Open in", ⌘O and the chevron are greys held to the same floor.
public struct LittleArcOpenInInk: Equatable, Sendable {
    /// The pill's fill, and its fill under the pointer.
    public let pill: SpaceColor
    public let pillHover: SpaceColor
    /// The space's name.
    public let name: SpaceColor
    /// "Open in" and the ⌄.
    public let label: SpaceColor
    /// The ⌘O key cap and its text.
    public let keyCap: SpaceColor
    public let keyCapText: SpaceColor

    /// `theme` is the target space's, nil when there is none to name.
    public init(theme: SpaceTheme?, dark: Bool) {
        let tint = theme?.spaceColor.clamped
        let base = dark ? SpaceColor(red: 0.2, green: 0.2, blue: 0.22) : .white
        let pill = tint.map { base.mixed(with: $0, fraction: dark ? 0.08 : 0.05) } ?? base
        let hover = pill.mixed(with: dark ? .white : .black, fraction: dark ? 0.07 : 0.05)
        let keyCap = pill.mixed(with: dark ? .white : .black, fraction: dark ? 0.16 : 0.09)
        // Dark ink must clear the darkest thing under it, light ink the lightest.
        let surface = SidebarBackdrop(darkest: dark ? pill : hover, lightest: dark ? hover : pill)
        let grey = dark ? SpaceColor(red: 0.72, green: 0.72, blue: 0.75) : SpaceColor(red: 0.42, green: 0.42, blue: 0.45)
        let plain = dark ? SpaceColor(red: 0.95, green: 0.95, blue: 0.97) : SpaceColor(red: 0.1, green: 0.1, blue: 0.12)
        self.pill = pill
        self.pillHover = hover
        self.keyCap = keyCap
        name = surface.legible(tint ?? plain, floor: SidebarContrast.text, lightInk: dark)
        label = surface.legible(grey, floor: SidebarContrast.text, lightInk: dark)
        keyCapText = SidebarBackdrop(darkest: keyCap, lightest: keyCap).legible(grey, floor: SidebarContrast.text, lightInk: dark)
    }
}

/// A space's tile in the picker: a small rounded square in a pale tint of the
/// space's colour, as Arc draws it, and the colour a symbol icon takes on it.
public struct LittleArcSpaceTileInk: Equatable, Sendable {
    public let fill: SpaceColor
    /// An SF Symbol icon: the space's colour, moved in lightness until it
    /// clears the glyph floor (3:1) on the tile. Emoji and pictures keep
    /// their own colours.
    public let glyph: SpaceColor

    public init(theme: SpaceTheme, dark: Bool) {
        let tint = theme.spaceColor.clamped
        let fill = (dark ? SpaceColor(red: 0.24, green: 0.24, blue: 0.26) : .white)
            .mixed(with: tint, fraction: dark ? 0.3 : 0.18)
        self.fill = fill
        glyph = SidebarBackdrop(darkest: fill, lightest: fill).legible(tint, floor: SidebarContrast.glyph, lightInk: dark)
    }
}
