import Foundation

// The Task Manager window (Window › Task Manager), after Chrome's: every
// engine process with the tasks it runs, its memory, CPU and network use.
// The engine lists processes (`ReArcEngineGetProcesses`); the shell knows
// what the tabs, profiles and extensions in them are called. Everything
// here is the arithmetic between the two, so it can be tested with made-up
// process lists.

/// One engine process, as one reading of the engine's list has it.
public struct TaskManagerProcess: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case browser, renderer, gpu, utility, other
    }

    /// What an engine with `task_manager` (ABI 1.65) adds to the list.
    public struct Details: Equatable, Sendable {
        /// The tabs whose page (primary main frame) runs here.
        public var mainFrameTabIDs: [UInt64]
        /// The tabs that only have a frame of another site of their page
        /// here. A tab in `tabIDs` and in neither list has a page kept for
        /// Back here, or one loading ahead: nothing the person sees.
        public var subframeTabIDs: [UInt64]
        /// The site of those frames.
        public var site: String
        /// An extension process: which extension.
        public var extensionID: String
        public var extensionName: String
        /// Chromium's warmed-up renderer that no page uses yet.
        public var isSpare: Bool
        /// The process's name as Chromium shows it ("Network Service").
        public var title: String
        /// Bytes received and sent for this process since the engine started.
        public var networkBytes: UInt64

        public init(
            mainFrameTabIDs: [UInt64] = [], subframeTabIDs: [UInt64] = [], site: String = "", extensionID: String = "",
            extensionName: String = "", isSpare: Bool = false, title: String = "", networkBytes: UInt64 = 0
        ) {
            self.mainFrameTabIDs = mainFrameTabIDs
            self.subframeTabIDs = subframeTabIDs
            self.site = site
            self.extensionID = extensionID
            self.extensionName = extensionName
            self.isSpare = isSpare
            self.title = title
            self.networkBytes = networkBytes
        }

        /// The engine's `details_json` (`ReArcEngineGetProcessDetails`): an
        /// object keyed by pid. 64-bit numbers come as strings; a key the
        /// shell does not know is ignored, a missing one keeps its default.
        public static func byProcess(json: String) -> [Int32: Details] {
            guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: Any]] else {
                return [:]
            }
            var result: [Int32: Details] = [:]
            for (key, entry) in object {
                guard let pid = Int32(key) else { continue }
                var details = Details()
                details.mainFrameTabIDs = (entry["main_frame_tabs"] as? [String] ?? []).compactMap { UInt64($0) }
                details.subframeTabIDs = (entry["subframe_tabs"] as? [String] ?? []).compactMap { UInt64($0) }
                details.site = entry["site"] as? String ?? ""
                details.extensionID = entry["extension_id"] as? String ?? ""
                details.extensionName = entry["extension_name"] as? String ?? ""
                details.isSpare = entry["spare"] as? Bool ?? false
                details.title = entry["title"] as? String ?? ""
                details.networkBytes = (entry["network_bytes"] as? String).flatMap { UInt64($0) } ?? 0
                result[pid] = details
            }
            return result
        }
    }

    public var pid: Int32
    public var kind: Kind
    /// A utility's service name; empty for the others.
    public var name: String
    /// The engine's profile ID of a renderer, 0 for none.
    public var profileID: UInt64
    public var isExtension: Bool
    /// Engine tab IDs with a frame in this process.
    public var tabIDs: [UInt64]
    /// `phys_footprint`, Activity Monitor's Memory column.
    public var memoryFootprint: UInt64
    /// User and system CPU time since the process started.
    public var cpuMicros: Int64
    /// nil from an engine without `task_manager`.
    public var details: Details?

    public init(
        pid: Int32, kind: Kind, name: String = "", profileID: UInt64 = 0, isExtension: Bool = false,
        tabIDs: [UInt64] = [], memoryFootprint: UInt64 = 0, cpuMicros: Int64 = 0, details: Details? = nil
    ) {
        self.pid = pid
        self.kind = kind
        self.name = name
        self.profileID = profileID
        self.isExtension = isExtension
        self.tabIDs = tabIDs
        self.memoryFootprint = memoryFootprint
        self.cpuMicros = cpuMicros
        self.details = details
    }
}

/// What the shell calls the things the engine lists by ID.
public struct TaskManagerDirectory: Equatable, Sendable {
    public struct Tab: Equatable, Sendable {
        public var title: String
        /// A page of a private window.
        public var isPrivate: Bool
        /// The extension whose page this tab shows (a popup, a side panel, an options page).
        public var extensionID: String?

        public init(title: String, isPrivate: Bool = false, extensionID: String? = nil) {
            self.title = title
            self.isPrivate = isPrivate
            self.extensionID = extensionID
        }
    }

    /// By engine tab ID. A tab the shell has no page for is left out.
    public var tabs: [UInt64: Tab]
    /// Profile names by engine profile ID.
    public var profiles: [UInt64: String]
    /// Extension names by extension ID.
    public var extensions: [String: String]

    public init(tabs: [UInt64: Tab] = [:], profiles: [UInt64: String] = [:], extensions: [String: String] = [:]) {
        self.tabs = tabs
        self.profiles = profiles
        self.extensions = extensions
    }
}

/// What a process used between two readings. nil: not known (the first
/// reading, a process that just started, an engine that does not count it).
public struct TaskManagerUsage: Equatable, Sendable {
    /// Percent of one core, so a busy process on several cores passes 100.
    public var cpuPercent: Double?
    public var networkBytesPerSecond: Double?

    public init(cpuPercent: Double? = nil, networkBytesPerSecond: Double? = nil) {
        self.cpuPercent = cpuPercent
        self.networkBytesPerSecond = networkBytesPerSecond
    }
}

/// Turns the engine's running totals into rates over the refresh interval.
public struct TaskManagerSampler: Equatable, Sendable {
    private struct Reading: Equatable, Sendable {
        var cpuMicros: Int64
        var networkBytes: UInt64?
    }

    private var previous: [Int32: Reading] = [:]
    private var previousTime: TimeInterval?

    public init() {}

    /// Forgets the last reading: the next one has nothing to compare with.
    public mutating func reset() {
        previous = [:]
        previousTime = nil
    }

    /// `time` is a clock that never goes back, in seconds. A total that
    /// went down belongs to a new process with a reused pid: no rate.
    public mutating func usage(of processes: [TaskManagerProcess], at time: TimeInterval) -> [Int32: TaskManagerUsage] {
        let elapsed = previousTime.map { time - $0 } ?? 0
        var result: [Int32: TaskManagerUsage] = [:]
        var readings: [Int32: Reading] = [:]
        for process in processes {
            let reading = Reading(cpuMicros: process.cpuMicros, networkBytes: process.details?.networkBytes)
            readings[process.pid] = reading
            guard elapsed > 0, let before = previous[process.pid], reading.cpuMicros >= before.cpuMicros else {
                result[process.pid] = TaskManagerUsage()
                continue
            }
            var usage = TaskManagerUsage(cpuPercent: Double(reading.cpuMicros - before.cpuMicros) / (elapsed * 1_000_000) * 100)
            if let now = reading.networkBytes, let then = before.networkBytes, now >= then {
                usage.networkBytesPerSecond = Double(now - then) / elapsed
            }
            result[process.pid] = usage
        }
        previous = readings
        previousTime = time
        return result
    }
}

/// The window's three segments, as Chrome's.
public enum TaskManagerCategory: String, CaseIterable, Sendable {
    case tabsAndExtensions, browser, all

    public var title: String {
        switch self {
        case .tabsAndExtensions: return "Tabs and extensions"
        case .browser: return "Browser"
        case .all: return "All tasks"
        }
    }
}

/// One line of the table: a tab, a frame, an extension or the process itself.
public struct TaskManagerTask: Equatable, Identifiable, Sendable {
    public enum Icon: Equatable, Sendable {
        /// ReArc's own icon.
        case browser
        /// The page's site icon, by engine tab ID.
        case tab(UInt64)
        /// The extension's icon; nil when the shell cannot tell which extension.
        case browserExtension(String?)
        /// The engine's own helpers.
        case system
    }

    /// The same from one reading to the next.
    public var id: String
    public var title: String
    public var icon: Icon

    public init(id: String, title: String, icon: Icon) {
        self.id = id
        self.title = title
        self.icon = icon
    }
}

/// One process and the tasks that share it.
public struct TaskManagerGroup: Equatable, Sendable {
    public var pid: Int32
    public var kind: TaskManagerProcess.Kind
    /// The segment the process belongs to (never `.all`).
    public var category: TaskManagerCategory
    /// At least one.
    public var tasks: [TaskManagerTask]
    public var profile: String
    public var memoryFootprint: UInt64
    public var usage: TaskManagerUsage
    /// The tabs that stop working when this process ends, by title.
    public var tabTitles: [String]

    /// Everything but ReArc itself can be ended.
    public var isKillable: Bool { kind != .browser && pid > 0 }
}

/// A group's task with the group's figures, for one table row.
public struct TaskManagerRow: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var icon: TaskManagerTask.Icon
    public var pid: Int32
    /// Tasks sharing a process show its figures on their first row only.
    public var isFirstInGroup: Bool
    public var profile: String
    public var memoryFootprint: UInt64
    public var usage: TaskManagerUsage
    public var isKillable: Bool

    /// The cell's text. A figure of the whole process is blank on every row but the group's first.
    public func text(for column: TaskManagerColumn) -> String {
        if column.isSharedByGroup, !isFirstInGroup { return "" }
        switch column {
        case .task: return title
        case .profile: return profile
        case .memoryFootprint: return TaskManagerFormat.memory(memoryFootprint)
        case .cpu: return TaskManagerFormat.cpu(usage.cpuPercent)
        case .network: return TaskManagerFormat.network(usage.networkBytesPerSecond)
        // A pid is a number for a terminal: no grouping.
        case .processID: return String(pid)
        }
    }
}

public enum TaskManagerColumn: String, CaseIterable, Codable, Sendable {
    case task, profile, memoryFootprint, cpu, network, processID

    public var title: String {
        switch self {
        case .task: return "Task"
        case .profile: return "Profile"
        case .memoryFootprint: return "Memory footprint"
        case .cpu: return "CPU"
        case .network: return "Network"
        case .processID: return "Process ID"
        }
    }

    /// The task's name always shows.
    public var canHide: Bool { self != .task }

    /// One value for the whole process, shown on its first row.
    public var isSharedByGroup: Bool { self != .task && self != .profile }
}

/// The columns the header's menu has switched on. Kept across launches.
public struct TaskManagerColumns: Equatable, Sendable {
    public private(set) var visible: Set<TaskManagerColumn>

    public init(visible: Set<TaskManagerColumn> = Set(TaskManagerColumn.allCases)) {
        self.visible = visible.union([.task])
    }

    /// In the table's order.
    public var ordered: [TaskManagerColumn] { TaskManagerColumn.allCases.filter(visible.contains) }

    public func isVisible(_ column: TaskManagerColumn) -> Bool { visible.contains(column) }

    public mutating func toggle(_ column: TaskManagerColumn) {
        guard column.canHide else { return }
        if visible.contains(column) { visible.remove(column) } else { visible.insert(column) }
    }

    static let defaultsKey = "ReArcTaskManagerColumns"

    /// Names this build does not know are ignored; nothing saved shows every column.
    public static func load(from defaults: UserDefaults) -> TaskManagerColumns {
        guard let names = defaults.stringArray(forKey: defaultsKey) else { return TaskManagerColumns() }
        return TaskManagerColumns(visible: Set(names.compactMap(TaskManagerColumn.init(rawValue:))))
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(ordered.map(\.rawValue), forKey: Self.defaultsKey)
    }
}

public struct TaskManagerSort: Equatable, Sendable {
    public var column: TaskManagerColumn
    public var ascending: Bool

    public init(column: TaskManagerColumn, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }
}

/// From process lists to the rows on screen.
public enum TaskManagerRows {
    /// One group per process, ReArc first, then the engine's helpers, then
    /// the pages, each kind by process ID. The order holds from one reading
    /// to the next, so rows do not jump about.
    public static func groups(
        processes: [TaskManagerProcess], usage: [Int32: TaskManagerUsage] = [:], directory: TaskManagerDirectory
    ) -> [TaskManagerGroup] {
        processes
            .map { process in
                let (tasks, category, tabTitles) = tasks(of: process, directory: directory)
                return TaskManagerGroup(
                    pid: process.pid, kind: process.kind, category: category, tasks: tasks,
                    profile: directory.profiles[process.profileID] ?? "", memoryFootprint: process.memoryFootprint,
                    usage: usage[process.pid] ?? TaskManagerUsage(), tabTitles: tabTitles
                )
            }
            .sorted(by: inDefaultOrder)
    }

    /// The rows of one segment that match the search, sorted. A process
    /// stays whole, as in Chrome: it shows when any of its tasks matches,
    /// and sorting moves it with all its tasks.
    public static func rows(
        _ groups: [TaskManagerGroup], category: TaskManagerCategory = .all, search: String = "", sort: TaskManagerSort? = nil
    ) -> [TaskManagerRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var shown = groups.filter { group in
            (category == .all || group.category == category)
                && (query.isEmpty || group.tasks.contains { matches($0.title, query) })
        }
        if let sort {
            shown.sort { a, b in
                switch compare(a, b, by: sort.column) {
                case .orderedSame: return inDefaultOrder(a, b)
                case .orderedAscending: return sort.ascending
                case .orderedDescending: return !sort.ascending
                }
            }
            // A figure that is not known goes last whichever way the column sorts.
            let known = shown.filter { hasValue($0, for: sort.column) }
            shown = known + shown.filter { !hasValue($0, for: sort.column) }
        }
        return shown.flatMap { group in
            group.tasks.enumerated().map { index, task in
                TaskManagerRow(
                    id: task.id, title: task.title, icon: task.icon, pid: group.pid, isFirstInGroup: index == 0,
                    profile: group.profile, memoryFootprint: group.memoryFootprint, usage: group.usage,
                    isKillable: group.isKillable
                )
            }
        }
    }

    /// A utility's name for its row. An engine without `task_manager` gives
    /// the service's interface ("network.mojom.NetworkService"): its last
    /// part, in words. A name that already has words is kept.
    public static func utilityName(_ name: String) -> String {
        guard !name.isEmpty, !name.contains(" "), let last = name.split(separator: ".").last else { return name }
        var words = ""
        for character in last {
            if character.isUppercase, let previous = words.last, previous.isLowercase || previous.isNumber { words.append(" ") }
            words.append(character)
        }
        return words
    }

    // MARK: Tasks of one process

    private static func tasks(
        of process: TaskManagerProcess, directory: TaskManagerDirectory
    ) -> (tasks: [TaskManagerTask], category: TaskManagerCategory, tabTitles: [String]) {
        let pid = process.pid
        func single(_ title: String, _ icon: TaskManagerTask.Icon) -> [TaskManagerTask] {
            [TaskManagerTask(id: "\(pid)", title: title, icon: icon)]
        }
        switch process.kind {
        case .browser:
            return (single("Browser", .browser), .browser, [])
        case .gpu:
            return (single("GPU Process", .system), .browser, [])
        case .utility:
            let name = process.details.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? utilityName(process.name)
            return (single(name.isEmpty ? "Utility" : "Utility: \(name)", .system), .browser, [])
        case .other:
            return (single(process.name.isEmpty ? "Helper" : utilityName(process.name), .system), .browser, [])
        case .renderer:
            break
        }

        let known = process.tabIDs.compactMap { id in directory.tabs[id].map { (id: id, tab: $0) } }
        if process.isExtension {
            let id = process.details.map(\.extensionID).flatMap { $0.isEmpty ? nil : $0 }
                ?? known.lazy.compactMap(\.tab.extensionID).first
            let name = process.details.map(\.extensionName).flatMap { $0.isEmpty ? nil : $0 }
                ?? id.flatMap { directory.extensions[$0] }
            return (single(name.map { "Extension: \($0)" } ?? "Extension", .browserExtension(id)), .tabsAndExtensions, [])
        }

        // Without `task_manager` the engine does not say which tabs only have
        // a frame here: every tab with a frame in the process is listed as a tab.
        let mainFrames = process.details.map { Set($0.mainFrameTabIDs) }
        var tasks: [TaskManagerTask] = []
        var tabTitles: [String] = []
        for (id, tab) in known where mainFrames?.contains(id) ?? true {
            tasks.append(TaskManagerTask(id: "\(pid)/tab/\(id)", title: "\(tab.isPrivate ? "Private tab" : "Tab"): \(tab.title)", icon: .tab(id)))
            tabTitles.append(tab.title)
        }
        if let mainFrames, let details = process.details {
            let subframes = Set(details.subframeTabIDs).subtracting(mainFrames)
            for (id, tab) in known where subframes.contains(id) {
                let prefix = tab.isPrivate ? "Private subframe" : "Subframe"
                tasks.append(TaskManagerTask(
                    id: "\(pid)/frame/\(id)", title: details.site.isEmpty ? prefix : "\(prefix): \(details.site)", icon: .tab(id)
                ))
            }
        }
        if !tasks.isEmpty { return (tasks, .tabsAndExtensions, tabTitles) }
        // No page of the shell's: Chrome lists these with the browser's own processes.
        let title = process.details?.isSpare == true ? "Spare renderer" : "Renderer"
        return (single(title, .system), .browser, [])
    }

    // MARK: Order

    private static func rank(_ kind: TaskManagerProcess.Kind) -> Int {
        switch kind {
        case .browser: return 0
        case .gpu: return 1
        case .utility: return 2
        case .other: return 3
        case .renderer: return 4
        }
    }

    private static func inDefaultOrder(_ a: TaskManagerGroup, _ b: TaskManagerGroup) -> Bool {
        (rank(a.kind), a.pid) < (rank(b.kind), b.pid)
    }

    private static func hasValue(_ group: TaskManagerGroup, for column: TaskManagerColumn) -> Bool {
        switch column {
        case .cpu: return group.usage.cpuPercent != nil
        case .network: return group.usage.networkBytesPerSecond != nil
        case .task, .profile, .memoryFootprint, .processID: return true
        }
    }

    private static func compare(_ a: TaskManagerGroup, _ b: TaskManagerGroup, by column: TaskManagerColumn) -> ComparisonResult {
        func order<Value: Comparable>(_ x: Value, _ y: Value) -> ComparisonResult {
            x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        }
        switch column {
        case .task: return (a.tasks.first?.title ?? "").localizedStandardCompare(b.tasks.first?.title ?? "")
        case .profile: return a.profile.localizedStandardCompare(b.profile)
        case .memoryFootprint: return order(a.memoryFootprint, b.memoryFootprint)
        case .cpu: return order(a.usage.cpuPercent ?? 0, b.usage.cpuPercent ?? 0)
        case .network: return order(a.usage.networkBytesPerSecond ?? 0, b.usage.networkBytesPerSecond ?? 0)
        case .processID: return order(a.pid, b.pid)
        }
    }

    private static func matches(_ title: String, _ query: String) -> Bool {
        title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// Which rows a click selects. A process is selected whole, as in Chrome:
/// a click on any of its tasks takes them all.
public enum TaskManagerSelection {
    /// `pids` is the process of each row on screen. `proposed` is what the
    /// table would select by itself, `current` what is selected now.
    /// `toggles`: a ⌘-click, which adds a row or takes one away; taking
    /// one row of a process away lets the whole process go.
    public static func rows(proposed: IndexSet, current: IndexSet, pids: [Int32], toggles: Bool) -> IndexSet {
        func processes(_ rows: IndexSet) -> Set<Int32> {
            Set(rows.filter(pids.indices.contains).map { pids[$0] })
        }
        var wanted = processes(proposed)
        if toggles { wanted.subtract(processes(current.subtracting(proposed))) }
        return IndexSet(pids.indices.filter { wanted.contains(pids[$0]) })
    }
}

/// The table's cell text, as Chrome on macOS writes it.
public enum TaskManagerFormat {
    /// Chrome's cell for a figure it does not have.
    public static let notAvailable = "–"

    /// "512 B", "84.5 MB", "1.2 GB": 1024 to a unit, one decimal under 100.
    public static func memory(_ bytes: UInt64) -> String {
        amount(Double(bytes), units: ["B", "KB", "MB", "GB", "TB"])
    }

    /// One decimal, "–" when not known.
    public static func cpu(_ percent: Double?) -> String {
        guard let percent else { return notAvailable }
        return String(format: "%.1f", max(0, percent))
    }

    /// "0" when idle, "–" when the engine does not count it.
    public static func network(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return notAvailable }
        guard bytesPerSecond >= 0.5 else { return "0" }
        return amount(bytesPerSecond, units: ["B/s", "KB/s", "MB/s", "GB/s"])
    }

    private static func amount(_ value: Double, units: [String]) -> String {
        var value = value
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        let text = unit == 0 || value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return "\(text) \(units[unit])"
    }
}

/// End task on processes that run more than one tab asks first.
public struct TaskManagerEndConfirmation: Equatable, Sendable {
    public var title: String
    public var message: String

    /// nil: nothing to ask, ending them stops at most one tab each.
    public init?(ending groups: [TaskManagerGroup]) {
        let shared = groups.filter { $0.isKillable && $0.tabTitles.count > 1 }
        guard !shared.isEmpty else { return nil }
        let titles = shared.flatMap(\.tabTitles)
        title = "End the \(shared.count == 1 ? "process" : "processes") behind \(titles.count) tabs?"
        let listed = titles.prefix(Self.listedTabs).map { "“\($0)”" }
        let rest = titles.count - listed.count
        let names = rest > 0
            ? listed.joined(separator: ", ") + " and \(rest) more"
            : listed.dropLast().joined(separator: ", ") + " and " + (listed.last ?? "")
        message = "\(names) share \(shared.count == 1 ? "a process" : "processes"). "
            + "They stop until you reload them, and anything not saved in them is lost."
    }

    static let listedTabs = 4
}
