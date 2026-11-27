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

    private func stacks(_ processes: [Process]? = nil, usage: [Int32: TaskManagerUsage] = [:],
                        directory: TaskManagerDirectory? = nil) -> [TaskManagerStack] {
        let directory = directory ?? self.directory
        return TaskManagerRows.stacks(
            TaskManagerRows.groups(processes: processes ?? self.processes, usage: usage, directory: directory), directory: directory
        )
    }

    // MARK: Grouping and names

    func testOneGroupPerProcessWithChromesPrefixes() {
        let groups = groups()
        XCTAssertEqual(groups.map(\.pid), [100, 200, 250, 300, 310, 320, 330], "Darni, its helpers, then the pages, by pid")
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
        XCTAssertEqual(groups.map { $0.tasks.map(\.kind) }, [
            [.browser], [.helper], [.helper], [.tab, .tab], [.tab], [.browserExtension], [.helper],
        ])
    }

    func testIconsFollowTheTask() {
        let icons = groups().map { $0.tasks.map(\.icon) }
        XCTAssertEqual(icons, [
            [.browser], [.system], [.system], [.tab(1), .tab(2)], [.tab(3)], [.browserExtension("abcd")], [.system],
        ])
    }

    func testOnlyTheBrowserCannotBeEnded() {
        let rows = TaskManagerRows.rows(stacks(), filter: .browser) + TaskManagerRows.rows(stacks(), filter: .tabs)
        XCTAssertEqual(rows.filter { !$0.isKillable }.map(\.title), ["Browser"])
        XCTAssertFalse(TaskManagerRows.rows(stacks())[0].isKillable, "Darni's own stack is never ended")
    }

    func testATabTheShellHasNoPageForIsLeftOut() {
        let groups = groups([Process(pid: 300, kind: .renderer, tabIDs: [1, 99])])
        XCTAssertEqual(groups[0].tasks.map(\.title), ["Tab: Mail"])
        XCTAssertEqual(self.groups([Process(pid: 300, kind: .renderer, tabIDs: [99])])[0].tasks.map(\.title), ["Renderer"])
    }

    func testAnExtensionWithoutAKnownNameIsStillAnExtension() {
        let group = groups([Process(pid: 320, kind: .renderer, isExtension: true)])[0]
        XCTAssertEqual(group.tasks, [TaskManagerTask(id: "320", title: "Extension", icon: .browserExtension(nil), kind: .browserExtension)])
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
        XCTAssertEqual(groups[2].tasks.map(\.site), ["https://ads.example/", "https://ads.example/"])
        XCTAssertEqual(groups[4].tasks.map(\.icon), [.browserExtension("zzzz")])
        XCTAssertEqual(groups[5].tasks.map(\.kind), [.helper], "Chrome lists the spare renderer with the browser's own processes")
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

    // MARK: Stacks

    /// Gmail with two frames of other sites, Calendar sharing the sign-in
    /// frame's process, and Darni itself (an engine with `task_manager`).
    private let gmailDirectory = TaskManagerDirectory(
        tabs: [
            1: .init(title: "Gmail", sleep: .init(state: .active, idle: 0, isOnScreen: true)),
            2: .init(title: "Calendar", sleep: .init(state: .sleeping, idle: 45 * 60)),
        ],
        profiles: [10: "Personal"],
        unloadedTabs: [.init(id: "A-1", title: "Docs", profile: "Work", idle: 3 * 3600)]
    )

    private var gmailProcesses: [Process] {
        [
            Process(pid: 400, kind: .renderer, profileID: 10, tabIDs: [1], memoryFootprint: 200 << 20,
                    details: .init(mainFrameTabIDs: [1], site: "https://mail.google.com/")),
            Process(pid: 410, kind: .renderer, profileID: 10, tabIDs: [1, 2], memoryFootprint: 40 << 20,
                    details: .init(subframeTabIDs: [1, 2], site: "https://accounts.google.com/")),
            Process(pid: 420, kind: .renderer, profileID: 10, tabIDs: [1], memoryFootprint: 60 << 20,
                    details: .init(subframeTabIDs: [1], site: "https://meet.google.com/")),
            Process(pid: 430, kind: .renderer, profileID: 10, tabIDs: [2], memoryFootprint: 100 << 20,
                    details: .init(mainFrameTabIDs: [2], site: "https://calendar.google.com/")),
            Process(pid: 100, kind: .browser, memoryFootprint: 500 << 20),
        ]
    }

    private let gmailUsage: [Int32: TaskManagerUsage] = [
        400: TaskManagerUsage(cpuPercent: 10, networkBytesPerSecond: 1000),
        410: TaskManagerUsage(cpuPercent: 2),
        420: TaskManagerUsage(),
        430: TaskManagerUsage(cpuPercent: 4, networkBytesPerSecond: 3000),
    ]

    private func gmailStacks() -> [TaskManagerStack] {
        stacks(gmailProcesses, usage: gmailUsage, directory: gmailDirectory)
    }

    private func row(_ rows: [TaskManagerRow], _ title: String) -> TaskManagerRow {
        rows.first { $0.title == title }!
    }

    func testDarnisProcessesShareOneStackAndEachTabAndExtensionHasItsOwn() {
        let stacks = stacks()
        XCTAssertEqual(stacks.map(\.id), ["darni", "tab/1", "tab/2", "tab/3", "extension/abcd"])
        XCTAssertEqual(stacks.map(\.title), ["Darni", "Tab: Mail", "Tab: News", "Private tab: Bank", "Extension: Reader Mode"])
        XCTAssertEqual(stacks[0].members.map(\.task.title), ["Browser", "GPU Process", "Utility: Network Service", "Renderer"])
        XCTAssertEqual(stacks.map(\.hasChildren), [true, false, false, false, false])
        XCTAssertEqual(titles(TaskManagerRows.rows(stacks)), ["Darni", "Tab: Mail", "Tab: News", "Private tab: Bank", "Extension: Reader Mode"],
                       "stacks start closed")
        XCTAssertEqual(TaskManagerRows.rows(stacks).map(\.disclosure), [.collapsed, .none, .none, .none, .none])
        XCTAssertEqual(stacks.map(\.profile), ["", "Personal", "Personal", "Work", "Personal"])
    }

    func testATabsStackAddsUpItsPageAndFrameProcesses() {
        let stacks = gmailStacks()
        XCTAssertEqual(stacks.map(\.title), ["Darni", "Tab: Gmail", "Tab: Calendar", "Tab: Docs"])
        let gmail = stacks[1]
        XCTAssertEqual(gmail.members.map(\.task.title),
                       ["Page: https://mail.google.com/", "Subframe: https://accounts.google.com/", "Subframe: https://meet.google.com/"])
        XCTAssertEqual(gmail.pids, [400, 410, 420])
        // 200 MB + half of the shared 40 MB + 60 MB.
        XCTAssertEqual(gmail.memoryFootprint, 280 << 20)
        // 10 % + half of 2 %; meet's CPU is not known yet and adds nothing.
        XCTAssertEqual(gmail.usage, TaskManagerUsage(cpuPercent: 11, networkBytesPerSecond: 1000))
        XCTAssertEqual(stacks[2].memoryFootprint, 120 << 20)
        XCTAssertEqual(stacks[2].usage.cpuPercent, 5)

        let header = TaskManagerRows.rows(stacks, filter: .tabs)[0]
        XCTAssertEqual(TaskManagerColumn.allCases.map(header.text(for:)),
                       ["Tab: Gmail", "Active", "Now", "Personal", "≈ 280 MB", "≈ 11.0", "≈ 1000 B/s", "400, 410, 420"])
        XCTAssertTrue(header.isEstimate)
    }

    func testASharedProcessIsSplitEvenlySoNothingIsCountedTwice() {
        let gmail = gmailStacks()
        let total = gmailProcesses.reduce(UInt64(0)) { $0 + $1.memoryFootprint }
        XCTAssertEqual(gmail.compactMap(\.memoryFootprint).reduce(0, +), total, "the stacks add up to the processes")
        XCTAssertEqual(gmail[1].members.map(\.sharedBy), [1, 2, 1])
        XCTAssertEqual(gmail[1].members[1].share, 0.5)

        // Two tabs of one renderer (no `task_manager`): each counts half, and says so.
        let shared = stacks()
        XCTAssertEqual(shared[1].memoryFootprint, 150 << 20)
        XCTAssertEqual(shared[2].memoryFootprint, 150 << 20)
        let rows = TaskManagerRows.rows(shared)
        XCTAssertEqual(row(rows, "Tab: Mail").text(for: .memoryFootprint), "≈ 150 MB")
        XCTAssertEqual(row(rows, "Tab: Mail").note, "shares its process with 1 other tab")
        XCTAssertEqual(row(rows, "Private tab: Bank").text(for: .memoryFootprint), "80.0 MB", "one process of its own: its own figure")
        XCTAssertEqual(row(rows, "Private tab: Bank").note, "")
        XCTAssertEqual(row(rows, "Darni").text(for: .memoryFootprint), "≈ 700 MB", "a total of several processes")
        XCTAssertEqual(shared.compactMap(\.memoryFootprint).reduce(0, +), self.processes.reduce(UInt64(0)) { $0 + $1.memoryFootprint })
    }

    func testAnOpenStackListsItsProcessesWithTheirWholeFigures() {
        let rows = TaskManagerRows.rows(gmailStacks(), filter: .tabs, expanded: ["tab/1"])
        XCTAssertEqual(titles(rows), [
            "Tab: Gmail", "Page: https://mail.google.com/", "Subframe: https://accounts.google.com/", "Subframe: https://meet.google.com/",
            "Tab: Calendar", "Tab: Docs",
        ])
        XCTAssertEqual(rows.map(\.level), [0, 1, 1, 1, 0, 0])
        XCTAssertEqual(rows.map(\.disclosure), [.expanded, .none, .none, .none, .collapsed, .none])
        let accounts = rows[2]
        XCTAssertEqual(TaskManagerColumn.allCases.map(accounts.text(for:)),
                       ["Subframe: https://accounts.google.com/", "", "", "Personal", "40.0 MB", "2.0", "–", "410"])
        XCTAssertEqual(accounts.note, "shared by 2 tabs")
        XCTAssertEqual(accounts.icon, .frame)
        XCTAssertEqual(accounts.tab, .engine(1), "Show Tab on a frame shows the tab it is in")
        XCTAssertEqual(accounts.stackID, "tab/1")
        XCTAssertFalse(accounts.isEstimate)
        XCTAssertEqual(rows[1].note, "")
    }

    func testRowIDsAreUniqueAndStayTheSameFromOneReadingToTheNext() {
        var later = gmailProcesses
        later[0].memoryFootprint += 1 << 20
        let all = Set(gmailStacks().map(\.id))
        let ids = TaskManagerRows.rows(gmailStacks(), expanded: all).map(\.id)
        XCTAssertEqual(ids, TaskManagerRows.rows(stacks(later, usage: gmailUsage, directory: gmailDirectory), expanded: all).map(\.id))
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids.filter { $0.hasSuffix("/410") }, ["tab/1/410", "tab/2/410"], "the shared process has a row under each tab")
    }

    // MARK: Filter and search

    func testTheFilterShowsOneKindOfTask() {
        let stacks = stacks()
        XCTAssertEqual(TaskManagerFilter.allCases.map(\.title), ["All", "Tabs", "Subframes", "Extensions", "Browser"])
        XCTAssertEqual(titles(TaskManagerRows.rows(stacks, filter: .tabs)), ["Tab: Mail", "Tab: News", "Private tab: Bank"])
        XCTAssertEqual(titles(TaskManagerRows.rows(stacks, filter: .extensions)), ["Extension: Reader Mode"])
        XCTAssertEqual(titles(TaskManagerRows.rows(stacks, filter: .browser)), ["Browser", "GPU Process", "Utility: Network Service", "Renderer"],
                       "Darni's processes one by one")
        XCTAssertEqual(TaskManagerRows.rows(stacks, filter: .browser).map(\.level), [0, 0, 0, 0])
        XCTAssertEqual(TaskManagerRows.rows(stacks, filter: .subframes), [], "an engine without task_manager tells no frames")

        let subframes = TaskManagerRows.rows(gmailStacks(), filter: .subframes)
        XCTAssertEqual(titles(subframes),
                       ["Subframe: https://accounts.google.com/", "Subframe: https://meet.google.com/", "Subframe: https://accounts.google.com/"])
        XCTAssertEqual(subframes.map(\.note), ["in Gmail · shared by 2 tabs", "in Gmail", "in Calendar · shared by 2 tabs"])
        XCTAssertEqual(subframes.map(\.disclosure), [.none, .none, .none])
        XCTAssertEqual(subframes.map(\.tab), [.engine(1), .engine(1), .engine(2)])
        XCTAssertEqual(titles(TaskManagerRows.rows(gmailStacks(), filter: .tabs)), ["Tab: Gmail", "Tab: Calendar", "Tab: Docs"],
                       "an unloaded tab is a tab")
    }

    func testSearchKeepsAStackAndOpensItWhenAProcessUnderItMatches() {
        let stacks = gmailStacks()
        XCTAssertEqual(titles(TaskManagerRows.rows(stacks, search: "gmail")), ["Tab: Gmail"], "found by its own row: stays closed")
        XCTAssertEqual(titles(TaskManagerRows.rows(stacks, search: "  MEET ")), [
            "Tab: Gmail", "Page: https://mail.google.com/", "Subframe: https://accounts.google.com/", "Subframe: https://meet.google.com/",
        ], "found by a frame: open, with the rest of the stack")
        XCTAssertEqual(titles(TaskManagerRows.rows(stacks, search: "accounts")).filter { $0.hasPrefix("Tab:") }, ["Tab: Gmail", "Tab: Calendar"])
        XCTAssertEqual(titles(TaskManagerRows.rows(stacks, search: "browser")), ["Darni"], "Darni's stack has no other process here")
        XCTAssertEqual(titles(TaskManagerRows.rows(stacks, search: "docs")), ["Tab: Docs"])
        XCTAssertEqual(titles(TaskManagerRows.rows(self.stacks(), search: "réader")), ["Extension: Reader Mode"])
        XCTAssertEqual(titles(TaskManagerRows.rows(self.stacks(), search: "gpu")), ["Darni", "Browser", "GPU Process", "Utility: Network Service", "Renderer"])
        XCTAssertEqual(TaskManagerRows.rows(stacks, search: "nothing like it"), [])
        XCTAssertEqual(TaskManagerRows.rows(stacks, search: "   ").count, 4)
    }

    func testSearchStaysInsideTheFilter() {
        let stacks = gmailStacks()
        XCTAssertEqual(TaskManagerRows.rows(stacks, filter: .browser, search: "gmail"), [])
        XCTAssertEqual(titles(TaskManagerRows.rows(stacks, filter: .subframes, search: "calendar")), ["Subframe: https://accounts.google.com/"],
                       "a frame is found by the tab it is in")
        XCTAssertEqual(titles(TaskManagerRows.rows(stacks, filter: .tabs, search: "meet")).first, "Tab: Gmail")
    }

    // MARK: Sorting

    func testSortingOrdersStacksByTheirTotalsAndProcessesWithinEachStack() {
        let stacks = gmailStacks()
        let largest = TaskManagerRows.rows(stacks, sort: TaskManagerSort(column: .memoryFootprint, ascending: false), expanded: ["tab/1"])
        XCTAssertEqual(titles(largest), [
            "Darni", "Tab: Gmail", "Page: https://mail.google.com/", "Subframe: https://meet.google.com/", "Subframe: https://accounts.google.com/",
            "Tab: Calendar", "Tab: Docs",
        ])
        let smallest = TaskManagerRows.rows(stacks, sort: TaskManagerSort(column: .memoryFootprint, ascending: true), expanded: ["tab/1"])
        XCTAssertEqual(titles(smallest), [
            "Tab: Calendar", "Tab: Gmail", "Subframe: https://accounts.google.com/", "Subframe: https://meet.google.com/",
            "Page: https://mail.google.com/", "Darni", "Tab: Docs",
        ], "an unloaded tab has no figure: last both ways")
        XCTAssertEqual(titles(TaskManagerRows.rows(self.stacks(), sort: TaskManagerSort(column: .task, ascending: true))),
                       ["Darni", "Extension: Reader Mode", "Private tab: Bank", "Tab: Mail", "Tab: News"])
    }

    func testAFigureThatIsNotKnownSortsLastBothWays() {
        let stacks = gmailStacks()
        let busiest = TaskManagerRows.rows(stacks, sort: TaskManagerSort(column: .cpu, ascending: false), expanded: ["tab/1"])
        XCTAssertEqual(titles(busiest), [
            "Tab: Gmail", "Page: https://mail.google.com/", "Subframe: https://accounts.google.com/", "Subframe: https://meet.google.com/",
            "Tab: Calendar", "Darni", "Tab: Docs",
        ])
        let idlest = TaskManagerRows.rows(stacks, sort: TaskManagerSort(column: .cpu, ascending: true))
        XCTAssertEqual(titles(idlest), ["Tab: Calendar", "Tab: Gmail", "Darni", "Tab: Docs"])
        XCTAssertEqual(TaskManagerRows.rows(stacks, sort: TaskManagerSort(column: .processID, ascending: false)).map(\.pids),
                       [[410, 430], [400, 410, 420], [100], []])
    }

    // MARK: State and idle

    func testStateAndIdleShowOnATabsRowOnly() {
        let rows = TaskManagerRows.rows(gmailStacks(), expanded: ["tab/1", "tab/2"])
        XCTAssertEqual(rows.map { $0.text(for: .state) }, ["", "Active", "", "", "", "Sleeping", "", "", "Unloaded"])
        XCTAssertEqual(rows.map { $0.text(for: .idle) }, ["", "Now", "", "", "", "45 min", "", "", "3 h"])
        XCTAssertEqual(row(rows, "Tab: Calendar").text(for: .memoryFootprint), "≈ 120 MB", "a sleeping tab keeps its memory")
    }

    func testAnUnloadedTabIsARowWithNoProcessAndNoFigures() {
        let docs = TaskManagerRows.rows(gmailStacks()).last!
        XCTAssertEqual(TaskManagerColumn.allCases.map(docs.text(for:)), ["Tab: Docs", "Unloaded", "3 h", "Work", "", "", "", ""])
        XCTAssertTrue(docs.isUnloaded)
        XCTAssertEqual(docs.pids, [])
        XCTAssertNil(docs.pid)
        XCTAssertEqual(docs.selectionKeys, [.row("unloaded/A-1")])
        XCTAssertEqual(docs.tab, .sidebar("A-1"), "Show Tab loads it")
        XCTAssertEqual(docs.icon, .sidebarTab("A-1"))
        XCTAssertFalse(docs.isKillable)
        XCTAssertEqual(docs.disclosure, .none)
    }

    func testSortingByStateAndIdle() {
        let stacks = gmailStacks()
        XCTAssertEqual(titles(TaskManagerRows.rows(stacks, sort: TaskManagerSort(column: .idle, ascending: false))),
                       ["Tab: Docs", "Tab: Calendar", "Tab: Gmail", "Darni"], "longest unseen first; no idle time last")
        XCTAssertEqual(titles(TaskManagerRows.rows(stacks, sort: TaskManagerSort(column: .idle, ascending: true))),
                       ["Tab: Gmail", "Tab: Calendar", "Tab: Docs", "Darni"], "on screen first")
        XCTAssertEqual(titles(TaskManagerRows.rows(stacks, sort: TaskManagerSort(column: .state, ascending: true))),
                       ["Tab: Gmail", "Tab: Calendar", "Tab: Docs", "Darni"])
        XCTAssertEqual(titles(TaskManagerRows.rows(stacks, sort: TaskManagerSort(column: .state, ascending: false))),
                       ["Tab: Docs", "Tab: Calendar", "Tab: Gmail", "Darni"])
    }

    func testATabsStateComesFromTheSleepChecks() {
        func state(_ change: (inout TabUnloadCandidate) -> Void = { _ in }, discarded: Bool = false, pageFrozen: Bool? = nil) -> TaskManagerTabState {
            var candidate = TabUnloadCandidate(tabID: UUID(), lastActive: Date())
            change(&candidate)
            return .of(candidate, isDiscarded: discarded, isPageFrozen: pageFrozen)
        }
        XCTAssertEqual(state(), .active)
        XCTAssertEqual(state { $0.isVisible = true }, .active)
        XCTAssertEqual(state(discarded: true), .unloaded)
        XCTAssertEqual(state { $0.isFrozen = true }, .sleeping, "the engine cannot say: the request counts")
        XCTAssertEqual(state({ $0.isFrozen = true }, pageFrozen: true), .sleeping)
        XCTAssertEqual(state({ $0.isFrozen = true }, pageFrozen: false), .fallingAsleep)
        XCTAssertEqual(state({ $0.isFrozen = true; $0.isAudible = true }, pageFrozen: false), .fallingAsleep)
        XCTAssertEqual(state { $0.isAudible = true }, .keptAwake(.playingSound))
        XCTAssertEqual(state { $0.isCapturing = true }, .keptAwake(.capturing))
        XCTAssertEqual(state { $0.isShared = true }, .keptAwake(.shared))
        XCTAssertEqual(state { $0.hasDownload = true }, .keptAwake(.downloading))
        XCTAssertEqual(state { $0.hasPendingPrompt = true }, .keptAwake(.waitingForAnswer))
        XCTAssertEqual(state { $0.isVisible = true; $0.isAudible = true }, .active, "on screen is simply active")
        XCTAssertEqual([TaskManagerTabState.active, .keptAwake(.playingSound), .keptAwake(.waitingForAnswer), .fallingAsleep, .sleeping, .unloaded]
            .map(\.title), ["Active", "Kept awake: sound", "Kept awake: waiting for you", "Falling asleep", "Sleeping", "Unloaded"])
        XCTAssertTrue(TaskManagerTabState.sleeping.explanation.contains("still in memory"))
    }

    func testTheStateHelpSaysWhatSleepingMeansWithTheChosenWaits() {
        let standard = TaskManagerHelp.state(nil)
        XCTAssertTrue(standard.contains("Sleeping: you haven't looked at the tab for 30 minutes, so Darni froze it."), standard)
        XCTAssertTrue(standard.contains("which is why it's still listed here"), standard)
        XCTAssertTrue(standard.contains("Unloaded: after 4 hours unseen, the page leaves memory and has no process."), standard)
        XCTAssertTrue(standard.contains("Kept awake:"), standard)
        let custom = TaskManagerHelp.state(.init(freeze: .fifteenMinutes, unload: .twelveHours, canFreeze: true))
        XCTAssertTrue(custom.contains("for 15 minutes") && custom.contains("after 12 hours"), custom)
        XCTAssertTrue(TaskManagerHelp.state(.init(freeze: .oneHour, unload: .oneHour, canFreeze: true)).contains("for 1 hour, so"))
        let off = TaskManagerHelp.state(.init(freeze: .never, unload: .never, canFreeze: true))
        XCTAssertTrue(off.contains("Sleeping: off. Choose when tabs sleep in Settings › General."), off)
        XCTAssertTrue(off.contains("Unloaded: no page in memory and no process"), off)
        let webKit = TaskManagerHelp.state(.init(freeze: .thirtyMinutes, unload: .fourHours, canFreeze: false))
        XCTAssertTrue(webKit.contains("this engine can't freeze a tab"), webKit)
        XCTAssertFalse(webKit.contains("Falling asleep"), webKit)
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

    func testIdleIsInMinutesHoursAndDays() {
        XCTAssertEqual(TaskManagerFormat.idle(nil), "–")
        XCTAssertEqual(TaskManagerFormat.idle(nil, onScreen: true), "Now")
        XCTAssertEqual(TaskManagerFormat.idle(500, onScreen: true), "Now", "on screen wins over an old reading")
        XCTAssertEqual(TaskManagerFormat.idle(0), "< 1 min")
        XCTAssertEqual(TaskManagerFormat.idle(59), "< 1 min")
        XCTAssertEqual(TaskManagerFormat.idle(-5), "< 1 min")
        XCTAssertEqual(TaskManagerFormat.idle(12 * 60 + 30), "12 min")
        XCTAssertEqual(TaskManagerFormat.idle(60 * 60), "1 h")
        XCTAssertEqual(TaskManagerFormat.idle(3 * 3600 + 5 * 60), "3 h 5 min")
        XCTAssertEqual(TaskManagerFormat.idle(48 * 3600), "2 d")
        XCTAssertEqual(TaskManagerFormat.idle(52 * 3600 + 59 * 60), "2 d 4 h")
    }

    // MARK: Columns

    func testColumnsAreChromesAndTheTaskAlwaysShows() {
        XCTAssertEqual(TaskManagerColumn.allCases.map(\.title),
                       ["Task", "State", "Idle", "Profile", "Memory footprint", "CPU", "Network", "Process ID"])
        XCTAssertEqual(TaskManagerColumn.allCases.filter(\.isFigure), [.idle, .memoryFootprint, .cpu, .network, .processID])
        var columns = TaskManagerColumns()
        XCTAssertEqual(columns.ordered, TaskManagerColumn.allCases)
        columns.toggle(.task)
        XCTAssertTrue(columns.isVisible(.task))
        columns.toggle(.network)
        columns.toggle(.profile)
        XCTAssertEqual(columns.ordered, [.task, .state, .idle, .memoryFootprint, .cpu, .processID])
        columns.toggle(.network)
        XCTAssertEqual(columns.ordered, [.task, .state, .idle, .memoryFootprint, .cpu, .network, .processID])
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
        columns.toggle(.idle)
        columns.save(to: defaults)
        XCTAssertEqual(TaskManagerColumns.load(from: defaults), columns)
        XCTAssertEqual(TaskManagerColumns.load(from: defaults).ordered, [.task, .state, .memoryFootprint, .cpu, .network],
                       "a new column hidden on purpose stays hidden")
        // A column of a later build, and the task column missing from the list.
        defaults.set(["cpu", "gpuMemory"], forKey: TaskManagerColumns.defaultsKey)
        XCTAssertEqual(TaskManagerColumns.load(from: defaults).ordered, [.task, .cpu])
    }

    func testAChoiceSavedBeforeStateAndIdleShowsThem() throws {
        let suite = "rearc-task-manager-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // As the first Task Manager saved it: the visible columns, nothing about the ones it knew.
        defaults.set(["task", "memoryFootprint", "cpu"], forKey: TaskManagerColumns.defaultsKey)
        XCTAssertEqual(TaskManagerColumns.load(from: defaults).ordered, [.task, .state, .idle, .memoryFootprint, .cpu],
                       "columns added since show; the ones hidden then stay hidden")
    }

    // MARK: Selection

    func testAClickSelectsTheWholeProcess() {
        // Rows: 100 | 300 300 | 310
        let keys: [[TaskManagerSelectionKey]] = [[.process(100)], [.process(300)], [.process(300)], [.process(310)]]
        func rows(_ proposed: [Int], current: [Int] = [], toggles: Bool = false) -> [Int] {
            Array(TaskManagerSelection.rows(proposed: IndexSet(proposed), current: IndexSet(current), keys: keys, toggles: toggles))
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

    func testATabsRowSelectsAllItsProcessesAndARowWithNoneSelectsItself() {
        // Rows: Darni (itself) | Tab: Mail (400, 410) | Page 400 | Subframe 410 | Tab: News (410, 430) | unloaded (itself)
        let keys: [[TaskManagerSelectionKey]] = [
            [.row("darni")], [.process(400), .process(410)], [.process(400)], [.process(410)], [.process(410), .process(430)],
            [.row("unloaded/x")],
        ]
        func rows(_ proposed: [Int], current: [Int] = [], toggles: Bool = false) -> [Int] {
            Array(TaskManagerSelection.rows(proposed: IndexSet(proposed), current: IndexSet(current), keys: keys, toggles: toggles))
        }
        XCTAssertEqual(rows([1]), [1, 2, 3], "the tab with its page and frame; News also needs 430")
        XCTAssertEqual(rows([3]), [3], "the frame's process alone: neither tab is wholly selected")
        XCTAssertEqual(rows([0]), [0])
        XCTAssertEqual(rows([5]), [5])
        XCTAssertEqual(rows([1, 4]), [1, 2, 3, 4])
        XCTAssertEqual(rows([2, 3], current: [1, 2, 3], toggles: true), [], "⌘-click on the tab lets its processes go together")
        XCTAssertEqual(TaskManagerSelection.selected(keys: keys + [[]], by: [.process(410), .process(430)]), IndexSet([3, 4]),
                       "a row that stands for nothing is never selected")
    }

    func testStackRowsSayWhatTheyStandFor() {
        let rows = TaskManagerRows.rows(gmailStacks(), expanded: ["tab/1"])
        XCTAssertEqual(rows.map(\.selectionKeys), [
            [.row("darni")],
            [.process(400), .process(410), .process(420)], [.process(400)], [.process(410)], [.process(420)],
            [.process(410), .process(430)],
            [.row("unloaded/A-1")],
        ], "Darni's own row stands for itself: End task never takes Darni's processes from it")
        XCTAssertEqual(TaskManagerRows.rows(stacks())[0].selectionKeys, [.row("darni")])
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
