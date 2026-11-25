import Foundation

/// Darni's own small log files (`relaunch.log`, `tab-sleep.log`): standard
/// error is lost when the app is opened from Finder or with `open`, so what
/// QA needs to read afterwards goes to a file.
public enum ShellFileLog {
    /// Appends a timestamped line with this process's pid (each file kept
    /// under `limit` bytes: a longer one starts again). The file is never
    /// followed through a symlink, is the person's own and readable by them
    /// only, and the line loses its control characters (RC-0.1.0-602 T-09).
    public static func append(_ line: String, to url: URL, limit: Int = 64_000) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let clean = String(String.UnicodeScalarView(line.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }).prefix(1000))
        let text = "\(ISO8601DateFormatter().string(from: Date())) pid \(ProcessInfo.processInfo.processIdentifier) \(clean)\n"
        var info = stat()
        if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > limit {
            unlink(url.path)
        }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else { return }
        _ = Array(text.utf8).withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    /// A test process: nothing is written to the person's real folders.
    static let isTestProcess = NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

/// Tab sleep's lines in Darni's file log, so QA can tell that a tab really
/// froze and when it ran again (NIGHT-1125 point 7). A line names the tab by
/// its sidebar id only: no address, no title.
///
/// - `tab <id> freeze requested`: the engine took the request.
/// - `tab <id> frozen`: the engine reports the page's renderer frozen.
/// - `tab <id> thawed (<why>); <whether it had frozen>`: the request ended.
public struct TabFreezeJournal: Equatable, Sendable {
    public enum ThawReason: String, Sendable {
        case shown = "shown"
        case due = "in use again or no longer due"
        case engine = "the engine ended it: the tab was used or unloaded"
    }

    /// Tabs with a request this shell made and has not seen end.
    public private(set) var requested: Set<UUID> = []
    /// Of those, the ones seen frozen.
    public private(set) var frozen: Set<UUID> = []

    public init() {}

    public mutating func freezeRequested(_ id: UUID) -> String? {
        guard requested.insert(id).inserted else { return nil }
        return "tab \(id.uuidString) freeze requested"
    }

    /// What the engine says now of the page of a tab with a request.
    public mutating func observed(_ id: UUID, frozen isFrozen: Bool?) -> String? {
        guard requested.contains(id), isFrozen == true, frozen.insert(id).inserted else { return nil }
        return "tab \(id.uuidString) frozen"
    }

    /// The request ended. `frozenNow`: the engine's word just before, when it has one.
    public mutating func thawed(_ id: UUID, reason: ThawReason, frozenNow: Bool? = nil) -> String? {
        guard requested.remove(id) != nil else { return nil }
        let wasFrozen = frozen.remove(id) != nil || frozenNow == true
        let state = wasFrozen ? "it had frozen" : frozenNow == false ? "it had not frozen yet" : "not seen frozen"
        return "tab \(id.uuidString) thawed (\(reason.rawValue)); \(state)"
    }

    /// A closed tab: nothing more to say of it.
    public mutating func forget(_ id: UUID) {
        requested.remove(id)
        frozen.remove(id)
    }
}

/// Where tab sleep's lines go: `Logs/tab-sleep.log` in the data root (so a
/// launch on `REARC_DATA_DIR` keeps its own). Nowhere in a test process
/// unless the test gives a file.
public struct TabSleepLog: Sendable {
    public let url: URL?

    public init(url: URL?) { self.url = url }

    public static let fileName = "tab-sleep.log"

    public static let standard = TabSleepLog(url: ShellFileLog.isTestProcess ? nil
        : ShellDataLocation.root.appendingPathComponent("Logs", isDirectory: true).appendingPathComponent(fileName))

    public func write(_ line: String?) {
        guard let line, let url else { return }
        ShellFileLog.append(line, to: url)
    }
}
