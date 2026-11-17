import Foundation
import Observation

/// Per-key observation for values kept in one large container. Reading a
/// key in a view body (or `withObservationTracking`) makes that reader
/// depend on the key alone, so a change to one tab redraws its row and not
/// every view that looked at the dictionary. A cell exists only while
/// someone has read it since its last change.
public final class ObservationCells<Key: Hashable> {
    @Observable
    final class Cell {
        var generation = 0
    }

    private var cells: [Key: Cell] = [:]

    public init() {}

    /// Registers the current observation scope on `key`.
    public func access(_ key: Key) {
        let cell: Cell
        if let existing = cells[key] {
            cell = existing
        } else {
            cell = Cell()
            cells[key] = cell
        }
        _ = cell.generation
    }

    /// Notifies whoever read `key` since its last change.
    public func invalidate(_ key: Key) {
        guard let cell = cells.removeValue(forKey: key) else { return }
        cell.generation &+= 1
    }

    public func invalidateAll() {
        let all = cells
        cells = [:]
        for cell in all.values { cell.generation &+= 1 }
    }

    /// No reader is waiting on any key.
    public var isEmpty: Bool { cells.isEmpty }
}

/// What a `SidebarStore` reader depends on (see `SidebarStore.observation`).
enum SidebarObservationKey: Hashable {
    /// One entry's own value and where it sits: a tab (split panes
    /// included), a split, an easel, or a folder's title and rank.
    case entry(UUID)
    /// Which ids exist at all; a lookup that found nothing waits on this.
    case membership
    /// Anything in a space's sections.
    case spaceContent(Space.ID)
    /// The order and nesting of a space's rows (`SidebarStore.outline(for:)`).
    case spaceOutline(Space.ID)
    /// Anything in a profile's favorites strip.
    case favorites(Profile.ID)
    /// Whether an item is the selection shown for a space.
    case selection(Space.ID, UUID)
    /// Whether a row is in a window's multi-row selection.
    case multiSelection(SidebarWindowID?, UUID)
    /// Whether a window has a multi-row selection at all.
    case multiSelectionPresence(SidebarWindowID?)
    /// The tab groups: which exist, and each one's name, colour and tabs.
    case tabGroups
}

/// One row of a space's outline: what it is and, for a folder, what it holds.
/// Views lay out rows from the outline and read each row's value by id, so
/// a title or last-active change redraws that row only.
public struct SidebarOutlineNode: Identifiable, Equatable {
    public enum Kind: Equatable {
        case tab, split, easel, folder
        /// A tab group's row; its children are the group's tabs.
        case tabGroup

        /// A row that holds other rows and opens and closes.
        public var isContainer: Bool { self == .folder || self == .tabGroup }
    }

    public let id: UUID
    public let kind: Kind
    public let children: [SidebarOutlineNode]

    public init(id: UUID, kind: Kind, children: [SidebarOutlineNode] = []) {
        self.id = id
        self.kind = kind
        self.children = children
    }

    init(_ entry: SidebarEntry) {
        switch entry {
        case .tab(let tab): self.init(id: tab.id, kind: .tab)
        case .split(let split): self.init(id: split.id, kind: .split)
        case .easel(let ref): self.init(id: ref.id, kind: .easel)
        case .folder(let folder): self.init(id: folder.id, kind: .folder, children: folder.children.map(SidebarOutlineNode.init))
        case .tabGroup(let reference):
            self.init(id: reference.id, kind: .tabGroup, children: reference.group.tabs.map { SidebarOutlineNode(id: $0.id, kind: .tab) })
        }
    }

    /// Every node that is not a folder or a tab group in display order, descending into both.
    public static func leaves(_ nodes: [SidebarOutlineNode]) -> [SidebarOutlineNode] {
        nodes.flatMap { $0.kind.isContainer ? leaves($0.children) : [$0] }
    }
}

/// A space's sections as rows, sorted like `SidebarStore.content(for:)`.
public struct SidebarSpaceOutline: Equatable {
    public var pinned: [SidebarOutlineNode]
    public var today: [SidebarOutlineNode]

    public init(pinned: [SidebarOutlineNode], today: [SidebarOutlineNode]) {
        self.pinned = pinned
        self.today = today
    }

    init(_ content: SidebarStore.SpaceContent) {
        pinned = content.pinned.map(SidebarOutlineNode.init)
        today = content.today.map(SidebarOutlineNode.init)
    }
}

/// Derived views of the store, rebuilt on demand after a mutation.
final class SidebarLookupCache {
    /// Where an entry sits in the store.
    enum Place: Equatable {
        case favorite(Profile.ID)
        /// In a space tree: its section and the folder directly holding it.
        case tree(spaceID: Space.ID, section: ItemContainerKind.SpaceSection, folderID: UUID?)
        /// A split's pane; `section` is the split's own.
        case splitPane(spaceID: Space.ID, section: ItemContainerKind.SpaceSection, splitID: UUID)
        /// A tab group's tab. It has no one space: every space with a
        /// reference to the group shows it (`SidebarStore.shownReference`).
        case groupTab(groupID: TabGroup.ID)
    }

    struct Item {
        /// The entry as `content(for:)` returns it (folder children sorted); a pane is `.tab`.
        let entry: SidebarEntry
        let place: Place
    }

    /// `content(for:)` per space, sorted.
    var sorted: [Space.ID: SidebarStore.SpaceContent] = [:]
    var outlines: [Space.ID: SidebarSpaceOutline] = [:]
    var sortedFavorites: [Profile.ID: [Tab]] = [:]
    /// Every entry, favorites first, then spaces in `spaces` order (the first id wins).
    var index: [UUID: Item]?
    /// Where each tab group is referenced, in `spaces` order; built with `index`.
    var groupReferences: [TabGroup.ID: [TabGroupPlace]] = [:]
    /// `displayEntries(in:)` per space, and its ids.
    var display: [Space.ID: (entries: [SidebarEntry], ids: Set<UUID>)] = [:]
    /// Each observed space's last summary, to tell which entries changed.
    var summaries: [Space.ID: SpaceSummary] = [:]
    var favoriteSummaries: [Profile.ID: [UUID: Tab]] = [:]
    /// The selection each space's rows last saw (`SidebarStore.isSelected`).
    var trackedSelection: [Space.ID: UUID?] = [:]
    var selectionNeedsRefresh = false
    var selectionRefreshScheduled = false
}

/// A space tree flattened in stored order: each entry's own value and place,
/// and the rows' order and nesting. Two summaries with the same signature
/// sort to the same outline.
struct SpaceSummary {
    struct Item: Equatable {
        /// A folder without its children (they are items of their own).
        let value: SidebarEntry
        let place: SidebarLookupCache.Place
    }

    struct Row: Equatable {
        let id: UUID
        let parent: UUID?
        let pinned: Bool
        let rank: String
    }

    private(set) var items: [UUID: Item] = [:]
    private(set) var signature: [Row] = []

    init(spaceID: Space.ID, content: SidebarStore.SpaceContent?) {
        guard let content else { return }
        add(content.pinned, spaceID: spaceID, section: .pinned, folderID: nil)
        add(content.today, spaceID: spaceID, section: .unpinned, folderID: nil)
    }

    private static func rank(of entry: SidebarEntry) -> String {
        switch entry {
        case .tab(let tab): return tab.sortRank
        case .split(let split): return split.sortRank
        case .easel(let ref): return ref.sortRank
        case .folder(let folder): return folder.sortRank
        case .tabGroup(let reference): return reference.sortRank
        }
    }

    private mutating func add(_ entries: [SidebarEntry], spaceID: Space.ID, section: ItemContainerKind.SpaceSection, folderID: UUID?) {
        for entry in entries {
            let place = SidebarLookupCache.Place.tree(spaceID: spaceID, section: section, folderID: folderID)
            signature.append(Row(id: entry.id, parent: folderID, pinned: section == .pinned, rank: Self.rank(of: entry)))
            switch entry {
            case .folder(var folder):
                let children = folder.children
                folder.children = []
                items[folder.id] = items[folder.id] ?? Item(value: .folder(folder), place: place)
                add(children, spaceID: spaceID, section: section, folderID: folder.id)
            case .split(let split):
                items[split.id] = items[split.id] ?? Item(value: entry, place: place)
                for pane in split.tabs where items[pane.id] == nil {
                    items[pane.id] = Item(value: .tab(pane), place: .splitPane(spaceID: spaceID, section: section, splitID: split.id))
                }
            case .tabGroup(var reference):
                // The row without its tabs (they are items of their own): its name, colour and rank.
                let tabs = reference.group.tabs
                reference.group.tabs = []
                items[reference.id] = items[reference.id] ?? Item(value: .tabGroup(reference), place: place)
                for tab in tabs {
                    signature.append(Row(id: tab.id, parent: reference.id, pinned: section == .pinned, rank: tab.sortRank))
                    items[tab.id] = items[tab.id] ?? Item(value: .tab(tab), place: .groupTab(groupID: reference.groupID))
                }
            case .tab, .easel:
                items[entry.id] = items[entry.id] ?? Item(value: entry, place: place)
            }
        }
    }
}

/// One reference to a tab group: the space and section its row is in.
struct TabGroupPlace: Equatable {
    let spaceID: Space.ID
    let section: ItemContainerKind.SpaceSection
    let referenceID: UUID
}
