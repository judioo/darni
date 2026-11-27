import Foundation

// The Task Manager's history (docs/TASK-MANAGER-INSIGHTS.md §5.1): per stack,
// its footprint and CPU share at each reading, folded into 10 s cells (the
// last 10 minutes, for the sparklines and the heat grid) and 1 min cells (the
// last 3 hours, for the memory history). Also what tab sleep did to each tab
// (fell asleep, woke, unloaded, loaded again, and by what), with the effect
// measured from the readings before and after it.
//
// It lives in memory only and dies at quit. Nothing is written to disk or
// sent anywhere. A private window's tabs are forgotten when they go.
//
// Times are seconds on a clock that never goes back (the controller's
// `systemUptime`); `TaskManagerTimeline` turns them into wall-clock times.

// MARK: Cells

/// What a reading saw of a stack, folded with the other readings of the same cell.
public struct TaskManagerHistoryCell: Equatable, Sendable {
    /// What tab sleep had done with the tab. A cell is awake if any reading in
    /// it was, asleep only if every reading was asleep or unloaded.
    public enum State: Int, Comparable, Sendable {
        case awake, asleep, unloaded

        public static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue }

        public init(_ sleep: TaskManagerTabState?) {
            switch sleep {
            case .sleeping?, .fallingAsleep?: self = .asleep
            case .unloaded?, .notLoaded?: self = .unloaded
            default: self = .awake
            }
        }
    }

    public internal(set) var state: State
    /// Every reading in the cell had the tab off screen (only tabs are ever hidden).
    public internal(set) var isHidden: Bool
    public internal(set) var memoryPeak: UInt64 = 0
    public internal(set) var cpuPeak: Double = 0
    var memorySum = 0.0
    var memoryCount = 0
    var cpuSum = 0.0
    var cpuCount = 0
    /// Readings made while the window was on screen (the others are the 60 s tick's).
    var windowReadings = 0

    init(state: State, isHidden: Bool) {
        self.state = state
        self.isHidden = isHidden
    }

    /// The average footprint of the readings; nil when no process was read (unloaded).
    public var memory: UInt64? { memoryCount == 0 ? nil : UInt64((memorySum / Double(memoryCount)).rounded()) }
    /// The average CPU share, percent of one core; nil when not known.
    public var cpuPercent: Double? { cpuCount == 0 ? nil : cpuSum / Double(cpuCount) }

    mutating func add(memory: UInt64?, cpu: Double?, state: State, isHidden: Bool, fromWindow: Bool) {
        self.state = min(self.state, state)
        self.isHidden = self.isHidden && isHidden
        if let memory {
            memorySum += Double(memory)
            memoryCount += 1
            memoryPeak = max(memoryPeak, memory)
        }
        if let cpu {
            cpuSum += cpu
            cpuCount += 1
            cpuPeak = max(cpuPeak, cpu)
        }
        if fromWindow { windowReadings += 1 }
    }

    static func first(memory: UInt64?, cpu: Double?, state: State, isHidden: Bool, fromWindow: Bool) -> Self {
        var cell = Self(state: state, isHidden: isHidden)
        cell.add(memory: memory, cpu: cpu, state: state, isHidden: isHidden, fromWindow: fromWindow)
        return cell
    }
}

// MARK: Tab controls' events

/// Something tab sleep or the person did to a tab, and what it changed.
public struct TaskManagerTabEvent: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case fellAsleep, woke, unloaded, loaded

        public var title: String {
            switch self {
            case .fellAsleep: return "Fell asleep"
            case .woke: return "Woke"
            case .unloaded: return "Unloaded"
            case .loaded: return "Loaded again"
            }
        }
    }

    /// What did it.
    public enum Cause: String, Sendable {
        /// Tab sleep's rule: unseen for the wait set in Settings › General.
        case automatic
        /// The Task Manager's Sleep or Unload.
        case taskManager
        /// The sidebar's Sleep Tab or Unload Tab, or ⌘W on a pinned tab.
        case sidebar
        /// The person showed the tab.
        case shown
        /// The engine ended the sleep: the page was used (sound, a share, a download) or unloaded.
        case engine
        /// The wait was raised or turned off, or the tab is in use again.
        case rule

        public var title: String {
            switch self {
            case .automatic: return "by tab sleep"
            case .taskManager: return "from the Task Manager"
            case .sidebar: return "from the sidebar"
            case .shown: return "when shown"
            case .engine: return "by the page"
            case .rule: return "by tab sleep's rule"
            }
        }
    }

    /// What it changed, measured from the readings around it.
    public enum Effect: Equatable, Sendable {
        /// Woke, loaded again: the start of the next reading's figures.
        case none
        /// An unload a few seconds old: the footprint has not settled yet.
        case measuring
        /// The footprint the tab's processes gave back. `approximate`: a process
        /// stayed alive (Chromium keeps a discarded tab's emptied frame in its
        /// renderer) or other tabs share it, so only the measured drop counts.
        case freed(bytes: UInt64, approximate: Bool)
        /// Why there is no figure.
        case notMeasured(String)
        /// Sleep frees CPU, not memory: `TaskManagerHistory.sleepEffect`.
        case sleep
    }

    public let id: Int
    public let kind: Kind
    public let cause: Cause
    public let time: TimeInterval
    public internal(set) var effect: Effect
    /// Noted while the window was closed: cleared with the background history.
    public let whileClosed: Bool
    /// A sleep or an unload that ended (woke, loaded again).
    public internal(set) var endedAt: TimeInterval?

    // Measurement.
    var before: [TaskManagerMemberSnapshot] = []
    /// Sleep: the CPU share in the 10 minutes before, and the stack's CPU
    /// seconds at the first reading once it settled.
    var cpuBefore: Double?
    var cpuBaseline: Double?
    var cpuAtEnd: Double?
}

/// One process of a stack at a reading.
struct TaskManagerMemberSnapshot: Equatable, Sendable {
    var pid: Int32
    var footprint: UInt64
    var sharedBy: Int
    var cpuMicros: Int64
}

/// A sleep's measured effect.
public struct TaskManagerSleepEffect: Equatable, Sendable {
    public var since: TimeInterval
    public var endedAt: TimeInterval?
    /// Percent of a core in the 10 minutes before it slept; nil: no reading then.
    public var cpuBefore: Double?
    /// CPU seconds used since it settled; nil until a reading after it.
    public var cpuSince: Double?
    /// The stack's figures are a share of shared processes.
    public var isEstimate: Bool

    /// The counterfactual (≈, stated in `TaskManagerInsightText.avoidedRule`):
    /// the average before times the time asleep, less what it used since.
    public func avoided(now: TimeInterval) -> Double? {
        guard let cpuBefore, cpuBefore >= TaskManagerHeat.idleBelow, let cpuSince else { return nil }
        let asleep = (endedAt ?? now) - since
        return max(0, cpuBefore / 100 * asleep - cpuSince)
    }
}

// MARK: One stack

/// One stack's history: a tab (across its unload and load), an extension or Darni.
public struct TaskManagerStackHistory: Equatable, Sendable {
    public let key: String
    public internal(set) var stackID: String
    public internal(set) var title: String
    public internal(set) var name: String
    public internal(set) var kind: TaskManagerStack.Kind
    public internal(set) var isPrivate: Bool
    /// 10 s cells by index (time / 10), the last 60.
    public internal(set) var recent: [Int: TaskManagerHistoryCell] = [:]
    /// 1 min cells by index (time / 60), the last 180.
    public internal(set) var minutes: [Int: TaskManagerHistoryCell] = [:]
    /// Each process's 10 s cells (its own whole CPU), the last 30, for the inspector's grid.
    public internal(set) var members: [Int32: TaskManagerMemberHistory] = [:]
    public internal(set) var events: [TaskManagerTabEvent] = []
    public internal(set) var firstSeen: TimeInterval
    public internal(set) var lastSeen: TimeInterval
    /// Since when the same page has been loaded: the growth rule looks no further back.
    public internal(set) var pageSince: TimeInterval
    /// CPU seconds the stack has used (shares of shared processes) since it was first read.
    public internal(set) var cpuSeconds = 0.0
    /// The latest reading's state, and since when the readings have seen it.
    public internal(set) var state: TaskManagerTabState?
    public internal(set) var stateSince: TimeInterval
    public internal(set) var isOnScreen = false
    var pageURL: String?
    var lastMembers: [TaskManagerMemberSnapshot] = []
    var lastMembersTime: TimeInterval?
    var windowReadings = 0

    init(key: String, time: TimeInterval) {
        self.key = key
        stackID = key
        title = ""
        name = ""
        kind = .tab
        isPrivate = false
        firstSeen = time
        lastSeen = time
        pageSince = time
        stateSince = time
    }

    /// The sleep or unload still going on.
    func open(_ kind: TaskManagerTabEvent.Kind) -> Int? {
        events.lastIndex { $0.kind == kind && $0.endedAt == nil }
    }

    public var isAsleepByEvent: Bool { open(.fellAsleep) != nil }
}

public struct TaskManagerMemberHistory: Equatable, Sendable {
    public internal(set) var label: String
    public internal(set) var cells: [Int: TaskManagerHistoryCell] = [:]
}

// MARK: The history

public struct TaskManagerHistory: Equatable, Sendable {
    /// Where a reading came from.
    public enum Source: Sendable {
        /// The once-a-second reading while the window is on screen.
        case window
        /// The 60 s reading while it is closed (Settings › Advanced).
        case background
    }

    public static let cellSeconds: TimeInterval = 10
    public static let recentCellCount = 60
    public static let minuteSeconds: TimeInterval = 60
    public static let minuteCellCount = 180
    public static let memberCellCount = 30
    /// A stack that is gone is kept this long (a tab closed by mistake and reopened keeps nothing, though: a new tab is a new key).
    public static let goneKeep: TimeInterval = 600
    /// An unload's figure is taken from the first reading this long after it.
    public static let settleDelay: TimeInterval = 5
    /// A reading older than this is not "before" an event.
    public static let beforeMaxAge: TimeInterval = 90
    /// A CPU share over a longer gap is an average too coarse for a 10 s cell (or a 1 min cell).
    static let recentCPUMaxGap: TimeInterval = 20
    static let minuteCPUMaxGap: TimeInterval = 150
    static let eventsKept = 40

    public private(set) var stacks: [String: TaskManagerStackHistory] = [:]
    public private(set) var lastReading: TimeInterval?
    private var lastPidCPU: [Int32: Int64] = [:]
    private var nextEventID = 1
    /// Measured unloads this session, for the summary strip.
    private var freedRecords: [(id: Int, bytes: UInt64, approximate: Bool, whileClosed: Bool)] = []

    public init() {}

    public static func == (a: Self, b: Self) -> Bool {
        a.stacks == b.stacks && a.lastReading == b.lastReading && a.nextEventID == b.nextEventID
    }

    public subscript(key: String) -> TaskManagerStackHistory? { stacks[key] }

    public func history(of stack: TaskManagerStack) -> TaskManagerStackHistory? { stacks[stack.historyKey] }

    static func recentIndex(_ time: TimeInterval) -> Int { Int((time / cellSeconds).rounded(.down)) }
    static func minuteIndex(_ time: TimeInterval) -> Int { Int((time / minuteSeconds).rounded(.down)) }

    // MARK: Readings

    /// Folds one reading in. Every process is in some stack (`TaskManagerRows.stacks`).
    public mutating func record(_ readings: [TaskManagerStack], at time: TimeInterval, source: Source) {
        let elapsed = lastReading.map { time - $0 }
        var pidCPU: [Int32: Int64] = [:]
        var pidFootprint: [Int32: UInt64] = [:]
        for stack in readings {
            for member in stack.members {
                pidCPU[member.pid] = member.cpuMicros
                pidFootprint[member.pid] = member.memoryFootprint
            }
        }
        // CPU seconds per process since the last reading; a total that went
        // down is a new process with a reused pid (as `TaskManagerSampler`).
        var pidDelta: [Int32: Double] = [:]
        for (pid, micros) in pidCPU {
            guard let before = lastPidCPU[pid], micros >= before else { continue }
            pidDelta[pid] = Double(micros - before) / 1_000_000
        }
        let recent = Self.recentIndex(time)
        let minute = Self.minuteIndex(time)
        var seen: Set<String> = []
        // The folded "Not loaded" group is not a stack of its own, and its tabs have nothing to read.
        for stack in readings where stack.kind != .notLoaded {
            let key = stack.historyKey.isEmpty ? stack.id : stack.historyKey
            guard seen.insert(key).inserted else { continue }
            var track = stacks[key] ?? TaskManagerStackHistory(key: key, time: time)
            track.stackID = stack.id
            track.title = stack.title
            track.name = stack.name
            track.kind = stack.kind
            track.isPrivate = stack.isPrivate
            track.lastSeen = time
            if source == .window { track.windowReadings += 1 }

            // A new page (another address, a reload, an unload) starts the growth rule again.
            let state = stack.sleep?.state
            if stack.isLoading || state == .unloaded
                || (stack.pageURL != nil && track.pageURL != nil && stack.pageURL != track.pageURL) {
                track.pageSince = time
            }
            if let url = stack.pageURL { track.pageURL = url }
            if TaskManagerHistoryCell.State(state) != TaskManagerHistoryCell.State(track.state) {
                track.stateSince = time
            }
            track.state = state
            track.isOnScreen = stack.sleep?.isOnScreen ?? false

            // The stack's share of its processes' CPU since the last reading.
            // An unloaded tab has no process: it used none.
            var cpuKnown = stack.members.isEmpty && lastReading != nil
            var cpuDelta = 0.0
            for member in stack.members {
                guard let delta = pidDelta[member.pid] else { continue }
                cpuDelta += delta * member.share
                cpuKnown = true
            }
            track.cpuSeconds += cpuDelta
            let cpu: Double? = cpuKnown && (elapsed ?? 0) > 0 ? cpuDelta / elapsed! * 100 : nil
            let cellState = TaskManagerHistoryCell.State(state)
            let hidden = stack.kind == .tab && stack.sleep.map { !$0.isOnScreen } ?? false
            let memory = stack.memoryFootprint

            if source == .window {
                let recentCPU = (elapsed ?? .infinity) <= Self.recentCPUMaxGap ? cpu : nil
                fold(&track.recent, at: recent, memory: memory, cpu: recentCPU, state: cellState, hidden: hidden, window: true)
                track.recent = track.recent.filter { $0.key > recent - Self.recentCellCount }
                for member in stack.members {
                    var entry = track.members[member.pid] ?? TaskManagerMemberHistory(label: member.task.title)
                    entry.label = member.task.title
                    let own = pidDelta[member.pid].flatMap { delta in (elapsed ?? .infinity) <= Self.recentCPUMaxGap ? delta / elapsed! * 100 : nil }
                    fold(&entry.cells, at: recent, memory: member.memoryFootprint, cpu: own, state: cellState, hidden: hidden, window: true)
                    entry.cells = entry.cells.filter { $0.key > recent - Self.memberCellCount }
                    track.members[member.pid] = entry
                }
                track.members = track.members.filter { !$0.value.cells.isEmpty }
            }
            let minuteCPU = (elapsed ?? .infinity) <= Self.minuteCPUMaxGap ? cpu : nil
            fold(&track.minutes, at: minute, memory: memory, cpu: minuteCPU, state: cellState, hidden: hidden, window: source == .window)
            track.minutes = track.minutes.filter { $0.key > minute - Self.minuteCellCount }

            reconcile(&track, with: stack, at: time)
            settle(&track, at: time, footprints: pidFootprint, cpu: pidCPU)

            if !stack.members.isEmpty {
                track.lastMembers = stack.members.map {
                    TaskManagerMemberSnapshot(pid: $0.pid, footprint: $0.memoryFootprint, sharedBy: $0.sharedBy, cpuMicros: $0.cpuMicros)
                }
                track.lastMembersTime = time
            }
            stacks[key] = track
        }
        // A tab no reading lists any more (unloaded, closed) still has its
        // unload measured from what its processes did.
        for key in stacks.keys where !seen.contains(key) {
            guard stacks[key]!.events.contains(where: { $0.effect == .measuring || ($0.effect == .sleep && $0.cpuBaseline == nil) }) else { continue }
            var track = stacks[key]!
            settle(&track, at: time, footprints: pidFootprint, cpu: pidCPU)
            stacks[key] = track
        }
        // A private window's tab is forgotten as soon as it is gone; the
        // others are kept for 10 minutes.
        stacks = stacks.filter { key, track in
            seen.contains(key) || (!track.isPrivate && time - track.lastSeen <= Self.goneKeep)
        }
        lastPidCPU = pidCPU
        lastReading = time
    }

    private func fold(_ cells: inout [Int: TaskManagerHistoryCell], at index: Int, memory: UInt64?, cpu: Double?,
                      state: TaskManagerHistoryCell.State, hidden: Bool, window: Bool) {
        if cells[index] == nil {
            cells[index] = .first(memory: memory, cpu: cpu, state: state, isHidden: hidden, fromWindow: window)
        } else {
            cells[index]!.add(memory: memory, cpu: cpu, state: state, isHidden: hidden, fromWindow: window)
        }
    }

    /// A sleep or unload the shell did not report the end of: the reading says it ended.
    private func reconcile(_ track: inout TaskManagerStackHistory, with stack: TaskManagerStack, at time: TimeInterval) {
        guard stack.kind == .tab, let state = stack.sleep?.state else { return }
        if let index = track.open(.fellAsleep), state != .sleeping, state != .fallingAsleep, time > track.events[index].time {
            end(&track, sleepAt: index, time: time)
        }
        if let index = track.open(.unloaded), state != .unloaded, !stack.members.isEmpty, time > track.events[index].time {
            track.events[index].endedAt = time
            if track.events[index].effect == .measuring {
                track.events[index].effect = .notMeasured("Shown again before it settled.")
            }
        }
    }

    private mutating func settle(_ track: inout TaskManagerStackHistory, at time: TimeInterval, footprints: [Int32: UInt64], cpu: [Int32: Int64]) {
        for index in track.events.indices where time >= track.events[index].time + Self.settleDelay {
            let event = track.events[index]
            switch (event.kind, event.effect) {
            case (.unloaded, .measuring):
                var freed = 0.0
                var approximate = false
                for member in event.before {
                    let gone = footprints[member.pid] == nil || (cpu[member.pid] ?? 0) < member.cpuMicros
                    if gone {
                        // The process ended: all of it went. Shared, the other tabs' part went too: ≈.
                        freed += Double(member.footprint)
                        if member.sharedBy > 1 { approximate = true }
                    } else {
                        // Still there (the emptied frame, or other tabs' pages): only what it gave back.
                        let after = footprints[member.pid] ?? 0
                        freed += Double(member.footprint > after ? member.footprint - after : 0)
                        approximate = true
                    }
                }
                let bytes = UInt64(freed.rounded())
                track.events[index].effect = .freed(bytes: bytes, approximate: approximate)
                freedRecords.append((event.id, bytes, approximate, event.whileClosed))
            case (.fellAsleep, .sleep) where event.cpuBaseline == nil && event.endedAt == nil:
                track.events[index].cpuBaseline = track.cpuSeconds
            default:
                break
            }
        }
    }

    private func end(_ track: inout TaskManagerStackHistory, sleepAt index: Int, time: TimeInterval) {
        track.events[index].endedAt = time
        if let baseline = track.events[index].cpuBaseline {
            track.events[index].cpuAtEnd = track.cpuSeconds - baseline
        }
    }

    // MARK: Events

    /// Tab sleep or the person did something to the tab filed under `key`.
    /// A wake with no sleep going on, or a load with no unload, is not news
    /// and is dropped (the shell reports every tab it shows). Returns the event, if kept.
    @discardableResult
    public mutating func note(_ kind: TaskManagerTabEvent.Kind, key: String, cause: TaskManagerTabEvent.Cause,
                              at time: TimeInterval, whileClosed: Bool = false) -> TaskManagerTabEvent? {
        var track = stacks[key] ?? TaskManagerStackHistory(key: key, time: time)
        var event = TaskManagerTabEvent(id: nextEventID, kind: kind, cause: cause, time: time, effect: .none, whileClosed: whileClosed)
        switch kind {
        case .fellAsleep:
            guard track.open(.fellAsleep) == nil else { return nil }
            event.effect = .sleep
            event.cpuBefore = averageCPU(track, from: time - 600, to: time)
        case .woke:
            guard let index = track.open(.fellAsleep) else { return nil }
            end(&track, sleepAt: index, time: time)
        case .unloaded:
            guard track.open(.unloaded) == nil else { return nil }
            if let index = track.open(.fellAsleep) { end(&track, sleepAt: index, time: time) }
            if let when = track.lastMembersTime, time - when <= Self.beforeMaxAge, when <= time, !track.lastMembers.isEmpty {
                event.before = track.lastMembers
                event.effect = .measuring
            } else {
                event.effect = .notMeasured("No reading in the minute before it.")
            }
        case .loaded:
            guard let index = track.open(.unloaded) else { return nil }
            track.events[index].endedAt = time
            if track.events[index].effect == .measuring {
                track.events[index].effect = .notMeasured("Shown again before it settled.")
            }
        }
        nextEventID += 1
        track.events.append(event)
        if track.events.count > Self.eventsKept { track.events.removeFirst(track.events.count - Self.eventsKept) }
        stacks[key] = track
        return event
    }

    /// The stack's average CPU share over a time range: its 10 s cells when
    /// they cover at least a minute of it, else its 1 min cells. nil: no reading.
    public func averageCPU(_ track: TaskManagerStackHistory, from start: TimeInterval, to end: TimeInterval) -> Double? {
        let recent = track.recent.filter { index, cell in
            let time = Double(index) * Self.cellSeconds
            return time >= start - Self.cellSeconds && time < end && cell.cpuPercent != nil
        }.values.compactMap(\.cpuPercent)
        if recent.count >= 6 { return recent.reduce(0, +) / Double(recent.count) }
        let minutes = track.minutes.filter { index, cell in
            let time = Double(index) * Self.minuteSeconds
            return time >= start - Self.minuteSeconds && time < end && cell.cpuPercent != nil
        }.values.compactMap(\.cpuPercent)
        if !minutes.isEmpty { return minutes.reduce(0, +) / Double(minutes.count) }
        return recent.isEmpty ? nil : recent.reduce(0, +) / Double(recent.count)
    }

    public func sleepEffect(of event: TaskManagerTabEvent, in track: TaskManagerStackHistory, isEstimate: Bool = false) -> TaskManagerSleepEffect? {
        guard event.kind == .fellAsleep else { return nil }
        let since = event.cpuAtEnd ?? event.cpuBaseline.map { track.cpuSeconds - $0 }
        return TaskManagerSleepEffect(since: event.time, endedAt: event.endedAt, cpuBefore: event.cpuBefore,
                                      cpuSince: since.map { max(0, $0) }, isEstimate: isEstimate)
    }

    // MARK: Forgetting

    /// A private window closed: its tab's history goes at once.
    public mutating func forget(key: String) {
        stacks[key] = nil
    }

    /// History was cleared (Clear Browsing Data opened, or the command bar's
    /// history cleared): the closed tabs kept for 10 minutes go now, with
    /// their titles and addresses (security N-2). Tabs still open keep theirs.
    public mutating func forgetGone() {
        guard let lastReading else { return stacks = [:] }
        stacks = stacks.filter { $0.value.lastSeen >= lastReading }
    }

    /// Settings › Advanced turned the background history off: what the 60 s
    /// readings kept while the window was closed goes, with the events noted then.
    public mutating func clearClosedWindowHistory() {
        stacks = stacks.compactMapValues { track in
            guard track.windowReadings > 0 else { return nil }
            var track = track
            track.minutes = track.minutes.filter { $0.value.windowReadings > 0 }
            track.events.removeAll(where: \.whileClosed)
            return track
        }
        freedRecords.removeAll(where: \.whileClosed)
    }

    // MARK: Summary

    /// Memory measured as freed by unloading this session (since Darni started, while the history was kept).
    public var freedThisSession: (bytes: UInt64, approximate: Bool, count: Int) {
        (freedRecords.reduce(0) { $0 + $1.bytes }, freedRecords.contains(where: \.approximate), freedRecords.count)
    }

    // MARK: Series for the views

    /// The last 60 10 s cells, oldest first, ending with the cell of `now`; nil where there was no reading.
    public func recentCells(_ key: String, now: TimeInterval, count: Int = recentCellCount) -> [TaskManagerHistoryCell?] {
        let last = Self.recentIndex(now)
        let cells = stacks[key]?.recent ?? [:]
        return (last - count + 1 ... last).map { cells[$0] }
    }

    /// The last 180 1 min cells, oldest first.
    public func minuteCells(_ key: String, now: TimeInterval, count: Int = minuteCellCount) -> [TaskManagerHistoryCell?] {
        let last = Self.minuteIndex(now)
        let cells = stacks[key]?.minutes ?? [:]
        return (last - count + 1 ... last).map { cells[$0] }
    }

    /// One process's last 30 10 s cells, oldest first.
    public func memberCells(_ key: String, pid: Int32, now: TimeInterval, count: Int = memberCellCount) -> [TaskManagerHistoryCell?] {
        let last = Self.recentIndex(now)
        let cells = stacks[key]?.members[pid]?.cells ?? [:]
        return (last - count + 1 ... last).map { cells[$0] }
    }

    /// Events of the stack between two times, for marks on a series.
    public func events(_ key: String, from start: TimeInterval, to end: TimeInterval) -> [TaskManagerTabEvent] {
        (stacks[key]?.events ?? []).filter { $0.time >= start && $0.time <= end }
    }
}

/// Monotonic history times on the wall clock.
public struct TaskManagerTimeline: Equatable, Sendable {
    public var now: TimeInterval
    public var wallNow: Date

    public init(now: TimeInterval, wallNow: Date) {
        self.now = now
        self.wallNow = wallNow
    }

    public func date(at time: TimeInterval) -> Date { wallNow.addingTimeInterval(time - now) }

    /// "13:02" in the person's locale.
    public func clock(_ time: TimeInterval, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("jjmm")
        return formatter.string(from: date(at: time))
    }
}
