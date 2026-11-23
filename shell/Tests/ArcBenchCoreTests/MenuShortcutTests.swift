import Testing
@testable import ArcBenchCore

/// Menu shortcuts as Accessibility reports them, as the probe's chord text.
struct MenuShortcutTests {
    @Test func charactersAndModifiers() {
        #expect(MenuShortcut.chord(character: "S", modifiers: 0, virtualKey: nil, glyph: nil) == "cmd+s")
        #expect(MenuShortcut.chord(character: "N", modifiers: 2, virtualKey: nil, glyph: nil) == "opt+cmd+n")
        #expect(MenuShortcut.chord(character: "]", modifiers: 1, virtualKey: nil, glyph: nil) == "shift+cmd+]")
        #expect(MenuShortcut.chord(character: "1", modifiers: 0, virtualKey: nil, glyph: nil) == "cmd+1")
    }

    @Test func glyphKeysAndNoCommand() {
        #expect(MenuShortcut.chord(character: nil, modifiers: 2, virtualKey: nil, glyph: 0x65) == "opt+cmd+right")
        #expect(MenuShortcut.chord(character: "", modifiers: 2, virtualKey: 125, glyph: nil) == "opt+cmd+down")
        #expect(MenuShortcut.chord(character: nil, modifiers: 4 | 8, virtualKey: 48, glyph: nil) == "ctrl+tab")
        #expect(MenuShortcut.chord(character: nil, modifiers: 8, virtualKey: nil, glyph: 0x1B) == "esc")
    }

    @Test func noShortcutIsNil() {
        #expect(MenuShortcut.chord(character: nil, modifiers: nil, virtualKey: nil, glyph: nil) == nil)
        #expect(MenuShortcut.chord(character: "\u{7F}", modifiers: 0, virtualKey: nil, glyph: nil) == nil)
    }
}
