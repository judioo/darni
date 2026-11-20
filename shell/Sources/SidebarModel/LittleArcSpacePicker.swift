import Foundation

/// The rows of Little Darni's space picker (Arc's "Search Spaces…" panel
/// under Open in ⌄): `LittleArcOpenInMenu.sections` filtered by what is typed,
/// laid out as the panel draws them, and which row ↑ ↓ and Return act on.
/// The panel only draws this and tells the shell which space was chosen; what
/// the choice does is still `LittleArcOpenInMenu.choice`'s to say.
public enum LittleArcSpacePicker {
    public enum Row: Identifiable, Equatable, Sendable {
        /// A profile's name over its spaces.
        case header(Profile.ID, String)
        case space(LittleArcOpenInMenu.Entry)
        /// Why some rows are disabled, as the last line.
        case note(String)
        /// Nothing matches what was typed.
        case empty(String)

        public var id: String {
            switch self {
            case .header(let profile, _): return "header-\(profile.uuidString)"
            case .space(let entry): return Self.id(forSpace: entry.spaceID)
            case .note: return "note"
            case .empty: return "empty"
            }
        }

        public static func id(forSpace id: Space.ID) -> String { "space-\(id.uuidString)" }

        public var entry: LittleArcOpenInMenu.Entry? {
            if case .space(let entry) = self { return entry }
            return nil
        }
    }

    public static let placeholder = "Search Spaces…"
    public static let nothingFound = "No spaces found"

    /// Whether `title` matches what was typed: every word of it, in any
    /// order, whatever its case or accents. Nothing typed matches everything.
    public static func matches(_ title: String, query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy {
            title.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// The sections with only the spaces that match. A section with none is
    /// dropped, and its header with it.
    public static func filtered(_ sections: [LittleArcOpenInMenu.Section], query: String) -> [LittleArcOpenInMenu.Section] {
        sections.compactMap { section in
            let entries = section.entries.filter { matches($0.title, query: query) }
            guard !entries.isEmpty else { return nil }
            return LittleArcOpenInMenu.Section(profileID: section.profileID, profileName: section.profileName,
                                               header: section.header, entries: entries)
        }
    }

    /// The panel's rows under its search field. The reason line shows only
    /// while a disabled row does.
    public static func rows(for sections: [LittleArcOpenInMenu.Section], query: String = "") -> [Row] {
        let shown = filtered(sections, query: query)
        guard !shown.isEmpty else { return [.empty(nothingFound)] }
        var rows: [Row] = []
        for section in shown {
            if let header = section.header { rows.append(.header(section.profileID, header)) }
            rows += section.entries.map(Row.space)
        }
        if let note = LittleArcOpenInMenu.note(for: shown) { rows.append(.note(note)) }
        return rows
    }

    /// The spaces Return can choose, in order: disabled rows are passed over.
    public static func choosable(_ rows: [Row]) -> [Space.ID] {
        rows.compactMap { $0.entry.flatMap { $0.isEnabled ? $0.spaceID : nil } }
    }

    /// The row highlighted when the panel opens or the search changes: the
    /// one already highlighted while it is still there, else the first that
    /// can be chosen.
    public static func highlight(_ current: Space.ID?, in rows: [Row]) -> Space.ID? {
        let ids = choosable(rows)
        if let current, ids.contains(current) { return current }
        return ids.first
    }

    /// ↓ (`offset` 1) and ↑ (-1) from `current`, stopping at the ends as a
    /// menu does. From nothing, ↓ takes the first row and ↑ the last.
    public static func highlight(_ current: Space.ID?, movedBy offset: Int, in rows: [Row]) -> Space.ID? {
        let ids = choosable(rows)
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return offset < 0 ? ids.last : ids.first }
        return ids[min(max(index + offset, 0), ids.count - 1)]
    }
}
