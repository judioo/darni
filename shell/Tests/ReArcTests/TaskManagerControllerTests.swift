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

    /// Tabs that are pages of a space, or sidebar tabs; the others (a private window's) cannot be shown.
    var showable: Set<TaskManagerTabRef> = []
    private(set) var shown: [TaskManagerTabRef] = []
    func canShowTab(_ tab: TaskManagerTabRef) -> Bool { showable.contains(tab) }
    func showTab(_ tab: TaskManagerTabRef) { shown.append(tab) }

    /// The engine runs: background readings get a list.
    var live = true
    var isLive: Bool { live }
    /// Tab sleep as the shell does it: the action, then the event noted with the Task Manager.
    weak var controller: TaskManagerController?
    var sleepable: Set<TaskManagerTabRef> = []
    var unloadable: Set<TaskManagerTabRef> = []
    private(set) var actions: [String] = []
    func canSleepTab(_ tab: TaskManagerTabRef) -> Bool { sleepable.contains(tab) }
    func canUnloadTab(_ tab: TaskManagerTabRef) -> Bool { unloadable.contains(tab) }
    func sleepTab(_ tab: TaskManagerTabRef) { act("sleep", tab, .fellAsleep) }
    func unloadTab(_ tab: TaskManagerTabRef) { act("unload", tab, .unloaded) }
    func canOpenDevTools(_ tab: TaskManagerTabRef) -> Bool { showable.contains(tab) }
    func openDevTools(_ tab: TaskManagerTabRef) { actions.append("devtools \(tab)") }

    private func act(_ name: String, _ tab: TaskManagerTabRef, _ kind: TaskManagerTabEvent.Kind) {
        actions.append("\(name) \(tab)")
        guard case .engine(let id) = tab, let sidebar = directory.tabs[id]?.sidebarID else { return }
        controller?.noteTabControl(kind, sidebarID: sidebar, cause: .taskManager)
    }
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

    func testShowTabBringsATabOrAFramesTabForwardAndLoadsAnUnloadedOne() {
        let source = makeSource()
        source.showable = [.engine(1), .engine(3), .sidebar("U-1")]
        source.processes.append(TaskManagerProcess(
            pid: 320, kind: .renderer, tabIDs: [1],
            details: .init(mainFrameTabIDs: [], subframeTabIDs: [1], site: "https://accounts.example")
        ))
        source.directory.unloadedTabs = [.init(id: "U-1", title: "Docs")]
        let controller = makeController(source)
        controller.expanded = ["tab/1"]
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 50)
        let row = { (title: String) in controller.rows.first { $0.title == title }! }

        XCTAssertTrue(controller.canShowTab(of: row("Tab: Mail")))
        XCTAssertTrue(controller.canShowTab(of: row("Subframe: https://accounts.example")), "a frame shows the tab it sits in")
        XCTAssertTrue(controller.canShowTab(of: row("Tab: Docs")), "an unloaded tab loads as it is shown")
        XCTAssertFalse(controller.canShowTab(of: row("Tab: News")), "a page the shell cannot show")
        XCTAssertFalse(controller.canShowTab(of: row("Darni")))

        controller.showTab(of: row("Subframe: https://accounts.example"))
        controller.showTab(of: row("Tab: News"))
        controller.showTab(of: row("Darni"))
        controller.showTab(of: row("Tab: Docs"))
        controller.showTab(of: row("Tab: Bank"))
        XCTAssertEqual(source.shown, [.engine(1), .sidebar("U-1"), .engine(3)])
    }

    // MARK: Readings

    func testAReadingBecomesRowsAndTheSecondOneHasCPU() {
        let source = makeSource()
        let controller = makeController(source)
        XCTAssertFalse(controller.hasReading)
        controller.expanded = [TaskManagerRows.browserStackID]
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 50)
        XCTAssertTrue(controller.hasReading)
        XCTAssertEqual(controller.rows.map(\.title), ["Darni", "Browser", "GPU Process", "Tab: Mail", "Tab: News", "Tab: Bank"])
        XCTAssertEqual(controller.rows.map { $0.text(for: .cpu) }, ["–", "–", "–", "–", "–", "–"])
        XCTAssertEqual(controller.rows.map { $0.text(for: .network) }, ["–", "–", "–", "–", "–", "–"], "this engine does not count network bytes")

        source.processes[2].cpuMicros += 500_000
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 51)
        XCTAssertEqual(controller.rows.map { $0.text(for: .cpu) }, ["≈ 0.0", "0.0", "0.0", "≈ 25.0", "≈ 25.0", "0.0"],
                       "two tabs of one process count half of it each")
    }

    func testStacksOpenAndCloseAndOptionClickOpensThemAll() {
        let source = makeSource()
        source.processes.append(TaskManagerProcess(pid: 320, kind: .renderer, tabIDs: [3], details: .init(subframeTabIDs: [3], site: "https://ads.example")))
        let controller = makeController(source)
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 50)
        XCTAssertEqual(controller.rows.map(\.title), ["Darni", "Tab: Mail", "Tab: News", "Tab: Bank"])
        controller.toggleExpanded("tab/3")
        XCTAssertEqual(controller.rows.map(\.title), ["Darni", "Tab: Mail", "Tab: News", "Tab: Bank", "Page", "Subframe: https://ads.example"])
        controller.toggleExpanded("tab/3")
        XCTAssertEqual(controller.rows.count, 4)
        controller.toggleExpanded("tab/3", all: true)
        XCTAssertEqual(controller.expanded, [TaskManagerRows.browserStackID, "tab/3"], "every stack with processes under it")
        controller.toggleExpanded(TaskManagerRows.browserStackID, all: true)
        XCTAssertEqual(controller.expanded, [])
    }

    func testTheReadingCarriesTabSleepToTheRowsAndTheHelp() {
        let source = makeSource()
        source.directory.tabs[1]?.sleep = .init(state: .active, idle: 0, isOnScreen: true)
        source.directory.tabs[3]?.sleep = .init(state: .sleeping, idle: 40 * 60)
        source.directory.unloadedTabs = [.init(id: "U-1", title: "Docs", idle: 5 * 3600)]
        source.directory.sleepSettings = .init(freeze: .oneHour, unload: .twelveHours, canFreeze: true)
        let controller = makeController(source)
        controller.filter = .tabs
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 50)
        XCTAssertEqual(controller.rows.map { "\($0.title) \($0.text(for: .state)) \($0.text(for: .idle))" },
                       ["Tab: Mail Active Now", "Tab: News  ", "Tab: Bank Sleeping 40 min", "Tab: Docs Unloaded 5 h"])
        XCTAssertEqual(controller.sleepSettings, .init(freeze: .oneHour, unload: .twelveHours, canFreeze: true))
        XCTAssertTrue(TaskManagerHelp.state(controller.sleepSettings).contains("for 1 hour"))
        // Shown again, the tab leaves the unloaded rows.
        source.directory.unloadedTabs = []
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 51)
        XCTAssertFalse(controller.rows.contains { $0.isUnloaded })
    }

    func testTheWindowOpensOnTabsAndExtensionsAndFollowsSegmentSearchAndSort() {
        let source = makeSource()
        let controller = makeController(source)
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 50)
        XCTAssertEqual(controller.filter, .all)
        XCTAssertEqual(controller.rows.map(\.title), ["Darni", "Tab: Mail", "Tab: News", "Tab: Bank"])
        controller.search = "bank"
        XCTAssertEqual(controller.rows.map(\.title), ["Tab: Bank"])
        controller.search = ""
        controller.filter = .browser
        XCTAssertEqual(controller.rows.map(\.title), ["Browser", "GPU Process"])
        controller.filter = .all
        controller.sort = TaskManagerSort(column: .processID, ascending: false)
        XCTAssertEqual(controller.rows.map(\.title), ["Tab: Bank", "Tab: Mail", "Tab: News", "Darni"])
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
        XCTAssertEqual(controller.rows.first?.text(for: .cpu), "–")
        controller.stopPolling()
    }

    func testTheSelectionForgetsAProcessThatIsGone() {
        let source = makeSource()
        let controller = makeController(source)
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 50)
        controller.selection = [.process(300), .process(310), .row("darni"), .row("unloaded/gone")]
        source.processes.removeAll { $0.pid == 310 }
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 51)
        XCTAssertEqual(controller.selection, [.process(300), .row("darni")])
    }

    // MARK: End task

    func testEndTaskIsOffForTheBrowserAndWithNothingSelected() {
        let source = makeSource()
        let controller = makeController(source)
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 50)
        XCTAssertFalse(controller.canEndSelection)
        controller.selection = [.process(100)]
        XCTAssertFalse(controller.canEndSelection, "Darni itself")
        controller.selection = [.row(TaskManagerRows.browserStackID)]
        XCTAssertFalse(controller.canEndSelection, "Darni's own stack")
        controller.selection = [.process(200)]
        XCTAssertTrue(controller.canEndSelection)
        controller.selection = [.process(100), .process(310)]
        XCTAssertEqual(controller.endableSelection.map(\.pid), [310])
    }

    func testEndingAProcessOfOneTabDoesNotAsk() async {
        let source = makeSource()
        let controller = makeController(source)
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 50)
        controller.selection = [.process(100), .process(310)]
        controller.endSelection { _, _ in XCTFail("one tab: nothing to ask") }
        await settle("the process to end") { source.ended == [310] }
        await settle("the reading after it") { !controller.groups.contains { $0.pid == 310 } }
        XCTAssertEqual(controller.selection, [.process(100)])
    }

    func testEndingAProcessOfSeveralTabsAsksFirst() async {
        let source = makeSource()
        let controller = makeController(source)
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 50)
        controller.selection = [.process(300)]

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

    // MARK: The table

    func testTheTableDrawsStacksWithAChevronAndTheArrowKeysOpenAndCloseThem() async throws {
        let source = makeSource()
        source.directory.unloadedTabs = [.init(id: "U-1", title: "Docs")]
        let controller = makeController(source)
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 50)
        let tableController = TaskManagerTableController(controller: controller)
        let table = try XCTUnwrap(tableController.makeScrollView().documentView as? TaskManagerTableView)
        defer { tableController.invalidate() }
        func column(_ column: TaskManagerColumn) -> NSTableColumn { table.tableColumns.first { $0.identifier.rawValue == column.rawValue }! }
        func taskCell(_ row: Int) -> TaskManagerTaskCell { tableController.tableView(table, viewFor: column(.task), row: row) as! TaskManagerTaskCell }
        func chevron(_ row: Int) -> NSButton { taskCell(row).subviews.compactMap { $0 as? NSButton }.first! }
        func text(_ row: Int) -> String { taskCell(row).textField?.stringValue ?? "" }

        XCTAssertEqual((0 ..< table.numberOfRows).map(text), ["Darni", "Tab: Mail", "Tab: News", "Tab: Bank", "Tab: Docs"])
        XCTAssertEqual((0 ..< table.numberOfRows).map { chevron($0).isHidden }, [false, true, true, true, true])
        XCTAssertEqual(taskCell(1).subviews.compactMap { ($0 as? NSTextField)?.stringValue }, ["Tab: Mail", "shares its process with 1 other tab"])
        XCTAssertEqual(taskCell(4).imageView?.alphaValue, 0.45, "an unloaded tab is dimmed, as in the sidebar")
        XCTAssertEqual(column(.state).headerToolTip, TaskManagerHelp.state(nil))
        XCTAssertEqual(column(.idle).headerToolTip, TaskManagerHelp.idle)
        XCTAssertEqual(column(.memoryFootprint).headerToolTip, TaskManagerHelp.estimate)
        let state = tableController.tableView(table, viewFor: column(.state), row: 4) as! TaskManagerFigureCell
        XCTAssertEqual(state.textField?.stringValue, "Unloaded")
        XCTAssertEqual(state.toolTip, TaskManagerTabState.unloaded.explanation)
        XCTAssertNotNil(tableController.tableView(table, viewFor: column(.memoryFootprint), row: 0)?.toolTip, "a total says it is an estimate")
        XCTAssertNil(tableController.tableView(table, viewFor: column(.memoryFootprint), row: 3)?.toolTip, "one process's own figure")

        chevron(0).performClick(nil)
        XCTAssertEqual(controller.expanded, [TaskManagerRows.browserStackID])
        await settle("the open stack") { table.numberOfRows == 7 }
        XCTAssertEqual((0 ..< 3).map(text), ["Darni", "Browser", "GPU Process"])
        XCTAssertEqual(chevron(0).accessibilityLabel(), "Hide processes")

        table.selectRowIndexes([0], byExtendingSelection: false)
        XCTAssertEqual(controller.selection, [.row(TaskManagerRows.browserStackID)], "Darni's row selects itself, not its processes")
        func key(_ code: Int, _ keyCode: UInt16) -> NSEvent {
            let characters = String(Character(UnicodeScalar(code)!))
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
        }
        table.keyDown(with: key(NSLeftArrowFunctionKey, 123))
        XCTAssertEqual(controller.expanded, [])
        await settle("the closed stack") { table.numberOfRows == 5 }
        table.keyDown(with: key(NSRightArrowFunctionKey, 124))
        XCTAssertEqual(controller.expanded, [TaskManagerRows.browserStackID])
    }

    // MARK: Columns

    // MARK: History and insights

    private func sidebarSource() -> FakeTaskManagerSource {
        let source = makeSource()
        source.directory.tabs = [
            1: .init(title: "Mail", sleep: .init(state: .active, idle: 0, isOnScreen: true), sidebarID: "S1"),
            2: .init(title: "News", sleep: .init(state: .active, idle: 60), sidebarID: "S2"),
            3: .init(title: "Bank", sleep: .init(state: .active, idle: 600), sidebarID: "S3"),
        ]
        source.processes[3].memoryFootprint = 300 << 20
        return source
    }

    private func sample(_ source: FakeTaskManagerSource) -> TaskManagerSample {
        TaskManagerSample(processes: source.processes, directory: source.directory)
    }

    func testTheHistoryAndItsEventsSurviveTheWindowHiding() async {
        let source = sidebarSource()
        let controller = makeController(source)
        source.controller = controller
        var now: TimeInterval = 50
        controller.clock = { now }
        controller.startPolling()
        await settle { controller.hasReading }
        controller.apply(sample(source), at: 51)
        let bank = controller.stacks.first { $0.historyKey == "sidebar/S3" }!
        source.unloadable = [.engine(3)]
        controller.focus(bank)
        now = 52
        controller.unload(bank)
        XCTAssertEqual(source.actions, ["unload engine(3)"])
        XCTAssertEqual(controller.history["sidebar/S3"]?.events.map(\.kind), [.unloaded])
        XCTAssertEqual(controller.history["sidebar/S3"]?.events.first?.cause, .taskManager)
        controller.stopPolling()
        XCTAssertFalse(controller.isPolling)
        XCTAssertNotNil(controller.history["sidebar/S3"]?.recent, "the window hid: nothing is lost")
        XCTAssertEqual(controller.history["sidebar/S3"]?.events.count, 1)
        XCTAssertEqual(controller.focusedKey, "sidebar/S3")
        // Back on screen: the tab is unloaded now, and the inspector is still on it, with the measured effect.
        source.processes.removeAll { $0.pid == 310 }
        source.directory.tabs[3] = nil
        source.directory.unloadedTabs = [.init(id: "S3", title: "Bank")]
        controller.apply(sample(source), at: 60)
        XCTAssertEqual(controller.focusedStack?.id, "unloaded/S3")
        XCTAssertEqual(controller.selection, [.row("unloaded/S3")], "its new row is selected")
        XCTAssertEqual(controller.history["sidebar/S3"]?.events.first?.effect, .freed(bytes: 300 << 20, approximate: false))
        XCTAssertEqual(controller.summary.text, "Tab sleep now: 0 asleep, 1 unloaded · freed 300 MB by unloading this session")
    }

    func testTheBackgroundReadingStartsAndStopsWithTheEngineAndLeavesTheWindowAlone() async {
        let source = sidebarSource()
        let controller = makeController(source)
        XCTAssertTrue(controller.keepsBackgroundHistory, "on by default")
        XCTAssertFalse(controller.isReadingInBackground, "nothing before the engine")
        controller.engineDidAttach()
        XCTAssertTrue(controller.isReadingInBackground)
        await settle("the first background reading") { controller.history.lastReading != nil }
        XCTAssertEqual(source.samples, 1)
        XCTAssertFalse(controller.hasReading, "the window's rows are untouched")
        XCTAssertNotNil(controller.history["sidebar/S1"]?.minutes.first, "the 1 min cells")
        XCTAssertEqual(controller.history["sidebar/S1"]?.recent.isEmpty, true, "not the 10 s ones")
        XCTAssertEqual(TaskManagerController.backgroundInterval, 60)

        // While the window reads, the background reading skips.
        controller.startPolling()
        await settle { controller.hasReading }
        let samples = source.samples
        controller.readInBackground()
        for _ in 0 ..< 20 { await Task.yield() }
        XCTAssertEqual(source.samples, samples)
        controller.stopPolling()

        // An engine that is stopping is not asked.
        source.live = false
        controller.readInBackground()
        for _ in 0 ..< 20 { await Task.yield() }
        XCTAssertEqual(source.samples, samples)

        controller.engineDidDetach()
        XCTAssertFalse(controller.isReadingInBackground, "stops with the engine")
    }

    func testTurningTheSettingOffStopsTheTickAtOnceAndClearsWhatItKept() async {
        let source = sidebarSource()
        source.live = false  // this test drives the readings itself
        let controller = makeController(source)
        source.controller = controller
        var scheduled: [TimeInterval] = []
        controller.schedule = { delay, _ in scheduled.append(delay) }
        var now: TimeInterval = 1000
        controller.clock = { now }
        controller.engineDidAttach()
        controller.applyInBackground(sample(source), at: 1000)
        controller.applyInBackground(sample(source), at: 1060)
        now = 1070
        controller.noteTabControl(.unloaded, sidebarID: "S3", cause: .automatic)
        XCTAssertEqual(controller.history["sidebar/S3"]?.events.first?.whileClosed, true)
        XCTAssertEqual(scheduled, [TaskManagerHistory.settleDelay + 0.5], "a reading once the unload settles")

        controller.setKeepsBackgroundHistory(false)
        XCTAssertFalse(controller.isReadingInBackground, "stopped at once")
        XCTAssertNil(controller.history["sidebar/S3"], "what the closed window's readings kept is gone")
        XCTAssertNil(controller.history["sidebar/S1"])
        XCTAssertFalse(TaskManagerHistoryPreference.isEnabled(in: defaults))
        XCTAssertFalse(makeController(sidebarSource()).keepsBackgroundHistory, "the choice is kept")
        // Off, with the window closed, nothing is noted.
        controller.noteTabControl(.unloaded, sidebarID: "S2", cause: .automatic)
        XCTAssertNil(controller.history["sidebar/S2"])

        controller.setKeepsBackgroundHistory(true)
        XCTAssertTrue(controller.isReadingInBackground)
        XCTAssertTrue(TaskManagerHistoryPreference.isEnabled(in: defaults))
        controller.engineDidDetach()
    }

    func testAPrivateWindowsTabIsForgottenWhenItsWindowCloses() {
        let source = sidebarSource()
        source.directory.tabs[3] = .init(title: "Bank", isPrivate: true, sidebarID: "P1")
        let controller = makeController(source)
        controller.apply(sample(source), at: 50)
        XCTAssertNotNil(controller.history["sidebar/P1"])
        controller.focus(controller.stacks.first { $0.historyKey == "sidebar/P1" })
        controller.forgetTab(sidebarID: "P1")
        XCTAssertNil(controller.history["sidebar/P1"])
        XCTAssertNil(controller.focusedKey)
        // Gone from a reading, a private tab goes at once, not after 10 minutes.
        controller.apply(sample(source), at: 51)
        source.processes.removeAll { $0.pid == 310 }
        source.directory.tabs[3] = nil
        controller.apply(sample(source), at: 52)
        XCTAssertNil(controller.history["sidebar/P1"])
        XCTAssertNotNil(controller.history["sidebar/S2"])
    }

    func testTheViewChoiceIsSavedAndTheInspectorFollowsTheSelection() {
        let source = sidebarSource()
        let controller = makeController(source)
        XCTAssertEqual(controller.viewMode, .list)
        controller.viewMode = .heatGrid
        XCTAssertEqual(makeController(source).viewMode, .heatGrid)
        controller.apply(sample(source), at: 50)
        XCTAssertFalse(controller.isInspectorShown, "nothing selected: no inspector")
        controller.selectionChanged(toStack: "tab/2")
        XCTAssertEqual(controller.focusedStack?.title, "Tab: News")
        XCTAssertTrue(controller.isInspectorShown)
        controller.isInspectorCollapsed = true
        XCTAssertFalse(controller.isInspectorShown)
        controller.focus(controller.stacks.first { $0.historyKey == "sidebar/S3" })
        XCTAssertTrue(controller.isInspectorShown, "a click in the grid or the map opens it")
        XCTAssertEqual(controller.selection, [.process(310)])
        controller.selectionChanged(toStack: nil)
        XCTAssertNil(controller.focusedStack)
        // The heat grid and the map follow the filter and the search.
        controller.filter = .tabs
        controller.search = "ban"
        XCTAssertEqual(controller.visibleStacks.map(\.title), ["Tab: Bank"])
        controller.filter = .browser
        controller.search = ""
        XCTAssertEqual(controller.visibleStacks.map(\.title), ["Darni"])
    }

    func testSleepFromTheTaskManagerIsNotedAndOffWhereTheShellSaysNo() {
        let source = sidebarSource()
        let controller = makeController(source)
        source.controller = controller
        source.sleepable = [.engine(2)]
        var now: TimeInterval = 50
        controller.clock = { now }
        controller.startPolling()
        controller.apply(sample(source), at: 50)
        let news = controller.stacks.first { $0.historyKey == "sidebar/S2" }!
        let mail = controller.stacks.first { $0.historyKey == "sidebar/S1" }!
        XCTAssertTrue(controller.canSleep(news))
        XCTAssertFalse(controller.canSleep(mail), "on screen")
        XCTAssertFalse(controller.canUnload(mail))
        controller.sleep(mail)
        XCTAssertEqual(source.actions, [])
        now = 51
        controller.sleep(news)
        XCTAssertEqual(source.actions, ["sleep engine(2)"])
        XCTAssertEqual(controller.history["sidebar/S2"]?.events.map(\.kind), [.fellAsleep])
        XCTAssertEqual(controller.history["sidebar/S2"]?.events.first?.effect, .sleep)
        XCTAssertFalse(controller.canOpenDevTools(news))
        source.showable = [.engine(2)]
        controller.openDevTools(news)
        XCTAssertEqual(source.actions.last, "devtools engine(2)")
        XCTAssertTrue(controller.figures(for: news).hasPrefix("Darni Task Manager · Tab: News"))
        controller.stopPolling()
    }

    func testTheTableDrawsASparklinePerStackWithWordsForVoiceOver() throws {
        let source = sidebarSource()
        let controller = makeController(source)
        controller.apply(sample(source), at: 50)
        source.processes[3].cpuMicros += 500_000
        controller.apply(sample(source), at: 51)
        let tableController = TaskManagerTableController(controller: controller)
        let table = try XCTUnwrap(tableController.makeScrollView().documentView as? TaskManagerTableView)
        defer { tableController.invalidate() }
        func column(_ column: TaskManagerColumn) -> NSTableColumn { table.tableColumns.first { $0.identifier.rawValue == column.rawValue }! }
        XCTAssertNil(column(.memoryHistory).sortDescriptorPrototype, "a sparkline does not sort")
        XCTAssertFalse(column(.cpuHistory).isHidden, "on by default")
        XCTAssertEqual(column(.memoryHistory).title, "Memory 10 min")
        let bank = try XCTUnwrap(tableController.rows.firstIndex { $0.title == "Tab: Bank" })
        let memory = try XCTUnwrap(tableController.tableView(table, viewFor: column(.memoryHistory), row: bank) as? TaskManagerSparklineCell)
        XCTAssertEqual(memory.accessibilityLabel(), "Memory, last 10 minutes: 300 MB to 300 MB, peak 300 MB")
        XCTAssertEqual(memory.sparkline.values.compactMap { $0 }.count, 1, "one 10 s cell so far")
        XCTAssertEqual(memory.sparkline.values.compactMap { $0 }.first, Double(300 << 20), "the footprint itself")
        let cpu = try XCTUnwrap(tableController.tableView(table, viewFor: column(.cpuHistory), row: bank) as? TaskManagerSparklineCell)
        XCTAssertEqual(cpu.accessibilityLabel(), "CPU, last 10 minutes: average 50.0 %, peak 50.0 %")
        XCTAssertEqual(column(.cpuHistory).headerToolTip, TaskManagerTableController.sparklineHelp)
    }

    func testTheNotLoadedFoldKeepsItsStateAcrossReadingsAndItsTabsCanBeInspected() {
        let source = sidebarSource()
        source.directory.unloadedTabs = (0 ..< 40).map {
            .init(id: "A\($0)", title: "Imported \($0)", idle: 14 * 86_400, wasUnloaded: false, openedInDarni: false)
        } + [.init(id: "U", title: "Report", idle: 300, wasUnloaded: true)]
        let controller = makeController(source)
        controller.filter = .tabs
        controller.apply(sample(source), at: 50)
        XCTAssertEqual(controller.rows.map(\.title), ["Tab: Mail", "Tab: News", "Tab: Bank", "Tab: Report", "Not loaded · 40 tabs"])
        controller.toggleExpanded(TaskManagerRows.notLoadedStackID)
        controller.apply(sample(source), at: 51)
        XCTAssertEqual(controller.rows.count, 5 + 40, "still open after a reading")
        controller.selectionChanged(toStack: "unloaded/A3")
        XCTAssertEqual(controller.focusedStack?.name, "Imported 3", "a folded tab opens the inspector")
        controller.selection = [.row("unloaded/A3")]
        controller.apply(sample(source), at: 52)
        XCTAssertEqual(controller.selection, [.row("unloaded/A3")], "a folded tab's row stays selected")
        XCTAssertFalse(controller.visibleStacks.contains { $0.kind == .notLoaded }, "nothing to draw in the grid or the map")
        XCTAssertEqual(controller.summary.text, "Tab sleep now: 0 asleep, 1 unloaded")
        controller.toggleExpanded(TaskManagerRows.notLoadedStackID)
        XCTAssertEqual(controller.rows.count, 5)
    }

    func testTheColumnChoiceIsSavedWhenItChanges() {
        let controller = makeController(makeSource())
        XCTAssertEqual(controller.columns.ordered, TaskManagerColumn.allCases)
        controller.columns.toggle(.network)
        controller.columns.toggle(.profile)
        let reopened = makeController(makeSource())
        XCTAssertEqual(reopened.columns.ordered, [.task, .state, .idle, .memoryFootprint, .memoryHistory, .cpu, .cpuHistory, .processID])
    }

    // MARK: Without an engine

    func testWithoutAnEngineTheListIsReArcItself() async {
        let sample = await ShellTaskManagerSource().sample()
        XCTAssertEqual(sample.processes.map(\.pid), [getpid()])
        XCTAssertEqual(sample.processes.map(\.kind), [.browser])
        XCTAssertGreaterThan(sample.processes[0].memoryFootprint, 0)
        XCTAssertGreaterThan(sample.processes[0].cpuMicros, 0)
        let stacks = TaskManagerRows.stacks(TaskManagerRows.groups(processes: sample.processes, directory: sample.directory), directory: sample.directory)
        XCTAssertEqual(TaskManagerRows.rows(stacks).map(\.title), ["Darni"])
        XCTAssertEqual(TaskManagerRows.rows(stacks).map(\.isKillable), [false])
        XCTAssertEqual(TaskManagerRows.rows(stacks, filter: .browser).map(\.title), ["Browser"])
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

    // MARK: The row menu holds the table still

    /// Owner, RC 1447: a right-click menu jumped away and went dead while the
    /// once-a-second reading redrew the rows under it. While a menu is open
    /// the table keeps its rows and the menu its items; the change lands
    /// when the menu closes.
    func testTheTableHoldsStillWhileItsMenuIsOpen() throws {
        let source = makeSource()
        let controller = makeController(source)
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 50)
        let table = TaskManagerTableController(controller: controller)
        let scroll = table.makeScrollView()
        defer { table.invalidate() }
        let view = try XCTUnwrap(scroll.documentView as? NSTableView)
        let menu = try XCTUnwrap(view.menu)
        func drain() { for _ in 0 ..< 20 { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) } }
        drain()
        let before = table.rows
        XCTAssertFalse(before.isEmpty)
        XCTAssertEqual(view.numberOfRows, before.count)

        table.menuNeedsUpdate(menu)
        table.menuWillOpen(menu)
        let items = menu.items.map(\.title)
        source.directory.tabs[4] = .init(title: "Shop")
        source.processes.append(TaskManagerProcess(pid: 330, kind: .renderer, tabIDs: [4], cpuMicros: 9_000_000))
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 51)
        drain()
        XCTAssertNotEqual(controller.rows.map(\.id), before.map(\.id), "the reading itself went on")
        XCTAssertEqual(table.rows, before, "the rows under an open menu did not move")
        XCTAssertEqual(view.numberOfRows, before.count)
        XCTAssertTrue(table.hasDeferredRebuild)
        table.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.map(\.title), items, "an open menu keeps its items")

        table.menuDidClose(menu)
        drain()
        XCTAssertFalse(table.hasDeferredRebuild)
        XCTAssertEqual(table.rows.map(\.id), controller.rows.map(\.id), "the change landed once the menu closed")
        XCTAssertEqual(view.numberOfRows, controller.rows.count)

        // With no menu open, a reading redraws at once, as before.
        source.directory.tabs[5] = .init(title: "Maps")
        source.processes.append(TaskManagerProcess(pid: 340, kind: .renderer, tabIDs: [5]))
        controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: 52)
        drain()
        XCTAssertEqual(table.rows.map(\.id), controller.rows.map(\.id))
    }

}
