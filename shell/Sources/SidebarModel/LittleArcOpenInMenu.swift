import Foundation

/// The ⌄ menu beside Little Darni's "Open in <Space>": every other space, in
/// every profile, grouped by profile with the window's own profile first.
/// The view only draws what this returns.
public enum LittleArcOpenInMenu {
    /// What choosing a space does. It follows storage, not listing: a
    /// container's space is listed under its profile and is another session.
    public enum Kind: Equatable, Sendable {
        /// A space of the window's own session: the page becomes a tab there
        /// (`promoteLittleArcToTab`).
        case move
        /// A space of another session (another profile, or a container): the
        /// address opens afresh as a tab there (`reopenLittleArcAsTab`). The
        /// page, its cookies and its sign-ins stay where they are (S-01).
        case reopen
    }

    public struct Entry: Identifiable, Equatable, Sendable {
        public let spaceID: Space.ID
        /// The item's words: the space's name, marked "(Container)" as Move to Space marks it.
        public let title: String
        public let theme: SpaceTheme
        public let kind: Kind

        public var id: Space.ID { spaceID }
    }

    public struct Section: Identifiable, Equatable, Sendable {
        public let profileID: Profile.ID
        public let profileName: String
        /// The profile's name, when the menu has to say whose spaces these
        /// are: more than one profile is listed, or the only one listed is not
        /// the window's own.
        public let header: String?
        public let entries: [Entry]

        public var id: Profile.ID { profileID }
    }

    /// What choosing `spaceID` does for Little Darni window `windowID`, or nil
    /// when the window is not open or the space cannot be shown (it is gone or
    /// archived). The shell asks this again when the choice is made, so a menu
    /// drawn earlier never decides how a page crosses sessions.
    public static func kind(store: SidebarStore, windowID: LittleArcWindow.ID, spaceID: Space.ID) -> Kind? {
        guard let window = store.littleArcWindow(withID: windowID),
              let space = store.listedSpace(withID: spaceID) else { return nil }
        return kind(of: space, for: window)
    }

    private static func kind(of space: Space, for window: LittleArcWindow) -> Kind {
        space.profileID == window.profileID ? .move : .reopen
    }

    /// The menu: each profile's spaces as its strip lists them (its
    /// containers' included), without the space the main button names. A
    /// profile left with nothing to offer has no section. Empty when there is
    /// no other space at all, and then the view draws no ⌄.
    public static func sections(store: SidebarStore, windowID: LittleArcWindow.ID) -> [Section] {
        guard let window = store.littleArcWindow(withID: windowID) else { return [] }
        let target = store.littleArcTargetSpace(for: windowID)?.id
        let own = store.owningProfileID(of: window.profileID)
        // The list Move to Profile is made from, with the window's own profile first.
        let listed = store.listedSpacesByProfile(without: target)
        let sections: [(profile: Profile, entries: [Entry])] = (listed.filter { $0.profile.id == own } + listed.filter { $0.profile.id != own })
            .map { group in
                (group.profile, group.spaces.map { space in
                    Entry(spaceID: space.id, title: store.menuTitle(forSpace: space), theme: space.theme,
                          kind: kind(of: space, for: window))
                })
            }
        let named = sections.count > 1 || sections.first.map { $0.profile.id != own } ?? false
        return sections.map {
            Section(profileID: $0.profile.id, profileName: $0.profile.name, header: named ? $0.profile.name : nil, entries: $0.entries)
        }
    }
}
