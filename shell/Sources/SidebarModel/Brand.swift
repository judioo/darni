/// The product's name as people see it. ReArc was renamed Darni at build 1054.
///
/// Only what people read changed. Identifiers keep the name ReArc for good: the bundle id
/// `com.rearc.browser`, the iCloud container, the "ReArc Safe Storage" Keychain item, the
/// data folder `Application Support/ReArc`, the update feed and blocklists on
/// rearc.imara.ae, the `rearc:` feed marker, user defaults keys, `REARC_*` variables and
/// the `rearc://` scheme. Changing any of them strands an installed copy's data or updates.
///
/// Most copy writes the name out. This file holds the pieces that are drawn in parts or
/// repeated across the onboarding, the welcome page and the membership card.
public enum Brand {
    public static let name = "Darni"

    /// The wordmark, two tone (brand board, option B): `wordmarkLead` in the text colour and
    /// `wordmarkTail` in the arc colour, bold, letter spacing -0.02 em, beside the mark.
    public static let wordmarkLead = "Dar"
    public static let wordmarkTail = "ni"
    /// The arc colour of `wordmarkTail`, as 0xRRGGBB: on a light and on a dark background.
    public static let arcOnLight: UInt32 = 0x2740FF
    public static let arcOnDark: UInt32 = 0x8EA0FF
    /// The text colour of `wordmarkLead` on a light and on a dark background.
    public static let inkOnLight: UInt32 = 0x1D2160
    public static let inkOnDark: UInt32 = 0xF3EBD3

    /// The motto. OPEN DECISION (owner, 2026-11-19): "ReFocused. ReStored. ReArc." only worked
    /// with a name that starts with "Re". Until the owner answers, the first two words stay
    /// and the third is the new name. This line is the only place to change.
    public static let motto = Motto(cleanStart: "ReFocused.", restored: "ReStored.", name: "Darni.")
}

/// The motto's three words, as the sunrise speaks them: one at a time, each with its full stop.
public struct Motto: Equatable, Sendable {
    /// The line for a clean start (nothing imported).
    public var cleanStart: String
    /// The line after an import.
    public var restored: String
    /// The last word, the name.
    public var name: String

    public init(cleanStart: String, restored: String, name: String) {
        self.cleanStart = cleanStart
        self.restored = restored
        self.name = name
    }

    /// In the order they land.
    public var words: [String] { [cleanStart, restored, name] }

    /// The motto as one line of small capitals: "REFOCUSED · RESTORED · DARNI".
    public var capitals: String {
        words.map { word in
            (word.hasSuffix(".") ? String(word.dropLast()) : word).uppercased()
        }.joined(separator: " · ")
    }
}
