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

    var category: TaskManagerCategory = .tabsAndExtensions
    var search = ""
    var sort: TaskManagerSort?
    /// The header menu's choice; saved when it changes.
    var columns: TaskManagerColumns {
        didSet { if columns != oldValue { columns.save(to: defaults) } }
    }
    private(set) var groups: [TaskManagerGroup] = []
    /// False until the first reading has arrived, so the window does not open on "No tasks".
    private(set) var hasReading = false
    /// The selected processes, by pid: a click on any task selects its process.
    var selection: Set<Int32> = []

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
        TaskManagerRows.rows(groups, category: category, search: search, sort: sort)
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
        if groups != self.groups { self.groups = groups }
        if !hasReading { hasReading = true }
        let live = Set(groups.map(\.pid))
        if !selection.isSubset(of: live) { selection.formIntersection(live) }
    }

    // MARK: End task

    /// The selected processes End task would end: never ReArc itself.
    var endableSelection: [TaskManagerGroup] {
        groups.filter { selection.contains($0.pid) && $0.isKillable }
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
}
