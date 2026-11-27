import Foundation

/// The command bar card's colours. Arc's card is opaque and neutral over
/// every space theme (#F9F9F9 in light, 2026-11-12 recording); only the
/// selected row and a site search's chip take a colour. Every ink is fitted
/// to its floor on that surface, and the selected fill is darkened (OKLab
/// lightness, its own hue) until white text on it reads, which Arc's own
/// fill on a pale theme does not (#AE9D8D with white is 2.6:1).
public enum CommandBarInk {
    /// Arc's card, measured: #F9F9F9. Dark is ReArc's own (not observed).
    public static func surface(dark: Bool) -> SpaceColor {
        dark ? grey(0x2B) : grey(0xF9)
    }

    /// Titles and typed text (Arc's are near black, #1A1A1A–#272727).
    public static func primaryText(dark: Bool) -> SpaceColor {
        fit(dark ? grey(0xF2) : grey(0x1C), dark: dark, floor: SidebarContrast.text)
    }

    /// Subtitles, hints ("Switch to Tab", "Search cushwake") and the
    /// placeholder. Arc's hint grey (#999) is 2.7:1; this one clears 4.5.
    public static func secondaryText(dark: Bool) -> SpaceColor {
        fit(dark ? grey(0xA8) : grey(0x8A), dark: dark, floor: SidebarContrast.text)
    }

    /// The magnifier and row glyphs.
    public static func glyph(dark: Bool) -> SpaceColor {
        fit(dark ? grey(0x9A) : grey(0x8A), dark: dark, floor: SidebarContrast.glyph)
    }

    /// The line under the field (Arc #DDDDDD) and the card's hairline.
    public static func separator(dark: Bool) -> SpaceColor { dark ? grey(0x3D) : grey(0xDD) }

    /// An unselected keycap's fill (Arc #EBEBEB).
    public static func keycap(dark: Bool) -> SpaceColor { dark ? grey(0x3F) : grey(0xEB) }

    /// Text on the selected row and on a chip.
    public static let selectedText = SpaceColor.white

    /// `accent` darkened just enough for white text on it to clear 4.5:1.
    public static func selectionFill(_ accent: SpaceColor) -> SpaceColor {
        SidebarBackdrop(darkest: .white, lightest: .white).legible(accent.clamped, floor: SidebarContrast.text, lightInk: false)
    }

    /// The selected row on a space: its accent lightened as Arc's is
    /// (`#2731FF` → `#858AFF` on the default theme, 43.5 % toward white),
    /// then fitted for white text.
    public static func accentFill(theme: SpaceTheme, dark: Bool) -> SpaceColor {
        let accent = SpaceThemeRoles(theme: theme).semantic(dark: dark).foregroundPrimary
        return selectionFill(accent.mixed(with: .white, fraction: 0.435))
    }

    /// A site search's chip and selected row: the entry's or its favicon's
    /// colour, fitted for white text; the space's fill when the site has
    /// none or when it would vanish into the dark card.
    public static func siteFill(_ color: SpaceColor?, accentFill: SpaceColor, dark: Bool) -> SpaceColor {
        guard let color else { return accentFill }
        let fill = selectionFill(color)
        if dark, fill.contrast(with: surface(dark: true)) < 1.5 { return accentFill }
        return fill
    }

    /// The card washed with a site's colour as it collapses to the field
    /// (Arc: 17 % of the colour over the card, gone in ≈ 0.25 s).
    public static let collapseTint = 0.17

    // MARK: Command rows

    /// How much of the space's colour a command row's resting fill takes.
    /// Search, page and tab rows sit on the bare card; commands get this
    /// "low light", far quieter than the selected row's solid fill. Increase
    /// Contrast doubles it (and adds `commandRowEdge`).
    public static func commandTintFraction(dark: Bool, increasedContrast: Bool = false) -> Double {
        switch (dark, increasedContrast) {
        case (false, false): return 0.08
        case (true, false): return 0.16
        case (false, true): return 0.16
        case (true, true): return 0.30
        }
    }

    /// A command row's resting fill: the card mixed with `accent`, the
    /// selected row's fill (`selectionFill` / the theme's `commandBarFill`),
    /// so commands carry the space's hue without competing with the selection.
    public static func commandRowFill(accent: SpaceColor, dark: Bool, increasedContrast: Bool = false) -> SpaceColor {
        surface(dark: dark).mixed(with: accent.clamped,
                                  fraction: commandTintFraction(dark: dark, increasedContrast: increasedContrast)).clamped
    }

    /// The hairline round a command row with Increase Contrast: the accent
    /// fitted to 3:1 on the row's fill.
    public static func commandRowEdge(accent: SpaceColor, dark: Bool) -> SpaceColor {
        let fill = commandRowFill(accent: accent, dark: dark, increasedContrast: true)
        return fit(accent.clamped, on: fill, dark: dark, floor: SidebarContrast.glyph)
    }

    /// A command row's ⌘ glyph: the accent, fitted to the glyph floor on the row.
    public static func commandGlyph(accent: SpaceColor, dark: Bool, increasedContrast: Bool = false) -> SpaceColor {
        let fill = commandRowFill(accent: accent, dark: dark, increasedContrast: increasedContrast)
        return fit(accent.clamped, on: fill, dark: dark, floor: SidebarContrast.glyph)
    }

    /// Titles on a command row: the card's title ink, refitted on the tint.
    public static func commandPrimaryText(accent: SpaceColor, dark: Bool, increasedContrast: Bool = false) -> SpaceColor {
        fit(primaryText(dark: dark), on: commandRowFill(accent: accent, dark: dark, increasedContrast: increasedContrast),
            dark: dark, floor: SidebarContrast.text)
    }

    /// Subtitles, keys and "No shortcut" on a command row, refitted on the tint.
    public static func commandSecondaryText(accent: SpaceColor, dark: Bool, increasedContrast: Bool = false) -> SpaceColor {
        fit(secondaryText(dark: dark), on: commandRowFill(accent: accent, dark: dark, increasedContrast: increasedContrast),
            dark: dark, floor: SidebarContrast.text)
    }

    /// The keycap behind a command's keys: the card's keycap, nudged toward
    /// the accent as the row is, so it still reads as a key on the tint.
    public static func commandKeycap(accent: SpaceColor, dark: Bool, increasedContrast: Bool = false) -> SpaceColor {
        keycap(dark: dark).mixed(with: accent.clamped,
                                 fraction: commandTintFraction(dark: dark, increasedContrast: increasedContrast)).clamped
    }

    private static func grey(_ value: Int) -> SpaceColor {
        let v = Double(value) / 255
        return SpaceColor(red: v, green: v, blue: v)
    }

    private static func fit(_ ink: SpaceColor, dark: Bool, floor: Double) -> SpaceColor {
        fit(ink, on: surface(dark: dark), dark: dark, floor: floor)
    }

    private static func fit(_ ink: SpaceColor, on fill: SpaceColor, dark: Bool, floor: Double) -> SpaceColor {
        SidebarBackdrop(darkest: fill, lightest: fill).legible(ink, floor: floor, lightInk: dark)
    }
}

/// A site's colour from its favicon (Arc `loadedSiteSearchDominantColor`):
/// the most common saturated colour, ignoring transparent, near-white,
/// near-black and grey pixels. Nil for a monochrome icon.
public enum FaviconColor {
    /// The colour's pixels must be at least this share of the opaque ones.
    public static let minimumShare = 0.08

    public static func dominant(rgba: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> SpaceColor? {
        guard width > 0, height > 0, bytesPerRow >= width * 4, rgba.count >= bytesPerRow * (height - 1) + width * 4 else {
            return nil
        }
        var counts = [Int](repeating: 0, count: 4096)
        var sums = [SIMD3<Double>](repeating: .zero, count: 4096)
        var opaque = 0
        for y in 0 ..< height {
            var i = y * bytesPerRow
            for _ in 0 ..< width {
                defer { i += 4 }
                guard rgba[i + 3] >= 128 else { continue }
                opaque += 1
                let r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2])
                let high = max(r, g, b), low = min(r, g, b)
                guard high > 36, low < 232, high - low >= 40 else { continue }
                let bucket = (r >> 4) << 8 | (g >> 4) << 4 | b >> 4
                counts[bucket] += 1
                sums[bucket] += SIMD3(Double(r), Double(g), Double(b))
            }
        }
        guard opaque > 0, let best = counts.indices.max(by: { counts[$0] < counts[$1] }),
              counts[best] > 0, Double(counts[best]) >= minimumShare * Double(opaque) else { return nil }
        let mean = sums[best] / Double(counts[best]) / 255
        return SpaceColor(red: mean.x, green: mean.y, blue: mean.z)
    }
}
