import CoreGraphics
import XCTest
@testable import SidebarModel

/// The Task Manager's history, its scripted rules, the tab controls' measured
/// effects and the memory map's layout, over made-up readings
/// (docs/TASK-MANAGER-INSIGHTS.md §5.1). Sites and titles are invented.
final class TaskManagerHistoryTests: XCTestCase {
    private let mb: UInt64 = 1 << 20

    // MARK: A made-up engine

    /// Tabs 1 (sidebar A), 2 (B) and 3 (C); Darni's own browser process.
    private struct Fixture {
        var processes: [TaskManagerProcess] = []
        var directory = TaskManagerDirectory()

        var stacks: [TaskManagerStack] {
            TaskManagerRows.stacks(TaskManagerRows.groups(processes: processes, directory: directory), directory: directory)
        }

        mutating func setCPU(_ pid: Int32, _ micros: Int64) {
            if let index = processes.firstIndex(where: { $0.pid == pid }) { processes[index].cpuMicros = micros }
        }

        mutating func addCPU(_ pid: Int32, percent: Double, over seconds: Double) {
            if let index = processes.firstIndex(where: { $0.pid == pid }) {
                processes[index].cpuMicros += Int64(percent / 100 * seconds * 1_000_000)
            }
        }

        mutating func setMemory(_ pid: Int32, _ bytes: UInt64) {
            if let index = processes.firstIndex(where: { $0.pid == pid }) { processes[index].memoryFootprint = bytes }
        }
    }

    private func tab(_ title: String, _ sidebar: String, state: TaskManagerTabState = .active, onScreen: Bool = false,
                     url: String? = nil, isPrivate: Bool = false) -> TaskManagerDirectory.Tab {
        .init(title: title, isPrivate: isPrivate, sleep: .init(state: state, idle: 0, isOnScreen: onScreen), sidebarID: sidebar,
              pageURL: url ?? "https://\(title.lowercased()).example/")
    }

    private func fixture() -> Fixture {
        var f = Fixture()
        f.directory.tabs = [1: tab("Mail", "A"), 2: tab("News", "B")]
        f.processes = [
            TaskManagerProcess(pid: 1, kind: .browser, memoryFootprint: 200 * mb, cpuMicros: 1_000_000),
            TaskManagerProcess(pid: 10, kind: .renderer, tabIDs: [1], memoryFootprint: 300 * mb, cpuMicros: 0,
                               details: .init(mainFrameTabIDs: [1], site: "https://mail.example")),
            TaskManagerProcess(pid: 20, kind: .renderer, tabIDs: [2], memoryFootprint: 100 * mb, cpuMicros: 0,
                               details: .init(mainFrameTabIDs: [2], site: "https://news.example")),
        ]
        return f
    }

    private let mail = "sidebar/A"
    private let news = "sidebar/B"

    private func timeline(_ now: TimeInterval) -> TaskManagerTimeline {
        TaskManagerTimeline(now: now, wallNow: Date(timeIntervalSinceReferenceDate: 800_000_000 + now))
    }

    // MARK: Folding

    func testReadingsFoldIntoTenSecondAndOneMinuteCells() throws {
        var f = fixture()
        var history = TaskManagerHistory()
        for second in 0 ..< 10 {
            f.setMemory(10, UInt64(100 + second) * mb)
            history.record(f.stacks, at: 1000 + TimeInterval(second), source: .window)
            f.addCPU(10, percent: 10, over: 1)
        }
        let cells = history.recentCells(mail, now: 1009)
        XCTAssertEqual(cells.count, TaskManagerHistory.recentCellCount)
        XCTAssertTrue(cells.dropLast().allSatisfy { $0 == nil }, "one cell so far")
        let cell = try XCTUnwrap(cells.last ?? nil)
        XCTAssertEqual(cell.memory, UInt64(104.5 * Double(mb)), "the average of the readings")
        XCTAssertEqual(cell.memoryPeak, 109 * mb)
        XCTAssertEqual(try XCTUnwrap(cell.cpuPercent), 10, accuracy: 0.001, "9 readings with a CPU figure, 10 % each")
        XCTAssertEqual(cell.state, .awake)
        XCTAssertEqual(try XCTUnwrap(history[mail]).cpuSeconds, 0.9, accuracy: 0.0001)
        let minute = try XCTUnwrap(history.minuteCells(mail, now: 1009).last ?? nil)
        XCTAssertEqual(minute.memory, cell.memory)

        history.record(f.stacks, at: 1010, source: .window)
        XCTAssertNotNil(history.recentCells(mail, now: 1010).last ?? nil, "a new 10 s cell")
        XCTAssertEqual(history.recentCells(mail, now: 1010).compactMap { $0 }.count, 2)
        XCTAssertEqual(history[mail]?.title, "Tab: Mail")
    }

    func testASharedProcessIsSplitAsTheStacksSplitIt() throws {
        var f = fixture()
        f.processes[1].tabIDs = [1, 2]
        f.processes[1].details = .init(mainFrameTabIDs: [1, 2], site: "https://example.com")
        f.processes.removeLast()
        f.setMemory(10, 400 * mb)
        var history = TaskManagerHistory()
        history.record(f.stacks, at: 1000, source: .window)
        f.addCPU(10, percent: 30, over: 1)
        history.record(f.stacks, at: 1001, source: .window)
        for key in [mail, news] {
            let cell = try XCTUnwrap(history.recentCells(key, now: 1001).last ?? nil)
            XCTAssertEqual(cell.memory, 200 * mb, "\(key): half of the process")
            XCTAssertEqual(try XCTUnwrap(cell.cpuPercent), 15, accuracy: 0.001)
        }
    }

    func testAsleepAndUnloadedCellsAndAnAwakeReadingWinsTheCell() throws {
        var f = fixture()
        f.directory.tabs[2] = tab("News", "B", state: .sleeping)
        f.directory.unloadedTabs = [.init(id: "C", title: "Docs")]
        var history = TaskManagerHistory()
        history.record(f.stacks, at: 1000, source: .window)
        history.record(f.stacks, at: 1001, source: .window)
        let asleep = try XCTUnwrap(history.recentCells(news, now: 1001).last ?? nil)
        XCTAssertEqual(asleep.state, .asleep)
        XCTAssertEqual(TaskManagerHeat.level(of: asleep), .asleep)
        let unloaded = try XCTUnwrap(history.recentCells("sidebar/C", now: 1001).last ?? nil)
        XCTAssertEqual(unloaded.state, .unloaded)
        XCTAssertNil(unloaded.memory, "no process: no footprint")
        XCTAssertEqual(unloaded.cpuPercent, 0, "and no CPU")
        XCTAssertEqual(TaskManagerHeat.level(of: unloaded), .unloaded)

        // Woken within the same cell: the cell is awake.
        f.directory.tabs[2] = tab("News", "B")
        history.record(f.stacks, at: 1002, source: .window)
        XCTAssertEqual(history.recentCells(news, now: 1002).last??.state, .awake)
        XCTAssertNotEqual(TaskManagerHeat.level(of: history.recentCells(news, now: 1002).last ?? nil), .asleep)
    }

    func testAReusedPidGivesNoCPUFigureAndNothingNegative() throws {
        var f = fixture()
        var history = TaskManagerHistory()
        f.setCPU(10, 5_000_000)
        history.record(f.stacks, at: 1000, source: .window)
        f.setCPU(10, 1_000_000)  // a new process with the same pid
        history.record(f.stacks, at: 1001, source: .window)
        XCTAssertNil(history.recentCells(mail, now: 1001).last??.cpuPercent)
        XCTAssertEqual(history[mail]?.cpuSeconds, 0)
        f.setCPU(10, 1_500_000)
        history.record(f.stacks, at: 1011, source: .window)
        XCTAssertEqual(try XCTUnwrap(history.recentCells(mail, now: 1011).last??.cpuPercent), 5, accuracy: 0.001)
    }

    func testTheHistoryKeepsThreeHoursAndTenMinutesAndForgetsWhatIsGone() throws {
        var f = fixture()
        f.directory.tabs[3] = tab("Private", "P", isPrivate: true)
        f.processes.append(TaskManagerProcess(pid: 30, kind: .renderer, tabIDs: [3], memoryFootprint: 50 * mb,
                                              details: .init(mainFrameTabIDs: [3])))
        var history = TaskManagerHistory()
        var time: TimeInterval = 100_000
        for _ in 0 ..< 240 {  // 4 hours of the 60 s reading
            history.record(f.stacks, at: time, source: .background)
            time += 60
        }
        let track = try XCTUnwrap(history[mail])
        XCTAssertEqual(track.minutes.count, TaskManagerHistory.minuteCellCount, "3 hours, no more")
        XCTAssertTrue(track.recent.isEmpty, "the 60 s reading feeds only the 1 min cells")
        for _ in 0 ..< 90 {  // 15 minutes of the window's reading
            history.record(f.stacks, at: time, source: .window)
            time += 10
        }
        XCTAssertEqual(history[mail]?.recent.count, TaskManagerHistory.recentCellCount, "10 minutes, no more")
        XCTAssertEqual(history[mail]?.members[10]?.cells.count, TaskManagerHistory.memberCellCount)

        // The private window closes: its tab is forgotten at once; a closed tab is kept 10 minutes.
        f.processes.removeAll { $0.pid == 30 || $0.pid == 20 }
        f.directory.tabs[3] = nil
        f.directory.tabs[2] = nil
        history.record(f.stacks, at: time, source: .window)
        XCTAssertNil(history["sidebar/P"])
        XCTAssertNotNil(history[news])
        // News was last read at `time - 10`.
        history.record(f.stacks, at: time - 10 + TaskManagerHistory.goneKeep, source: .window)
        XCTAssertNotNil(history[news])
        history.record(f.stacks, at: time - 10 + TaskManagerHistory.goneKeep + 1, source: .window)
        XCTAssertNil(history[news], "gone for more than 10 minutes")
        XCTAssertNotNil(history[mail])
    }

    // MARK: Growth

    private func growthHistory(minutes: Int, memory: (Int) -> Double, url: (Int) -> String = { _ in "https://feed.example/" })
        -> TaskManagerHistory {
        var f = fixture()
        var history = TaskManagerHistory()
        for minute in 0 ..< minutes {
            f.setMemory(10, UInt64(memory(minute) * Double(mb)))
            f.directory.tabs[1] = tab("Feed", "A", url: url(minute))
            history.record(f.stacks, at: 60_000 + Double(minute) * 60, source: .background)
        }
        return history
    }

    func testGrowthFiresOnASteadyClimbOnTheSamePage() throws {
        let history = growthHistory(minutes: 40) { 300 + Double($0) * 10 }
        let track = try XCTUnwrap(history[mail])
        let insight = try XCTUnwrap(TaskManagerInsights.growth(track, now: 60_000 + 39 * 60))
        XCTAssertEqual(insight.text, "Grew 380 MB in 38 min on the same page, and it never fell back.")
        XCTAssertTrue(insight.rule.hasPrefix("Scripted rule, not AI"))
        XCTAssertFalse(insight.text.contains("leak"), "it may be a cache by design")
        XCTAssertTrue(insight.isWarning)
    }

    func testGrowthStartsAgainAfterANavigation() throws {
        let history = growthHistory(minutes: 40, memory: { 300 + Double($0) * 10 },
                                    url: { $0 < 20 ? "https://feed.example/" : "https://feed.example/other" })
        XCTAssertNil(TaskManagerInsights.growth(try XCTUnwrap(history[mail]), now: 60_000 + 39 * 60), "only 19 minutes on this page")
    }

    func testSlowGrowthAndASawtoothCacheDoNotFire() throws {
        // 90 MB an hour for 3 hours: up 270 MB, but under the slope.
        let slow = growthHistory(minutes: 181) { 300 + Double($0) * 1.5 }
        XCTAssertNil(TaskManagerInsights.growth(try XCTUnwrap(slow[mail]), now: 60_000 + 180 * 60))
        // A cache that fills and empties every 10 minutes.
        let sawtooth = growthHistory(minutes: 60) { 300 + Double($0 % 10) * 45 }
        XCTAssertNil(TaskManagerInsights.growth(try XCTUnwrap(sawtooth[mail]), now: 60_000 + 59 * 60))
        // Up 400 MB but fell back at the end: the last 10 minutes dip under the first 10.
        let fellBack = growthHistory(minutes: 50) { $0 < 45 ? 300 + Double($0) * 10 : 250 }
        XCTAssertNil(TaskManagerInsights.growth(try XCTUnwrap(fellBack[mail]), now: 60_000 + 49 * 60))
    }

    func testLeastSquaresFit() {
        let line = TaskManagerInsights.leastSquares([(0, 1), (1, 3), (2, 5)])
        XCTAssertEqual(line.slope, 2, accuracy: 1e-9)
        XCTAssertEqual(line.r2, 1, accuracy: 1e-9)
        XCTAssertLessThan(TaskManagerInsights.leastSquares([(0, 0), (1, 5), (2, 0), (3, 5)]).r2, 0.3)
    }

    // MARK: Busy, burst

    private func cpuHistory(seconds: Int, step: Int = 2, start: TimeInterval = 20_000, state: TaskManagerTabState = .active,
                            onScreen: Bool = false, percent: (Int) -> Double) -> (TaskManagerHistory, TimeInterval) {
        var f = fixture()
        f.directory.tabs[1] = tab("Player", "A", state: state, onScreen: onScreen)
        var history = TaskManagerHistory()
        var time = start
        history.record(f.stacks, at: time, source: .window)
        while time < start + Double(seconds) {
            f.addCPU(10, percent: percent(Int(time - start)), over: Double(step))
            time += Double(step)
            history.record(f.stacks, at: time, source: .window)
        }
        return (history, time)
    }

    func testBusyWhileHiddenFiresAfterTwoMinutesAndSaysWhyTabSleepKeepsItAwake() throws {
        // 18 cells of 10 s: readings from 20 000 to 20 178.
        let (history, now) = cpuHistory(seconds: 178, state: .keptAwake(.playingSound)) { _ in 15 }
        let insight = try XCTUnwrap(TaskManagerInsights.busyWhileHidden(try XCTUnwrap(history[mail]), now: now))
        XCTAssertEqual(insight.text, "Used 15.0 % of a core for 3 min while hidden and playing sound.")
        let (plain, plainNow) = cpuHistory(seconds: 178) { _ in 15 }
        XCTAssertEqual(TaskManagerInsights.busyWhileHidden(try XCTUnwrap(plain[mail]), now: plainNow)?.text,
                       "Used 15.0 % of a core for 3 min while hidden.")
    }

    func testBusyWhileHiddenNeedsTwoMinutesHiddenAndAwake() throws {
        let (short, shortNow) = cpuHistory(seconds: 90) { _ in 15 }
        XCTAssertNil(TaskManagerInsights.busyWhileHidden(try XCTUnwrap(short[mail]), now: shortNow))
        let (shown, shownNow) = cpuHistory(seconds: 180, onScreen: true) { _ in 15 }
        XCTAssertNil(TaskManagerInsights.busyWhileHidden(try XCTUnwrap(shown[mail]), now: shownNow), "on screen")
        let (light, lightNow) = cpuHistory(seconds: 180) { _ in 8 }
        XCTAssertNil(TaskManagerInsights.busyWhileHidden(try XCTUnwrap(light[mail]), now: lightNow), "under 10 %")
    }

    func testABurstThatSettledIsSpottedAndOneStillRunningIsNot() throws {
        let (history, now) = cpuHistory(seconds: 90, start: 20_000) { $0 < 40 ? 40 : 1 }
        let insight = try XCTUnwrap(TaskManagerInsights.burst(try XCTUnwrap(history[mail]), timeline: timeline(now)))
        XCTAssertTrue(insight.text.hasPrefix("Ran 40 % for 40 s at "), insight.text)
        XCTAssertTrue(insight.text.hasSuffix(", then settled."))
        let (running, runningNow) = cpuHistory(seconds: 90, start: 20_000) { $0 < 60 ? 1 : 40 }
        XCTAssertNil(TaskManagerInsights.burst(try XCTUnwrap(running[mail]), timeline: timeline(runningNow)))
        // A cell the burst ended inside (about 18 %) lies between: still settled.
        let (winding, windingNow) = cpuHistory(seconds: 100, start: 20_000) { $0 < 44 ? 40 : 1 }
        XCTAssertNotNil(TaskManagerInsights.burst(try XCTUnwrap(winding[mail]), timeline: timeline(windingNow)))
        // Two cells of 15 % between: not "then settled".
        let (slow, slowNow) = cpuHistory(seconds: 100, start: 20_000) { $0 < 40 ? 40 : $0 < 60 ? 15 : 1 }
        XCTAssertNil(TaskManagerInsights.burst(try XCTUnwrap(slow[mail]), timeline: timeline(slowNow)))
        let (short, shortNow) = cpuHistory(seconds: 90, start: 20_000) { $0 < 20 ? 40 : 1 }
        XCTAssertNil(TaskManagerInsights.burst(try XCTUnwrap(short[mail]), timeline: timeline(shortNow)), "20 s is not a burst")
    }

    // MARK: Heat grid

    func testHeatGridBucketEdges() {
        let cases: [(Double, TaskManagerHeat)] = [
            (0, .idle), (0.099, .idle), (0.1, .low), (2.999, .low), (3, .moderate), (9.99, .moderate), (10, .busy),
            (24.99, .busy), (25, .high), (59.99, .high), (60, .hot), (250, .hot),
        ]
        for (cpu, level) in cases { XCTAssertEqual(TaskManagerHeat.level(cpu: cpu), level, "\(cpu) %") }
        XCTAssertEqual(TaskManagerHeat.level(of: nil), .noReading)
        XCTAssertEqual(TaskManagerHeat.allCases.compactMap(\.step), [0, 1, 2, 3, 4, 5], "six steps of CPU")
        XCTAssertNil(TaskManagerHeat.asleep.step)
        XCTAssertNil(TaskManagerHeat.unloaded.step)
        XCTAssertEqual(TaskManagerHeat.hot.title, "60 %+")
    }

    // MARK: Tab controls: unload

    func testAnUnloadIsMeasuredOnceItSettles() throws {
        var f = fixture()
        var history = TaskManagerHistory()
        history.record(f.stacks, at: 1000, source: .window)
        let event = try XCTUnwrap(history.note(.unloaded, key: mail, cause: .taskManager, at: 1000.5))
        XCTAssertEqual(event.effect, .measuring)
        // The renderer goes with the page.
        f.processes.removeAll { $0.pid == 10 }
        f.directory.tabs[1] = nil
        f.directory.unloadedTabs = [.init(id: "A", title: "Mail")]
        history.record(f.stacks, at: 1003, source: .window)
        XCTAssertEqual(history[mail]?.events.last?.effect, .measuring, "a few seconds first")
        history.record(f.stacks, at: 1006, source: .window)
        XCTAssertEqual(history[mail]?.events.last?.effect, .freed(bytes: 300 * mb, approximate: false))
        let track = try XCTUnwrap(history[mail])
        let line = TaskManagerEventText.line(track.events.last!, track: track, history: history, timeline: timeline(1006))
        XCTAssertTrue(line.hasPrefix("Unloaded at "), line)
        XCTAssertTrue(line.hasSuffix("from the Task Manager · freed 300 MB"), line)
        XCTAssertEqual(history.freedThisSession.bytes, 300 * mb)
        XCTAssertEqual(TaskManagerTabSleepSummary(stacks: f.stacks, history: history).text,
                       "Tab sleep now: 0 asleep, 1 unloaded · freed 300 MB by unloading this session")
    }

    func testAnUnloadWhoseProcessStaysCountsOnlyTheMeasuredDropAsAnEstimate() throws {
        // Chromium keeps the discarded tab's emptied frame in its renderer.
        var f = fixture()
        var history = TaskManagerHistory()
        history.record(f.stacks, at: 1000, source: .window)
        history.note(.unloaded, key: mail, cause: .automatic, at: 1001)
        f.directory.tabs[1] = tab("Mail", "A", state: .unloaded)
        f.setMemory(10, 40 * mb)
        history.record(f.stacks, at: 1007, source: .window)
        XCTAssertEqual(history[mail]?.events.last?.effect, .freed(bytes: 260 * mb, approximate: true))
        let track = try XCTUnwrap(history[mail])
        XCTAssertTrue(TaskManagerEventText.line(track.events.last!, track: track, history: history, timeline: timeline(1007))
            .hasSuffix("by tab sleep · freed ≈ 260 MB"))
        XCTAssertTrue(TaskManagerTabSleepSummary(stacks: f.stacks, history: history).text.hasSuffix("freed ≈ 260 MB by unloading this session"))
    }

    func testAnUnloadOfATabThatSharesItsProcessNeverClaimsTheOtherTabsMemory() throws {
        var f = fixture()
        f.processes[1].tabIDs = [1, 2]
        f.processes[1].details = .init(mainFrameTabIDs: [1, 2], site: "https://example.com")
        f.processes.removeLast()
        f.setMemory(10, 400 * mb)
        var history = TaskManagerHistory()
        history.record(f.stacks, at: 1000, source: .window)
        XCTAssertEqual(history.recentCells(mail, now: 1000).last??.memory, 200 * mb, "Mail's share before")
        history.note(.unloaded, key: mail, cause: .sidebar, at: 1001)
        f.directory.tabs[1] = tab("Mail", "A", state: .unloaded)
        f.setMemory(10, 380 * mb)
        history.record(f.stacks, at: 1007, source: .window)
        XCTAssertEqual(history[mail]?.events.last?.effect, .freed(bytes: 20 * mb, approximate: true),
                       "the measured drop, not the 200 MB share")

        // A process that grew gave nothing back: nothing is claimed.
        history.note(.loaded, key: mail, cause: .shown, at: 1010)
        f.directory.tabs[1] = tab("Mail", "A")
        history.record(f.stacks, at: 1011, source: .window)
        history.note(.unloaded, key: mail, cause: .sidebar, at: 1012)
        f.directory.tabs[1] = tab("Mail", "A", state: .unloaded)
        f.setMemory(10, 420 * mb)
        history.record(f.stacks, at: 1020, source: .window)
        XCTAssertEqual(history[mail]?.events.last?.effect, .freed(bytes: 0, approximate: true))
        let track = try XCTUnwrap(history[mail])
        XCTAssertTrue(TaskManagerEventText.line(track.events.last!, track: track, history: history, timeline: timeline(1020))
            .hasSuffix("freed nothing its process gave back"))
    }

    func testAnUnloadWithNoReadingBeforeItIsNotMeasured() throws {
        var history = TaskManagerHistory()
        let event = try XCTUnwrap(history.note(.unloaded, key: mail, cause: .automatic, at: 1000))
        XCTAssertEqual(event.effect, .notMeasured("No reading in the minute before it."))
        // Shown again before it settled: no figure either.
        var f = fixture()
        history.record(f.stacks, at: 2000, source: .window)
        history.note(.unloaded, key: news, cause: .sidebar, at: 2001)
        f.directory.tabs[2] = tab("News", "B")
        history.record(f.stacks, at: 2002, source: .window)
        XCTAssertEqual(history[news]?.events.last?.effect, .notMeasured("Shown again before it settled."))
        XCTAssertNotNil(history[news]?.events.last?.endedAt)
        XCTAssertEqual(history.freedThisSession.count, 0)
    }

    // MARK: Tab controls: sleep

    func testSleepShowsTheCPUBeforeAndSinceAndTheAvoidedEstimate() throws {
        var f = fixture()
        var history = TaskManagerHistory()
        var time: TimeInterval = 50_000
        history.record(f.stacks, at: time, source: .window)
        for _ in 0 ..< 300 {  // 10 minutes at 4 % of a core
            f.addCPU(10, percent: 4, over: 2)
            time += 2
            history.record(f.stacks, at: time, source: .window)
        }
        let slept = time
        history.note(.fellAsleep, key: mail, cause: .automatic, at: slept)
        f.directory.tabs[1] = tab("Mail", "A", state: .sleeping)
        for _ in 0 ..< 300 {  // 10 minutes asleep: no CPU
            time += 2
            history.record(f.stacks, at: time, source: .window)
        }
        let track = try XCTUnwrap(history[mail])
        let event = try XCTUnwrap(track.events.last)
        let effect = try XCTUnwrap(history.sleepEffect(of: event, in: track))
        XCTAssertEqual(try XCTUnwrap(effect.cpuBefore), 4, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(effect.cpuSince), 0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(effect.avoided(now: time)), 24, accuracy: 0.01, "4 % of 600 s")
        let line = TaskManagerEventText.line(event, track: track, history: history, timeline: timeline(time))
        XCTAssertTrue(line.hasPrefix("Asleep since "), line)
        XCTAssertTrue(line.hasSuffix("by tab sleep · 0 s CPU since (4.0 % average in the 10 min before)"), line)
        XCTAssertEqual(TaskManagerEventText.avoided(event, track: track, history: history, now: time), "≈ 24 s of CPU avoided")
        XCTAssertTrue(TaskManagerInsights.avoidedRule.contains("Scripted rule, not AI"))
        XCTAssertEqual(TaskManagerInsights.asleep(track, in: history, now: time)?.text, "Has slept for 10 min and used no CPU since.")
        XCTAssertNil(TaskManagerInsights.asleep(track, in: history, now: slept + 120), "under 5 minutes")
        XCTAssertEqual(TaskManagerTabSleepSummary(stacks: f.stacks, history: history).text, "Tab sleep now: 1 asleep, 0 unloaded")

        // Woken when shown: the sleep closes with what it used.
        f.directory.tabs[1] = tab("Mail", "A", onScreen: true)
        history.note(.woke, key: mail, cause: .shown, at: time + 1)
        let woken = try XCTUnwrap(history[mail])
        let closed = TaskManagerEventText.line(woken.events[woken.events.count - 2], track: woken, history: history, timeline: timeline(time + 1))
        XCTAssertTrue(closed.hasPrefix("Slept "), closed)
        XCTAssertTrue(closed.contains("by tab sleep · 0 s CPU in 10 min (4.0 % average in the 10 min before)"), closed)
        XCTAssertTrue(TaskManagerEventText.line(woken.events.last!, track: woken, history: history, timeline: timeline(time + 1))
            .hasSuffix("when shown"))
    }

    func testCPUWhileAsleepIsCountedFromTheReadingsAfterItSettled() throws {
        var f = fixture()
        var history = TaskManagerHistory()
        history.record(f.stacks, at: 1000, source: .window)
        history.note(.fellAsleep, key: mail, cause: .taskManager, at: 1000)
        f.directory.tabs[1] = tab("Mail", "A", state: .sleeping)
        f.addCPU(10, percent: 50, over: 4)  // still winding down
        history.record(f.stacks, at: 1004, source: .window)
        history.record(f.stacks, at: 1006, source: .window)  // settled: the count starts here
        f.addCPU(10, percent: 1, over: 10)
        history.record(f.stacks, at: 1016, source: .window)
        let track = try XCTUnwrap(history[mail])
        let effect = try XCTUnwrap(history.sleepEffect(of: track.events.last!, in: track))
        XCTAssertEqual(try XCTUnwrap(effect.cpuSince), 0.1, accuracy: 0.0001)
        XCTAssertNil(effect.cpuBefore, "no 10 minutes of readings before it")
        XCTAssertTrue(TaskManagerEventText.line(track.events.last!, track: track, history: history, timeline: timeline(1016))
            .hasSuffix("from the Task Manager · 0.1 s CPU since (no reading in the 10 min before)"))
    }

    func testEventsThatAreNotNewsAreDropped() {
        var history = TaskManagerHistory()
        XCTAssertNil(history.note(.woke, key: mail, cause: .shown, at: 1), "never asleep")
        XCTAssertNil(history.note(.loaded, key: mail, cause: .shown, at: 1), "never unloaded")
        XCTAssertNil(history[mail], "nothing kept for it")
        XCTAssertNotNil(history.note(.fellAsleep, key: mail, cause: .automatic, at: 2))
        XCTAssertNil(history.note(.fellAsleep, key: mail, cause: .automatic, at: 3), "already asleep")
        XCTAssertNotNil(history.note(.unloaded, key: mail, cause: .automatic, at: 4))
        XCTAssertNotNil(history[mail]?.events.first?.endedAt, "an unload ends the sleep")
        XCTAssertNil(history.note(.unloaded, key: mail, cause: .automatic, at: 5))
        XCTAssertEqual(history[mail]?.events.map(\.kind), [.fellAsleep, .unloaded])
    }

    func testAReadingEndsASleepTheShellDidNotReport() throws {
        var f = fixture()
        var history = TaskManagerHistory()
        history.record(f.stacks, at: 1000, source: .window)
        history.note(.fellAsleep, key: mail, cause: .automatic, at: 1000)
        f.directory.tabs[1] = tab("Mail", "A", state: .keptAwake(.playingSound))
        history.record(f.stacks, at: 1010, source: .window)
        XCTAssertEqual(history[mail]?.events.last?.endedAt, 1010)
        XCTAssertFalse(try XCTUnwrap(history[mail]).isAsleepByEvent)
    }

    // MARK: The background history

    func testTurningTheBackgroundHistoryOffClearsWhatItKeptWhileTheWindowWasClosed() throws {
        var f = fixture()
        var history = TaskManagerHistory()
        var time: TimeInterval = 60_000
        for _ in 0 ..< 5 {
            history.record(f.stacks, at: time, source: .background)
            time += 60
        }
        history.note(.unloaded, key: news, cause: .automatic, at: time - 30, whileClosed: true)
        f.processes.removeAll { $0.pid == 20 }
        f.directory.tabs[2] = nil
        f.directory.unloadedTabs = [.init(id: "B", title: "News")]
        history.record(f.stacks, at: time, source: .background)
        XCTAssertEqual(history.freedThisSession.count, 1)
        // Then the window opens.
        time += 60
        f.directory.tabs[1] = tab("Mail", "A")
        history.record(f.stacks, at: time, source: .window)
        history.note(.fellAsleep, key: mail, cause: .taskManager, at: time)
        XCTAssertEqual(history[mail]?.minutes.count, 7)

        history.clearClosedWindowHistory()
        XCTAssertEqual(history[mail]?.minutes.count, 1, "only the minute the window read")
        XCTAssertEqual(history[mail]?.events.map(\.kind), [.fellAsleep], "what happened with the window open stays")
        XCTAssertNil(history[news]?.events.first(where: { $0.kind == .unloaded }), "the unload noted while closed goes")
        XCTAssertEqual(history.freedThisSession.count, 0)
    }

    // MARK: Memory map

    func testTheTreemapsAreasAreProportionalWithNoOverlapAndAStableOrder() throws {
        let values: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let items = values.enumerated().map { TaskManagerTreemap.Item(id: "t\($0.offset)", value: $0.element) }
        let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
        let tiles = TaskManagerTreemap.layout(items, in: rect)
        XCTAssertEqual(tiles.map(\.id), ["t0", "t1", "t2", "t3", "t4", "t5", "t6"], "largest first, equal ones by ID")
        let total = values.reduce(0, +)
        for tile in tiles {
            let value = values[Int(tile.id.dropFirst())!]
            XCTAssertEqual(Double(tile.rect.width * tile.rect.height), value / total * 240_000, accuracy: 240_000 * 0.001, tile.id)
            XCTAssertTrue(rect.insetBy(dx: -0.01, dy: -0.01).contains(tile.rect), "\(tile.id) inside")
        }
        for (i, a) in tiles.enumerated() {
            for b in tiles.dropFirst(i + 1) {
                let overlap = a.rect.intersection(b.rect)
                XCTAssertTrue(overlap.isNull || overlap.width * overlap.height < 0.01, "\(a.id) and \(b.id) overlap")
            }
        }
        // Squarified: no sliver.
        XCTAssertTrue(tiles.allSatisfy { max($0.rect.width / $0.rect.height, $0.rect.height / $0.rect.width) < 4 })
        // The same figures in another order give the same picture.
        XCTAssertEqual(TaskManagerTreemap.layout(items.reversed(), in: rect), tiles)
        XCTAssertEqual(TaskManagerTreemap.layout([.init(id: "a", value: 0), .init(id: "b", value: -1)], in: rect), [])
        XCTAssertEqual(TaskManagerTreemap.layout(items, in: .zero), [])
    }

    // MARK: Words

    func testDurationsAndCPUTimes() {
        XCTAssertEqual(TaskManagerFormat.duration(30), "30 s")
        XCTAssertEqual(TaskManagerFormat.duration(140), "2 min 20 s")
        XCTAssertEqual(TaskManagerFormat.duration(600), "10 min")
        XCTAssertEqual(TaskManagerFormat.duration(2700), "45 min")
        XCTAssertEqual(TaskManagerFormat.duration(10_800), "3 h")
        XCTAssertEqual(TaskManagerFormat.duration(7800), "2 h 10 min")
        XCTAssertEqual(TaskManagerFormat.duration(100_800), "1 d 4 h")
        XCTAssertEqual(TaskManagerFormat.cpuTime(0.01), "0 s")
        XCTAssertEqual(TaskManagerFormat.cpuTime(4.2), "4.2 s")
        XCTAssertEqual(TaskManagerFormat.cpuTime(38), "38 s")
        XCTAssertEqual(TaskManagerFormat.cpuTime(360), "6 min")
    }

    func testVoiceOverReadsAHeatRowAndTheSparklines() throws {
        var f = fixture()
        var history = TaskManagerHistory()
        history.record(f.stacks, at: 1000, source: .window)
        f.addCPU(10, percent: 10, over: 10)
        f.setMemory(10, 320 * mb)
        history.record(f.stacks, at: 1010, source: .window)
        f.addCPU(10, percent: 30, over: 10)
        history.record(f.stacks, at: 1020, source: .window)
        let cells = history.recentCells(mail, now: 1020)
        let row = TaskManagerAccessibility.heatRow(name: "Mail", cells: cells, timeline: timeline(1020))
        XCTAssertTrue(row.hasPrefix("Mail, average 20.0 %, peak 30 % at "), row)
        XCTAssertEqual(TaskManagerAccessibility.memorySparkline(cells), "Memory, last 10 minutes: 300 MB to 320 MB, peak 320 MB")
        XCTAssertEqual(TaskManagerAccessibility.cpuSparkline(cells), "CPU, last 10 minutes: average 20.0 %, peak 30.0 %")
        XCTAssertEqual(TaskManagerAccessibility.cpuSparkline([nil, nil]), "CPU, last 10 minutes: no readings yet")
        f.directory.tabs[1] = tab("Mail", "A", state: .sleeping)
        history.record(f.stacks, at: 1030, source: .window)
        XCTAssertTrue(TaskManagerAccessibility.heatRow(name: "Mail", cells: history.recentCells(mail, now: 1030), timeline: timeline(1030))
            .hasSuffix("asleep 10 s"))
    }

    func testSpottedPicksTheMostImportantHintsFirst() throws {
        var f = fixture()
        f.directory.tabs[1] = tab("Player", "A")
        f.directory.tabs[2] = tab("News", "B", state: .sleeping)
        var history = TaskManagerHistory()
        var time: TimeInterval = 30_000
        history.record(f.stacks, at: time, source: .window)
        history.note(.fellAsleep, key: news, cause: .automatic, at: time)
        for _ in 0 ..< 200 {
            f.addCPU(10, percent: 20, over: 2)
            time += 2
            history.record(f.stacks, at: time, source: .window)
        }
        let spotted = TaskManagerInsights.spotted([mail, news, "darni"], in: history, timeline: timeline(time))
        XCTAssertEqual(spotted.map(\.kind), [.busyWhileHidden, .asleep])
        XCTAssertEqual(spotted.map(\.name), ["Player", "News"])
        XCTAssertTrue(spotted.allSatisfy { $0.rule.hasPrefix("Scripted rule, not AI") })
    }

    func testCopyFiguresIsPlainTextOfTheCard() throws {
        var f = fixture()
        var history = TaskManagerHistory()
        history.record(f.stacks, at: 1000, source: .window)
        history.note(.unloaded, key: news, cause: .taskManager, at: 1001)
        f.processes.removeAll { $0.pid == 20 }
        f.directory.tabs[2] = nil
        f.directory.unloadedTabs = [.init(id: "B", title: "News")]
        history.record(f.stacks, at: 1010, source: .window)
        let mailStack = try XCTUnwrap(f.stacks.first { $0.historyKey == mail })
        let text = TaskManagerFigures.text(stack: mailStack, history: history, timeline: timeline(1010))
        XCTAssertTrue(text.hasPrefix("Darni Task Manager · Tab: Mail"), text)
        XCTAssertTrue(text.contains("Site: https://mail.example"))
        XCTAssertTrue(text.contains("By process:\n  Page: https://mail.example · 300 MB · pid 10"), text)
        let newsStack = try XCTUnwrap(f.stacks.first { $0.historyKey == news })
        let unloaded = TaskManagerFigures.text(stack: newsStack, history: history, timeline: timeline(1010))
        XCTAssertTrue(unloaded.contains("No process: nothing of the page is in memory."))
        XCTAssertTrue(unloaded.contains("Tab controls:\n  Unloaded at "), unloaded)
        XCTAssertTrue(unloaded.contains("from the Task Manager · freed 100 MB"), unloaded)
    }

    // MARK: Preferences

    func testTheBackgroundHistoryIsOnByDefaultAndTheViewChoiceIsKept() throws {
        let suite = "darni-tm-history-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TaskManagerHistoryPreference.defaultsKey, "rearc.taskManagerBackgroundHistory")
        XCTAssertTrue(TaskManagerHistoryPreference.isEnabled(in: defaults))
        defaults.set(false, forKey: TaskManagerHistoryPreference.defaultsKey)
        XCTAssertFalse(TaskManagerHistoryPreference.isEnabled(in: defaults))
        XCTAssertEqual(TaskManagerHistoryPreference.detail,
                       "Reads the process list once a minute and keeps it in memory only. Nothing is saved or sent.")
        XCTAssertEqual(TaskManagerViewMode.load(from: defaults), .list)
        TaskManagerViewMode.memoryMap.save(to: defaults)
        XCTAssertEqual(TaskManagerViewMode.load(from: defaults), .memoryMap)
        XCTAssertEqual(TaskManagerViewMode.allCases.map(\.title), ["List", "Heat grid", "Memory map"])
    }
}
