import Foundation

/// How the reader looks: Darni settings, the same for every profile and
/// window. They say nothing about a page (docs/FEATURE-SPECS/READER-VIEW.md §8).
public struct ReaderAppearance: Equatable, Sendable {
    public enum Font: String, CaseIterable, Sendable {
        case serif, sans

        public var title: String { self == .serif ? "Serif" : "Sans" }
    }

    public enum Width: String, CaseIterable, Sendable {
        case narrow, medium, wide

        public var title: String {
            switch self {
            case .narrow: return "Narrow"
            case .medium: return "Medium"
            case .wide: return "Wide"
            }
        }
    }

    public enum Theme: String, CaseIterable, Sendable {
        /// Follows the window's light or dark appearance.
        case auto, light, sepia, dark

        public var title: String {
            switch self {
            case .auto: return "Auto"
            case .light: return "Light"
            case .sepia: return "Sepia"
            case .dark: return "Dark"
            }
        }
    }

    public static let sizeRange = 1...7
    public static let defaultSize = 3

    public var font: Font = .serif
    /// A step in `sizeRange`; the stylesheet has one text size per step.
    public var size: Int = ReaderAppearance.defaultSize
    public var width: Width = .medium
    public var theme: Theme = .auto

    public init() {}

    public init(font: Font, size: Int, width: Width, theme: Theme) {
        self.font = font
        self.size = min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        self.width = width
        self.theme = theme
    }

    public var canGrow: Bool { size < Self.sizeRange.upperBound }
    public var canShrink: Bool { size > Self.sizeRange.lowerBound }

    public func resized(by steps: Int) -> ReaderAppearance {
        ReaderAppearance(font: font, size: size + steps, width: width, theme: theme)
    }

    /// The theme as drawn: `auto` follows the window's light or dark appearance.
    public func resolvedTheme(isDark: Bool) -> Theme {
        theme == .auto ? (isDark ? .dark : .light) : theme
    }

    /// The reader's page colour (`--bg` in `ReaderHTML.stylesheet`): what the
    /// toolbar takes while the reader is open, in place of the page's colour.
    public func backgroundColor(isDark: Bool) -> PageColor {
        switch resolvedTheme(isDark: isDark) {
        case .sepia: return PageColor(red: 0xF6 / 255, green: 0xEF / 255, blue: 0xE0 / 255)
        case .dark: return PageColor(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)
        default: return PageColor(red: 0xFB / 255, green: 0xFB / 255, blue: 0xF9 / 255)
        }
    }

    /// The attributes the stylesheet's selectors read on the page's root element.
    public var rootAttributes: [(name: String, value: String)] {
        [("data-font", font.rawValue), ("data-size", String(size)), ("data-width", width.rawValue), ("data-theme", theme.rawValue)]
    }
}

/// Reads and writes `ReaderAppearance` in the app's defaults, one key per
/// setting. A value this build does not know (written by a newer build, or
/// damaged) reads as that setting's default and is left as it is until the
/// person changes the setting.
public struct ReaderAppearanceStore {
    public static let fontKey = "rearc.reader.font"
    public static let sizeKey = "rearc.reader.textSize"
    public static let widthKey = "rearc.reader.width"
    public static let themeKey = "rearc.reader.theme"

    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> ReaderAppearance {
        let standard = ReaderAppearance()
        let size = (defaults.object(forKey: Self.sizeKey) as? Int).flatMap { ReaderAppearance.sizeRange.contains($0) ? $0 : nil }
        return ReaderAppearance(
            font: defaults.string(forKey: Self.fontKey).flatMap(ReaderAppearance.Font.init(rawValue:)) ?? standard.font,
            size: size ?? standard.size,
            width: defaults.string(forKey: Self.widthKey).flatMap(ReaderAppearance.Width.init(rawValue:)) ?? standard.width,
            theme: defaults.string(forKey: Self.themeKey).flatMap(ReaderAppearance.Theme.init(rawValue:)) ?? standard.theme
        )
    }

    /// Writes only what differs from `previous`, so a setting this build could
    /// not read keeps its stored value until that setting is changed.
    public func save(_ appearance: ReaderAppearance, replacing previous: ReaderAppearance) {
        if appearance.font != previous.font { defaults.set(appearance.font.rawValue, forKey: Self.fontKey) }
        if appearance.size != previous.size { defaults.set(appearance.size, forKey: Self.sizeKey) }
        if appearance.width != previous.width { defaults.set(appearance.width.rawValue, forKey: Self.widthKey) }
        if appearance.theme != previous.theme { defaults.set(appearance.theme.rawValue, forKey: Self.themeKey) }
    }
}
