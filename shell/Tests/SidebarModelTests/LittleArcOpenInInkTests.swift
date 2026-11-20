import XCTest
@testable import SidebarModel

/// Little Darni's "Open in <Space>" pill. QA 2026-11-08 #19: the space's name
/// in its theme colour was unreadable on the default lavender, so it became a
/// dot. The name is in the space's colour again, as in Arc, on an opaque pill,
/// with the colour moved in lightness until it reads at WCAG AA (4.5:1) there.
final class LittleArcOpenInInkTests: XCTestCase {
    private var themes: [SpaceTheme] {
        var all = SpaceTheme.presets + SpaceTheme.gradientPresets + [.default, .white, .black]
        // Every corner and edge of the colour cube, and greys: no hue is left out.
        for red in stride(from: 0.0, through: 1.0, by: 0.25) {
            for green in stride(from: 0.0, through: 1.0, by: 0.25) {
                for blue in stride(from: 0.0, through: 1.0, by: 0.25) {
                    all.append(SpaceTheme(red: red, green: green, blue: blue))
                }
            }
        }
        return all
    }

    func testEveryWordReadsOnThePillAndUnderThePointerInLightAndDark() {
        for dark in [false, true] {
            for theme in themes + [nil] {
                let ink = LittleArcOpenInInk(theme: theme, dark: dark)
                let what = "\(dark ? "dark" : "light"), \(theme.map { $0.spaceColor.hex } ?? "no space")"
                for surface in [ink.pill, ink.pillHover] {
                    XCTAssertGreaterThanOrEqual(ink.name.contrast(with: surface), 4.5, "name, \(what)")
                    XCTAssertGreaterThanOrEqual(ink.label.contrast(with: surface), 4.5, "Open in, \(what)")
                }
                XCTAssertGreaterThanOrEqual(ink.keyCapText.contrast(with: ink.keyCap), 4.5, "⌘O, \(what)")
            }
        }
    }

    /// The fault that made it a dot: lavender on a light bar. It fails as it
    /// was, and reads once fitted, still a violet.
    func testTheDefaultLavenderIsDarkenedAndKeepsItsHue() {
        let lavender = SpaceTheme.default
        let ink = LittleArcOpenInInk(theme: lavender, dark: false)
        XCTAssertLessThan(lavender.spaceColor.contrast(with: ink.pill), 4.5, "the theme colour itself does not read on the pill")
        XCTAssertGreaterThanOrEqual(ink.name.contrast(with: ink.pill), 4.5)
        XCTAssertLessThan(ink.name.luminance, lavender.spaceColor.luminance, "darker")
        let before = lavender.spaceColor.oklab.lch, after = ink.name.oklab.lch
        XCTAssertEqual(after.h, before.h, accuracy: 0.12, "the same hue")
        XCTAssertGreaterThan(after.c, 0.04, "still a colour, not a grey")
    }

    /// A colour that already reads is left exactly as it is.
    func testAColourThatAlreadyReadsIsKept() {
        let navy = SpaceTheme(red: 0.05, green: 0.15, blue: 0.45)
        XCTAssertEqual(LittleArcOpenInInk(theme: navy, dark: false).name, navy.spaceColor)
        let pale = SpaceTheme(red: 0.85, green: 0.95, blue: 1)
        XCTAssertEqual(LittleArcOpenInInk(theme: pale, dark: true).name, pale.spaceColor)
        // And each is moved the other way in the other appearance.
        XCTAssertGreaterThan(LittleArcOpenInInk(theme: navy, dark: true).name.luminance, navy.spaceColor.luminance)
        XCTAssertLessThan(LittleArcOpenInInk(theme: pale, dark: false).name.luminance, pale.spaceColor.luminance)
    }

    /// The pill is one opaque colour, near white or a dark grey, with a trace
    /// of the space's colour: that is what makes the contrast knowable.
    func testThePillIsLightInLightAndDarkInDark() {
        for theme in themes {
            XCTAssertGreaterThan(LittleArcOpenInInk(theme: theme, dark: false).pill.luminance, 0.8)
            XCTAssertLessThan(LittleArcOpenInInk(theme: theme, dark: true).pill.luminance, 0.08)
        }
        XCTAssertEqual(LittleArcOpenInInk(theme: nil, dark: false).pill, .white)
    }

    /// The picker's tiles: a symbol icon in the space's colour clears the
    /// glyph floor on its tile, and the tile stays a pale (or deep) tint.
    func testASymbolReadsOnItsTile() {
        for dark in [false, true] {
            for theme in themes {
                let ink = LittleArcSpaceTileInk(theme: theme, dark: dark)
                XCTAssertGreaterThanOrEqual(ink.glyph.contrast(with: ink.fill), 3, "\(dark ? "dark" : "light") \(theme.spaceColor.hex)")
                if dark {
                    XCTAssertLessThan(ink.fill.luminance, 0.25)
                } else {
                    XCTAssertGreaterThan(ink.fill.luminance, 0.55)
                }
            }
        }
    }
}
