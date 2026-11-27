import AppKit
import Darwin
import SidebarModel

/// One reading for the Task Manager: the processes, and what the shell
/// calls the tabs, profiles and extensions in them.
struct TaskManagerSample {
    var processes: [TaskManagerProcess]
    var directory = TaskManagerDirectory()
}

/// Where the Task Manager's rows come from. The Chromium shell reads the
/// engine's process list (`ChromiumTaskManagerSource`); without an engine
/// there is only ReArc itself (`ShellTaskManagerSource`). Tests use a fake.
@MainActor
protocol TaskManagerSource: AnyObject {
    func sample() async -> TaskManagerSample
    /// The 60 s reading while the window is closed: the process list alone
    /// (no 1.65 details, so the engine counts no network bytes for it).
    func backgroundSample() async -> TaskManagerSample
    /// The picture for a row; nil draws the row's stock symbol.
    func icon(for icon: TaskManagerTask.Icon) -> NSImage?
    /// Ends the process as Chrome's End task does. False: it was not ended
    /// (already gone, or not one of the engine's).
    func endProcess(_ pid: Int32) async -> Bool
    /// Whether the tab is a page of the shell's (or an unloaded sidebar tab) that can be brought forward.
    func canShowTab(_ tab: TaskManagerTabRef) -> Bool
    /// Brings the last focused browser window forward and selects the tab there, in its space.
    func showTab(_ tab: TaskManagerTabRef)
    /// The engine is running: a background reading would get its processes.
    var isLive: Bool { get }
    /// Tab sleep from the Task Manager (the inspector's Tab controls, the row menu).
    func canSleepTab(_ tab: TaskManagerTabRef) -> Bool
    func sleepTab(_ tab: TaskManagerTabRef)
    func canUnloadTab(_ tab: TaskManagerTabRef) -> Bool
    func unloadTab(_ tab: TaskManagerTabRef)
    /// Darni's hosted DevTools for the tab (the Elements panel until ABI 1.75).
    func canOpenDevTools(_ tab: TaskManagerTabRef) -> Bool
    func openDevTools(_ tab: TaskManagerTabRef)
}

extension TaskManagerSource {
    func backgroundSample() async -> TaskManagerSample { await sample() }
    func canShowTab(_ tab: TaskManagerTabRef) -> Bool { false }
    func showTab(_ tab: TaskManagerTabRef) {}
    var isLive: Bool { true }
    func canSleepTab(_ tab: TaskManagerTabRef) -> Bool { false }
    func sleepTab(_ tab: TaskManagerTabRef) {}
    func canUnloadTab(_ tab: TaskManagerTabRef) -> Bool { false }
    func unloadTab(_ tab: TaskManagerTabRef) {}
    func canOpenDevTools(_ tab: TaskManagerTabRef) -> Bool { false }
    func openDevTools(_ tab: TaskManagerTabRef) {}
}

/// ReArc itself as the only process: the WebKit shell, and the Chromium
/// shell until its engine answers.
final class ShellTaskManagerSource: TaskManagerSource {
    nonisolated init() {}

    func sample() async -> TaskManagerSample {
        TaskManagerSample(processes: [TaskManagerProcessControl.browserProcess()])
    }

    func icon(for icon: TaskManagerTask.Icon) -> NSImage? { nil }

    func endProcess(_ pid: Int32) async -> Bool { false }
}

/// What the shell asks macOS about a process.
enum TaskManagerProcessControl {
    /// ReArc's own process with its memory and CPU time, as the engine
    /// reports its processes (`proc_pid_rusage`).
    static func browserProcess() -> TaskManagerProcess {
        var process = TaskManagerProcess(pid: getpid(), kind: .browser)
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(process.pid, RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { return process }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        process.memoryFootprint = usage.ri_phys_footprint
        // ri_*_time are mach absolute time units.
        let nanos = Double(usage.ri_user_time + usage.ri_system_time) * Double(timebase.numer) / Double(timebase.denom)
        process.cpuMicros = Int64(nanos / 1000)
        return process
    }

    static func parent(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(bitPattern: info.pbi_ppid)
    }

    /// Chrome's End task (`task_manager::Task::Kill`): SIGTERM. Only to a
    /// process ReArc started, so a pid that another program now has is never
    /// signalled.
    static func terminate(_ pid: Int32) -> Bool {
        guard pid > 0, pid != getpid(), parent(of: pid) == getpid() else { return false }
        return kill(pid, SIGTERM) == 0
    }
}

/// The Task Manager window's state: the last reading as process groups,
/// what the window shows of them, and the once-a-second reading while the
/// window is on screen. Also its history (`TaskManagerHistory`), which the
/// 60 s background reading keeps going while the window is closed when
/// Settings › Advanced allows it, and what tab sleep did to each tab.
@Observable
final class TaskManagerController {
    /// Chrome reads about once a second.
    static let refreshInterval: TimeInterval = 1
    /// The reading while the window is closed: one process list a minute.
    static let backgroundInterval: TimeInterval = 60

    var filter: TaskManagerFilter = .all
    var search = ""
    var sort: TaskManagerSort?
    /// The header menu's choice; saved when it changes.
    var columns: TaskManagerColumns {
        didSet { if columns != oldValue { columns.save(to: defaults) } }
    }
    /// The engine's processes, one group each.
    private(set) var groups: [TaskManagerGroup] = []
    /// The groups' tasks under their tabs, and the tabs with no page in memory.
    private(set) var stacks: [TaskManagerStack] = []
    /// Tab sleep's settings at the last reading, for the State column's help.
    private(set) var sleepSettings: TaskManagerSleepSettings?
    /// The stacks whose processes show under them. Closed by default.
    var expanded: Set<String> = []
    /// False until the first reading has arrived, so the window does not open on "No tasks".
    private(set) var hasReading = false
    /// What is selected: processes (a click on any row of a process selects
    /// every row of it), or a row with no process to end of its own.
    var selection: Set<TaskManagerSelectionKey> = []
    /// List, Heat grid or Memory map; saved when it changes.
    var viewMode: TaskManagerViewMode {
        didSet { if viewMode != oldValue { viewMode.save(to: defaults) } }
    }
    /// The stack the inspector shows, by history key, so it stays on a tab
    /// that is unloaded or loaded again. nil: no inspector.
    var focusedKey: String?
    /// ⌥⌘I and the toolbar button fold the inspector away.
    var isInspectorCollapsed = false
    /// Per stack: footprint and CPU at each reading, and tab sleep's events.
    private(set) var history = TaskManagerHistory()
    /// Bumped at each change of the history: the sparklines redraw.
    private(set) var historyRevision = 0
    /// Settings › Advanced: read once a minute while the window is closed.
    private(set) var keepsBackgroundHistory: Bool
    /// The focused space's theme at the last reading, for the window's tint and accent.
    private(set) var spaceTheme: SpaceTheme?
    /// The wall-clock time of the last reading, for "13:02".
    private(set) var lastReadingDate = Date()

    @ObservationIgnored var source: any TaskManagerSource
    /// Seconds on a clock that never goes back.
    @ObservationIgnored var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored var wallClock: () -> Date = { Date() }
    /// The focused space's theme (`BrowserViewModel.showTaskManager` sets it).
    @ObservationIgnored var spaceThemeProvider: (() -> SpaceTheme?)?
    /// Runs `work` after a delay: the reading a few seconds after an unload while the window is closed.
    @ObservationIgnored var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var backgroundTimer: Timer?
    /// The engine reported ready: background readings have something to read.
    @ObservationIgnored private var engineIsAttached = false
    @ObservationIgnored private var backgroundReadingInFlight = false
    /// Bumped when the background readings stop: one in flight is dropped.
    @ObservationIgnored private var backgroundGeneration = 0
    @ObservationIgnored private var sampler = TaskManagerSampler()
    @ObservationIgnored private var timer: Timer?
    /// Bumped when polling stops: a reading asked for before that is dropped.
    @ObservationIgnored private var pollGeneration = 0
    /// The generation of the reading in flight.
    @ObservationIgnored private var reading: Int?

    init(source: any TaskManagerSource = ShellTaskManagerSource(), defaults: UserDefaults = .standard) {
        self.source = source
        self.defaults = defaults
        columns = .load(from: defaults)
        viewMode = .load(from: defaults)
        keepsBackgroundHistory = TaskManagerHistoryPreference.isEnabled(in: defaults)
    }

    var rows: [TaskManagerRow] {
        TaskManagerRows.rows(stacks, filter: filter, search: search, sort: sort, expanded: expanded)
    }

    /// A stack's disclosure: opens or closes it. `all` (⌥-click, as in a
    /// Finder list) opens or closes every stack with processes under it.
    func toggleExpanded(_ stackID: String, all: Bool = false) {
        let open = !expanded.contains(stackID)
        let ids = all ? Set(stacks.filter(\.hasChildren).map(\.id)) : [stackID]
        if open { expanded.formUnion(ids) } else { expanded.subtract(ids) }
    }

    var isPolling: Bool { timer != nil }

    // MARK: Reading

    /// The window came on screen: reads now, then once a second.
    func startPolling() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
        // Common modes: the figures keep moving while a menu is open or the table scrolls.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    /// The window closed or went out of sight. The next reading starts
    /// afresh, so its CPU figure is not an average over the time away.
    func stopPolling() {
        timer?.invalidate()
        timer = nil
        pollGeneration += 1
        sampler.reset()
    }

    /// One reading, unless one is already on its way.
    func refresh() {
        let generation = pollGeneration
        guard reading != generation else { return }
        reading = generation
        Task { @MainActor [weak self, source] in
            let sample = await source.sample()
            guard let self else { return }
            if self.reading == generation { self.reading = nil }
            guard generation == self.pollGeneration else { return }
            self.apply(sample, at: self.clock())
        }
    }

    func apply(_ sample: TaskManagerSample, at time: TimeInterval) {
        let usage = sampler.usage(of: sample.processes, at: time)
        let groups = TaskManagerRows.groups(processes: sample.processes, usage: usage, directory: sample.directory)
        let stacks = TaskManagerRows.stacks(groups, directory: sample.directory)
        if groups != self.groups { self.groups = groups }
        if stacks != self.stacks { self.stacks = stacks }
        if sample.directory.sleepSettings != sleepSettings { sleepSettings = sample.directory.sleepSettings }
        if !hasReading { hasReading = true }
        record(stacks, at: time, source: .window)
        let theme = spaceThemeProvider?()
        if theme != spaceTheme { spaceTheme = theme }
        let live = Set(groups.map { TaskManagerSelectionKey.process($0.pid) }).union(allStacks.map { .row($0.id) })
        if !selection.isSubset(of: live) { selection.formIntersection(live) }
        // The inspected tab was unloaded or loaded again: its row is a new one; keep it selected.
        if selection.isEmpty, let stack = focusedStack {
            selection = Set(stack.selectsProcesses ? stack.pids.map(TaskManagerSelectionKey.process) : [.row(stack.id)])
        }
    }

    private func record(_ stacks: [TaskManagerStack], at time: TimeInterval, source: TaskManagerHistory.Source) {
        history.record(stacks, at: time, source: source)
        lastReadingDate = wallClock()
        historyRevision &+= 1
        // A focused tab closed for good (its history dropped): no inspector.
        if let key = focusedKey, history[key] == nil, !allStacks.contains(where: { $0.historyKey == key }) { focusedKey = nil }
    }

    // MARK: Reading while closed

    /// Background readings run while the engine runs and Settings › Advanced
    /// keeps the history; they skip a minute the window reads itself.
    var isReadingInBackground: Bool { backgroundTimer != nil }

    /// The engine is ready (`ChromiumHost`): the 60 s reading may start.
    @MainActor func engineDidAttach() {
        engineIsAttached = true
        syncBackgroundReadings()
    }

    /// The engine is stopping or gone.
    @MainActor func engineDidDetach() {
        engineIsAttached = false
        syncBackgroundReadings()
    }

    /// Settings › Advanced. Off stops the 60 s reading at once and clears
    /// what it kept while the window was closed.
    @MainActor func setKeepsBackgroundHistory(_ keeps: Bool) {
        guard keeps != keepsBackgroundHistory else { return }
        keepsBackgroundHistory = keeps
        defaults.set(keeps, forKey: TaskManagerHistoryPreference.defaultsKey)
        if !keeps {
            history.clearClosedWindowHistory()
            historyRevision &+= 1
        }
        syncBackgroundReadings()
    }

    @MainActor private func syncBackgroundReadings() {
        let wanted = engineIsAttached && keepsBackgroundHistory
        if wanted, backgroundTimer == nil {
            let timer = Timer(timeInterval: Self.backgroundInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.readInBackground() }
            }
            // A minute's precision is plenty; the system may batch it with other wake-ups.
            timer.tolerance = 10
            RunLoop.main.add(timer, forMode: .common)
            backgroundTimer = timer
            readInBackground()
        } else if !wanted, backgroundTimer != nil {
            backgroundTimer?.invalidate()
            backgroundTimer = nil
            backgroundGeneration += 1
        }
    }

    /// One background reading: the history only, never the window's rows or
    /// its CPU sampler. Skipped while the window reads, and when the engine is not running.
    @MainActor func readInBackground() {
        guard isReadingInBackground, !isPolling, !backgroundReadingInFlight, source.isLive else { return }
        backgroundReadingInFlight = true
        let generation = backgroundGeneration
        Task { @MainActor [weak self, source] in
            let sample = await source.backgroundSample()
            guard let self else { return }
            self.backgroundReadingInFlight = false
            guard generation == self.backgroundGeneration, !self.isPolling else { return }
            self.applyInBackground(sample, at: self.clock())
        }
    }

    func applyInBackground(_ sample: TaskManagerSample, at time: TimeInterval) {
        let groups = TaskManagerRows.groups(processes: sample.processes, directory: sample.directory)
        record(TaskManagerRows.stacks(groups, directory: sample.directory), at: time, source: .background)
    }

    // MARK: Tab sleep's events

    /// Tab sleep or the person did something to a sidebar tab (or a private
    /// window's page). Kept while the window is open, or while the history
    /// is kept with it closed. An unload with the window closed gets a
    /// reading a few seconds later, so its effect is measured.
    func noteTabControl(_ kind: TaskManagerTabEvent.Kind, sidebarID: String, cause: TaskManagerTabEvent.Cause) {
        let closed = !isPolling
        guard !closed || isReadingInBackground else { return }
        let key = TaskManagerStack.historyKey(sidebarID: sidebarID)
        guard let event = history.note(kind, key: key, cause: cause, at: clock(), whileClosed: closed) else { return }
        historyRevision &+= 1
        if closed, event.effect == .measuring || event.effect == .sleep {
            schedule(TaskManagerHistory.settleDelay + 0.5) { [weak self] in self?.readInBackground() }
        }
    }

    /// A private window closed: its page's history goes now.
    func forgetTab(sidebarID: String) {
        let key = TaskManagerStack.historyKey(sidebarID: sidebarID)
        guard history[key] != nil else { return }
        history.forget(key: key)
        if focusedKey == key { focusedKey = nil }
        historyRevision &+= 1
    }

    // MARK: Insights

    /// "13:02" for the history's times, anchored at the last reading.
    var timeline: TaskManagerTimeline {
        TaskManagerTimeline(now: history.lastReading ?? clock(), wallNow: history.lastReading == nil ? wallClock() : lastReadingDate)
    }

    var summary: TaskManagerTabSleepSummary { TaskManagerTabSleepSummary(stacks: stacks, history: history) }

    /// The stacks the filter and the search leave, for the heat grid and the memory map.
    var visibleStacks: [TaskManagerStack] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        func found(_ text: String) -> Bool {
            query.isEmpty || text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return stacks.filter { stack in
            // The folded "Not loaded" tabs have nothing to draw in a grid or a map.
            switch (filter, stack.kind) {
            case (_, .notLoaded): return false
            case (.all, _), (.tabs, .tab), (.extensions, .browserExtension), (.browser, .browser): break
            case (.subframes, .tab) where stack.members.contains(where: { $0.task.kind == .subframe }): break
            default: return false
            }
            return found(stack.title) || stack.members.contains { found($0.task.title) }
        }
    }

    /// "Spotted" under the heat grid: up to three hints over the stacks shown.
    var spotted: [TaskManagerInsight] {
        TaskManagerInsights.spotted(visibleStacks.map(\.historyKey), in: history, timeline: timeline)
    }

    // MARK: Inspector

    /// The stack the inspector shows, at the last reading.
    var focusedStack: TaskManagerStack? {
        guard let focusedKey else { return nil }
        return allStacks.first { $0.historyKey == focusedKey }
    }

    /// The stacks and the tabs folded into "Not loaded" (not the group itself).
    var allStacks: [TaskManagerStack] {
        stacks.flatMap { $0.kind == .notLoaded ? $0.folded : [$0] }
    }

    var isInspectorShown: Bool { focusedStack != nil && !isInspectorCollapsed }

    /// A click in the list, the heat grid or the memory map: the stack is
    /// selected (its processes, as a click on its row does) and inspected.
    func focus(_ stack: TaskManagerStack?) {
        guard let stack else {
            focusedKey = nil
            return
        }
        focusedKey = stack.historyKey
        isInspectorCollapsed = false
        selection = Set(stack.selectsProcesses ? stack.pids.map(TaskManagerSelectionKey.process) : [.row(stack.id)])
    }

    /// The table's selection changed: the inspector follows the clicked row's stack.
    func selectionChanged(toStack stackID: String?) {
        focusedKey = stackID.flatMap { id in allStacks.first { $0.id == id }?.historyKey }
    }

    func figures(for stack: TaskManagerStack) -> String {
        TaskManagerFigures.text(stack: stack, history: history, timeline: timeline)
    }

    // MARK: Tab controls

    @MainActor func canSleep(_ stack: TaskManagerStack) -> Bool { stack.tab.map(source.canSleepTab) ?? false }
    @MainActor func canUnload(_ stack: TaskManagerStack) -> Bool { stack.tab.map(source.canUnloadTab) ?? false }
    @MainActor func canOpenDevTools(_ stack: TaskManagerStack) -> Bool { stack.tab.map(source.canOpenDevTools) ?? false }

    /// Sleep from the Task Manager: the shell notes the event; the next readings measure it.
    @MainActor func sleep(_ stack: TaskManagerStack) {
        guard let tab = stack.tab, source.canSleepTab(tab) else { return }
        source.sleepTab(tab)
        refresh()
    }

    @MainActor func unload(_ stack: TaskManagerStack) {
        guard let tab = stack.tab, source.canUnloadTab(tab) else { return }
        source.unloadTab(tab)
        refresh()
    }

    @MainActor func openDevTools(_ stack: TaskManagerStack) {
        guard let tab = stack.tab, source.canOpenDevTools(tab) else { return }
        source.openDevTools(tab)
    }

    // MARK: Show Tab

    /// A tab's row, or a row of a process under it, whose tab can be brought forward.
    @MainActor func canShowTab(of row: TaskManagerRow) -> Bool {
        row.tab.map(source.canShowTab) ?? false
    }

    /// Double-click or Show Tab: the row's tab, in its window and space. An
    /// unloaded tab loads as it is shown.
    @MainActor func showTab(of row: TaskManagerRow) {
        guard let tab = row.tab, source.canShowTab(tab) else { return }
        source.showTab(tab)
    }

    // MARK: End task

    /// The selected processes End task would end: never ReArc itself.
    var endableSelection: [TaskManagerGroup] {
        groups.filter { selection.contains(.process($0.pid)) && $0.isKillable }
    }

    var canEndSelection: Bool { !endableSelection.isEmpty }

    /// End task. A process that runs several tabs is ended only after
    /// `confirm` calls back with true.
    func endSelection(confirm: (TaskManagerEndConfirmation, @escaping (Bool) -> Void) -> Void) {
        let targets = endableSelection
        guard !targets.isEmpty else { return }
        guard let question = TaskManagerEndConfirmation(ending: targets) else { return end(targets) }
        confirm(question) { [weak self] accepted in
            if accepted { self?.end(targets) }
        }
    }

    private func end(_ targets: [TaskManagerGroup]) {
        Task { @MainActor [weak self, source] in
            for target in targets { _ = await source.endProcess(target.pid) }
            self?.refresh()
        }
    }
}

extension BrowserViewModel {
    /// Window › Task Manager and the sidebar's empty-space menu: one window,
    /// brought forward when it is already open.
    func showTaskManager() {
        if taskManager.spaceThemeProvider == nil {
            taskManager.spaceThemeProvider = { [weak self] in
                guard let self else { return nil }
                return self.shownTheme(in: self.store.keyWindowID)
            }
        }
        if taskManagerWindow == nil { taskManagerWindow = TaskManagerWindowController(controller: taskManager) }
        taskManagerWindow?.showWindow(nil)
    }

    /// The Task Manager's Show Tab: the last focused browser window comes
    /// forward and shows the tab there (its profile, space and folder open).
    func showTabFromTaskManager(_ tabID: Tab.ID) {
        if let window = store.keyWindowID { windowPresenter?.focusBrowserWindow(window) }
        showTab(tabID)
    }

    /// Tab sleep as the Task Manager shows it: the State and Idle of every
    /// sidebar tab with a live page, by sidebar tab, and a row for each
    /// sidebar tab with no page in memory. Only looks: no wait starts, no
    /// tab is frozen, thawed or loaded. Idle is in whole minutes, so a
    /// reading changes it once a minute.
    func taskManagerTabSleep(now: Date = Date()) -> (byTab: [Tab.ID: TaskManagerTabSleep], unloaded: [TaskManagerUnloadedTab]) {
        func idle(_ id: Tab.ID, since: Date?) -> TimeInterval? {
            guard let since else { return nil }
            return (max(0, now.timeIntervalSince(since)) / 60).rounded(.down) * 60
        }
        var byTab: [Tab.ID: TaskManagerTabSleep] = [:]
        for candidate in tabSleepCandidates(now: now, recordsFirstSight: false) {
            let id = candidate.tabID
            let state = TaskManagerTabState.of(
                candidate, isDiscarded: isTabUnloaded(id), isPageFrozen: (liveEngine(for: id) as? TabFreezing)?.isPageFrozen
            )
            let since = tabLastShown[id] ?? store.tab(withID: id)?.lastActiveAt
            byTab[id] = TaskManagerTabSleep(state: state, idle: candidate.isVisible ? 0 : idle(id, since: since), isOnScreen: candidate.isVisible)
        }
        var unloaded: [TaskManagerUnloadedTab] = []
        var listed: Set<Tab.ID> = []
        var pageless: [Tab] = []
        // Every tab of every space, in folders and tab groups too; a tab
        // group shared by several spaces and the favorites are listed once.
        for space in store.spaces {
            for tab in store.displayTabs(in: space.id) where listed.insert(tab.id).inserted {
                if let sleep = byTab[tab.id], sleep.state != .unloaded { continue }
                pageless.append(tab)
            }
        }
        // A last-active time that several tabs share to the second is their
        // import's or their making's (Arc's import stamps them all), not a visit.
        let stamps = TaskManagerUnloadedTab.stampCounts(pageless.map(\.lastActiveAt))
        for tab in pageless {
            let profile = store.profile(withID: store.owningProfileID(of: profileID(for: tab)))?.name ?? ""
            // Seen with a page this session, or with a date of its own: opened in Darni.
            let opened = tabLastShown[tab.id] != nil || !TaskManagerUnloadedTab.isBatchStamp(tab.lastActiveAt, counts: stamps)
            unloaded.append(TaskManagerUnloadedTab(
                id: tab.id.uuidString, title: tab.displayTitle, profile: profile,
                idle: idle(tab.id, since: tabLastShown[tab.id] ?? tab.lastActiveAt),
                // Unloaded by tab sleep or by hand this session, not merely never loaded.
                wasUnloaded: isTabUnloaded(tab.id), openedInDarni: opened
            ))
        }
        return (byTab, unloaded)
    }

    /// Tab sleep's settings for the Task Manager's help.
    func taskManagerSleepSettings(canFreeze: Bool) -> TaskManagerSleepSettings {
        TaskManagerSleepSettings(freeze: tabFreezeThreshold, unload: tabUnloadThreshold, canFreeze: canFreeze)
    }

    /// The sidebar tab of an unloaded tab's row, if it is still in the sidebar.
    func sidebarTab(fromTaskManager id: String) -> Tab.ID? {
        UUID(uuidString: id).flatMap { store.tab(withID: $0)?.id }
    }
}
