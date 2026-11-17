import Foundation

/// Where links opened from other apps go (Arc
/// `openExternalLinksInLittleBrowserEnabled`, PEEK-LITTLE-BROWSER §2.1).
public enum ExternalLinkDestination: String, CaseIterable, Codable, Sendable {
    /// A disposable Little Arc window, so the sidebar stays tidy (Arc's default).
    case littleArc
    /// A new Today tab in the space of the window last in front.
    case activeSpace

    public var title: String {
        switch self {
        case .littleArc: return "Open External Links in Little ReArc"
        case .activeSpace: return "Open External Links in the Current Space"
        }
    }

    /// The External Links menu's wording.
    public var menuTitle: String {
        switch self {
        case .littleArc: return "Open in Little ReArc"
        case .activeSpace: return "Open in the Current Space"
        }
    }

    static let defaultsKey = "ReArcExternalLinkDestination"

    public static func load(from defaults: UserDefaults) -> ExternalLinkDestination {
        defaults.string(forKey: defaultsKey).flatMap(ExternalLinkDestination.init(rawValue:)) ?? .littleArc
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// Decides what a link from another app does. Only web pages (and local
/// files) are admitted, through the same URL policy as the command bar. As
/// in Arc, a link meant for Little ReArc always gets a Little ReArc: the one
/// still showing that page, else a new one, never a tab in a space (a Little
/// ReArc moved into a space is a tab from then on). Links for a space focus
/// a page already open there instead of opening it twice.
public enum ExternalLinkRouting {

    public enum Route: Equatable, Sendable {
        case littleArc(URL, profileID: Profile.ID)
        /// A Little ReArc window still showing the page.
        case focusLittleArc(LittleArcWindow.ID)
        case newTab(URL, spaceID: Space.ID)
        case focusTab(Tab.ID)
        case rejected
    }

    /// Air Traffic Control rules come first: the first enabled rule whose
    /// space or profile exists decides (a page already open in that space, or
    /// in a Little ReArc of that profile, is focused). Otherwise `destination`:
    /// Little ReArc as above, or the current space, which focuses a page
    /// already open in the active profile.
    public static func route(
        _ url: URL,
        destination: ExternalLinkDestination,
        in store: SidebarStore,
        engine: NavigationURLPolicy.EngineSchemes = [],
        rules: LinkRoutingState = LinkRoutingState()
    ) -> Route {
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https", "file"].contains(scheme),
              NavigationURLPolicy.allows(url, engine: engine) else { return .rejected }
        if let rule = rules.firstMatch(for: url, in: store) {
            switch rule.destination {
            case .space(let spaceID):
                let open = store.displayTabs(in: spaceID).first { $0.url.absoluteString == url.absoluteString }
                return open.map { .focusTab($0.id) } ?? .newTab(url, spaceID: spaceID)
            case .littleArc(let profileID):
                return littleArc(url, profileID: profileID, in: store)
            }
        }
        switch destination {
        case .littleArc:
            return littleArc(url, profileID: store.activeProfileID, in: store)
        case .activeSpace:
            if let open = openTab(matching: url, in: store) { return .focusTab(open) }
            return .newTab(url, spaceID: store.activeSpaceID)
        }
    }

    /// The live Little ReArc of `profileID` showing `url` (the most recently
    /// used), else a new one.
    static func littleArc(_ url: URL, profileID: Profile.ID, in store: SidebarStore) -> Route {
        let target = url.absoluteString
        let open = store.littleArcLiveWindows
            .filter { $0.profileID == profileID && $0.url.absoluteString == target }
            .max { $0.lastActiveAt < $1.lastActiveAt }
        return open.map { .focusLittleArc($0.id) } ?? .littleArc(url, profileID: profileID)
    }

    /// A tab of the active profile (favorites included) already showing `url`.
    static func openTab(matching url: URL, in store: SidebarStore) -> Tab.ID? {
        let target = url.absoluteString
        let favorites = store.favorites(in: store.activeProfileID)
        let spaceTabs = store.spaces(in: store.activeProfileID).flatMap { store.displayTabs(in: $0.id) }
        return (favorites + spaceTabs).first { $0.url.absoluteString == target }?.id
    }
}
