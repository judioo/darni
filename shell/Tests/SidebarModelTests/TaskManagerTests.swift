import XCTest
@testable import SidebarModel

/// Window › Task Manager: from the engine's process list to the rows on
/// screen, with made-up process lists.
final class TaskManagerTests: XCTestCase {
    private typealias Process = TaskManagerProcess

    private let directory = TaskManagerDirectory(
        tabs: [
            1: .init(title: "Mail"),
            2: .init(title: "News"),
            3: .init(title: "Bank", isPrivate: true),
            4: .init(title: "Options", extensionID: "abcd"),
        ],
        profiles: [10: "Personal", 11: "Work"],
        extensions: ["abcd": "Reader Mode"]
    )

    /// ReArc, the GPU process, the network service, a renderer with two
    /// tabs, a renderer with one, an extension and a renderer with no page.
    private var processes: [Process] {
        [
            Process(pid: 300, kind: .renderer, profileID: 10, tabIDs: [1, 2], memoryFootprint: 300 << 20, cpuMicros: 9_000_000),
            Process(pid: 100, kind: .browser, memoryFootprint: 500 << 20, cpuMicros: 50_000_000),
            Process(pid: 250, kind: .utility, name: "network.mojom.NetworkService", memoryFootprint: 20 << 20, cpuMicros: 1_000_000),
            Process(pid: 200, kind: .gpu, memoryFootprint: 150 << 20, cpuMicros: 4_000_000),
            Process(pid: 310, kind: .renderer, profileID: 11, tabIDs: [3], memoryFootprint: 80 << 20, cpuMicros: 2_000_000),
            Process(pid: 320, kind: .renderer, profileID: 10, isExtension: true, tabIDs: [4], memoryFootprint: 40 << 20),
            Process(pid: 330, kind: .renderer, profileID: 10, memoryFootprint: 30 << 20),
        ]
    }

    private func groups(_ processes: [Process]? = nil, usage: [Int32: TaskManagerUsage] = [:]) -> [TaskManagerGroup] {
        TaskManagerRows.groups(processes: processes ?? self.processes, usage: usage, directory: directory)
    }

    private func titles(_ rows: [TaskManagerRow]) -> [String] { rows.map(\.title) }

    // MARK: Grouping and names

    func testOneGroupPerProcessWithChromesPrefixes() {
        let groups = groups()
        XCTAssertEqual(groups.map(\.pid), [100, 200, 250, 300, 310, 320, 330], "ReArc, its helpers, then the pages, by pid")
        XCTAssertEqual(groups.map { $0.tasks.map(\.title) }, [
            ["Browser"],
            ["GPU Process"],
            ["Utility: Network Service"],
            ["Tab: Mail", "Tab: News"],
            ["Private tab: Bank"],
            ["Extension: Reader Mode"],
            ["Renderer"],
        ])
        XCTAssertEqual(groups.map(\.profile), ["", "", "", "Personal", "Work", "Personal", "Personal"])
        XCTAssertEqual(groups.map(\.category), [.browser, .browser, .browser, .tabsAndExtensions, .tabsAndExtensions, .tabsAndExtensions, .browser])
    }

    func testIconsFollowTheTask() {
        let icons = groups().map { $0.tasks.map(\.icon) }
        XCTAssertEqual(icons, [
            [.browser], [.system], [.system], [.tab(1), .tab(2)], [.tab(3)], [.browserExtension("abcd")], [.system],
        ])
    }

    func testFiguresShowOnTheFirstRowOfAProcessOnly() {
        let rows = TaskManagerRows.rows(groups(usage: [300: TaskManagerUsage(cpuPercent: 12.34, networkBytesPerSecond: 2048)]))
        let mail = rows.first { $0.title == "Tab: Mail" }!
        let news = rows.first { $0.title == "Tab: News" }!
        XCTAssertTrue(mail.isFirstInGroup)
        XCTAssertFalse(news.isFirstInGroup)
        XCTAssertEqual(TaskManagerColumn.allCases.map(mail.text(for:)), ["Tab: Mail", "Personal", "300 MB", "12.3", "2.0 KB/s", "300"])
        XCTAssertEqual(TaskManagerColumn.allCases.map(news.text(for:)), ["Tab: News", "Personal", "", "", "", ""])
        XCTAssertEqual(mail.pid, news.pid)
        XCTAssertNotEqual(mail.id, news.id)
    }

    func testRowIDsStayTheSameFromOneReadingToTheNext() {
        var later = processes
        later[0].memoryFootprint += 1 << 20
        XCTAssertEqual(TaskManagerRows.rows(groups()).map(\.id), TaskManagerRows.rows(groups(later)).map(\.id))
        XCTAssertEqual(Set(TaskManagerRows.rows(groups()).map(\.id)).count, 8)
    }

    func testOnlyTheBrowserCannotBeEnded() {
        let rows = TaskManagerRows.rows(groups())
        XCTAssertEqual(rows.filter { !$0.isKillable }.map(\.title), ["Browser"])
    }

    func testATabTheShellHasNoPageForIsLeftOut() {
        let groups = groups([Process(pid: 300, kind: .renderer, tabIDs: [1, 99])])
        XCTAssertEqual(groups[0].tasks.map(\.title), ["Tab: Mail"])
        XCTAssertEqual(self.groups([Process(pid: 300, kind: .renderer, tabIDs: [99])])[0].tasks.map(\.title), ["Renderer"])
    }

    func testAnExtensionWithoutAKnownNameIsStillAnExtension() {
        let group = groups([Process(pid: 320, kind: .renderer, isExtension: true)])[0]
        XCTAssertEqual(group.tasks, [TaskManagerTask(id: "320", title: "Extension", icon: .browserExtension(nil))])
        XCTAssertEqual(group.category, .tabsAndExtensions)
    }

    func testUtilityNamesComeFromTheServiceInterface() {
        XCTAssertEqual(TaskManagerRows.utilityName("network.mojom.NetworkService"), "Network Service")
        XCTAssertEqual(TaskManagerRows.utilityName("storage.mojom.StorageService"), "Storage Service")
        XCTAssertEqual(TaskManagerRows.utilityName("video_capture.mojom.VideoCaptureService"), "Video Capture Service")
        XCTAssertEqual(TaskManagerRows.utilityName("Audio Service"), "Audio Service", "a name with words is kept")
        XCTAssertEqual(TaskManagerRows.utilityName(""), "")
        XCTAssertEqual(groups([Process(pid: 5, kind: .utility)])[0].tasks.map(\.title), ["Utility"])
        XCTAssertEqual(groups([Process(pid: 5, kind: .other, name: "ppapi.mojom.Broker")])[0].tasks.map(\.title), ["Broker"])
        XCTAssertEqual(groups([Process(pid: 5, kind: .other)])[0].tasks.map(\.title), ["Helper"])
    }

    // MARK: What `task_manager` adds

    func testDetailsTellPagesFromFramesAndNameTheRest() {
        let detailed = [
            Process(pid: 300, kind: .renderer, profileID: 10, tabIDs: [1, 2],
                    details: .init(mainFrameTabIDs: [1], subframeTabIDs: [2], site: "https://ads.example/")),
            Process(pid: 310, kind: .renderer, tabIDs: [3], details: .init(subframeTabIDs: [3])),
            Process(pid: 320, kind: .renderer, isExtension: true, details: .init(extensionID: "zzzz", extensionName: "Dark Pages")),
            Process(pid: 330, kind: .renderer, details: .init(isSpare: true)),
            // A page kept for Back: a frame of tab 1, but nothing the person sees.
            Process(pid: 340, kind: .renderer, tabIDs: [1], details: .init()),
            Process(pid: 250, kind: .utility, name: "network.mojom.NetworkService", details: .init(title: "Network Service")),
            Process(pid: 260, kind: .utility, name: "audio.mojom.AudioService", details: .init()),
        ]
        let groups = groups(detailed)
        XCTAssertEqual(groups.map { $0.tasks.map(\.title) }, [
            ["Utility: Network Service"],
            ["Utility: Audio Service"],
            ["Tab: Mail", "Subframe: https://ads.example/"],
            ["Private subframe"],
            ["Extension: Dark Pages"],
            ["Spare renderer"],
            ["Renderer"],
        ])
        XCTAssertEqual(groups[2].tasks.map(\.icon), [.tab(1), .tab(2)])
        XCTAssertEqual(groups[2].tabTitles, ["Mail"], "a frame of another tab's page is not a tab of this process")
        XCTAssertEqual(groups[4].tasks.map(\.icon), [.browserExtension("zzzz")])
        XCTAssertEqual(groups[5].category, .browser, "Chrome lists the spare renderer with the browser's own processes")
    }

    func testDetailsJSON() {
        let json = """
        {"300": {"main_frame_tabs": ["1", "18446744073709551615"], "subframe_tabs": ["2"], "site": "https://a.example/",
                 "network_bytes": "5000000000", "later_key": [1, 2]},
         "320": {"extension_id": "abcd", "extension_name": "Reader Mode"},
         "330": {"spare": true},
         "250": {"title": "Network Service"},
         "not a pid": {"spare": true}}
        """
        let details = Process.Details.byProcess(json: json)
        XCTAssertEqual(details.count, 4)
        XCTAssertEqual(details[300], .init(mainFrameTabIDs: [1, .max], subframeTabIDs: [2], site: "https://a.example/",
                                           networkBytes: 5_000_000_000))
        XCTAssertEqual(details[320], .init(extensionID: "abcd", extensionName: "Reader Mode"))
        XCTAssertEqual(details[330], .init(isSpare: true))
        XCTAssertEqual(details[250], .init(title: "Network Service"))
        XCTAssertEqual(Process.Details.byProcess(json: "nonsense"), [:])
        XCTAssertEqual(Process.Details.byProcess(json: "[]"), [:])
    }

    // MARK: CPU and network from two readings

    func testCPUPercentIsTheCPUTimeUsedOverTheInterval() {
        var sampler = TaskManagerSampler()
        let first = sampler.usage(of: [Process(pid: 1, kind: .renderer, cpuMicros: 1_000_000)], at: 10)
        XCTAssertEqual(first, [1: TaskManagerUsage()], "one reading has nothing to compare with")
        // 250 ms of CPU in one second: 25 % of a core.
        let second = sampler.usage(of: [Process(pid: 1, kind: .renderer, cpuMicros: 1_250_000)], at: 11)
        XCTAssertEqual(second[1]?.cpuPercent ?? -1, 25, accuracy: 0.0001)
        // 3 s of CPU in two seconds: 150 %, a process busy on more than one core.
        let third = sampler.usage(of: [Process(pid: 1, kind: .renderer, cpuMicros: 4_250_000)], at: 13)
        XCTAssertEqual(third[1]?.cpuPercent ?? -1, 150, accuracy: 0.0001)
        let idle = sampler.usage(of: [Process(pid: 1, kind: .renderer, cpuMicros: 4_250_000)], at: 14)
        XCTAssertEqual(idle[1]?.cpuPercent, 0)
    }

    func testANewProcessAReusedPidAndAStoppedClockHaveNoRate() {
        var sampler = TaskManagerSampler()
        _ = sampler.usage(of: [Process(pid: 1, kind: .renderer, cpuMicros: 5_000_000)], at: 10)
        let next = sampler.usage(of: [
            Process(pid: 1, kind: .renderer, cpuMicros: 100_000),
            Process(pid: 2, kind: .renderer, cpuMicros: 900_000),
        ], at: 11)
        XCTAssertNil(next[1]?.cpuPercent, "a total that went down is another process with the same pid")
        XCTAssertNil(next[2]?.cpuPercent, "a process first seen now")
        let same = sampler.usage(of: [Process(pid: 1, kind: .renderer, cpuMicros: 200_000)], at: 11)
        XCTAssertNil(same[1]?.cpuPercent, "no time has passed")
        let later = sampler.usage(of: [Process(pid: 1, kind: .renderer, cpuMicros: 300_000)], at: 12)
        XCTAssertEqual(later[1]?.cpuPercent ?? -1, 10, accuracy: 0.0001)
    }

    func testResetForgetsTheLastReading() {
        var sampler = TaskManagerSampler()
        _ = sampler.usage(of: [Process(pid: 1, kind: .renderer, cpuMicros: 0)], at: 10)
        sampler.reset()
        // An hour away must not show as an average over the hour.
        let back = sampler.usage(of: [Process(pid: 1, kind: .renderer, cpuMicros: 60_000_000)], at: 3610)
        XCTAssertNil(back[1]?.cpuPercent)
    }

    func testNetworkIsBytesPerSecondAndUnknownWithoutDetails() {
        var sampler = TaskManagerSampler()
        func reading(_ bytes: UInt64?) -> [Process] {
            [
                Process(pid: 1, kind: .renderer, details: bytes.map { .init(networkBytes: $0) }),
                Process(pid: 2, kind: .renderer),
            ]
        }
        _ = sampler.usage(of: reading(1000), at: 10)
        let next = sampler.usage(of: reading(5000), at: 12)
        XCTAssertEqual(next[1]?.networkBytesPerSecond, 2000)
        XCTAssertNil(next[2]?.networkBytesPerSecond, "an engine that does not count it")
        XCTAssertEqual(next[2]?.cpuPercent, 0)
        let restarted = sampler.usage(of: reading(10), at: 13)
        XCTAssertNil(restarted[1]?.networkBytesPerSecond, "a count that went down started again")
        XCTAssertNotNil(restarted[1]?.cpuPercent)
    }

    // MARK: Segments and search

    func testSegments() {
        let groups = groups()
        XCTAssertEqual(titles(TaskManagerRows.rows(groups, category: .tabsAndExtensions)),
                       ["Tab: Mail", "Tab: News", "Private tab: Bank", "Extension: Reader Mode"])
        XCTAssertEqual(titles(TaskManagerRows.rows(groups, category: .browser)),
                       ["Browser", "GPU Process", "Utility: Network Service", "Renderer"])
        XCTAssertEqual(TaskManagerRows.rows(groups, category: .all).count, 8)
        XCTAssertEqual(TaskManagerCategory.allCases.map(\.title), ["Tabs and extensions", "Browser", "All tasks"])
    }

    func testSearchKeepsAProcessWhoseTaskMatchesWhole() {
        let groups = groups()
        XCTAssertEqual(titles(TaskManagerRows.rows(groups, search: "news")), ["Tab: Mail", "Tab: News"],
                       "as Chrome: the tasks that share the matching task's process stay")
        XCTAssertEqual(titles(TaskManagerRows.rows(groups, search: "  GPU ")), ["GPU Process"])
        XCTAssertEqual(titles(TaskManagerRows.rows(groups, search: "tab:")), ["Tab: Mail", "Tab: News", "Private tab: Bank"])
        XCTAssertEqual(titles(TaskManagerRows.rows(groups, search: "réader")), ["Extension: Reader Mode"])
        XCTAssertEqual(TaskManagerRows.rows(groups, search: "nothing like it"), [])
        XCTAssertEqual(TaskManagerRows.rows(groups, search: "   ").count, 8)
    }

    func testSearchStaysInsideTheSegment() {
        let groups = groups()
        XCTAssertEqual(TaskManagerRows.rows(groups, category: .browser, search: "mail"), [])
        XCTAssertEqual(titles(TaskManagerRows.rows(groups, category: .tabsAndExtensions, search: "e")),
                       ["Tab: Mail", "Tab: News", "Private tab: Bank", "Extension: Reader Mode"])
    }

    // MARK: Sorting

    func testSortingMovesAProcessWithAllItsTasks() {
        let groups = groups()
        let largest = TaskManagerRows.rows(groups, sort: TaskManagerSort(column: .memoryFootprint, ascending: false))
        XCTAssertEqual(titles(largest), [
            "Browser", "Tab: Mail", "Tab: News", "GPU Process", "Private tab: Bank", "Extension: Reader Mode", "Renderer",
            "Utility: Network Service",
        ])
        XCTAssertEqual(largest.map(\.isFirstInGroup), [true, true, false, true, true, true, true, true])
        let smallest = TaskManagerRows.rows(groups, sort: TaskManagerSort(column: .memoryFootprint, ascending: true))
        XCTAssertEqual(titles(smallest).first, "Utility: Network Service")
        XCTAssertEqual(titles(smallest).suffix(3), ["Tab: Mail", "Tab: News", "Browser"])
    }

    func testSortingByNameProfileAndPid() {
        let groups = groups()
        XCTAssertEqual(titles(TaskManagerRows.rows(groups, sort: TaskManagerSort(column: .task, ascending: true))), [
            "Browser", "Extension: Reader Mode", "GPU Process", "Private tab: Bank", "Renderer", "Tab: Mail", "Tab: News",
            "Utility: Network Service",
        ])
        XCTAssertEqual(TaskManagerRows.rows(groups, sort: TaskManagerSort(column: .processID, ascending: false)).map(\.pid),
                       [330, 320, 310, 300, 300, 250, 200, 100])
        // The same profile keeps the default order: by kind, then pid.
        XCTAssertEqual(TaskManagerRows.rows(groups, sort: TaskManagerSort(column: .profile, ascending: false)).map(\.pid),
                       [310, 300, 300, 320, 330, 100, 200, 250])
    }

    func testAFigureThatIsNotKnownSortsLastBothWays() {
        let usage: [Int32: TaskManagerUsage] = [
            100: TaskManagerUsage(cpuPercent: 3), 200: TaskManagerUsage(cpuPercent: 40), 250: TaskManagerUsage(cpuPercent: 0),
        ]
        let groups = groups(Array(processes.filter { [100, 200, 250, 330].contains($0.pid) }), usage: usage)
        XCTAssertEqual(TaskManagerRows.rows(groups, sort: TaskManagerSort(column: .cpu, ascending: false)).map(\.pid), [200, 100, 250, 330])
        XCTAssertEqual(TaskManagerRows.rows(groups, sort: TaskManagerSort(column: .cpu, ascending: true)).map(\.pid), [250, 100, 200, 330])
        XCTAssertEqual(TaskManagerRows.rows(groups, sort: TaskManagerSort(column: .network, ascending: false)).map(\.pid),
                       [100, 200, 250, 330], "nothing known: the default order")
    }

    // MARK: Cell text

    func testCellTextIsChromesOnMacOS() {
        XCTAssertEqual(TaskManagerFormat.memory(0), "0 B")
        XCTAssertEqual(TaskManagerFormat.memory(512), "512 B")
        XCTAssertEqual(TaskManagerFormat.memory(1536), "1.5 KB")
        XCTAssertEqual(TaskManagerFormat.memory(84 << 20 + 512 << 10), "84.5 MB")
        XCTAssertEqual(TaskManagerFormat.memory(300 << 20), "300 MB")
        XCTAssertEqual(TaskManagerFormat.memory(5 << 30 / 4), "1.2 GB")
        XCTAssertEqual(TaskManagerFormat.cpu(nil), "–")
        XCTAssertEqual(TaskManagerFormat.cpu(0), "0.0")
        XCTAssertEqual(TaskManagerFormat.cpu(104.26), "104.3")
        XCTAssertEqual(TaskManagerFormat.cpu(-0.4), "0.0")
        XCTAssertEqual(TaskManagerFormat.network(nil), "–")
        XCTAssertEqual(TaskManagerFormat.network(0), "0")
        XCTAssertEqual(TaskManagerFormat.network(700), "700 B/s")
        XCTAssertEqual(TaskManagerFormat.network(3 * 1024 * 1024), "3.0 MB/s")
    }

    // MARK: Columns

    func testColumnsAreChromesAndTheTaskAlwaysShows() {
        XCTAssertEqual(TaskManagerColumn.allCases.map(\.title), ["Task", "Profile", "Memory footprint", "CPU", "Network", "Process ID"])
        var columns = TaskManagerColumns()
        XCTAssertEqual(columns.ordered, TaskManagerColumn.allCases)
        columns.toggle(.task)
        XCTAssertTrue(columns.isVisible(.task))
        columns.toggle(.network)
        columns.toggle(.profile)
        XCTAssertEqual(columns.ordered, [.task, .memoryFootprint, .cpu, .processID])
        columns.toggle(.network)
        XCTAssertEqual(columns.ordered, [.task, .memoryFootprint, .cpu, .network, .processID])
        XCTAssertTrue(TaskManagerColumns(visible: []).isVisible(.task))
    }

    func testColumnsAreKeptAcrossLaunches() throws {
        let suite = "rearc-task-manager-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TaskManagerColumns.load(from: defaults), TaskManagerColumns(), "nothing saved: every column")
        var columns = TaskManagerColumns()
        columns.toggle(.profile)
        columns.toggle(.processID)
        columns.save(to: defaults)
        XCTAssertEqual(TaskManagerColumns.load(from: defaults), columns)
        XCTAssertEqual(TaskManagerColumns.load(from: defaults).ordered, [.task, .memoryFootprint, .cpu, .network])
        // A column of a later build, and the task column missing from the list.
        defaults.set(["cpu", "gpuMemory"], forKey: TaskManagerColumns.defaultsKey)
        XCTAssertEqual(TaskManagerColumns.load(from: defaults).ordered, [.task, .cpu])
    }

    // MARK: Selection

    func testAClickSelectsTheWholeProcess() {
        // Rows: 100 | 300 300 | 310
        let pids: [Int32] = [100, 300, 300, 310]
        func rows(_ proposed: [Int], current: [Int] = [], toggles: Bool = false) -> [Int] {
            Array(TaskManagerSelection.rows(proposed: IndexSet(proposed), current: IndexSet(current), pids: pids, toggles: toggles))
        }
        XCTAssertEqual(rows([2]), [1, 2])
        XCTAssertEqual(rows([2], current: [1, 2]), [1, 2], "a click on a selected process keeps it selected")
        XCTAssertEqual(rows([3], current: [1, 2]), [3])
        XCTAssertEqual(rows([0, 1], current: [0]), [0, 1, 2], "⇧-click")
        XCTAssertEqual(rows([1, 2, 3], current: [1, 2], toggles: true), [1, 2, 3], "⌘-click adds a process")
        XCTAssertEqual(rows([1, 3], current: [1, 2, 3], toggles: true), [3], "⌘-click on one task lets its whole process go")
        XCTAssertEqual(rows([], current: [0], toggles: true), [])
        XCTAssertEqual(rows([9]), [], "a row that is gone")
    }

    // MARK: End task

    func testEndingAProcessOfOneTabDoesNotAsk() {
        let groups = groups()
        XCTAssertNil(TaskManagerEndConfirmation(ending: groups.filter { [310, 200, 320, 330].contains($0.pid) }))
        XCTAssertNil(TaskManagerEndConfirmation(ending: []))
    }

    func testEndingAProcessOfSeveralTabsAsksAndNamesThem() throws {
        let question = try XCTUnwrap(TaskManagerEndConfirmation(ending: groups().filter { [300, 310].contains($0.pid) }))
        XCTAssertEqual(question.title, "End the process behind 2 tabs?")
        XCTAssertEqual(question.message,
                       "“Mail” and “News” share a process. They stop until you reload them, and anything not saved in them is lost.")
    }

    func testALongListOfTabsIsCutShort() throws {
        var directory = TaskManagerDirectory()
        for id in 1 ... 6 as ClosedRange<UInt64> { directory.tabs[id] = .init(title: "T\(id)") }
        let groups = TaskManagerRows.groups(
            processes: [Process(pid: 1, kind: .renderer, tabIDs: [1, 2, 3]), Process(pid: 2, kind: .renderer, tabIDs: [4, 5, 6])],
            directory: directory
        )
        let question = try XCTUnwrap(TaskManagerEndConfirmation(ending: groups))
        XCTAssertEqual(question.title, "End the processes behind 6 tabs?")
        XCTAssertEqual(question.message,
                       "“T1”, “T2”, “T3”, “T4” and 2 more share processes. They stop until you reload them, and anything not saved in them is lost.")
    }
}
