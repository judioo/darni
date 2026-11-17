import Foundation

/// What ReArc reads of one of its own child processes: where its executable
/// is and when it started. Nothing else of the process is asked for.
public struct ChildProcessFact: Equatable, Sendable {
    public var executablePath: String
    public var startTime: Date

    public init(executablePath: String, startTime: Date) {
        self.executablePath = executablePath
        self.startTime = startTime
    }
}

/// ReArc's direct children at one moment.
public struct ChildProcessSnapshot: Equatable, Sendable {
    public var takenAt: Date
    public var children: [ChildProcessFact]

    public init(takenAt: Date, children: [ChildProcessFact]) {
        self.takenAt = takenAt
        self.children = children
    }
}

/// Whether 1Password's connection to ReArc is evidently working, from
/// process facts alone (security pre-review of 2026-11-17, proposal B).
///
/// When 1Password's extension connects, the engine starts 1Password's
/// native messaging helper as a direct child of ReArc, and the extension
/// drops the connection at once when the helper refuses the browser. So a
/// helper that has stayed, while the 1Password app runs, is what a working
/// connection looks like from outside.
///
/// What this knows: the helper stayed attached. What it does not know: that
/// 1Password trusts ReArc. Nothing here reads the connection, 1Password's
/// files, or the helper's arguments or environment, and nothing starts the
/// helper. That is why Settings says "Connected" only while a helper is seen
/// and keeps the setup steps in every state.
public enum OnePasswordConnection {
    /// The native messaging host of the 1Password 8 app. ReArc knows the
    /// helper by the `path` of this host's manifest, never by a process name.
    public static let hostName = "com.1password.1password"

    /// A helper waiting for an app that does not answer can outlive ten
    /// seconds, so "stayed" means this long.
    public static let minimumHelperAge: TimeInterval = 30
    /// Between readings, and only while one can change what shows.
    public static let pollInterval: TimeInterval = 20
    /// From a launch's first reading: the extension has connected and its
    /// helper has had time to stay. After this the launch has its verdict.
    public static let verdictDelay: TimeInterval = 90
    /// Settings says "Connected" from a reading no older than this.
    public static let readingLifetime: TimeInterval = 2 * pollInterval

    public enum Reading: Equatable, Sendable {
        /// The helper has stayed attached and the 1Password app is running.
        case attached
        /// A helper was due and none has stayed: the app is running, the
        /// extension is here, ReArc knows the helper's path.
        case absent
        /// Nothing to go on: the app is not running, the extension is not
        /// here, or ReArc copied no manifest.
        case unknown
    }

    /// One reading. `snapshot` is nil when the children were not listed.
    public static func reading(of snapshot: ChildProcessSnapshot?, helperPath: String?, appRunning: Bool,
                               extensionInstalled: Bool) -> Reading {
        guard appRunning, let helperPath, !helperPath.isEmpty else { return .unknown }
        let stayed = snapshot.map { snapshot in
            snapshot.children.contains {
                $0.executablePath == helperPath && snapshot.takenAt.timeIntervalSince($0.startTime) >= minimumHelperAge
            }
        } ?? false
        if stayed { return .attached }
        return extensionInstalled ? .absent : .unknown
    }
}

/// What the readings add up to in one launch, and the one value kept
/// between launches.
public struct OnePasswordConnectionState: Equatable, Sendable {
    /// Whether the last launch that could tell saw the helper attached. Kept
    /// on this Mac only: the key is in no synced record and no export.
    public static let storedKey = "rearc.onePasswordConnectionSeen"

    public enum Outcome: Equatable, Sendable {
        case nothingNew
        /// This launch's first sight of an attached helper.
        case connected
        /// The launch's verdict came without one. `lost`: an earlier launch
        /// saw a connection, and this one ran with 1Password from its first
        /// reading and saw none.
        case notConnected(lost: Bool)
    }

    /// From an earlier launch until this one's verdict, then this launch's
    /// own. It only ever hides the prompt (`hidesPrompt`).
    public private(set) var stored: Bool
    /// This launch has its own answer: a helper seen attached, or
    /// `verdictDelay` gone by without one.
    public private(set) var hasVerdict = false
    public private(set) var wasConnectedThisLaunch = false
    private var latest: OnePasswordConnection.Reading?
    private var latestUptime: TimeInterval = 0
    private var firstUptime: TimeInterval?
    /// Every reading so far was `absent`: 1Password ran, the extension was
    /// here, and no helper stayed.
    private var helperWasDueThroughout = true

    public init(stored: Bool = false) {
        self.stored = stored
    }

    public static func load(from defaults: UserDefaults) -> Self {
        Self(stored: defaults.bool(forKey: storedKey))
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(stored, forKey: Self.storedKey)
    }

    /// Settings' "Connected": this launch's latest reading, while it is
    /// fresh. The stored value never counts here.
    public func isConnected(uptime: TimeInterval) -> Bool {
        latest == .attached && uptime - latestUptime <= OnePasswordConnection.readingLifetime
    }

    /// The prompt stays away: a helper was seen attached in this launch (if
    /// it goes later, the prompt does not come back before the next launch),
    /// or an earlier launch saw one and this launch has no verdict yet.
    public var hidesPrompt: Bool {
        wasConnectedThisLaunch || (stored && !hasVerdict)
    }

    /// `uptime` is time awake since boot, so a sleeping Mac does not use up
    /// `verdictDelay`.
    @discardableResult
    public mutating func record(_ reading: OnePasswordConnection.Reading, uptime: TimeInterval) -> Outcome {
        latest = reading
        latestUptime = uptime
        let first = firstUptime ?? uptime
        firstUptime = first
        switch reading {
        case .attached:
            let isFirst = !wasConnectedThisLaunch
            wasConnectedThisLaunch = true
            hasVerdict = true
            stored = true
            return isFirst ? .connected : .nothingNew
        case .absent, .unknown:
            if reading == .unknown { helperWasDueThroughout = false }
            guard !hasVerdict, uptime - first >= OnePasswordConnection.verdictDelay else { return .nothingNew }
            hasVerdict = true
            // A launch that could not tell (1Password not running) leaves
            // the stored value for the next one.
            guard helperWasDueThroughout else { return .notConnected(lost: false) }
            let lost = stored
            stored = false
            return .notConnected(lost: lost)
        }
    }
}
