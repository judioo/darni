import Foundation

/// Key chords as the performance check's probe takes them (`arc-vs-rearc probe`,
/// docs/PERFORMANCE-CHIP.md): "cmd+t", "cmd+2", "esc", "opt+cmd+n".
public enum ProbeChord {
    private static let keys: [String: (label: String, code: UInt16)] = [
        "t": ("T", 17), "n": ("N", 45), "w": ("W", 13), "l": ("L", 37), "s": ("S", 1), "r": ("R", 15),
        "esc": ("Esc", 53), "escape": ("Esc", 53), "tab": ("Tab", 48), "return": ("Return", 36),
    ]
    private static let modifiers: [String: KeyModifiers] = [
        "cmd": .command, "command": .command, "opt": .option, "option": .option, "alt": .option,
        "shift": .shift, "ctrl": .control, "control": .control,
    ]

    /// The chord `text` names, or nil when a part is unknown or no key is named.
    public static func parse(_ text: String) -> KeyChord? {
        var held: KeyModifiers = []
        var key: (label: String, code: UInt16)?
        for part in text.lowercased().split(separator: "+").map(String.init) {
            if let modifier = modifiers[part] {
                held.insert(modifier)
            } else if key == nil, let known = keys[part] {
                key = known
            } else if key == nil, let digit = Int(part), (1 ... 9).contains(digit) {
                let chord = KeyChord.digit(digit, [])
                key = (chord.key, chord.keyCode)
            } else {
                return nil
            }
        }
        return key.map { KeyChord($0.label, $0.code, held) }
    }

    /// Why the probe never posts `chord`, or nil when it may. ⌃digit switches the
    /// macOS desktop on this Mac whatever the frontmost app is, so it is refused
    /// outright, as is anything `reserved` (the system's own shortcuts).
    public static func refusal(_ chord: KeyChord, reserved: [ReservedShortcut] = []) -> String? {
        if chord.modifiers.contains(.control), KeyChord.digitCodes.contains(chord.keyCode) {
            return "\(chord.label): Control with a digit is never posted (it switches the macOS desktop)"
        }
        if let shortcut = reserved.first(where: { $0.matches(chord) }) {
            return "\(chord.label) is \(shortcut.name), so the key would never reach the app"
        }
        return nil
    }
}
