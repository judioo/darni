import Foundation

/// A menu item's keyboard shortcut as Accessibility reports it, turned into the probe's chord
/// text ("opt+cmd+right", "cmd+s", "ctrl+tab"). The performance check reads a browser's menus
/// to learn which of the key-press actions it has, so it never posts a key whose meaning in
/// that browser it does not know (⌘S is Save Page in Chrome).
public enum MenuShortcut {
    // kAXMenuItemModifier* bits.
    static let shift = 1 << 0, option = 1 << 1, control = 1 << 2, noCommand = 1 << 3

    // Glyphs (kMenu*Glyph) for keys with no character.
    static let glyphs: [Int: String] = [0x64: "left", 0x65: "right", 0x68: "up", 0x6A: "down", 0x1B: "esc", 0x02: "tab", 0x17: "tab"]
    // Virtual key codes, when the glyph is missing.
    static let virtualKeys: [Int: String] = [123: "left", 124: "right", 125: "down", 126: "up", 53: "esc", 48: "tab"]

    /// The chord text, or nil when the item has no shortcut.
    public static func chord(character: String?, modifiers: Int?, virtualKey: Int?, glyph: Int?) -> String? {
        var key: String?
        if let character, !character.isEmpty, character.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) {
            key = character.lowercased()
        } else if let glyph, let name = glyphs[glyph] {
            key = name
        } else if let virtualKey, let name = virtualKeys[virtualKey] {
            key = name
        }
        guard let key else { return nil }
        let mask = modifiers ?? 0
        var parts: [String] = []
        if mask & control != 0 { parts.append("ctrl") }
        if mask & option != 0 { parts.append("opt") }
        if mask & shift != 0 { parts.append("shift") }
        if mask & noCommand == 0 { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }
}
