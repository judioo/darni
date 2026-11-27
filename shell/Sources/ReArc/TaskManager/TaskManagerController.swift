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
    /// The picture for a row; nil draws the row's stock symbol.
    func icon(for icon: TaskManagerTask.Icon) -> NSImage?
    /// Ends the process as Chrome's End task does. False: it was not ended
    /// (already gone, or not one of the engine's).
    func endProcess(_ pid: Int32) async -> Bool
    /// Whether the tab is a page of the shell's (or an unloaded sidebar tab) that can be brought forward.
    func canShowTab(_ tab: TaskManagerTabRef) -> Bool
    /// Brings the last focused browser window forward and selects the tab there, in its space.
    func showTab(_ tab: TaskManagerTabRef)
}

extension TaskManagerSource {
    func canShowTab(_ tab: TaskManagerTabRef) -> Bool { false }
    func showTab(_ tab: TaskManagerTabRef) {}
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
/// window is on screen.
@Observable
final class TaskManagerController {
    /// Chrome reads about once a second.
    static let refreshInterval: TimeInterval = 1

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

    @ObservationIgnored var source: any TaskManagerSource
    /// Seconds on a clock that never goes back.
    @ObservationIgnored var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored private let defaults: UserDefaults
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
        let live = Set(groups.map { TaskManagerSelectionKey.process($0.pid) }).union(stacks.map { .row($0.id) })
        if !selection.isSubset(of: live) { selection.formIntersection(live) }
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
        // Every tab of every space, in folders and tab groups too; a tab
        // group shared by several spaces and the favorites are listed once.
        for space in store.spaces {
            for tab in store.displayTabs(in: space.id) where listed.insert(tab.id).inserted {
                if let sleep = byTab[tab.id], !sleep.isUnloaded { continue }
                let profile = store.profile(withID: store.owningProfileID(of: profileID(for: tab)))?.name ?? ""
                unloaded.append(TaskManagerUnloadedTab(
                    id: tab.id.uuidString, title: tab.displayTitle, profile: profile,
                    idle: idle(tab.id, since: tabLastShown[tab.id] ?? tab.lastActiveAt)
                ))
            }
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
