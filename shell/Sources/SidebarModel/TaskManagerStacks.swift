import Foundation

// The Task Manager's stacks: every tab with the processes that work for
// it, under one row with their total. Also the tab sleep columns (State,
// Idle) and the tabs with no process at all (unloaded).
//
// Shared processes: a process can work for several tabs (two tabs of one
// site share their renderer; a frame's process can serve two pages). Each
// tab's row counts an even share of it: a process three tabs use adds a
// third of its memory, CPU and network to each. The stacks then add up to
// the processes, with nothing counted twice. The process's own row under
// each tab shows its whole figures and says how many tabs share it.

// MARK: Tab sleep

/// What tab sleep has done with a tab, for the State column.
public enum TaskManagerTabState: Equatable, Sendable {
    /// Why a hidden tab is not put to sleep: the checks' reasons (`TabUnloadCandidate.isInUse`).
    public enum Reason: Equatable, Sendable {
        case playingSound, capturing, shared, downloading, waitingForAnswer
    }

    /// Running as usual: on screen, or not unseen long enough yet.
    case active
    /// Hidden and running: something on it is in use, so it never sleeps.
    case keptAwake(Reason)
    /// Darni asked the engine to freeze the page, and the page has not stopped yet.
    case fallingAsleep
    /// Frozen: in memory, running nothing.
    case sleeping
    /// No page in memory and no process: tab sleep or the person unloaded it this session.
    case unloaded
    /// No page in memory and no process: not opened since Darni started (or never in Darni).
    case notLoaded

    public var title: String {
        switch self {
        case .active: return "Active"
        case .keptAwake(let reason):
            switch reason {
            case .playingSound: return "Kept awake: sound"
            case .capturing: return "Kept awake: camera or mic"
            case .shared: return "Kept awake: shared"
            case .downloading: return "Kept awake: download"
            case .waitingForAnswer: return "Kept awake: waiting for you"
            }
        case .fallingAsleep: return "Falling asleep"
        case .sleeping: return "Sleeping"
        case .unloaded: return "Unloaded"
        case .notLoaded: return "Not loaded"
        }
    }

    /// The cell's tooltip.
    public var explanation: String {
        switch self {
        case .active: return "Running as usual."
        case .keptAwake(let reason):
            switch reason {
            case .playingSound: return "Doesn't sleep while it plays sound."
            case .capturing: return "Doesn't sleep while it uses the camera, the microphone or shares your screen."
            case .shared: return "Doesn't sleep while it's shared."
            case .downloading: return "Doesn't sleep while its download runs."
            case .waitingForAnswer: return "Doesn't sleep while it waits for your answer."
            }
        case .fallingAsleep: return "Darni asked the page to sleep. It hasn't stopped yet."
        case .sleeping: return "Frozen: still in memory, but running nothing. Wakes at once when you show it."
        case .unloaded: return "Not in memory. Loads again when you show it."
        case .notLoaded: return "Not opened since Darni started. Loads when you show it."
        }
    }

    /// Sorting from awake to unloaded.
    var rank: Int {
        switch self {
        case .active: return 0
        case .keptAwake: return 1
        case .fallingAsleep: return 2
        case .sleeping: return 3
        case .unloaded: return 4
        case .notLoaded: return 5
        }
    }

    /// A tab with a live engine, as tab sleep's checks see it. `isDiscarded`:
    /// the shell unloaded it. `isPageFrozen`: what the renderer reports, nil
    /// when the engine cannot say (then a freeze request counts as asleep).
    public static func of(_ candidate: TabUnloadCandidate, isDiscarded: Bool, isPageFrozen: Bool?) -> TaskManagerTabState {
        if isDiscarded { return .unloaded }
        if candidate.isVisible { return .active }
        if candidate.isFrozen { return isPageFrozen == false ? .fallingAsleep : .sleeping }
        if candidate.isAudible { return .keptAwake(.playingSound) }
        if candidate.isCapturing { return .keptAwake(.capturing) }
        if candidate.isShared { return .keptAwake(.shared) }
        if candidate.hasDownload { return .keptAwake(.downloading) }
        if candidate.hasPendingPrompt { return .keptAwake(.waitingForAnswer) }
        return .active
    }
}

/// A tab's State and Idle cells.
public struct TaskManagerTabSleep: Equatable, Sendable {
    public var state: TaskManagerTabState
    /// Seconds since the tab was last on screen; nil when not known.
    public var idle: TimeInterval?
    /// On screen now: idle "Now".
    public var isOnScreen: Bool
    /// False: the only date the tab has is when it was imported or made, so
    /// Idle says "Not opened in Darni" instead of a time.
    public var openedInDarni: Bool

    public init(state: TaskManagerTabState, idle: TimeInterval? = nil, isOnScreen: Bool = false, openedInDarni: Bool = true) {
        self.state = state
        self.idle = idle
        self.isOnScreen = isOnScreen
        self.openedInDarni = openedInDarni
    }

    /// The Idle cell.
    public var idleText: String {
        openedInDarni || isOnScreen ? TaskManagerFormat.idle(idle, onScreen: isOnScreen) : TaskManagerHelp.notOpenedInDarni
    }
}

/// A tab of the sidebar with no page in memory: unloaded by tab sleep or by
/// hand, or not opened since Darni started.
public struct TaskManagerUnloadedTab: Equatable, Sendable {
    /// The sidebar tab's ID.
    public var id: String
    public var title: String
    public var profile: String
    public var idle: TimeInterval?
    /// Tab sleep or the person unloaded it this session; false: it was never
    /// loaded since Darni started.
    public var wasUnloaded: Bool
    /// False: its only date is its import or creation time (`TaskManagerTabSleep.openedInDarni`).
    public var openedInDarni: Bool

    public init(id: String, title: String, profile: String = "", idle: TimeInterval? = nil, wasUnloaded: Bool = true,
                openedInDarni: Bool = true) {
        self.id = id
        self.title = title
        self.profile = profile
        self.idle = idle
        self.wasUnloaded = wasUnloaded
        self.openedInDarni = openedInDarni
    }

    /// Its own row: unloaded this session, or opened within the last day. The
    /// others fold into the "Not loaded" group (`TaskManagerRows.notLoadedStackID`).
    public var hasOwnRow: Bool {
        wasUnloaded || (openedInDarni && (idle ?? .infinity) < TaskManagerRows.foldAfter)
    }

    /// Several tabs with the very same last-active time (to the second) got it
    /// from an import or from being made together, not from being opened:
    /// Arc's import stamps every tab with the import's time. `stamps` counts
    /// the tabs per second.
    public static func isBatchStamp(_ date: Date?, counts stamps: [Int: Int]) -> Bool {
        guard let date else { return true }
        return (stamps[Int(date.timeIntervalSinceReferenceDate.rounded(.down))] ?? 0) >= batchSize
    }

    /// The tabs per second of their last-active times, for `isBatchStamp`.
    public static func stampCounts(_ dates: [Date?]) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for case let date? in dates { counts[Int(date.timeIntervalSinceReferenceDate.rounded(.down)), default: 0] += 1 }
        return counts
    }

    public static let batchSize = 3

    /// Opened in Darni: its mark (`TabOpenedMarks`) says so. A tab with no
    /// mark yet (one from before marks, or one an older build opened) falls
    /// back to the same-second rule: not opened only when its last-active
    /// time is a batch's stamp. The fallback ends for each tab the first time
    /// it is shown or loaded, which writes its mark.
    public static func isOpenedInDarni(mark: Date?, lastActiveAt: Date?, counts stamps: [Int: Int]) -> Bool {
        if mark != nil { return true }
        return !isBatchStamp(lastActiveAt, counts: stamps)
    }
}

/// Why the sidebar's Sleep Tab (and the Task Manager's Sleep) is off for a
/// tab; nil from `BrowserViewModel.sleepTabUnavailable` when it applies.
public enum TabSleepUnavailable: Equatable, Sendable {
    /// No page in memory: nothing to freeze.
    case notLoaded
    /// Unloaded by tab sleep or by hand.
    case unloaded
    case onScreen
    /// Already asked to sleep, frozen or about to be.
    case asleep
    /// Sound, camera or microphone, a share, a download or a question keeps it awake.
    case inUse(TaskManagerTabState.Reason)
    /// The engine has no freeze (WebKit, or Chromium without `tab_freeze`).
    case engineCannotFreeze
    /// Not a tab tab sleep looks after (a page in another role).
    case notNow

    /// The disabled item's tooltip.
    public var text: String {
        switch self {
        case .notLoaded: return "Not loaded: nothing in memory to freeze."
        case .unloaded: return "Already unloaded."
        case .onScreen: return "On screen. A tab sleeps once you leave it."
        case .asleep: return "Already asleep."
        case .inUse(let reason): return TaskManagerTabState.keptAwake(reason).explanation
        case .engineCannotFreeze: return "This engine can't freeze a tab."
        case .notNow: return "Can't put this tab to sleep now."
        }
    }

    /// The Sleep item's tooltip when it applies.
    public static let sleepHelp = "Freezes the tab now: it stays in memory and runs nothing until you show it."
}

/// Tab sleep's settings as the State column's help tells them.
public struct TaskManagerSleepSettings: Equatable, Sendable {
    /// Freeze after this long unseen; nil: never.
    public var freezeAfter: TimeInterval?
    /// Unload after this long unseen; nil: never.
    public var unloadAfter: TimeInterval?
    /// The engine can freeze a page (Chromium `tab_freeze`).
    public var canFreeze: Bool

    public init(freezeAfter: TimeInterval?, unloadAfter: TimeInterval?, canFreeze: Bool) {
        self.freezeAfter = freezeAfter
        self.unloadAfter = unloadAfter
        self.canFreeze = canFreeze
    }

    public init(freeze: TabFreezeThreshold, unload: TabUnloadThreshold, canFreeze: Bool) {
        self.init(freezeAfter: freeze.interval, unloadAfter: unload.interval, canFreeze: canFreeze)
    }
}

/// The column headers' tooltips, in Darni's words.
public enum TaskManagerHelp {
    /// What the states mean, with the waits the person chose.
    public static func state(_ settings: TaskManagerSleepSettings?) -> String {
        let settings = settings ?? TaskManagerSleepSettings(freeze: .default, unload: .default, canFreeze: true)
        var lines = ["What tab sleep is doing with each tab.", "Active: runs as usual."]
        if !settings.canFreeze {
            lines.append("Sleeping: this engine can't freeze a tab, so tabs run until they're unloaded.")
        } else if let freeze = settings.freezeAfter {
            lines.append("Sleeping: you haven't looked at the tab for \(duration(freeze)), so Darni froze it. "
                + "It stays in memory, which is why it's still listed here, but runs nothing: no scripts, no timers. "
                + "It wakes at once when you show it, without reloading.")
            lines.append("Falling asleep: Darni asked the tab to sleep, and the page hasn't stopped yet.")
        } else {
            lines.append("Sleeping: off. Choose when tabs sleep in Settings › General.")
        }
        if let unload = settings.unloadAfter {
            lines.append("Unloaded: after \(duration(unload)) unseen, the page leaves memory and has no process. "
                + "The tab stays in the sidebar and loads again when you show it. Tabs you haven't opened since Darni started are unloaded too.")
        } else {
            lines.append("Unloaded: no page in memory and no process: a tab you unloaded, or one you haven't opened since Darni started. "
                + "It loads again when you show it.")
        }
        lines.append("Not loaded: a tab not opened since Darni started. Those last opened more than a day ago "
            + "(or never in Darni) fold into one row at the bottom, left out of every total.")
        lines.append("Kept awake: a tab that plays sound, uses the camera or microphone, is shared, downloads or waits for your answer never sleeps.")
        return lines.joined(separator: "\n")
    }

    public static let idle = "How long since you last looked at the tab. Now: it's on screen. "
        + "Not opened in Darni: Darni has never shown or loaded it, and its only date is when it was imported or made."

    public static let notOpenedInDarni = "Not opened in Darni"

    public static let notLoadedGroup = "Tabs not opened in this session and last opened more than a day ago (or never in Darni). "
        + "They use no memory and are left out of every total. Unloaded tabs, and tabs opened within the last day, keep their own rows."

    public static let estimate = "A tab's row adds up the processes under it, so it's an estimate (≈). "
        + "A process several tabs share is split evenly between them: each tab counts its share, and nothing is counted twice."

    /// "30 minutes", "1 hour", "4 hours".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}

// MARK: Filter

/// The window's filter: everything in stacks, or one kind of task.
public enum TaskManagerFilter: String, CaseIterable, Sendable {
    case all, tabs, subframes, extensions, browser

    public var title: String {
        switch self {
        case .all: return "All"
        case .tabs: return "Tabs"
        case .subframes: return "Subframes"
        case .extensions: return "Extensions"
        case .browser: return "Browser"
        }
    }

    /// Subframes and the browser's own processes are listed one by one, not in stacks.
    var isFlat: Bool { self == .subframes || self == .browser }
}

// MARK: Stacks

/// Where Show Tab goes.
public enum TaskManagerTabRef: Hashable, Sendable {
    /// A tab with a page, by engine tab ID.
    case engine(UInt64)
    /// A sidebar tab with no page in memory, by its sidebar ID.
    case sidebar(String)
}

/// One tab (or Darni itself, or an extension) with the processes that work for it.
public struct TaskManagerStack: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Darni's own processes: the browser, the GPU process, the utilities.
        case browser
        case tab
        /// The engine does not say which tab an extension's work is for (its
        /// content scripts run in the tab's own process): each extension is a stack of its own.
        case browserExtension
        /// The folded group of tabs not loaded for more than a day (`folded`).
        case notLoaded
    }

    /// One process's part in the stack.
    public struct Member: Equatable, Sendable {
        /// The member's row: "Page: https://mail.google.com/", "Subframe: …", "GPU Process".
        public var task: TaskManagerTask
        public var pid: Int32
        public var processKind: TaskManagerProcess.Kind
        public var profile: String
        /// The whole process's figures.
        public var memoryFootprint: UInt64
        public var usage: TaskManagerUsage
        public var isKillable: Bool
        /// How many stacks this process works for (1: this one only).
        public var sharedBy: Int
        /// The whole process's CPU time since it started.
        public var cpuMicros: Int64 = 0

        /// The part of the process's figures this stack counts.
        public var share: Double { 1 / Double(max(1, sharedBy)) }
    }

    public var id: String
    public var kind: Kind
    /// "Tab: Gmail", "Darni", "Extension: 1Password".
    public var title: String
    /// The tab's own title, for a subframe listed outside its stack ("in Gmail").
    public var name: String
    public var icon: TaskManagerTask.Icon
    public var profile: String
    public var members: [Member]
    public var sleep: TaskManagerTabSleep?
    public var tab: TaskManagerTabRef?
    /// What the history files the stack under: the sidebar tab when the shell
    /// knows it (so a tab keeps its history across an unload and a load), else the stack's ID.
    public var historyKey: String = ""
    /// A private window's page: its history is forgotten when the window closes.
    public var isPrivate = false
    /// The page's address and whether it is loading (`TaskManagerDirectory.Tab`).
    public var pageURL: String?
    public var isLoading = false
    /// The "Not loaded" group's tabs, the most recently opened first.
    public var folded: [TaskManagerStack] = []
    /// The group's grey words: "last opened 3 d – 14 d ago".
    public var summary = ""
    /// The group's Idle cell: "3 d – 14 d".
    public var idleRange = ""

    /// The history's key for a sidebar tab (`TaskManagerUnloadedTab.id`, `TaskManagerDirectory.Tab.sidebarID`).
    public static func historyKey(sidebarID: String) -> String { "sidebar/\(sidebarID)" }

    /// The process this stack is about when it has one alone: the tab's page, the extension, Darni itself.
    var ownKind: TaskManagerTask.Kind {
        switch kind {
        case .browser: return .browser
        case .tab: return .tab
        case .browserExtension: return .browserExtension
        case .notLoaded: return .tab
        }
    }

    /// Rows under it: more than one process, or one that is not its own (a frame alone).
    public var hasChildren: Bool {
        !folded.isEmpty || members.count > 1 || members.contains { $0.task.kind != ownKind }
    }

    /// Selecting the stack's row selects its processes, so End task ends
    /// the tab; never for Darni's own stack, whose processes are everything.
    public var selectsProcesses: Bool { kind != .browser && kind != .notLoaded && !members.isEmpty }

    /// The sum of each process's share; nil with no process (an unloaded tab).
    public var memoryFootprint: UInt64? {
        members.isEmpty ? nil : UInt64(members.reduce(0.0) { $0 + Double($1.memoryFootprint) * $1.share }.rounded())
    }

    public var usage: TaskManagerUsage {
        func total(_ value: (TaskManagerUsage) -> Double?) -> Double? {
            let known = members.compactMap { member in value(member.usage).map { $0 * member.share } }
            return known.isEmpty ? nil : known.reduce(0, +)
        }
        return TaskManagerUsage(cpuPercent: total(\.cpuPercent), networkBytesPerSecond: total(\.networkBytesPerSecond))
    }

    /// CPU seconds its processes have used since they started (each process's share).
    public var cpuTime: Double {
        members.reduce(0) { $0 + Double($1.cpuMicros) / 1_000_000 * $1.share }
    }

    /// The page's site: its own process's ("https://mail.google.com").
    public var site: String {
        members.first { $0.task.kind == .tab }?.task.site ?? ""
    }

    /// The stack's figures are a sum or a share, not one process's own.
    public var isEstimate: Bool {
        members.count > 1 || members.contains { $0.sharedBy > 1 }
    }

    public var pids: [Int32] { Array(Set(members.map(\.pid))).sorted() }
}

/// A row of the table: a stack, a process under it, or one task of a flat filter.
public struct TaskManagerRow: Equatable, Identifiable, Sendable {
    public enum Disclosure: Equatable, Sendable {
        case none, collapsed, expanded
    }

    public var id: String
    public var title: String
    public var icon: TaskManagerTask.Icon
    public var kind: TaskManagerTask.Kind
    /// 0 for a stack (or a flat row), 1 for a process under it.
    public var level: Int
    public var stackID: String
    public var disclosure: Disclosure
    /// The processes the row's figures come from: none for an unloaded tab.
    public var pids: [Int32]
    public var selectionKeys: [TaskManagerSelectionKey]
    public var profile: String
    /// nil: no process (an unloaded tab).
    public var memoryFootprint: UInt64?
    public var usage: TaskManagerUsage
    /// A stack's total: drawn with "≈".
    public var isEstimate: Bool
    /// How many tabs share the row's process (1: none).
    public var sharedBy: Int
    public var sleep: TaskManagerTabSleep?
    /// A subframe listed outside its stack: the tab it belongs to.
    public var context: String?
    public var isKillable: Bool
    /// Double-click or Show Tab brings this tab forward.
    public var tab: TaskManagerTabRef?
    /// A stack's row: what its history is filed under (`TaskManagerStack.historyKey`); empty for a process's row.
    public var historyKey: String = ""
    /// The "Not loaded" group's grey words.
    public var summary: String = ""
    /// The "Not loaded" group's Idle cell.
    public var idleRange: String = ""

    /// The engine tab a tab's or a frame's row belongs to.
    public var engineTabID: UInt64? {
        if case .engine(let id) = tab { return id }
        return nil
    }

    /// The row's one process, if it has exactly one.
    public var pid: Int32? { pids.count == 1 ? pids[0] : nil }

    /// No page in memory (unloaded or not loaded): dimmed, as in the sidebar.
    public var isUnloaded: Bool { sleep?.state == .unloaded || sleep?.state == .notLoaded }

    /// Grey words after the title: which tab a frame is in, who shares the process.
    public var note: String {
        var parts: [String] = []
        if !summary.isEmpty { parts.append(summary) }
        if let context { parts.append("in \(context)") }
        if sharedBy > 1 {
            parts.append(level == 0 && context == nil ? "shares its process with \(sharedBy - 1) other tab\(sharedBy == 2 ? "" : "s")"
                                                      : "shared by \(sharedBy) tabs")
        }
        return parts.joined(separator: " · ")
    }

    /// The cell's text. A row with no process has no figures.
    public func text(for column: TaskManagerColumn) -> String {
        func estimated(_ text: String) -> String {
            isEstimate && text != TaskManagerFormat.notAvailable ? "≈ \(text)" : text
        }
        let hasProcess = memoryFootprint != nil
        switch column {
        case .task: return title
        case .state: return sleep?.state.title ?? ""
        case .idle: return sleep?.idleText ?? idleRange
        case .profile: return profile
        case .memoryFootprint: return memoryFootprint.map { estimated(TaskManagerFormat.memory($0)) } ?? ""
        case .cpu: return hasProcess ? estimated(TaskManagerFormat.cpu(usage.cpuPercent)) : ""
        case .network: return hasProcess ? estimated(TaskManagerFormat.network(usage.networkBytesPerSecond)) : ""
        // A pid is a number for a terminal: no grouping.
        case .processID: return pids.map(String.init).joined(separator: ", ")
        // Drawn, not written (`TaskManagerHistory`).
        case .memoryHistory, .cpuHistory: return ""
        }
    }
}

extension TaskManagerRows {
    /// Darni's own stack.
    public static let browserStackID = "darni"

    /// The process groups' tasks under their tabs: Darni's own processes in
    /// one stack, each tab with its page and frames, each extension, then each
    /// tab with no page in memory. A process several tabs use goes under
    /// each of them, with its share (see the top of this file).
    public static func stacks(_ groups: [TaskManagerGroup], directory: TaskManagerDirectory) -> [TaskManagerStack] {
        var stacks: [String: TaskManagerStack] = [:]
        var order: [String] = []
        func add(_ id: String, _ make: () -> TaskManagerStack, _ member: TaskManagerStack.Member) {
            if stacks[id] == nil {
                stacks[id] = make()
                order.append(id)
            }
            guard stacks[id]?.members.contains(where: { $0.pid == member.pid }) == false else { return }
            stacks[id]?.members.append(member)
            // A tab's profile is its processes'; Darni's own stack has none.
            if stacks[id]?.kind == .tab, stacks[id]?.profile.isEmpty == true { stacks[id]?.profile = member.profile }
        }

        for group in groups {
            for task in group.tasks {
                var member = TaskManagerStack.Member(
                    task: task, pid: group.pid, processKind: group.kind, profile: group.profile,
                    memoryFootprint: group.memoryFootprint, usage: group.usage, isKillable: group.isKillable, sharedBy: 1,
                    cpuMicros: group.cpuMicros
                )
                switch task.kind {
                case .browser, .helper:
                    member.task.id = "\(browserStackID)/\(group.pid)"
                    add(browserStackID, {
                        TaskManagerStack(id: browserStackID, kind: .browser, title: Brand.name, name: Brand.name, icon: .browser,
                                         profile: "", members: [])
                    }, member)
                case .browserExtension:
                    var extensionID: String?
                    if case .browserExtension(let id) = task.icon { extensionID = id }
                    let id = "extension/\(extensionID ?? String(group.pid))"
                    member.task.id = "\(id)/\(group.pid)"
                    add(id, {
                        TaskManagerStack(id: id, kind: .browserExtension, title: task.title, name: task.title, icon: task.icon,
                                         profile: group.profile, members: [])
                    }, member)
                case .tab, .subframe:
                    guard let tabID = task.engineTabID else { continue }
                    let tab = directory.tabs[tabID]
                    let id = "tab/\(tabID)"
                    let isPage = task.kind == .tab
                    let what = isPage ? "Page" : "Subframe"
                    member.task = TaskManagerTask(
                        id: "\(id)/\(group.pid)", title: task.site.isEmpty ? what : "\(what): \(task.site)", icon: .frame,
                        kind: task.kind, site: task.site
                    )
                    add(id, {
                        let title = tab?.title ?? ""
                        return TaskManagerStack(
                            id: id, kind: .tab, title: "\(tab?.isPrivate == true ? "Private tab" : "Tab"): \(title)", name: title,
                            icon: .tab(tabID), profile: "", members: [], sleep: tab?.sleep, tab: .engine(tabID),
                            historyKey: tab?.sidebarID.map(TaskManagerStack.historyKey(sidebarID:)) ?? id,
                            isPrivate: tab?.isPrivate ?? false, pageURL: tab?.pageURL, isLoading: tab?.isLoading ?? false
                        )
                    }, member)
                }
            }
        }

        // Each process's share: one even part per stack it works for.
        var uses: [Int32: Int] = [:]
        for id in order { for member in stacks[id]!.members { uses[member.pid, default: 0] += 1 } }
        var result = order.map { id -> TaskManagerStack in
            var stack = stacks[id]!
            if stack.historyKey.isEmpty { stack.historyKey = stack.id }
            for index in stack.members.indices { stack.members[index].sharedBy = uses[stack.members[index].pid] ?? 1 }
            let own = stack.ownKind
            stack.members.sort { memberRank($0, own: own) < memberRank($1, own: own) }
            return stack
        }
        // A tab the engine lists with a page is never also a row of its own.
        let withPage = Set(directory.tabs.values.compactMap { $0.hasPage ? $0.sidebarID : nil })
        var folded: [(stack: TaskManagerStack, tab: TaskManagerUnloadedTab)] = []
        for tab in directory.unloadedTabs where !withPage.contains(tab.id) {
            let stack = TaskManagerStack(
                id: "unloaded/\(tab.id)", kind: .tab, title: "Tab: \(tab.title)", name: tab.title, icon: .sidebarTab(tab.id),
                profile: tab.profile, members: [],
                sleep: TaskManagerTabSleep(state: tab.wasUnloaded ? .unloaded : .notLoaded, idle: tab.idle, openedInDarni: tab.openedInDarni),
                tab: .sidebar(tab.id), historyKey: TaskManagerStack.historyKey(sidebarID: tab.id)
            )
            if tab.hasOwnRow { result.append(stack) } else { folded.append((stack, tab)) }
        }
        if !folded.isEmpty { result.append(notLoadedGroup(folded)) }
        // The order holds from one reading to the next: Darni, the tabs by
        // their first process, the extensions, then the unloaded tabs by title.
        return result.enumerated().sorted { a, b in
            let x = stackRank(a.element), y = stackRank(b.element)
            if x.rank != y.rank { return x.rank < y.rank }
            if x.pid != y.pid { return x.pid < y.pid }
            switch a.element.title.localizedStandardCompare(b.element.title) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Tabs not loaded for longer than this fold into one group row.
    public static let foldAfter: TimeInterval = 24 * 3600
    public static let notLoadedStackID = "not-loaded"

    /// "Not loaded · 63 tabs", "last opened 3 d – 14 d ago · 40 not opened in Darni"; its
    /// tabs the most recently opened first, then those never opened in Darni by title.
    static func notLoadedGroup(_ folded: [(stack: TaskManagerStack, tab: TaskManagerUnloadedTab)]) -> TaskManagerStack {
        let opened = folded.filter { $0.tab.openedInDarni && $0.tab.idle != nil }.sorted { $0.tab.idle! < $1.tab.idle! }
        let never = folded.filter { !($0.tab.openedInDarni && $0.tab.idle != nil) }
            .sorted { $0.stack.title.localizedStandardCompare($1.stack.title) == .orderedAscending }
        var parts: [String] = []
        var range = ""
        if let newest = opened.first?.tab.idle, let oldest = opened.last?.tab.idle {
            let a = TaskManagerFormat.idle(newest), b = TaskManagerFormat.idle(oldest)
            range = a == b ? a : "\(a) – \(b)"
            parts.append("last opened \(range) ago")
        }
        if !never.isEmpty {
            parts.append(opened.isEmpty ? "not opened in Darni" : "\(never.count) not opened in Darni")
        }
        return TaskManagerStack(
            id: notLoadedStackID, kind: .notLoaded, title: "Not loaded · \(folded.count) tab\(folded.count == 1 ? "" : "s")",
            name: "Not loaded", icon: .notLoadedGroup, profile: "", members: [],
            folded: (opened + never).map(\.stack), summary: parts.joined(separator: " · "),
            idleRange: range.isEmpty ? TaskManagerHelp.notOpenedInDarni : range
        )
    }

    private static func stackRank(_ stack: TaskManagerStack) -> (rank: Int, pid: Int32) {
        let rank: Int
        switch stack.kind {
        case .browser: rank = 0
        case .tab: rank = stack.members.isEmpty ? 3 : 1
        case .browserExtension: rank = 2
        case .notLoaded: rank = 4
        }
        return (rank, stack.members.map(\.pid).min() ?? .max)
    }

    /// A tab's page first, then its frames; Darni's processes as the groups are ordered.
    private static func memberRank(_ member: TaskManagerStack.Member, own: TaskManagerTask.Kind) -> (Int, Int, Int32) {
        (member.task.kind == own ? 0 : 1, rank(member.processKind), member.pid)
    }

    // MARK: Rows

    /// The rows on screen. `.all`, `.tabs` and `.extensions` show stacks:
    /// a stack's processes show under it when it is in `expanded`. The search
    /// keeps a stack whose row or any process under it matches; a stack found
    /// by a process under it opens. Sorting orders the stacks by their
    /// totals and the processes in each stack among themselves. `.subframes`
    /// and `.browser` list those tasks one by one.
    public static func rows(
        _ stacks: [TaskManagerStack], filter: TaskManagerFilter = .all, search: String = "", sort: TaskManagerSort? = nil,
        expanded: Set<String> = []
    ) -> [TaskManagerRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        func found(_ text: String?) -> Bool {
            guard let text else { return false }
            return query.isEmpty || text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }

        if filter.isFlat {
            let rows = stacks.flatMap { stack -> [TaskManagerRow] in
                switch filter {
                case .subframes:
                    guard stack.kind == .tab else { return [] }
                    return stack.members.filter { $0.task.kind == .subframe }.map { row($0, of: stack, level: 0, context: stack.name) }
                default:
                    guard stack.kind == .browser else { return [] }
                    return stack.members.map { row($0, of: stack, level: 0, context: nil) }
                }
            }
            return sorted(rows.filter { found($0.title) || found($0.context) }, by: sort)
        }

        var shown: [(stack: TaskManagerRow, children: [TaskManagerRow])] = []
        var group: (stack: TaskManagerRow, children: [TaskManagerRow])?
        for stack in stacks {
            switch (filter, stack.kind) {
            case (.all, _), (.tabs, .tab), (.tabs, .notLoaded), (.extensions, .browserExtension): break
            default: continue
            }
            if stack.kind == .notLoaded {
                // The search looks inside the fold and opens it on the tabs it finds.
                let matching = query.isEmpty ? stack.folded : stack.folded.filter { found($0.title) }
                let stackFound = query.isEmpty || found(stack.title)
                guard stackFound || !matching.isEmpty else { continue }
                let open = expanded.contains(stack.id) || (!query.isEmpty && !matching.isEmpty)
                let children = open ? (query.isEmpty || matching.isEmpty ? stack.folded : matching)
                    .map { row($0, disclosure: .none, level: 1) } : []
                group = (row(stack, disclosure: open ? .expanded : .collapsed), children)
                continue
            }
            let stackFound = found(stack.title)
            let memberFound = !query.isEmpty && stack.members.contains { found($0.task.title) }
            guard stackFound || memberFound else { continue }
            let open = stack.hasChildren && (expanded.contains(stack.id) || (memberFound && !stackFound))
            let disclosure: TaskManagerRow.Disclosure = stack.hasChildren ? (open ? .expanded : .collapsed) : .none
            let children = open ? stack.members.map { row($0, of: stack, level: 1, context: nil) } : []
            shown.append((row(stack, disclosure: disclosure), children))
        }
        let order = sortedIndices(shown.map(\.stack), by: sort)
        // The fold stays last whatever the sort, its tabs in their own order.
        return order.flatMap { index in [shown[index].stack] + sorted(shown[index].children, by: sort) }
            + (group.map { [$0.stack] + $0.children } ?? [])
    }

    private static func row(_ stack: TaskManagerStack, disclosure: TaskManagerRow.Disclosure, level: Int = 0) -> TaskManagerRow {
        let pids = stack.pids
        let alone = stack.hasChildren ? nil : stack.members.first
        return TaskManagerRow(
            id: stack.id, title: stack.title, icon: stack.icon, kind: alone?.task.kind ?? stack.ownKind, level: level, stackID: stack.id,
            disclosure: disclosure, pids: pids,
            selectionKeys: stack.selectsProcesses ? pids.map(TaskManagerSelectionKey.process) : [.row(stack.id)],
            profile: stack.profile, memoryFootprint: stack.memoryFootprint, usage: stack.usage, isEstimate: stack.isEstimate,
            sharedBy: alone?.sharedBy ?? 1, sleep: stack.sleep, context: nil,
            isKillable: stack.selectsProcesses && stack.members.contains(where: \.isKillable), tab: stack.tab,
            historyKey: stack.kind == .notLoaded ? "" : stack.historyKey, summary: stack.summary, idleRange: stack.idleRange
        )
    }

    private static func row(_ member: TaskManagerStack.Member, of stack: TaskManagerStack, level: Int, context: String?) -> TaskManagerRow {
        TaskManagerRow(
            id: member.task.id, title: member.task.title, icon: member.task.icon, kind: member.task.kind, level: level, stackID: stack.id,
            disclosure: .none, pids: [member.pid], selectionKeys: [.process(member.pid)], profile: member.profile,
            memoryFootprint: member.memoryFootprint, usage: member.usage, isEstimate: false,
            sharedBy: stack.kind == .tab ? member.sharedBy : 1, sleep: nil, context: context, isKillable: member.isKillable,
            tab: stack.kind == .tab ? stack.tab : nil
        )
    }

    // MARK: Sorting

    private static func sorted(_ rows: [TaskManagerRow], by sort: TaskManagerSort?) -> [TaskManagerRow] {
        sortedIndices(rows, by: sort).map { rows[$0] }
    }

    /// The rows' order for `sort`; equal rows keep the order they came in.
    /// A figure that is not known goes last whichever way the column sorts.
    private static func sortedIndices(_ rows: [TaskManagerRow], by sort: TaskManagerSort?) -> [Int] {
        guard let sort else { return Array(rows.indices) }
        let ordered = rows.indices.sorted { a, b in
            switch compare(rows[a], rows[b], by: sort.column) {
            case .orderedSame: return a < b
            case .orderedAscending: return sort.ascending
            case .orderedDescending: return !sort.ascending
            }
        }
        return ordered.filter { hasValue(rows[$0], for: sort.column) } + ordered.filter { !hasValue(rows[$0], for: sort.column) }
    }

    private static func hasValue(_ row: TaskManagerRow, for column: TaskManagerColumn) -> Bool {
        switch column {
        case .task, .profile, .memoryHistory, .cpuHistory: return true
        case .state: return row.sleep != nil
        case .idle: return row.sleep.map { $0.isOnScreen || $0.idle != nil } ?? false
        case .memoryFootprint: return row.memoryFootprint != nil
        case .cpu: return row.memoryFootprint != nil && row.usage.cpuPercent != nil
        case .network: return row.memoryFootprint != nil && row.usage.networkBytesPerSecond != nil
        case .processID: return !row.pids.isEmpty
        }
    }

    private static func compare(_ a: TaskManagerRow, _ b: TaskManagerRow, by column: TaskManagerColumn) -> ComparisonResult {
        func order<Value: Comparable>(_ x: Value, _ y: Value) -> ComparisonResult {
            x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        }
        func idle(_ row: TaskManagerRow) -> TimeInterval {
            guard let sleep = row.sleep else { return 0 }
            if sleep.isOnScreen { return -1 }
            return sleep.openedInDarni ? sleep.idle ?? 0 : .greatestFiniteMagnitude
        }
        switch column {
        case .task: return a.title.localizedStandardCompare(b.title)
        case .state: return order(a.sleep?.state.rank ?? 0, b.sleep?.state.rank ?? 0)
        case .idle: return order(idle(a), idle(b))
        case .profile: return a.profile.localizedStandardCompare(b.profile)
        case .memoryFootprint: return order(a.memoryFootprint ?? 0, b.memoryFootprint ?? 0)
        case .cpu: return order(a.usage.cpuPercent ?? 0, b.usage.cpuPercent ?? 0)
        case .network: return order(a.usage.networkBytesPerSecond ?? 0, b.usage.networkBytesPerSecond ?? 0)
        case .processID: return order(a.pids.first ?? 0, b.pids.first ?? 0)
        case .memoryHistory, .cpuHistory: return .orderedSame
        }
    }
}
