import Foundation

/// The ⌄ menu beside Little Darni's "Open in <Space>": every other space, in
/// every profile, grouped by profile with the window's own profile first.
/// The view only draws what this returns, and the shell asks `choice` what a
/// row does when it is chosen.
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
        /// False for a `.reopen` when the window's address cannot leave its
        /// session (`canCrossSessions`): the row is drawn disabled, and the
        /// menu ends with `note`. A `.move` is always enabled.
        public let isEnabled: Bool

        public var id: Space.ID { spaceID }
    }

    public struct Section: Identifiable, Equatable, Sendable {
        public let profileID: Profile.ID
        public let profileName: String
        /// Whose spaces these are, when the menu has to say: more than one
        /// profile is listed, the only one listed is not the window's own, or
        /// the window is a container's. From a container's window its
        /// profile's spaces are all another session, and the header says so
        /// (`outsideContainerHeader`, OI-01).
        public let header: String?
        public let entries: [Entry]

        public var id: Profile.ID { profileID }
    }

    /// A `.reopen` waiting for its answer (OI-01). The address is the one the
    /// window showed when the row was chosen. It is what opens on Yes, however
    /// far the page has gone since (OI-03).
    public struct Question: Equatable, Sendable {
        public let windowID: LittleArcWindow.ID
        public let spaceID: Space.ID
        public let url: URL
        /// The address's host for the question's words, as trusted UI shows a
        /// host: a long one keeps the site's own name (`PageOrigin.shortenedHost`).
        public let host: String

        public init(windowID: LittleArcWindow.ID, spaceID: Space.ID, url: URL, host: String) {
            self.windowID = windowID
            self.spaceID = spaceID
            self.url = url
            self.host = host
        }
    }

    /// What choosing a row leads to.
    public enum Choice: Equatable, Sendable {
        /// A space of the window's own session: the page goes there, unasked.
        case move
        /// A space of another session and a web address: ask first.
        case ask(Question)
        /// A space of another session and any other address: nothing opens,
        /// the window stays, and the shell says `webOnlyMessage`.
        case refuse
    }

    /// Why a row is disabled, and the toast when a refused row is chosen all
    /// the same (the page changed its address while the menu was up).
    public static let webOnlyMessage = "Only web pages can open in another profile or container"

    /// The header over a profile's spaces in the menu of a window that
    /// belongs to one of that profile's containers.
    public static func outsideContainerHeader(_ profileName: String) -> String {
        "\(profileName) (outside this container)"
    }

    /// Whether `url` may open in another session (OI-02): a web address only,
    /// http or https with a host and no user name or password in it. A `blob:`
    /// address belongs to the first session's storage, an extension's page to
    /// the first profile's extensions, a `data:` address carries the page
    /// itself, and `file:`, `rearc:` and the engine's own pages are not a
    /// page's to hand on. Within one session nothing of this applies: the
    /// page itself moves (`promoteLittleArcToTab`).
    public static func canCrossSessions(_ url: URL) -> Bool {
        NavigationURLPolicy.isImportableWebPage(url)
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

    /// What choosing `spaceID` leads to for a window showing `url`, or nil
    /// when the window is not open or the space cannot be shown. The shell
    /// asks this when the row is chosen, with the address the window shows
    /// then, and keeps the `Question` until it is answered.
    public static func choice(store: SidebarStore, windowID: LittleArcWindow.ID, spaceID: Space.ID, url: URL) -> Choice? {
        guard let kind = kind(store: store, windowID: windowID, spaceID: spaceID) else { return nil }
        guard kind == .reopen else { return .move }
        guard canCrossSessions(url), let host = url.host(), !host.isEmpty else { return .refuse }
        return .ask(Question(windowID: windowID, spaceID: spaceID, url: url, host: PageOrigin.shortenedHost(host)))
    }

    /// The menu: each profile's spaces as its strip lists them (its
    /// containers' included), without the space the main button names. A
    /// profile left with nothing to offer has no section. Empty when there is
    /// no other space at all, and then the view draws no ⌄. `url` is the
    /// address the window shows (its record's, when nil): rows that would
    /// take it to another session are disabled unless it is a web address.
    public static func sections(store: SidebarStore, windowID: LittleArcWindow.ID, url: URL? = nil) -> [Section] {
        guard let window = store.littleArcWindow(withID: windowID) else { return [] }
        let target = store.littleArcTargetSpace(for: windowID)?.id
        let own = store.owningProfileID(of: window.profileID)
        // A container has one space, the main button's, so from its window
        // every space its profile lists is another session.
        let inContainer = own != window.profileID
        let crosses = canCrossSessions(url ?? window.url)
        let listed = store.listedProfiles
        let sections: [(profile: Profile, entries: [Entry])] = (listed.filter { $0.id == own } + listed.filter { $0.id != own })
            .compactMap { profile in
                let entries = store.spaces(listedIn: profile.id).filter { $0.id != target }.map { space in
                    let kind = kind(of: space, for: window)
                    return Entry(spaceID: space.id, title: store.menuTitle(forSpace: space), theme: space.theme,
                                 kind: kind, isEnabled: kind == .move || crosses)
                }
                return entries.isEmpty ? nil : (profile, entries)
            }
        let named = sections.count > 1 || sections.first.map { $0.profile.id != own } ?? false
        return sections.map { section in
            let crossesFromContainer = inContainer && section.profile.id == own && section.entries.allSatisfy { $0.kind == .reopen }
            let header = crossesFromContainer ? outsideContainerHeader(section.profile.name) : named ? section.profile.name : nil
            return Section(profileID: section.profile.id, profileName: section.profile.name, header: header, entries: section.entries)
        }
    }

    /// The line that ends the menu when it has disabled rows, saying why.
    public static func note(for sections: [Section]) -> String? {
        sections.contains { $0.entries.contains { !$0.isEnabled } } ? webOnlyMessage : nil
    }
}
