import Foundation

/// When each sidebar tab was first shown or loaded in Darni (owner,
/// 2026-11-27). Arc's import stamps every imported tab's `lastActiveAt`
/// with the import's time, so that date can't tell "never opened here"
/// from "opened then"; this mark can. The Task Manager reads it for the
/// "Not loaded" fold and its Idle text (TASK-MANAGER-INSIGHTS §4.6).
///
/// Local only. The marks live in a file of their own beside the sidebar
/// file (`TabOpened.json`), never in `sidebar.json`'s tabs: sync's split
/// records carry a whole `Tab` minus `SidebarSyncProjection.localTabKeys`,
/// so a new `Tab` field would reach iCloud unless every encoder dropped it.
/// Builds that don't know the file (1451 and before) never read or write it.
///
/// Only sidebar tabs get a mark: private windows aren't sidebar tabs and
/// never write one. A tab that leaves the sidebar (closed, archived,
/// deleted here or on another Mac) loses its mark, and clearing history
/// clears them all: they say when you visited.
public struct TabOpenedMarks: Equatable, Sendable {
    public static let fileName = "TabOpened.json"

    /// The first time each tab was shown or loaded, by sidebar tab ID.
    public private(set) var openedAt: [UUID: Date]

    public init(openedAt: [UUID: Date] = [:]) {
        self.openedAt = openedAt
    }

    public var isEmpty: Bool { openedAt.isEmpty }

    public subscript(id: UUID) -> Date? { openedAt[id] }

    /// Records the tab's first opening. A tab already marked keeps its
    /// first date. False when nothing changed.
    @discardableResult
    public mutating func mark(_ id: UUID, at date: Date) -> Bool {
        guard openedAt[id] == nil else { return false }
        openedAt[id] = date
        return true
    }

    /// Drops the marks of tabs `keep` says no to. False when nothing changed.
    @discardableResult
    public mutating func keepOnly(_ keep: (UUID) -> Bool) -> Bool {
        let kept = openedAt.filter { keep($0.key) }
        guard kept.count != openedAt.count else { return false }
        openedAt = kept
        return true
    }

    /// Clear History: every mark goes. False when there were none.
    @discardableResult
    public mutating func removeAll() -> Bool {
        guard !openedAt.isEmpty else { return false }
        openedAt = [:]
        return true
    }

    // MARK: The file

    /// `{"version": 1, "opened": {"<tab UUID>": "<ISO 8601>"}}`. A later
    /// version keeps `opened` readable; unknown keys are ignored.
    private struct Payload: Codable {
        var version = 1
        var opened: [String: Date]
    }

    /// An absent, unreadable or foreign file gives no marks: the Task Manager
    /// then falls back to the same-second rule for every tab.
    public static func load(from url: URL) -> TabOpenedMarks {
        guard let data = try? Data(contentsOf: url) else { return TabOpenedMarks() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return TabOpenedMarks() }
        var marks: [UUID: Date] = [:]
        for (key, date) in payload.opened {
            if let id = UUID(uuidString: key) { marks[id] = date }
        }
        return TabOpenedMarks(openedAt: marks)
    }

    /// Written whole, readable by the person only. With no mark left the
    /// file is removed: nothing remains to say when a tab was opened.
    public func save(to url: URL) throws {
        let fm = FileManager.default
        if openedAt.isEmpty {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let opened = Dictionary(uniqueKeysWithValues: openedAt.map { ($0.key.uuidString, $0.value) })
        let data = try encoder.encode(Payload(opened: opened))
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
