import Foundation

// What the Task Manager's insights say about the history
// (docs/TASK-MANAGER-INSIGHTS.md §4.4). Every hint is a fixed rule over the
// readings, and its help says which: "Scripted rule, not AI". No model, no
// network.

// MARK: Heat grid

/// One cell of a heat grid: six steps of one hue for CPU, a red last step,
/// and three kinds that are not a CPU figure, each drawn with a pattern or an
/// outline of its own so the grid reads without colour vision.
public enum TaskManagerHeat: Int, CaseIterable, Sendable {
    /// No reading in the cell (the window was closed, or the tab was not there).
    case noReading
    /// Unloaded: no process. A dashed outline.
    case unloaded
    /// Asleep (frozen) the whole cell. Hatched.
    case asleep
    case idle, low, moderate, busy, high, hot

    /// Under this share of a core, a cell is idle (the table shows "0.0").
    public static let idleBelow = 0.1
    /// The upper edges of low, moderate, busy and high; hot is 60 % and up.
    public static let edges: [Double] = [3, 10, 25, 60]

    public static func level(cpu: Double) -> Self {
        switch cpu {
        case ..<idleBelow: return .idle
        case ..<edges[0]: return .low
        case ..<edges[1]: return .moderate
        case ..<edges[2]: return .busy
        case ..<edges[3]: return .high
        default: return .hot
        }
    }

    /// An asleep or unloaded cell is that, whatever it used: the readings
    /// were all asleep (or unloaded) in it. An awake cell with no CPU figure has no reading of CPU.
    public static func level(of cell: TaskManagerHistoryCell?) -> Self {
        guard let cell else { return .noReading }
        switch cell.state {
        case .unloaded: return .unloaded
        case .asleep: return .asleep
        case .awake: return cell.cpuPercent.map(level(cpu:)) ?? .noReading
        }
    }

    /// The legend's words.
    public var title: String {
        switch self {
        case .noReading: return "no reading"
        case .unloaded: return "unloaded"
        case .asleep: return "asleep"
        case .idle: return "idle"
        case .low: return "< 3 %"
        case .moderate: return "< 10 %"
        case .busy: return "< 25 %"
        case .high: return "< 60 %"
        case .hot: return "60 %+"
        }
    }

    /// The CPU steps, 0 (idle) to 5 (hot); nil for the other kinds.
    public var step: Int? {
        switch self {
        case .idle: return 0
        case .low: return 1
        case .moderate: return 2
        case .busy: return 3
        case .high: return 4
        case .hot: return 5
        case .noReading, .unloaded, .asleep: return nil
        }
    }
}

// MARK: Hints

public struct TaskManagerInsight: Equatable, Identifiable, Sendable {
    public enum Kind: Int, Comparable, Sendable {
        case growth, busyWhileHidden, burst, asleep

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    public var kind: Kind
    /// The stack's history key.
    public var key: String
    /// The tab's (or extension's) own name, for "Spotted".
    public var name: String
    /// The hint, without the name: "Grew 610 MB in 3 h on the same page, and it never fell back."
    public var text: String
    /// Its rule, for the help: "Scripted rule, not AI: …".
    public var rule: String
    /// Warning colour and ▲; else ● (asleep).
    public var isWarning: Bool
    /// Sorts hints of a kind: the bigger first.
    public var weight: Double

    public var id: String { "\(kind.rawValue)/\(key)" }
}

public enum TaskManagerInsights {
    static let megabyte = 1024.0 * 1024.0
    public static let notAI = "Scripted rule, not AI"

    // Growth (§4.4).
    public static let growthMinimumSpan: TimeInterval = 30 * 60
    public static let growthMinimumBytes = 200 * megabyte
    public static let growthMinimumSlope = 100 * megabyte  // per hour
    public static let growthMinimumFit = 0.8
    // Busy while hidden.
    public static let busyMinimumShare = 10.0
    public static let busyMinimumCells = 12  // 2 min of 10 s cells
    // Burst.
    public static let burstMinimumShare = 25.0
    public static let burstMinimumCells = 3  // 30 s
    public static let calmBelow = 10.0
    public static let calmCells = 3
    // Asleep.
    public static let asleepMinimum: TimeInterval = 5 * 60

    public static let growthRule = "\(notAI): at least 30 minutes on the same page (no navigation or reload), up 200 MB or more, "
        + "climbing steadily (a least-squares slope of 100 MB an hour or more, fit R² 0.8 or more), and the lowest reading of the "
        + "last 10 minutes above the highest of the first 10. It may be a cache by design. Reloading the page frees it."
    public static let busyRule = "\(notAI): a tab off screen and awake that used 10 % of a core or more for 2 minutes or longer."
    public static let burstRule = "\(notAI): 25 % of a core or more for 30 seconds or longer, then under 10 % for at least "
        + "30 seconds (after at most 10 seconds of winding down)."
    public static let asleepRule = "\(notAI): a tab tab sleep froze 5 minutes ago or more. Its CPU since is measured "
        + "from the readings after it settled."
    public static let avoidedRule = "≈ CPU avoided, \(notAI): the tab's average CPU in the 10 minutes before it slept, "
        + "times how long it has slept, less the CPU it used since. An estimate of what it would have used awake, never a measurement."
    public static let freedRule = "Freed: the footprint the tab's processes gave back, measured from the readings before an unload "
        + "and a few seconds after it. ≈: a process stayed alive (the engine keeps an unloaded tab's emptied frame in its process) "
        + "or other tabs share it, so only the measured drop counts. Nothing is counted that a process didn't give back."

    /// Every hint for one stack, most important first.
    public static func insights(for track: TaskManagerStackHistory, in history: TaskManagerHistory,
                                timeline: TaskManagerTimeline) -> [TaskManagerInsight] {
        [growth(track, now: timeline.now), busyWhileHidden(track, now: timeline.now),
         burst(track, timeline: timeline), asleep(track, in: history, now: timeline.now)].compactMap { $0 }
    }

    /// "Spotted": up to `limit` hints across the stacks shown, the most important kinds first.
    public static func spotted(_ keys: [String], in history: TaskManagerHistory, timeline: TaskManagerTimeline,
                               limit: Int = 3) -> [TaskManagerInsight] {
        let all = keys.compactMap { history[$0] }.flatMap { insights(for: $0, in: history, timeline: timeline) }
        return Array(all.enumerated().sorted { a, b in
            if a.element.kind != b.element.kind { return a.element.kind < b.element.kind }
            if a.element.weight != b.element.weight { return a.element.weight > b.element.weight }
            return a.offset < b.offset
        }.map(\.element).prefix(limit))
    }

    // MARK: Growth

    /// The same page over ≥ 30 min: up ≥ 200 MB, a least-squares slope ≥ 100
    /// MB/h with R² ≥ 0.8, and the minimum of the last 10 min above the
    /// maximum of the first 10 min. A navigation, reload or unload starts it again.
    public static func growth(_ track: TaskManagerStackHistory, now: TimeInterval) -> TaskManagerInsight? {
        guard track.kind == .tab else { return nil }
        let start = TaskManagerHistory.minuteIndex(track.pageSince)
        let points = track.minutes.filter { $0.key > start }.compactMap { index, cell in cell.memory.map { (index, Double($0)) } }
            .sorted { $0.0 < $1.0 }
        guard let first = points.first, let last = points.last, points.count >= 3 else { return nil }
        let span = Double(last.0 - first.0) * TaskManagerHistory.minuteSeconds
        guard span >= growthMinimumSpan else { return nil }
        let grew = last.1 - first.1
        guard grew >= growthMinimumBytes else { return nil }
        let fit = leastSquares(points.map { (Double($0.0) * TaskManagerHistory.minuteSeconds / 3600, $0.1) })
        guard fit.slope >= growthMinimumSlope, fit.r2 >= growthMinimumFit else { return nil }
        let firstTen = points.filter { $0.0 < first.0 + 10 }.map(\.1)
        let lastTen = points.filter { $0.0 > last.0 - 10 }.map(\.1)
        guard let low = lastTen.min(), let high = firstTen.max(), low > high else { return nil }
        return TaskManagerInsight(
            kind: .growth, key: track.key, name: track.name,
            text: "Grew \(TaskManagerFormat.memory(UInt64(grew))) in \(TaskManagerFormat.duration(span)) on the same page, and it never fell back.",
            rule: growthRule, isWarning: true, weight: grew
        )
    }

    /// Least squares of y on x: slope and R² (1 when y does not vary).
    static func leastSquares(_ points: [(x: Double, y: Double)]) -> (slope: Double, r2: Double) {
        let n = Double(points.count)
        let mx = points.reduce(0) { $0 + $1.x } / n
        let my = points.reduce(0) { $0 + $1.y } / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for point in points {
            sxx += (point.x - mx) * (point.x - mx)
            sxy += (point.x - mx) * (point.y - my)
            syy += (point.y - my) * (point.y - my)
        }
        guard sxx > 0 else { return (0, 0) }
        let slope = sxy / sxx
        let r2 = syy > 0 ? (sxy * sxy) / (sxx * syy) : 1
        return (slope, r2)
    }

    // MARK: Busy while hidden

    /// A hidden, awake tab at ≥ 10 % of a core for ≥ 2 min (the latest such run of 10 s cells).
    public static func busyWhileHidden(_ track: TaskManagerStackHistory, now: TimeInterval) -> TaskManagerInsight? {
        guard track.kind == .tab else { return nil }
        let cells = recentCells(track, now: now)
        guard let run = runs(cells, where: { $0.isHidden && $0.state == .awake && ($0.cpuPercent ?? 0) >= busyMinimumShare })
            .last(where: { $0.count >= busyMinimumCells }) else { return nil }
        let average = run.map { cells[$0]!.cpuPercent! }.reduce(0, +) / Double(run.count)
        var text = "Used \(String(format: "%.1f", average)) % of a core for "
            + "\(TaskManagerFormat.duration(Double(run.count) * TaskManagerHistory.cellSeconds)) while hidden"
        if case .keptAwake(let reason)? = track.state { text += " and \(doing(reason))" }
        return TaskManagerInsight(kind: .busyWhileHidden, key: track.key, name: track.name, text: text + ".",
                                  rule: busyRule, isWarning: true, weight: average * Double(run.count))
    }

    /// Why tab sleep keeps it awake, as the hint says it.
    static func doing(_ reason: TaskManagerTabState.Reason) -> String {
        switch reason {
        case .playingSound: return "playing sound"
        case .capturing: return "using the camera or microphone"
        case .shared: return "shared"
        case .downloading: return "downloading"
        case .waitingForAnswer: return "waiting for your answer"
        }
    }

    // MARK: Burst

    /// ≥ 25 % for ≥ 30 s, then calm (< 10 % for ≥ 30 s, after at most one cell between): the latest such run.
    public static func burst(_ track: TaskManagerStackHistory, timeline: TaskManagerTimeline) -> TaskManagerInsight? {
        let cells = recentCells(track, now: timeline.now)
        let calm = { (index: Int) -> Bool in
            guard cells.indices.contains(index), let cpu = cells[index]?.cpuPercent, cells[index]?.state == .awake else { return false }
            return cpu < calmBelow
        }
        let candidates = runs(cells, where: { $0.state == .awake && ($0.cpuPercent ?? 0) >= burstMinimumShare }).filter { run in
            // Calm right after, or after one cell of winding down (a cell the burst ended inside).
            run.count >= burstMinimumCells
                && ((1 ... calmCells).allSatisfy { calm(run.last! + $0) } || (2 ... calmCells + 1).allSatisfy { calm(run.last! + $0) })
        }
        guard let run = candidates.last else { return nil }
        let low = Int(run.map { cells[$0]!.cpuPercent! }.min()!.rounded())
        let high = Int(run.map { cells[$0]!.cpuPeak }.max()!.rounded())
        let start = Double(TaskManagerHistory.recentIndex(timeline.now) - (cells.count - 1) + run.first!) * TaskManagerHistory.cellSeconds
        let range = low == high ? "\(low) %" : "\(low)–\(high) %"
        return TaskManagerInsight(
            kind: .burst, key: track.key, name: track.name,
            text: "Ran \(range) for \(TaskManagerFormat.duration(Double(run.count) * TaskManagerHistory.cellSeconds)) "
                + "at \(timeline.clock(start)), then settled.",
            rule: burstRule, isWarning: true, weight: Double(high * run.count)
        )
    }

    // MARK: Asleep

    /// Asleep ≥ 5 min: for how long, and the CPU it used since.
    public static func asleep(_ track: TaskManagerStackHistory, in history: TaskManagerHistory, now: TimeInterval) -> TaskManagerInsight? {
        guard track.kind == .tab, track.state == .sleeping else { return nil }
        if let index = track.open(.fellAsleep) {
            let event = track.events[index]
            let slept = now - event.time
            guard slept >= asleepMinimum else { return nil }
            var text = "Has slept for \(TaskManagerFormat.duration(slept))"
            if let since = history.sleepEffect(of: event, in: track)?.cpuSince {
                text += since < 0.05 ? " and used no CPU since" : " and used \(TaskManagerFormat.cpuTime(since)) of CPU since"
            }
            return TaskManagerInsight(kind: .asleep, key: track.key, name: track.name, text: text + ".", rule: asleepRule,
                                      isWarning: false, weight: slept)
        }
        // Asleep before the history began: as long as the readings have seen it.
        let slept = now - track.stateSince
        guard slept >= asleepMinimum else { return nil }
        let start = TaskManagerHistory.minuteIndex(track.stateSince)
        let shares = track.minutes.filter { $0.key > start }.compactMap(\.value.cpuPercent)
        var text = "Has slept for at least \(TaskManagerFormat.duration(slept))"
        if !shares.isEmpty, shares.allSatisfy({ $0 < TaskManagerHeat.idleBelow }) { text += " and used no CPU since" }
        return TaskManagerInsight(kind: .asleep, key: track.key, name: track.name, text: text + ".", rule: asleepRule,
                                  isWarning: false, weight: slept)
    }

    // MARK: Helpers

    static func recentCells(_ track: TaskManagerStackHistory, now: TimeInterval) -> [TaskManagerHistoryCell?] {
        let last = TaskManagerHistory.recentIndex(now)
        return (last - TaskManagerHistory.recentCellCount + 1 ... last).map { track.recent[$0] }
    }

    /// Runs of consecutive cells (by position) that match.
    static func runs(_ cells: [TaskManagerHistoryCell?], where matches: (TaskManagerHistoryCell) -> Bool) -> [[Int]] {
        var result: [[Int]] = []
        var current: [Int] = []
        for (index, cell) in cells.enumerated() {
            if let cell, matches(cell) {
                current.append(index)
            } else if !current.isEmpty {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

// MARK: Tab sleep's summary strip

/// "Tab sleep now: 6 asleep, 3 unloaded · freed 1.9 GB by unloading this session".
public struct TaskManagerTabSleepSummary: Equatable, Sendable {
    public var asleep: Int
    public var unloaded: Int
    public var freedBytes: UInt64
    public var freedApproximate: Bool
    public var measuredUnloads: Int

    public init(asleep: Int, unloaded: Int, freedBytes: UInt64 = 0, freedApproximate: Bool = false, measuredUnloads: Int = 0) {
        self.asleep = asleep
        self.unloaded = unloaded
        self.freedBytes = freedBytes
        self.freedApproximate = freedApproximate
        self.measuredUnloads = measuredUnloads
    }

    /// The counts from the latest reading's stacks; freed from the measured unloads only.
    public init(stacks: [TaskManagerStack], history: TaskManagerHistory) {
        let states = stacks.filter { $0.kind == .tab }.compactMap { $0.sleep?.state }
        let freed = history.freedThisSession
        self.init(asleep: states.filter { $0 == .sleeping || $0 == .fallingAsleep }.count,
                  unloaded: states.filter { $0 == .unloaded }.count,
                  freedBytes: freed.bytes, freedApproximate: freed.approximate, measuredUnloads: freed.count)
    }

    public var text: String {
        var text = "Tab sleep now: \(asleep) asleep, \(unloaded) unloaded"
        if measuredUnloads > 0 {
            text += " · freed \(freedApproximate ? "≈ " : "")\(TaskManagerFormat.memory(freedBytes)) by unloading this session"
        }
        return text
    }

    public static let help = "Asleep: frozen, still in memory, running nothing. Unloaded: not in memory. "
        + TaskManagerInsights.freedRule + " The total counts every unload measured since Darni started, while the history was kept."
}

// MARK: Event lines

public enum TaskManagerEventText {
    /// One line of the inspector's Tab controls card.
    public static func line(_ event: TaskManagerTabEvent, track: TaskManagerStackHistory, history: TaskManagerHistory,
                            timeline: TaskManagerTimeline, isEstimate: Bool = false) -> String {
        let at = timeline.clock(event.time)
        switch event.kind {
        case .unloaded:
            let head = "Unloaded at \(at) \(event.cause.title)"
            switch event.effect {
            case .measuring: return "\(head) · measuring…"
            case .freed(let bytes, let approximate):
                guard bytes > 0 else { return "\(head) · freed nothing its process gave back" }
                return "\(head) · freed \(approximate ? "≈ " : "")\(TaskManagerFormat.memory(bytes))"
            case .notMeasured(let why): return "\(head) · not measured: \(why)"
            case .none, .sleep: return head
            }
        case .fellAsleep:
            guard let effect = history.sleepEffect(of: event, in: track, isEstimate: isEstimate) else { return "" }
            let approx = isEstimate ? "≈ " : ""
            let before = effect.cpuBefore.map { " (\(String(format: "%.1f", $0)) % average in the 10 min before)" }
                ?? " (no reading in the 10 min before)"
            if let ended = effect.endedAt {
                let used = effect.cpuSince.map { "\(approx)\(TaskManagerFormat.cpuTime($0)) CPU in \(TaskManagerFormat.duration(ended - event.time))" }
                    ?? "slept \(TaskManagerFormat.duration(ended - event.time))"
                return "Slept \(at)–\(timeline.clock(ended)) \(event.cause.title) · \(used)\(before)"
            }
            let since = effect.cpuSince.map { "\(approx)\(TaskManagerFormat.cpuTime($0)) CPU since" } ?? "measuring CPU…"
            return "Asleep since \(at) \(event.cause.title) · \(since)\(before)"
        case .woke:
            return "Woke at \(at) \(event.cause.title)"
        case .loaded:
            return "Loaded again at \(at) \(event.cause.title)"
        }
    }

    /// "≈ 38 s of CPU avoided" for a sleep, when its rule gives one worth saying.
    public static func avoided(_ event: TaskManagerTabEvent, track: TaskManagerStackHistory, history: TaskManagerHistory,
                               now: TimeInterval) -> String? {
        guard let avoided = history.sleepEffect(of: event, in: track)?.avoided(now: now), avoided >= 1 else { return nil }
        return "≈ \(TaskManagerFormat.cpuTime(avoided)) of CPU avoided"
    }
}

// MARK: VoiceOver

public enum TaskManagerAccessibility {
    /// "YouTube, average 16.5 %, peak 38 % at 14:52" (+ "asleep 4 min", "unloaded 2 min").
    public static func heatRow(name: String, cells: [TaskManagerHistoryCell?], timeline: TaskManagerTimeline) -> String {
        let shares = cells.compactMap { $0?.state == .awake ? $0?.cpuPercent : nil }
        var parts = [name]
        if shares.isEmpty {
            parts.append("no CPU readings")
        } else {
            parts.append("average \(String(format: "%.1f", shares.reduce(0, +) / Double(shares.count))) %")
            let last = TaskManagerHistory.recentIndex(timeline.now)
            if let peak = cells.indices.filter({ cells[$0]?.state == .awake && cells[$0]?.cpuPercent != nil })
                .max(by: { cells[$0]!.cpuPeak < cells[$1]!.cpuPeak }) {
                let time = Double(last - (cells.count - 1) + peak) * TaskManagerHistory.cellSeconds
                parts.append("peak \(String(format: "%.0f", cells[peak]!.cpuPeak)) % at \(timeline.clock(time))")
            }
        }
        let asleep = cells.filter { $0?.state == .asleep }.count
        let unloaded = cells.filter { $0?.state == .unloaded }.count
        if asleep > 0 { parts.append("asleep \(TaskManagerFormat.duration(Double(asleep) * TaskManagerHistory.cellSeconds))") }
        if unloaded > 0 { parts.append("unloaded \(TaskManagerFormat.duration(Double(unloaded) * TaskManagerHistory.cellSeconds))") }
        return parts.joined(separator: ", ")
    }

    public static func memorySparkline(_ cells: [TaskManagerHistoryCell?], span: String = "last 10 minutes") -> String {
        let values = cells.compactMap { $0?.memory }
        guard let first = values.first, let last = values.last, let peak = cells.compactMap({ $0?.memoryPeak }).max() else {
            return "Memory, \(span): no readings yet"
        }
        return "Memory, \(span): \(TaskManagerFormat.memory(first)) to \(TaskManagerFormat.memory(last)), peak \(TaskManagerFormat.memory(peak))"
    }

    public static func cpuSparkline(_ cells: [TaskManagerHistoryCell?]) -> String {
        let values = cells.compactMap { $0?.cpuPercent }
        guard !values.isEmpty, let peak = cells.compactMap({ $0?.cpuPercent == nil ? nil : $0?.cpuPeak }).max() else {
            return "CPU, last 10 minutes: no readings yet"
        }
        return "CPU, last 10 minutes: average \(String(format: "%.1f", values.reduce(0, +) / Double(values.count))) %, "
            + "peak \(String(format: "%.1f", peak)) %"
    }
}

// MARK: Durations

extension TaskManagerFormat {
    /// "30 s", "2 min 20 s", "45 min", "3 h", "2 h 10 min", "1 d 4 h".
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        switch total {
        case ..<60: return "\(total) s"
        case ..<600: return total % 60 == 0 ? "\(total / 60) min" : "\(total / 60) min \(total % 60) s"
        default:
            let minutes = total / 60
            switch minutes {
            case ..<60: return "\(minutes) min"
            case ..<(24 * 60): return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
            default:
                let hours = minutes / 60
                return hours % 24 == 0 ? "\(hours / 24) d" : "\(hours / 24) d \(hours % 24) h"
            }
        }
    }

    /// CPU time: "0 s", "4.2 s", "38 s", "6 min", "1 h 5 min".
    public static func cpuTime(_ seconds: Double) -> String {
        switch seconds {
        case ..<0.05: return "0 s"
        case ..<10: return String(format: "%.1f s", seconds)
        case ..<60: return String(format: "%.0f s", seconds)
        default: return duration(seconds)
        }
    }
}
