import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// A process list the test sets, in place of the engine's.
@MainActor
private final class FakeTaskManagerSource: TaskManagerSource {
    var processes: [TaskManagerProcess] = []
    var directory = TaskManagerDirectory()
    private(set) var samples = 0
    private(set) var ended: [Int32] = []
    /// Set: `sample()` waits here until the test calls `release()`.
    var holdsSamples = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func sample() async -> TaskManagerSample {
        samples += 1
        let sample = TaskManagerSample(processes: processes, directory: directory)
        if holdsSamples { await withCheckedContinuation { held.append($0) } }
        return sample
    }

    func release() {
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }

    func icon(for icon: TaskManagerTask.Icon) -> NSImage? { nil }

    func endProcess(_ pid: Int32) async -> Bool {
        ended.append(pid)
        processes.removeAll { $0.pid == pid }
        return true
    }

    /// Engine tabs that are pages of a space; the others (a private window's) cannot be shown.
    var showable: Set<UInt64> = []
    private(set) var shown: [UInt64] = []
    func canShowTab(_ engineTabID: UInt64) -> Bool { showable.contains(engineTabID) }
    func showTab(_ engineTabID: UInt64) { shown.append(engineTabID) }
}

/// Window › Task Manager: the window's state over a made-up process list.
@MainActor
final class TaskManagerControllerTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "rearc-task-manager-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeSource() -> FakeTaskManagerSource {
        let source = FakeTaskManagerSource()
        source.directory = TaskManagerDirectory(tabs: [1: .init(title: "Mail"), 2: .init(title: "News"), 3: .init(title: "Bank")])
        source.processes = [
            TaskManagerProcess(pid: 100, kind: .browser, cpuMicros: 1_000_000),
            TaskManagerProcess(pid: 200, kind: .gpu),
            TaskManagerProcess(pid: 300, kind: .renderer, tabIDs: [1, 2], cpuMicros: 2_000_000),
            TaskManagerProcess(pid: 310, kind: .renderer, tabIDs: [3]),
        ]
        return source
    }

    private func makeController(_ source: FakeTaskManagerSource) -> TaskManagerController {
        TaskManagerController(source: source, defaults: defaults)
    }

    /// Lets the main actor's queued work run until `condition` holds.
    private func settle(_ what: String = "the reading", until condition: () -> Bool) async {
        for _ in 0 ..< 200 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    // MARK: Show Tab

    func testShowTabBringsATabOrAFramesTabForwardAndNothingElse() {
        let source = makeSource()
        source.showable = [1, 3]
        source.processes.append(TaskManagerProcess(
            pid: 320, kind: .renderer, tabIDs: [1],
            details: .init(mainFrameTabIDs: [], subframeTabIDs: [1], site: "https://accounts.example")
        ))
        let controller = makeController(source)
        controller.category = .all
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 50)
        let row = { (title: String) in controller.rows.first { $0.title == title }! }

        XCTAssertTrue(controller.canShowTab(of: row("Tab: Mail")))
        XCTAssertTrue(controller.canShowTab(of: row("Subframe: https://accounts.example")), "a frame shows the tab it sits in")
        XCTAssertFalse(controller.canShowTab(of: row("Tab: News")), "a page the shell cannot show")
        XCTAssertFalse(controller.canShowTab(of: row("GPU Process")))

        controller.showTab(of: row("Subframe: https://accounts.example"))
        controller.showTab(of: row("Tab: News"))
        controller.showTab(of: row("Browser"))
        controller.showTab(of: row("Tab: Bank"))
        XCTAssertEqual(source.shown, [1, 3])
    }

    // MARK: Readings

    func testAReadingBecomesRowsAndTheSecondOneHasCPU() {
        let source = makeSource()
        let controller = makeController(source)
        XCTAssertFalse(controller.hasReading)
        controller.category = .all
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 50)
        XCTAssertTrue(controller.hasReading)
        XCTAssertEqual(controller.rows.map(\.title), ["Browser", "GPU Process", "Tab: Mail", "Tab: News", "Tab: Bank"])
        XCTAssertEqual(controller.rows.map { $0.text(for: .cpu) }, ["–", "–", "–", "", "–"])
        XCTAssertEqual(controller.rows.map { $0.text(for: .network) }, ["–", "–", "–", "", "–"], "this engine does not count network bytes")

        source.processes[2].cpuMicros += 500_000
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 51)
        XCTAssertEqual(controller.rows.map { $0.text(for: .cpu) }, ["0.0", "0.0", "50.0", "", "0.0"])
    }

    func testTheWindowOpensOnTabsAndExtensionsAndFollowsSegmentSearchAndSort() {
        let source = makeSource()
        let controller = makeController(source)
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 50)
        XCTAssertEqual(controller.rows.map(\.title), ["Tab: Mail", "Tab: News", "Tab: Bank"])
        controller.search = "bank"
        XCTAssertEqual(controller.rows.map(\.title), ["Tab: Bank"])
        controller.search = ""
        controller.category = .browser
        XCTAssertEqual(controller.rows.map(\.title), ["Browser", "GPU Process"])
        controller.category = .all
        controller.sort = TaskManagerSort(column: .processID, ascending: false)
        XCTAssertEqual(controller.rows.map(\.pid), [310, 300, 300, 200, 100])
    }

    func testRefreshReadsTheSourceOnceAtATime() async {
        let source = makeSource()
        let controller = makeController(source)
        source.holdsSamples = true
        controller.refresh()
        controller.refresh()
        await settle("the first sample") { source.samples == 1 }
        controller.refresh()
        XCTAssertEqual(source.samples, 1, "a reading on its way is not asked for again")
        source.release()
        await settle { controller.hasReading }
        controller.refresh()
        await settle("the second sample") { source.samples == 2 }
        source.release()
    }

    func testPollingStartsAndStopsWithTheWindow() async {
        let source = makeSource()
        let controller = makeController(source)
        XCTAssertFalse(controller.isPolling)
        controller.startPolling()
        controller.startPolling()
        XCTAssertTrue(controller.isPolling)
        await settle { controller.hasReading }
        XCTAssertEqual(source.samples, 1, "showing the window reads at once, and once")
        controller.stopPolling()
        XCTAssertFalse(controller.isPolling)
        controller.stopPolling()
        XCTAssertEqual(source.samples, 1)
    }

    func testAReadingAskedForBeforeTheWindowWentAwayIsDropped() async {
        let source = makeSource()
        let controller = makeController(source)
        source.holdsSamples = true
        controller.startPolling()
        await settle("the sample") { source.samples == 1 }
        controller.stopPolling()
        source.release()
        for _ in 0 ..< 20 { await Task.yield() }
        XCTAssertFalse(controller.hasReading, "the window is away: its rows stay as they were")
        // Back on screen: a fresh reading, and no CPU figure averaged over the time away.
        source.holdsSamples = false
        controller.startPolling()
        await settle { controller.hasReading }
        XCTAssertEqual(source.samples, 2)
        controller.category = .all
        XCTAssertEqual(controller.rows.first?.text(for: .cpu), "–")
        controller.stopPolling()
    }

    func testTheSelectionForgetsAProcessThatIsGone() {
        let source = makeSource()
        let controller = makeController(source)
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 50)
        controller.selection = [300, 310]
        source.processes.removeAll { $0.pid == 310 }
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 51)
        XCTAssertEqual(controller.selection, [300])
    }

    // MARK: End task

    func testEndTaskIsOffForTheBrowserAndWithNothingSelected() {
        let source = makeSource()
        let controller = makeController(source)
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 50)
        XCTAssertFalse(controller.canEndSelection)
        controller.selection = [100]
        XCTAssertFalse(controller.canEndSelection, "Darni itself")
        controller.selection = [200]
        XCTAssertTrue(controller.canEndSelection)
        controller.selection = [100, 310]
        XCTAssertEqual(controller.endableSelection.map(\.pid), [310])
    }

    func testEndingAProcessOfOneTabDoesNotAsk() async {
        let source = makeSource()
        let controller = makeController(source)
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 50)
        controller.selection = [100, 310]
        controller.endSelection { _, _ in XCTFail("one tab: nothing to ask") }
        await settle("the process to end") { source.ended == [310] }
        await settle("the reading after it") { !controller.groups.contains { $0.pid == 310 } }
        XCTAssertEqual(controller.selection, [100])
    }

    func testEndingAProcessOfSeveralTabsAsksFirst() async {
        let source = makeSource()
        let controller = makeController(source)
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 50)
        controller.selection = [300]

        var asked: [TaskManagerEndConfirmation] = []
        controller.endSelection { question, answer in
            asked.append(question)
            answer(false)
        }
        for _ in 0 ..< 20 { await Task.yield() }
        XCTAssertEqual(asked.map(\.title), ["End the process behind 2 tabs?"])
        XCTAssertEqual(source.ended, [], "Cancel ends nothing")

        controller.endSelection { _, answer in answer(true) }
        await settle("the process to end") { source.ended == [300] }
    }

    // MARK: Columns

    func testTheColumnChoiceIsSavedWhenItChanges() {
        let controller = makeController(makeSource())
        XCTAssertEqual(controller.columns.ordered, TaskManagerColumn.allCases)
        controller.columns.toggle(.network)
        controller.columns.toggle(.profile)
        let reopened = makeController(makeSource())
        XCTAssertEqual(reopened.columns.ordered, [.task, .memoryFootprint, .cpu, .processID])
    }

    // MARK: Without an engine

    func testWithoutAnEngineTheListIsReArcItself() async {
        let sample = await ShellTaskManagerSource().sample()
        XCTAssertEqual(sample.processes.map(\.pid), [getpid()])
        XCTAssertEqual(sample.processes.map(\.kind), [.browser])
        XCTAssertGreaterThan(sample.processes[0].memoryFootprint, 0)
        XCTAssertGreaterThan(sample.processes[0].cpuMicros, 0)
        let rows = TaskManagerRows.rows(TaskManagerRows.groups(processes: sample.processes, directory: sample.directory))
        XCTAssertEqual(rows.map(\.title), ["Browser"])
        XCTAssertEqual(rows.map(\.isKillable), [false])
    }

    func testOnlyAChildOfReArcIsEverSignalled() {
        XCTAssertFalse(TaskManagerProcessControl.terminate(getpid()), "never Darni itself")
        XCTAssertFalse(TaskManagerProcessControl.terminate(0))
        XCTAssertFalse(TaskManagerProcessControl.terminate(-1), "kill(-1) would signal every process of the user")
        XCTAssertFalse(TaskManagerProcessControl.terminate(1), "launchd is not a child of the test")
        XCTAssertFalse(TaskManagerProcessControl.terminate(getppid()), "the parent is not a child")
    }

    func testEndTaskStopsAChildProcess() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        XCTAssertEqual(TaskManagerProcessControl.parent(of: child.processIdentifier), getpid())
        XCTAssertTrue(TaskManagerProcessControl.terminate(child.processIdentifier))
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGTERM)
    }

    // MARK: What the engine adds

    func testEngineDetailsNeedABI165AndTheFeature() {
        let all: (String) -> Bool = { _ in true }
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 64, hasFeature: all).taskManager)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 65, hasFeature: all).taskManager)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 65, hasFeature: { $0 != "task_manager" }).taskManager)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 65, hasFeature: { $0 != "perf_metrics" }).taskManager,
                       "the details come with the process list")
        XCTAssertFalse(ChromiumCapabilities.none.taskManager)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 65, hasFeature: all).summary.contains("task_manager=1"))
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 64, hasFeature: all).summary.contains("task_manager=0"))
    }

    // MARK: Menus

    func testTheWindowMenuAndTheSidebarMenuOfferTaskManager() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-task-manager-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: SidebarStore(spaces: [Space(name: "Main", sortRank: "a")]),
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        XCTAssertEqual(ShellMenus.taskManager(model).map { $0.map(\.title) }, [["Task Manager"]])
        let menu = SidebarEmptySpaceMenu.menu(model: model, spaceID: model.store.activeSpaceID)
        let items = menu.items
        XCTAssertEqual(items.last?.title, "Task Manager", "Chrome's place for it: the last item")
        XCTAssertEqual(items.dropLast().last?.isSeparatorItem, true, "after a divider")
        XCTAssertEqual(items.filter { !$0.isSeparatorItem }.map(\.title), ["New Tab", "New Folder", "Reopen Closed Tab", "Task Manager"])
    }
}
