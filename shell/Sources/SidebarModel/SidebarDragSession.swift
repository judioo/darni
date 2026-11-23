import Foundation

/// The sidebar drag under way. There is one pointer, so there is one drag for
/// the whole app, whichever window it began in, and a drop target in any
/// window reads the dragged row from here.
///
/// A window's own view state could not serve another window: there it was
/// nil, and the drop fell back to reading the row's id from the drag itself,
/// which a SwiftUI drop target cannot do for the sidebar's private type
/// (`SidebarDragPayload.load`). The drop was accepted and then moved nothing
/// (owner, 2026-11-23: a tab dragged from one window's sidebar to another's).
public struct SidebarDragSession: Equatable, Sendable {
    public var itemID: UUID
    /// The window the drag began in; nil when it is not known (a bare view).
    public var sourceWindow: SidebarWindowID?
    /// The other windows the drag has been over.
    public private(set) var reached: Set<SidebarWindowID> = []

    public init(itemID: UUID, sourceWindow: SidebarWindowID?) {
        self.itemID = itemID
        self.sourceWindow = sourceWindow
    }

    /// Whether the drag began in `window`. An unknown window on either side
    /// counts as the same one, as it did before windows were told apart.
    public func began(in window: SidebarWindowID?) -> Bool {
        guard let window, let sourceWindow else { return true }
        return window == sourceWindow
    }

    /// Whether `window`'s sidebar shows the drag: its drop areas open and
    /// every row is a drop target. The window the drag began in does from the
    /// start. Another one does once the pointer has been over it, and then
    /// until the drag ends, so a drag that stays in its own window changes
    /// nothing in the others.
    public func isShown(in window: SidebarWindowID?) -> Bool {
        guard let window, !began(in: window) else { return true }
        return reached.contains(window)
    }

    /// The pointer is over `window`. True when that is news.
    @discardableResult
    public mutating func reach(_ window: SidebarWindowID?) -> Bool {
        guard let window, !began(in: window) else { return false }
        return reached.insert(window).inserted
    }
}

/// Where a sidebar drop puts its rows.
public enum SidebarDropPlacement: Equatable {
    /// Before or after a row, in the container that holds it.
    case beside(UUID, after: Bool)
    /// At `index` of a container (the index it has once it is there).
    case at(SidebarStore.ItemDestination, index: Int)
    /// After a container's last row.
    case end(SidebarStore.ItemDestination)
    /// Into a folder, after its last row.
    case intoFolder(UUID)
}

extension SidebarStore {

    /// The container a placement's rows land in; nil when its row is gone.
    public func parent(for placement: SidebarDropPlacement) -> ItemParent? {
        switch placement {
        case .beside(let targetID, _): parent(of: targetID)
        case .at(let destination, _), .end(let destination): resolvedParent(destination)
        case .intoFolder(let folderID): folder(withID: folderID) == nil ? nil : .folder(folderID)
        }
    }

    /// The space a container is in; nil for a favorites strip.
    public func spaceID(of parent: ItemParent) -> Space.ID? {
        switch parent {
        case .favorites: nil
        case .section(let spaceID, _): spaceID
        case .folder(let folderID): spaceContaining(entryID: folderID)
        case .tabGroup(let groupID): shownPlace(ofTabGroup: groupID)?.spaceID
        }
    }

    /// Whether a drop of `ids` into `parent` takes any of them to another
    /// profile (a container counts: it is another session). Move to Space
    /// asks before such a move (`crossesProfile(_:toSpace:)`); a drop is the
    /// same move with a place. A tab group takes no other profile's tabs at
    /// all (`canPlace`), so nothing crosses into one.
    public func crossesProfile(_ ids: [UUID], to parent: ItemParent) -> Bool {
        let destination: Profile.ID?
        switch parent {
        case .favorites(let profileID): destination = profileID
        case .section, .folder: destination = spaceID(of: parent).flatMap { space(withID: $0)?.profileID }
        case .tabGroup: return false
        }
        guard let destination else { return false }
        return ids.contains { id in
            let current = favoriteOwner(of: id) ?? spaceContaining(entryID: id).flatMap { space(withID: $0)?.profileID }
            return current.map { $0 != destination } ?? false
        }
    }

    /// Moves rows to a drop's place, in order. Returns the ids that moved.
    @discardableResult
    public func moveEntries(_ ids: [UUID], to placement: SidebarDropPlacement) -> [UUID] {
        switch placement {
        case .beside(let targetID, let after):
            return moveEntries(ids, relativeTo: targetID, after: after) ?? []
        case .at(let destination, let index):
            var next = index
            return topmostEntries(ids).filter { id in
                guard moveItem(id, to: destination, index: next) else { return false }
                next += 1
                return true
            }
        case .end(let destination):
            return moveEntries(ids, appendingTo: destination)
        case .intoFolder(let folderID):
            return moveEntries(ids, intoFolder: folderID)
        }
    }
}
