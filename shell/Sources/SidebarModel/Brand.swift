/// The product's name as people see it. ReArc was renamed Darni at build 1054.
///
/// Only what people read changed. Identifiers keep the name ReArc for good: the bundle id
/// `com.rearc.browser`, the iCloud container, the "ReArc Safe Storage" Keychain item, the
/// data folder `Application Support/ReArc`, the update feed and blocklists on
/// rearc.imara.ae, the `rearc:` feed marker, user defaults keys, `REARC_*` variables and
/// the `rearc://` scheme. Changing any of them strands an installed copy's data or updates.
///
/// Most copy writes the name out. This file holds the pieces that are drawn in parts: the
/// wordmark of the onboarding, the About window and the membership card.
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

    // There is no motto. "ReFocused. ReStored. ReArc." only worked with a name that starts with
    // "Re", and the owner dropped it with the rename (2026-11-19) rather than replace it. The
    // onboarding, the welcome page and the membership card show the wordmark with no line of
    // words beside it. Do not add one without the owner asking.
}
