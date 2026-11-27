import XCTest
@testable import SidebarModel

/// The owner on 1447 (2026-11-27): dozens of rows read "Unloaded · 14 d 7 h",
/// tabs imported from Arc and never opened in Darni. Unloaded (tab sleep or the
/// person, this session) and not loaded are told apart; tabs not loaded for
/// more than a day fold into one row at the bottom; Idle is relative and honest.
final class TaskManagerNotLoadedTests: XCTestCase {
    private let day: TimeInterval = 24 * 3600

    private func directory() -> TaskManagerDirectory {
        var directory = TaskManagerDirectory(tabs: [1: .init(title: "Mail", sleep: .init(state: .active, idle: 0, isOnScreen: true), sidebarID: "M")])
        directory.unloadedTabs = [
            .init(id: "U", title: "Report", idle: 3 * day, wasUnloaded: true),  // tab sleep unloaded it this session
            .init(id: "R", title: "Recent", idle: 5 * 3600, wasUnloaded: false),  // opened 5 h ago, not since launch
        ]
        // 40 that fold: 30 imported from Arc (never opened in Darni), 10 last opened 3 to 14 days ago.
        for index in 0 ..< 30 {
            directory.unloadedTabs.append(.init(id: "A\(index)", title: "Imported \(index)", idle: 14 * day + 7 * 3600,
                                                wasUnloaded: false, openedInDarni: false))
        }
        for index in 0 ..< 10 {
            directory.unloadedTabs.append(.init(id: "O\(index)", title: "Old \(index)", idle: (3 + Double(index)) * day + 600,
                                                wasUnloaded: false))
        }
        directory.unloadedTabs.append(.init(id: "O-last", title: "Recipes", idle: 14 * day, wasUnloaded: false))
        return directory
    }

    private func stacks() -> [TaskManagerStack] {
        let directory = directory()
        let processes = [
            TaskManagerProcess(pid: 1, kind: .browser, memoryFootprint: 300 << 20),
            TaskManagerProcess(pid: 10, kind: .renderer, tabIDs: [1], memoryFootprint: 200 << 20, details: .init(mainFrameTabIDs: [1])),
        ]
        return TaskManagerRows.stacks(TaskManagerRows.groups(processes: processes, directory: directory), directory: directory)
    }

    func testABatchOfIdenticalDatesIsAnImportNotAVisit() {
        let imported = Date(timeIntervalSinceReferenceDate: 800_000_000.4)
        let dates: [Date?] = [imported, imported.addingTimeInterval(0.3), imported, Date(timeIntervalSinceReferenceDate: 800_000_500), nil]
        let counts = TaskManagerUnloadedTab.stampCounts(dates)
        XCTAssertTrue(TaskManagerUnloadedTab.isBatchStamp(imported, counts: counts), "three tabs in the same second")
        XCTAssertFalse(TaskManagerUnloadedTab.isBatchStamp(dates[3], counts: counts), "a date of its own")
        XCTAssertTrue(TaskManagerUnloadedTab.isBatchStamp(nil, counts: counts), "no date at all")
        XCTAssertEqual(TaskManagerUnloadedTab.batchSize, 3)
    }

    func testOnlyUnloadedTabsAndTabsOpenedWithinADayKeepTheirOwnRows() {
        XCTAssertTrue(TaskManagerUnloadedTab(id: "a", title: "a", idle: 30 * day, wasUnloaded: true).hasOwnRow)
        XCTAssertTrue(TaskManagerUnloadedTab(id: "b", title: "b", idle: day - 60, wasUnloaded: false).hasOwnRow)
        XCTAssertFalse(TaskManagerUnloadedTab(id: "c", title: "c", idle: day, wasUnloaded: false).hasOwnRow)
        XCTAssertFalse(TaskManagerUnloadedTab(id: "d", title: "d", idle: 60, wasUnloaded: false, openedInDarni: false).hasOwnRow,
                       "its only date is its import's")
        XCTAssertFalse(TaskManagerUnloadedTab(id: "e", title: "e", idle: nil, wasUnloaded: false).hasOwnRow)
    }

    func testTheRestFoldIntoOneGroupAtTheBottom() throws {
        let stacks = stacks()
        XCTAssertEqual(stacks.map(\.title), ["Darni", "Tab: Mail", "Tab: Recent", "Tab: Report", "Not loaded · 41 tabs"])
        let group = try XCTUnwrap(stacks.last)
        XCTAssertEqual(group.kind, .notLoaded)
        XCTAssertEqual(group.summary, "last opened 3 d – 14 d ago · 30 not opened in Darni")
        XCTAssertEqual(group.folded.prefix(3).map(\.name), ["Old 0", "Old 1", "Old 2"], "the most recently opened first")
        XCTAssertEqual(group.folded[10].name, "Recipes")
        XCTAssertEqual(group.folded[11].name, "Imported 0", "then the ones never opened in Darni")
        XCTAssertNil(group.memoryFootprint, "out of every total")
        XCTAssertFalse(group.isEstimate)
        XCTAssertTrue(group.hasChildren)
        XCTAssertFalse(group.selectsProcesses)

        let report = try XCTUnwrap(stacks.first { $0.name == "Report" })
        let recent = try XCTUnwrap(stacks.first { $0.name == "Recent" })
        XCTAssertEqual(report.sleep?.state, .unloaded)
        XCTAssertEqual(recent.sleep?.state, .notLoaded)
        XCTAssertEqual(TaskManagerTabState.notLoaded.title, "Not loaded")
        // The tab sleep strip counts only what tab sleep (or the person) unloaded.
        XCTAssertEqual(TaskManagerTabSleepSummary(stacks: stacks, history: TaskManagerHistory()).text, "Tab sleep now: 0 asleep, 1 unloaded")
    }

    func testTheGroupIsOneCollapsedRowThatOpensOnItsTabsAndStaysLast() throws {
        let stacks = stacks()
        var rows = TaskManagerRows.rows(stacks, filter: .tabs)
        XCTAssertEqual(rows.map(\.title), ["Tab: Mail", "Tab: Recent", "Tab: Report", "Not loaded · 41 tabs"])
        let group = try XCTUnwrap(rows.last)
        XCTAssertEqual(group.disclosure, .collapsed)
        XCTAssertEqual(group.note, "last opened 3 d – 14 d ago · 30 not opened in Darni")
        XCTAssertEqual(group.selectionKeys, [.row(TaskManagerRows.notLoadedStackID)])
        XCTAssertEqual(group.text(for: .idle), "3 d – 14 d", "relative: when its tabs were last opened")
        XCTAssertEqual(TaskManagerColumn.allCases.filter { $0 != .task && $0 != .idle }.map(group.text(for:)), Array(repeating: "", count: 8),
                       "no figures, no ≈")
        XCTAssertEqual(group.historyKey, "", "no history of its own")

        rows = TaskManagerRows.rows(stacks, filter: .tabs, expanded: [TaskManagerRows.notLoadedStackID])
        XCTAssertEqual(rows.count, 4 + 41)
        let children = rows.suffix(41)
        XCTAssertTrue(children.allSatisfy { $0.level == 1 && $0.isUnloaded })
        XCTAssertEqual(children.first?.title, "Tab: Old 0")
        XCTAssertEqual(children.first?.text(for: .idle), "3 d")
        XCTAssertEqual(children.first?.text(for: .state), "Not loaded")
        XCTAssertEqual(children.last?.text(for: .idle), "Not opened in Darni")
        XCTAssertEqual(children.first?.selectionKeys, [.row("unloaded/O0")])
        XCTAssertEqual(children.first?.tab, .sidebar("O0"), "Show Tab loads it")

        // Sorted by memory, or by idle, the fold stays at the bottom with its own order.
        for sort in [TaskManagerSort(column: .memoryFootprint, ascending: false), TaskManagerSort(column: .idle, ascending: true)] {
            let sorted = TaskManagerRows.rows(stacks, filter: .all, sort: sort, expanded: [TaskManagerRows.notLoadedStackID])
            XCTAssertEqual(sorted[sorted.count - 42].title, "Not loaded · 41 tabs", "\(sort)")
            XCTAssertEqual(sorted[sorted.count - 41].title, "Tab: Old 0")
        }
    }

    func testSearchFindsATabInsideTheFoldAndOpensItOnTheMatches() {
        let rows = TaskManagerRows.rows(stacks(), filter: .all, search: "recipes")
        XCTAssertEqual(rows.map(\.title), ["Not loaded · 41 tabs", "Tab: Recipes"])
        XCTAssertEqual(rows.first?.disclosure, .expanded)
        XCTAssertEqual(TaskManagerRows.rows(stacks(), filter: .all, search: "imported 2").count, 1 + 11, "Imported 2, 20–29")
        XCTAssertEqual(TaskManagerRows.rows(stacks(), filter: .all, search: "nothing like it"), [])
        XCTAssertEqual(TaskManagerRows.rows(stacks(), filter: .extensions).map(\.title), [], "not an extension")
    }

    func testIdleIsRelativeAndHonest() {
        XCTAssertEqual(TaskManagerTabSleep(state: .notLoaded, idle: 14 * day + 7 * 3600).idleText, "14 d")
        XCTAssertEqual(TaskManagerTabSleep(state: .notLoaded, idle: 14 * day, openedInDarni: false).idleText, "Not opened in Darni")
        XCTAssertEqual(TaskManagerTabSleep(state: .active, idle: 0, isOnScreen: true, openedInDarni: false).idleText, "Now")
        XCTAssertTrue(TaskManagerHelp.idle.contains("Not opened in Darni"))
        XCTAssertTrue(TaskManagerHelp.state(nil).contains("Not loaded:"))
        // Sorted by Idle, a tab never opened in Darni comes after every time.
        var directory = directory()
        directory.unloadedTabs = [.init(id: "x", title: "x", idle: 2 * 3600, wasUnloaded: true),
                                  .init(id: "y", title: "y", idle: 60, wasUnloaded: true, openedInDarni: false)]
        let stacks = TaskManagerRows.stacks([], directory: directory)
        XCTAssertEqual(TaskManagerRows.rows(stacks, sort: .init(column: .idle, ascending: false)).map(\.title), ["Tab: y", "Tab: x"])
    }

    func testTheFoldIsNotAStackOfTheHistory() {
        var history = TaskManagerHistory()
        history.record(stacks(), at: 1000, source: .window)
        XCTAssertNil(history[TaskManagerRows.notLoadedStackID])
        XCTAssertNil(history["sidebar/A0"], "a folded tab is not read")
        XCTAssertNotNil(history["sidebar/R"])
        XCTAssertEqual(history.recentCells("sidebar/R", now: 1000).last??.state, .unloaded, "no process: drawn as one with none")
    }
}
