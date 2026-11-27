import Foundation

/// A key with its modifiers: what a shortcut row's chip shows and records.
public struct ShortcutChord: Hashable, Sendable {
    public let key: ShortcutKey
    public let modifiers: ShortcutModifiers

    public init(_ key: ShortcutKey, _ modifiers: ShortcutModifiers) {
        // Arc's table names letters lowercase; a recorded "C" is the same key.
        if case .character(let character) = key {
            self.key = .character(Character(character.lowercased()))
        } else {
            self.key = key
        }
        self.modifiers = modifiers
    }

    public init(of shortcut: ArcShortcut) {
        self.init(shortcut.key, shortcut.modifiers)
    }

    /// "⇧⌘C".
    public var display: String { modifiers.display + key.display }

    /// A chord the recorder accepts: ⌘, ⌃ or ⌥ with a key, or a function key.
    /// A bare or Shift-only letter would steal typing from every text field.
    public var isAssignable: Bool {
        if case .function = key { return true }
        return !modifiers.isDisjoint(with: [.command, .control, .option])
    }
}

/// What the user set for one binding: another chord, or none ("—").
public enum ShortcutOverride: Hashable, Sendable {
    case chord(ShortcutChord)
    case unbound
}

/// Why a chord is flagged with ⚠ in the Shortcuts list.
public enum ShortcutConflict: Hashable, Sendable {
    /// Another binding has the same chord; the first in menu-bar order wins.
    case binding(ArcShortcut)
    /// macOS takes the chord before any app (Mission Control, Spotlight, screenshots).
    case system(String)
    /// This binding's default chord is one the user gave another binding, so
    /// it has none (a key someone set before a new default came in keeps working).
    case displaced(by: ArcShortcut, chord: ShortcutChord)

    public var message: String {
        switch self {
        case .binding(let other): return "Also used by \(other.title)"
        case .system(let owner): return "macOS uses this shortcut for \(owner)"
        case .displaced(let other, let chord): return "No shortcut: you set \(chord.display) for \(other.title)"
        }
    }
}

/// One row of the Shortcuts pane's A–Z list.
public struct ShortcutListRow: Hashable, Sendable, Identifiable {
    public let shortcut: ArcShortcut
    /// The title shown: an alternate key (⌘← for Go Back) says so.
    public let title: String
    public let chord: ShortcutChord?
    public let isCustomized: Bool
    public let conflicts: [ShortcutConflict]

    public var id: String { shortcut.id }
    /// The chip's text: "—" when unbound.
    public var chipText: String { chord?.display ?? "—" }
}

/// The user's changes to Arc's default bindings (`ArcShortcuts.all`), kept in
/// user defaults. Every lookup the shell makes for a key (the menu bar's key
/// equivalents, `ShortcutRouter`) goes through `binding(for:)` and
/// `chord(for:)`, so a change applies everywhere at once.
public struct ShortcutOverrides: Equatable, Sendable {
    public static let defaultsKey = "rearc.shortcutOverrides"

    public private(set) var overrides: [String: ShortcutOverride]
    private let table: [ArcShortcut]
    /// Each binding's default chord by id: the command bar asks for a chord
    /// per command row on every keystroke.
    private let defaults: [String: ShortcutChord]

    public init(_ overrides: [String: ShortcutOverride] = [:], table: [ArcShortcut] = ArcShortcuts.all) {
        self.table = table
        let chords = Dictionary(table.map { ($0.id, ShortcutChord(of: $0)) }, uniquingKeysWith: { first, _ in first })
        defaults = chords
        self.overrides = overrides.filter { chords[$0.key] != nil }
    }

    public static func == (lhs: ShortcutOverrides, rhs: ShortcutOverrides) -> Bool {
        lhs.overrides == rhs.overrides && lhs.table == rhs.table
    }

    /// Reset All Shortcuts is enabled only with changes.
    public var hasChanges: Bool { !overrides.isEmpty }

    public func isCustomized(_ id: String) -> Bool { overrides[id] != nil }

    /// The chord that runs `id` now; nil when unbound or unknown. A chord the
    /// user set beats another binding's default: that binding then has none,
    /// so a key set on an earlier build is not taken by a new default
    /// (⇧⌘P for Peek at URL… in 1447).
    public func chord(for id: String) -> ShortcutChord? {
        switch overrides[id] {
        case .chord(let chord): return chord
        case .unbound: return nil
        case nil: return displacement(of: id) == nil ? defaults[id] : nil
        }
    }

    /// When the user gave `id`'s default chord to another binding and left
    /// `id` as it was: that binding, and the chord. `id` then has no chord.
    public func displacement(of id: String) -> (by: ArcShortcut, chord: ShortcutChord)? {
        guard overrides[id] == nil, let chord = defaults[id], let owner = userOwner(of: chord, excluding: id) else { return nil }
        return (owner, chord)
    }

    /// The binding, first in menu-bar order, the user gave `chord` to.
    public func userOwner(of chord: ShortcutChord, excluding id: String) -> ArcShortcut? {
        let owners = overrides.filter { $0.key != id && $0.value == .chord(chord) }
        guard !owners.isEmpty else { return nil }
        return table.first { owners[$0.id] != nil }
    }

    /// Records `chord` for `id`; the default chord clears the override, unless
    /// the user gave that chord to another binding (then it is kept as set, so
    /// the choice is not lost under the other binding's claim).
    public mutating func set(_ chord: ShortcutChord, for id: String) {
        guard let shortcut = table.first(where: { $0.id == id }) else { return }
        let isDefault = ShortcutChord(of: shortcut) == chord && userOwner(of: chord, excluding: id) == nil
        overrides[id] = isDefault ? nil : .chord(chord)
    }

    public mutating func unbind(_ id: String) {
        guard table.contains(where: { $0.id == id }) else { return }
        overrides[id] = .unbound
    }

    public mutating func reset(_ id: String) {
        overrides[id] = nil
    }

    public mutating func resetAll() {
        overrides = [:]
    }

    /// The binding a key press triggers now: the first in menu-bar order whose
    /// current chord it is (as AppKit resolves duplicate key equivalents).
    public func binding(for key: ShortcutKey, modifiers: ShortcutModifiers) -> ArcShortcut? {
        let pressed = ShortcutChord(key, modifiers)
        return table.first { chord(for: $0.id) == pressed }
    }

    /// The chord a menu item built with Arc's default `chord` should carry now.
    /// Keys no Arc binding has by default (ReArc's own) are kept; nil means the
    /// binding was unbound and the item gets no key equivalent.
    public func effectiveChord(forDefault chord: ShortcutChord) -> ShortcutChord? {
        guard let shortcut = ArcShortcuts.defaultBinding(for: chord, in: table) else { return chord }
        return self.chord(for: shortcut.id)
    }

    /// Why `chord` is flagged for `id`: other bindings with the same chord now,
    /// in menu-bar order, then a macOS owner.
    public func conflicts(for chord: ShortcutChord, excluding id: String) -> [ShortcutConflict] {
        var result: [ShortcutConflict] = table
            .filter { $0.id != id && self.chord(for: $0.id) == chord }
            .map { .binding($0) }
        if let owner = SystemShortcuts.owner(of: chord) { result.append(.system(owner)) }
        return result
    }

    /// The Shortcuts pane's list: A–Z by title, filtered by a feature name or
    /// a chord ("cmd shift c", "⇧⌘C", "copy").
    public func rows(matching query: String = "") -> [ShortcutListRow] {
        let rows = table.map { shortcut -> ShortcutListRow in
            let chord = chord(for: shortcut.id)
            var conflicts = chord.map { conflicts(for: $0, excluding: shortcut.id) } ?? []
            if let displaced = displacement(of: shortcut.id) {
                conflicts.append(.displaced(by: displaced.by, chord: displaced.chord))
            }
            return ShortcutListRow(
                shortcut: shortcut,
                title: Self.listTitle(for: shortcut),
                chord: chord,
                isCustomized: isCustomized(shortcut.id),
                conflicts: conflicts
            )
        }
        .filter { ShortcutSearch.matches($0, query: query) }
        return rows.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// Alternate keys (`goBack_Alternate`, `zoomIn_Plus`) share their item's title.
    static func listTitle(for shortcut: ArcShortcut) -> String {
        shortcut.id.contains("_") ? "\(shortcut.title) (Alternate)" : shortcut.title
    }

    // MARK: Persistence

    public static func load(from defaults: UserDefaults, table: [ArcShortcut] = ArcShortcuts.all) -> ShortcutOverrides {
        guard let stored = defaults.dictionary(forKey: defaultsKey) as? [String: String] else {
            return ShortcutOverrides(table: table)
        }
        return ShortcutOverrides(stored.compactMapValues(ShortcutOverride.init(token:)), table: table)
    }

    public func save(to defaults: UserDefaults) {
        if overrides.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(overrides.mapValues(\.token), forKey: Self.defaultsKey)
        }
    }
}

extension ArcShortcuts {
    /// The binding whose default chord this is, first in menu-bar order.
    static func defaultBinding(for chord: ShortcutChord, in table: [ArcShortcut]) -> ArcShortcut? {
        table.first { $0.key == chord.key && $0.modifiers == chord.modifiers }
    }
}

/// Chords macOS keeps for itself with its default settings. Arc's ⚠ on ⌃1…⌃9
/// matches Mission Control's Switch to Desktop keys.
enum SystemShortcuts {
    static func owner(of chord: ShortcutChord) -> String? {
        switch (chord.key, chord.modifiers) {
        case (.character(let c), .control) where ("1" ... "9").contains(c): return "Switch to Desktop \(c)"
        case (.leftArrow, .control), (.rightArrow, .control): return "moving between Spaces"
        case (.upArrow, .control): return "Mission Control"
        case (.downArrow, .control): return "App Exposé"
        case (.space, .command): return "Spotlight"
        case (.space, [.control, .command]): return "the Character Viewer"
        case (.tab, .command), (.tab, [.shift, .command]): return "the app switcher"
        case (.character("3"), [.shift, .command]), (.character("4"), [.shift, .command]),
             (.character("5"), [.shift, .command]): return "screenshots"
        case (.character("q"), [.control, .command]): return "Lock Screen"
        default: return nil
        }
    }
}

/// The Shortcuts pane's search: words match the title; modifier names and
/// symbols match the chord.
enum ShortcutSearch {
    private static let modifierWords: [String: ShortcutModifiers] = [
        "cmd": .command, "command": .command, "⌘": .command,
        "shift": .shift, "⇧": .shift,
        "opt": .option, "option": .option, "alt": .option, "⌥": .option,
        "ctrl": .control, "control": .control, "⌃": .control,
    ]

    static func matches(_ row: ShortcutListRow, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if row.title.localizedCaseInsensitiveContains(trimmed) { return true }
        guard let chord = row.chord else { return false }
        // "cmd shift c", "ctrl+tab" or "⇧⌘C": with a key, exactly that chord;
        // modifiers alone ("cmd shift") list every chord holding them.
        var wanted: ShortcutModifiers = []
        var rest = ""
        for part in trimmed.lowercased().split(whereSeparator: { $0 == " " || $0 == "+" }) {
            var word = Substring(part)
            while let first = word.first, let modifier = modifierWords[String(first)] {
                wanted.insert(modifier)
                word = word.dropFirst()
            }
            if let modifier = modifierWords[String(word)] { wanted.insert(modifier) } else { rest += word }
        }
        guard !wanted.isEmpty else { return false }
        guard !rest.isEmpty else { return chord.modifiers.isSuperset(of: wanted) }
        return chord.modifiers == wanted && (rest == chord.key.token || rest == chord.key.display.lowercased())
    }
}

// MARK: Stored form

extension ShortcutOverride {
    /// "-" for unbound, else modifiers then the key: "shift+command+c", "control+tab".
    var token: String {
        switch self {
        case .unbound: return "-"
        case .chord(let chord): return chord.token
        }
    }

    init?(token: String) {
        if token == "-" {
            self = .unbound
        } else if let chord = ShortcutChord(token: token) {
            self = .chord(chord)
        } else {
            return nil
        }
    }
}

extension ShortcutChord {
    private static let modifierNames: [(String, ShortcutModifiers)] = [
        ("control", .control), ("option", .option), ("shift", .shift), ("command", .command),
    ]

    var token: String {
        (Self.modifierNames.filter { modifiers.contains($0.1) }.map(\.0) + [key.token]).joined(separator: "+")
    }

    init?(token: String) {
        // A layout with an unshifted "+" stores "command++".
        let plusKey = token == "+" || token.hasSuffix("++")
        var parts = (plusKey ? String(token.dropLast(2)) : token).split(separator: "+").map(String.init)
        guard let key = plusKey ? .character("+") : parts.popLast().flatMap(ShortcutKey.init(token:)) else { return nil }
        var modifiers: ShortcutModifiers = []
        for part in parts {
            guard let modifier = Self.modifierNames.first(where: { $0.0 == part })?.1 else { return nil }
            modifiers.insert(modifier)
        }
        self.init(key, modifiers)
    }
}

extension ShortcutKey {
    var token: String {
        switch self {
        case .character(let character): return String(character)
        case .leftArrow: return "left"
        case .rightArrow: return "right"
        case .upArrow: return "up"
        case .downArrow: return "down"
        case .tab: return "tab"
        case .escape: return "escape"
        case .space: return "space"
        case .function(let number): return "f\(number)"
        }
    }

    init?(token: String) {
        switch token {
        case "left": self = .leftArrow
        case "right": self = .rightArrow
        case "up": self = .upArrow
        case "down": self = .downArrow
        case "tab": self = .tab
        case "escape": self = .escape
        case "space": self = .space
        default:
            if token.count > 1, token.hasPrefix("f"), let number = Int(token.dropFirst()), (1 ... 20).contains(number) {
                self = .function(number)
            } else if token.count == 1, let character = token.first {
                self = .character(character)
            } else {
                return nil
            }
        }
    }
}
