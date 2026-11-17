import Foundation

/// A tab group's colour: Chrome's nine, in Chrome's order.
public enum TabGroupColor: String, CaseIterable, Sendable {
    case grey, blue, red, yellow, green, pink, purple, cyan, orange

    public var title: String {
        switch self {
        case .grey: return "Grey"
        case .blue: return "Blue"
        case .red: return "Red"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .pink: return "Pink"
        case .purple: return "Purple"
        case .cyan: return "Cyan"
        case .orange: return "Orange"
        }
    }

    /// The header's fill and the bar beside the group's tabs: Chrome's
    /// tab-group colours, the lighter set on a dark sidebar.
    public func fill(dark: Bool) -> SpaceColor {
        let hex: String
        switch self {
        case .grey: hex = dark ? "#DADCE0" : "#5F6368"
        case .blue: hex = dark ? "#8AB4F8" : "#1A73E8"
        case .red: hex = dark ? "#F28B82" : "#D93025"
        case .yellow: hex = dark ? "#FDD663" : "#F9AB00"
        case .green: hex = dark ? "#81C995" : "#188038"
        case .pink: hex = dark ? "#FF8BCB" : "#D01884"
        case .purple: hex = dark ? "#C58AF9" : "#A142F4"
        case .cyan: hex = dark ? "#78D9EC" : "#007B83"
        case .orange: hex = dark ? "#FCAD70" : "#FA903E"
        }
        return SpaceColor(hex: hex) ?? SpaceColor(red: 0.5, green: 0.5, blue: 0.5)
    }

    /// Whether the header's name and icon are dark on `fill(dark:)`, or
    /// white: whichever has the greater contrast with the fill (dark ink wins
    /// above a relative luminance of about 0.18), as the page-coloured
    /// toolbar decides (`PageColor.prefersLightInk`).
    public func inkIsDark(dark: Bool) -> Bool {
        let color = fill(dark: dark)
        return !PageColor(red: color.red, green: color.green, blue: color.blue).prefersLightInk
    }

    /// The colour a new group takes: the first one no group in `used` has,
    /// else the least used.
    public static func next(after used: [TabGroupColor]) -> TabGroupColor {
        let counts = Dictionary(used.map { ($0, 1) }, uniquingKeysWith: +)
        return allCases.min { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? .grey
    }
}

extension TabGroupColor: Codable {
    /// A colour a newer ReArc added reads as grey instead of failing the file.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TabGroupColor(rawValue: raw) ?? .grey
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A tab group (Chrome's tab groups): a named, coloured, ordered set of tabs
/// kept once per profile. Spaces of that profile show it through a
/// `TabGroupReference` in their pinned or Today section; every reference
/// shows the same tabs, so an edit made in one space is seen in all.
///
/// A group belongs to one profile because its tabs' pages do: a tab has one
/// engine, with one profile's cookies, whichever space shows it.
public struct TabGroup: Identifiable, Equatable, Codable {
    public let id: UUID
    public var profileID: Profile.ID
    /// May be empty (Chrome's unnamed group); `displayName` is what to show.
    public var name: String
    public var color: TabGroupColor
    /// In order. Group tabs are `today` tabs: closing one removes it from
    /// the group, and it never auto-archives while it is in a group.
    public var tabs: [Tab]

    public init(id: UUID = UUID(), profileID: Profile.ID, name: String = "", color: TabGroupColor = .grey, tabs: [Tab] = []) {
        self.id = id
        self.profileID = profileID
        self.name = name
        self.color = color
        self.tabs = tabs
    }

    enum CodingKeys: String, CodingKey { case id, profileID, name, color, tabs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        profileID = try c.decode(UUID.self, forKey: .profileID)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = try c.decodeIfPresent(TabGroupColor.self, forKey: .color) ?? .grey
        tabs = TabGroup.normalized(try c.decodeIfPresent([Tab].self, forKey: .tabs) ?? [])
    }

    /// The name, or what an unnamed group is called ("3 Tabs").
    public var displayName: String {
        name.isEmpty ? TabGroup.countText(tabs.count) : name
    }

    public static func countText(_ count: Int) -> String {
        count == 1 ? "1 Tab" : "\(count) Tabs"
    }

    /// Group tabs as the store keeps them: `today` tabs, one per id, ordered by rank.
    static func normalized(_ tabs: [Tab]) -> [Tab] {
        var seen = Set<UUID>()
        let unique = tabs.filter { seen.insert($0.id).inserted }.map { tab -> Tab in
            var tab = tab
            tab.setKind(.today)
            return tab
        }
        guard unique.contains(where: { $0.sortRank.isEmpty }) || Set(unique.map(\.sortRank)).count != unique.count else {
            return RankedSortable.sortedTabs(unique)
        }
        // No usable ranks (a hand-edited or synced list): the list's order is the order.
        let ranks = LexoRank.initialSequence(count: unique.count)
        return zip(unique, ranks).map { tab, rank in
            var tab = tab
            tab.sortRank = rank
            return tab
        }
    }
}

/// A space's row for a tab group: where the group sits in that space's
/// pinned or Today section. `group` mirrors the profile's one record
/// (`SidebarStore.tabGroupsByID`); the store rewrites it in every space
/// whenever the group changes, so the sidebar's tree, outline and
/// observation see a group's tabs the way they see a folder's children.
public struct TabGroupReference: Identifiable, Equatable, Codable {
    /// The row's id, different in each space.
    public let id: UUID
    public var sortRank: String
    public var group: TabGroup

    public var groupID: TabGroup.ID { group.id }

    public init(id: UUID = UUID(), sortRank: String = "", group: TabGroup) {
        self.id = id
        self.sortRank = sortRank
        self.group = group
    }
}

extension TabGroupReference: SidebarRanked {}

/// Settings › General › Tab groups. Off (the default): nothing offers to make
/// a group, and the command bar lists none. Groups made while it was on stay
/// in the sidebar and keep working.
public enum TabGroupsPreference {
    public static let defaultsKey = "rearc.tabGroupsEnabled"

    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    public static func setEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}

/// Delete Group's confirmation (Chrome's "Delete tab group?").
public enum TabGroupDeleteConfirmation {
    /// "Don't ask again" was ticked.
    public static let defaultsKey = "rearc.tabGroupDeleteWithoutAsking"

    public static func asks(in defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: defaultsKey)
    }

    public static func setAsks(_ asks: Bool, in defaults: UserDefaults) {
        defaults.set(!asks, forKey: defaultsKey)
    }

    public static let title = "Delete tab group?"
    public static let confirmTitle = "Delete Group"
    public static let cancelTitle = "Cancel"
    public static let dontAskTitle = "Don't ask again"

    /// `spaceCount`: the spaces that show the group now. `syncOn`: iCloud
    /// sync carries the delete to the person's other Macs.
    public static func message(groupName: String, tabCount: Int, spaceCount: Int, syncOn: Bool = false) -> String {
        let named = groupName.isEmpty ? "This group" : "“\(groupName)”"
        let spaces: String
        switch spaceCount {
        case 0: spaces = "\(named) is deleted."
        case 1: spaces = "\(named) is removed from the space that shows it."
        default: spaces = "\(named) is removed from every space that shows it (\(spaceCount) spaces)."
        }
        let tabs: String
        switch tabCount {
        case 0: tabs = ""
        case 1: tabs = " Its tab closes and goes to the Archive."
        default: tabs = " Its \(tabCount) tabs close and go to the Archive."
        }
        return spaces + tabs + (syncOn ? " It is deleted on your other Macs too." : "")
    }
}

/// Tab groups as `sidebar.json` keeps them, under their own key
/// (`SidebarSnapshot.tabGroups`): the groups once each, and which spaces
/// show them where. They are not in the space trees' tables, so a build
/// from before tab groups reads the rest of the file as it always did.
public struct TabGroupsSnapshot: Equatable, Codable {
    /// The format of this key, apart from the file's `schemaVersion`.
    public static let currentVersion = 1

    public struct Reference: Equatable, Codable {
        public var id: UUID
        public var groupID: TabGroup.ID
        public var spaceID: Space.ID
        /// In the space's pinned section, else Today.
        public var pinned: Bool
        public var sortRank: String

        public init(id: UUID, groupID: TabGroup.ID, spaceID: Space.ID, pinned: Bool, sortRank: String) {
            self.id = id
            self.groupID = groupID
            self.spaceID = spaceID
            self.pinned = pinned
            self.sortRank = sortRank
        }
    }

    public var version: Int
    public var groups: [TabGroup]
    public var references: [Reference]

    public var isEmpty: Bool { groups.isEmpty && references.isEmpty }

    public init(groups: [TabGroup] = [], references: [Reference] = []) {
        self.version = TabGroupsSnapshot.currentVersion
        self.groups = groups
        self.references = references
    }

    enum CodingKeys: String, CodingKey { case version, groups, references }

    /// One group or row that does not read is left out; the others load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        groups = (try c.decodeIfPresent([Lenient<TabGroup>].self, forKey: .groups) ?? []).compactMap(\.value)
        references = (try c.decodeIfPresent([Lenient<Reference>].self, forKey: .references) ?? []).compactMap(\.value)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(TabGroupsSnapshot.currentVersion, forKey: .version)
        try c.encode(groups, forKey: .groups)
        try c.encode(references, forKey: .references)
    }

    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }
}

/// What a build from before tab groups sees of them in `sidebar.json`.
///
/// Such a build ignores the `tabGroups` key and writes the file back without
/// it, so a group saved only there would be gone after one launch of an
/// older ReArc. Each group is therefore also written as a pinned folder
/// holding copies of its tabs, in the first space that shows it (else the
/// first space of its profile): an older build shows the folder, and keeps
/// it. This build takes the copies out again on reading the file, so they
/// are never in a snapshot in memory, the store, or sync.
///
/// The copies have ids of their own (`id(for:)`), so an older build that
/// syncs the folder writes new records and leaves the group's alone.
enum TabGroupShadow {
    private static let mask: [UInt8] = [0x7A, 0xB6, 0x3D, 0x91, 0x5C, 0xE4, 0x00, 0x00, 0x00, 0x2F, 0xC8, 0x17, 0xA3, 0x6E, 0xD5, 0x49]

    /// The copy's id: the original's with fixed bits flipped (the version and
    /// variant bits are left alone).
    static func id(for original: UUID) -> UUID {
        var bytes = withUnsafeBytes(of: original.uuid) { Array($0) }
        for index in bytes.indices { bytes[index] ^= mask[index] }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    struct Tables {
        var spaceContainers: [Space.ID: SidebarSnapshot.SpaceContainerBundle]
        var foldersByID: [UUID: SidebarFolderRecord]
        var tabsByID: [UUID: Tab]
    }

    /// The snapshot's tables with a folder for each group added.
    static func adding(to snapshot: SidebarSnapshot) -> Tables {
        var tables = Tables(spaceContainers: snapshot.spaceContainers, foldersByID: snapshot.foldersByID, tabsByID: snapshot.tabsByID)
        func rank(of id: UUID) -> String {
            tables.tabsByID[id]?.sortRank ?? tables.foldersByID[id]?.sortRank
                ?? snapshot.splitsByID[id]?.sortRank ?? snapshot.easelRefsByID[id]?.sortRank ?? ""
        }
        for group in snapshot.tabGroups.groups {
            let rows = snapshot.tabGroups.references.filter { $0.groupID == group.id && tables.spaceContainers[$0.spaceID] != nil }
            guard let home = rows.first?.spaceID
                ?? snapshot.spaces.first(where: { $0.profileID == group.profileID && tables.spaceContainers[$0.id] != nil })?.id,
                  var bundle = tables.spaceContainers[home] else { continue }
            let folderID = id(for: group.id)
            guard tables.foldersByID[folderID] == nil else { continue }
            var childIDs: [UUID] = []
            for tab in group.tabs {
                var copy = Tab(
                    id: id(for: tab.id), kind: .pinned, title: tab.title, url: tab.url, faviconToken: tab.faviconToken,
                    isUnread: tab.isUnread, sortRank: tab.sortRank, customTitle: tab.customTitle, lastActiveAt: tab.lastActiveAt,
                    customIcon: tab.customIcon
                )
                copy.customTitleIsAutomatic = tab.customTitleIsAutomatic
                guard tables.tabsByID[copy.id] == nil else { continue }
                tables.tabsByID[copy.id] = copy
                childIDs.append(copy.id)
            }
            // Where the group's row is when it is pinned there, else after the space's pins.
            let pinnedRow = rows.first(where: { $0.spaceID == home && $0.pinned })
            let sortRank = pinnedRow?.sortRank ?? LexoRank.after(bundle.pinned.childIDs.map(rank(of:)).max())
            tables.foldersByID[folderID] = SidebarFolderRecord(id: folderID, title: group.displayName, childIDs: childIDs, sortRank: sortRank)
            bundle.pinned.childIDs.append(folderID)
            tables.spaceContainers[home] = bundle
        }
        return tables
    }

    /// Takes the folders `adding(to:)` wrote out of a snapshot just read.
    static func remove(from snapshot: inout SidebarSnapshot) {
        var ids = Set<UUID>()
        for group in snapshot.tabGroups.groups {
            let folderID = id(for: group.id)
            guard let folder = snapshot.foldersByID.removeValue(forKey: folderID) else { continue }
            ids.insert(folderID)
            for child in folder.childIDs where snapshot.foldersByID[child] == nil && snapshot.splitsByID[child] == nil {
                snapshot.tabsByID[child] = nil
                ids.insert(child)
            }
        }
        guard !ids.isEmpty else { return }
        for (spaceID, var bundle) in snapshot.spaceContainers {
            bundle.pinned.childIDs.removeAll { ids.contains($0) }
            bundle.unpinned.childIDs.removeAll { ids.contains($0) }
            snapshot.spaceContainers[spaceID] = bundle
        }
        snapshot.expandedFolderIDs.removeAll { ids.contains($0) }
    }
}
