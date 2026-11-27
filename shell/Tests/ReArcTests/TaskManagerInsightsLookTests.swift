import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// A made-up engine for the look: three hours of a browsing session, read
/// once a minute with the window closed and every 2 s for its last 10
/// minutes. Every site and title is invented.
@MainActor
private final class LookSource: TaskManagerSource {
    var processes: [TaskManagerProcess] = []
    var directory = TaskManagerDirectory()
    private var icons: [String: NSImage] = [:]

    func sample() async -> TaskManagerSample { TaskManagerSample(processes: processes, directory: directory) }
    func endProcess(_ pid: Int32) async -> Bool { false }
    var isLive: Bool { false }  // the test drives every reading itself
    func canShowTab(_ tab: TaskManagerTabRef) -> Bool { true }
    func canSleepTab(_ tab: TaskManagerTabRef) -> Bool {
        guard case .engine(let id) = tab, let state = directory.tabs[id]?.sleep else { return false }
        return state.state == .active && !state.isOnScreen
    }
    func canUnloadTab(_ tab: TaskManagerTabRef) -> Bool {
        guard case .engine(let id) = tab else { return false }
        return directory.tabs[id]?.sleep?.isOnScreen == false
    }
    func canOpenDevTools(_ tab: TaskManagerTabRef) -> Bool { if case .engine = tab { return true } else { return false } }

    /// A favicon: a rounded square of the site's colour with its letter.
    func icon(for icon: TaskManagerTask.Icon) -> NSImage? {
        let key: String
        switch icon {
        case .tab(let id): key = "tab\(id)"
        case .sidebarTab(let id): key = "side\(id)"
        case .browserExtension: key = "ext"
        default: return nil
        }
        if let image = icons[key] { return image }
        let (color, letter): (NSColor, String) = {
            switch key {
            case "tab1": return (NSColor(red: 0.04, green: 0.40, blue: 0.76, alpha: 1), "F")
            case "tab2": return (NSColor(red: 0.85, green: 0.19, blue: 0.15, alpha: 1), "M")
            case "tab3": return (NSColor(red: 0.98, green: 0.0, blue: 0.2, alpha: 1), "▶")
            case "tab4": return (NSColor(red: 0.64, green: 0.35, blue: 1.0, alpha: 1), "C")
            case "tab5": return (NSColor(red: 1.0, green: 0.40, blue: 0.0, alpha: 1), "D")
            case "tab6": return (NSColor(red: 0.13, green: 0.13, blue: 0.13, alpha: 1), "▲")
            case "sideK", "tab7": return (NSColor(red: 0.39, green: 0.36, blue: 1.0, alpha: 1), "P")
            case "ext": return (NSColor(red: 0.10, green: 0.53, blue: 1.0, alpha: 1), "K")
            default: return (NSColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1), "R")
            }
        }()
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            let text = NSAttributedString(string: letter, attributes: [
                .font: NSFont.systemFont(ofSize: 18, weight: .bold), .foregroundColor: NSColor.white,
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
        icons[key] = image
        return image
    }
}

@MainActor
final class TaskManagerInsightsLookTests: XCTestCase {
    private let mb = Double(1 << 20)
    /// The fixture's "now" on the monotonic clock, and on the wall clock (15:00 local).
    private let end: TimeInterval = 200_000
    private lazy var wallEnd: Date = {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = 15
        components.minute = 0
        return Calendar.current.date(from: components)!
    }()

    // MARK: The fixture

    private struct Track {
        var pid: Int32
        var memory: (TimeInterval) -> Double  // MB at minutes before the end
        var cpu: (TimeInterval) -> Double     // percent of a core
    }

    private func makeController() -> (TaskManagerController, LookSource) {
        let suite = "darni-tm-look-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let source = LookSource()
        let controller = TaskManagerController(source: source, defaults: defaults)
        controller.schedule = { _, _ in }
        controller.spaceThemeProvider = { .arcDefault }
        var now = end - 3 * 3600
        controller.clock = { now }
        controller.wallClock = { [wallEnd, end] in wallEnd.addingTimeInterval(now - end) }
        controller.engineDidAttach()

        let digestSleeps = 130.0  // minutes before the end
        let docsUnloads = 40.0
        func tab(_ title: String, _ sidebar: String, _ state: TaskManagerTabState = .active, onScreen: Bool = false,
                 idle: TimeInterval = 600, url: String) -> TaskManagerDirectory.Tab {
            .init(title: title, sleep: .init(state: state, idle: idle, isOnScreen: onScreen), sidebarID: sidebar, pageURL: url)
        }
        func wobble(_ base: Double, _ t: TimeInterval, _ amount: Double = 0.3) -> Double {
            max(0, base + amount * sin(t / 37) + amount * 0.6 * sin(t / 11))
        }
        let tracks: [Track] = [
            Track(pid: 1, memory: { 380 + 6 * sin($0 / 300) }, cpu: { wobble(1.4, $0, 0.6) }),
            Track(pid: 2, memory: { _ in 160 }, cpu: { wobble(1.8, $0, 0.7) }),
            Track(pid: 3, memory: { _ in 72 }, cpu: { wobble(0.3, $0, 0.2) }),
            // The feed grows steadily on the same page: the growth rule fires.
            Track(pid: 10, memory: { 1010 - 580 * ($0 / 10_800) + 4 * sin($0 / 60) },
                  cpu: { Int($0) % 90 < 4 ? 6 : wobble(0.3, $0, 0.2) }),
            Track(pid: 11, memory: { _ in 38 }, cpu: { Int($0) % 120 < 6 ? 3 : 0.1 }),
            Track(pid: 20, memory: { 948 + 10 * sin($0 / 900) }, cpu: { wobble(0.6, $0, 0.4) }),
            // Video playing in a hidden tab, kept awake by its sound.
            Track(pid: 30, memory: { 512 + 8 * sin($0 / 120) }, cpu: { wobble(14.8, $0, 2) }),
            // A design tool: a burst 6 to 4 minutes ago, then calm.
            Track(pid: 40, memory: { 734 + 3 * sin($0 / 200) },
                  cpu: { ($0 >= 240 && $0 < 380) ? wobble(42, $0, 8) : wobble(1.5, $0, 0.8) }),
            Track(pid: 50, memory: { $0 > digestSleeps * 60 ? 64 + 2 * sin($0 / 300) : 64 },
                  cpu: { $0 > digestSleeps * 60 ? wobble(1.2, $0, 0.8) : 0 }),
            Track(pid: 60, memory: { 188 + 4 * sin($0 / 400) }, cpu: { wobble(0.4, $0, 0.3) }),
            Track(pid: 70, memory: { _ in 96 }, cpu: { wobble(0.1, $0, 0.1) }),
            Track(pid: 80, memory: { 412 + 5 * sin($0 / 500) }, cpu: { wobble(0.8, $0, 0.5) }),
        ]
        source.processes = [
            TaskManagerProcess(pid: 1, kind: .browser),
            TaskManagerProcess(pid: 2, kind: .gpu),
            TaskManagerProcess(pid: 3, kind: .utility, details: .init(title: "Network Service")),
            TaskManagerProcess(pid: 10, kind: .renderer, tabIDs: [1], details: .init(mainFrameTabIDs: [1], site: "https://feed.example")),
            TaskManagerProcess(pid: 11, kind: .renderer, tabIDs: [1], details: .init(subframeTabIDs: [1], site: "https://ads.example")),
            TaskManagerProcess(pid: 20, kind: .renderer, tabIDs: [2], details: .init(mainFrameTabIDs: [2], site: "https://mail.example")),
            TaskManagerProcess(pid: 30, kind: .renderer, tabIDs: [3], details: .init(mainFrameTabIDs: [3], site: "https://video.example")),
            TaskManagerProcess(pid: 40, kind: .renderer, tabIDs: [4], details: .init(mainFrameTabIDs: [4], site: "https://canvas.example")),
            TaskManagerProcess(pid: 50, kind: .renderer, tabIDs: [5], details: .init(mainFrameTabIDs: [5], site: "https://digest.example")),
            TaskManagerProcess(pid: 60, kind: .renderer, tabIDs: [6], details: .init(mainFrameTabIDs: [6], site: "https://deploy.example")),
            TaskManagerProcess(pid: 70, kind: .renderer, isExtension: true,
                               details: .init(extensionID: "passwords", extensionName: "Keyring Passwords")),
            TaskManagerProcess(pid: 80, kind: .renderer, tabIDs: [7], details: .init(mainFrameTabIDs: [7], site: "https://pay.example")),
        ]
        // Tabs not loaded since launch: one opened 26 h ago, six 3 to 9 days ago, and 34 imported from
        // another browser 14 days ago and never opened in Darni. They fold into one row.
        source.directory.unloadedTabs = [.init(id: "R", title: "Recipes – Example Kitchen", idle: 26 * 3600, wasUnloaded: false)]
        let sites = ["Garden Notes", "Trail Maps", "Bread Club", "Chess Puzzles", "Synth Patches", "Tide Tables", "Kite Plans",
                     "Moth Atlas", "Tea Ledger", "Pottery Log", "Star Charts", "Knot Guide"]
        for index in 0 ..< 6 {
            source.directory.unloadedTabs.append(.init(id: "W\(index)", title: "\(sites[index]) – Example Wiki",
                                                       idle: Double(3 + index) * 86_400 + 3600, wasUnloaded: false))
        }
        for index in 0 ..< 34 {
            source.directory.unloadedTabs.append(.init(id: "I\(index)", title: "\(sites[index % sites.count]) \(index / sites.count + 1) – Example Archive",
                                                       idle: (14 * 24 + 7) * 3600, wasUnloaded: false, openedInDarni: false))
        }
        source.directory.sleepSettings = .init(freeze: .thirtyMinutes, unload: .fourHours, canFreeze: true)

        var digestAsleep = false
        var docsGone = false
        func update(at t: TimeInterval, step: TimeInterval) {
            let before = (end - t) / 60  // minutes before the end
            for track in tracks {
                guard let index = source.processes.firstIndex(where: { $0.pid == track.pid }) else { continue }
                source.processes[index].memoryFootprint = UInt64(track.memory((end - t)) * mb)
                source.processes[index].cpuMicros += Int64(track.cpu(end - t) / 100 * step * 1_000_000)
            }
            if !digestAsleep, before <= digestSleeps {
                digestAsleep = true
                controller.noteTabControl(.fellAsleep, sidebarID: "D", cause: .automatic)
            }
            if !docsGone, before <= docsUnloads {
                docsGone = true
                controller.noteTabControl(.unloaded, sidebarID: "K", cause: .taskManager)
                source.processes.removeAll { $0.pid == 80 }
                source.directory.unloadedTabs.insert(.init(id: "K", title: "Docs – Example Pay", idle: 2 * 3600, wasUnloaded: true), at: 0)
            }
            source.directory.tabs = [
                1: tab("Feed | Example Social", "F", idle: 3 * 3600 + 240, url: "https://feed.example/"),
                2: tab("Inbox – Example Mail", "I", idle: 12 * 60, url: "https://mail.example/inbox"),
                3: tab("Video – Example Tube", "V", .keptAwake(.playingSound), idle: 25 * 60, url: "https://video.example/watch"),
                4: tab("Board – Example Canvas", "C", onScreen: true, idle: 0, url: "https://canvas.example/board"),
                5: tab("Hacker Digest", "D", digestAsleep ? .sleeping : .active, idle: 2 * 3600 + 40 * 60, url: "https://digest.example/"),
                6: tab("Deployments – Example Cloud", "P", idle: 26 * 60, url: "https://deploy.example/"),
            ]
            if !docsGone { source.directory.tabs[7] = tab("Docs – Example Pay", "K", idle: 80 * 60, url: "https://pay.example/docs") }
        }

        // Three hours with the window closed: the 60 s reading.
        while now < end - 600 {
            update(at: now, step: 60)
            controller.applyInBackground(TaskManagerSample(processes: source.processes, directory: source.directory), at: now)
            now += 60
        }
        // The last 10 minutes with the window open: every 2 s.
        now = end - 600
        controller.startPolling()
        while now <= end {
            update(at: now, step: 2)
            controller.apply(TaskManagerSample(processes: source.processes, directory: source.directory), at: now)
            now += 2
        }
        now = end
        controller.stopPolling()
        controller.engineDidDetach()
        return (controller, source)
    }

    // MARK: Snapshots

    private func outputDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["REARC_TM_DIR"] else {
            throw XCTSkip("set REARC_TM_DIR to write the Task Manager insights snapshots")
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testTheFixtureSaysWhatTheSnapshotsShow() throws {
        let (controller, _) = makeController()
        let timeline = controller.timeline
        let feed = try XCTUnwrap(controller.history["sidebar/F"])
        XCTAssertNotNil(TaskManagerInsights.growth(feed, now: timeline.now), "the feed's growth")
        XCTAssertEqual(controller.spotted.map(\.kind), [.growth, .busyWhileHidden, .burst])
        XCTAssertTrue(controller.summary.text.hasPrefix("Tab sleep now: 1 asleep, 1 unloaded · freed "), controller.summary.text)
        XCTAssertEqual(controller.stacks.last?.title, "Not loaded · 41 tabs")
        XCTAssertEqual(controller.stacks.last?.summary, "last opened 1 d – 8 d ago · 34 not opened in Darni")
        let docs = try XCTUnwrap(controller.history["sidebar/K"]?.events.first)
        guard case .freed(let bytes, false) = docs.effect else { return XCTFail("\(docs.effect)") }
        XCTAssertGreaterThan(bytes, 400 << 20)
        XCTAssertEqual(controller.history["sidebar/D"]?.events.first?.kind, .fellAsleep)
        // The memory line climbs with the feed (a UInt64 must become its value, not its bit pattern).
        let values = controller.history.minuteCells("sidebar/F", now: timeline.now).map { $0?.memory.map { Double($0) } }
        XCTAssertGreaterThan(values.compactMap { $0 }.max() ?? 0, 900 * mb)
        let scale = TaskManagerLineChart.memoryScale(values)
        let line = try XCTUnwrap(TaskManagerLineChart.points(values, low: scale.low, high: scale.high, size: CGSize(width: 300, height: 64)).first)
        XCTAssertGreaterThan(try XCTUnwrap(line.first).y - (try XCTUnwrap(line.last).y), 30, "it rises across the chart")
    }

    func testTaskManagerInsightsSnapshots() throws {
        let directory = try outputDirectory()
        let (controller, _) = makeController()
        let size = NSSize(width: 1320, height: 880)
        let fold = TaskManagerRows.notLoadedStackID
        let cases: [(name: String, mode: TaskManagerViewMode, focus: String?, filter: TaskManagerFilter, expanded: Set<String>)] = [
            ("insights-fold", .list, nil, .tabs, [fold]),
            ("insights-fold-collapsed", .list, nil, .tabs, []),
            ("insights-list", .list, "sidebar/F", .all, ["tab/1"]),
            ("insights-heat", .heatGrid, nil, .all, []),
            ("insights-map", .memoryMap, nil, .all, []),
            ("insights-sleep", .list, "sidebar/D", .all, []),
            ("insights-unloaded", .memoryMap, "sidebar/K", .all, []),
            ("insights-heat-inspector", .heatGrid, "sidebar/V", .all, []),
        ]
        for item in cases {
            for dark in [false, true] {
                controller.viewMode = item.mode
                controller.focus(item.focus.flatMap { key in controller.stacks.first { $0.historyKey == key } })
                if item.focus == nil { controller.selection = [] }
                controller.expanded = item.expanded
                controller.filter = item.filter
                let view = TaskManagerView(controller: controller, endTask: {})
                let rep = try render(view, size: size, dark: dark)
                try write(rep, to: directory.appendingPathComponent("\(item.name)\(dark ? "-dark" : "").png"))
            }
        }
        // Settings › Advanced's switch.
        for dark in [false, true] {
            let row = SettingsGroup {
                SettingsSwitchRow(label: TaskManagerHistoryPreference.label, detail: TaskManagerHistoryPreference.detail,
                                  icon: SettingsIconTile(systemImage: "chart.xyaxis.line", color: .orange), isOn: .constant(true))
            }
            .padding(20)
            .frame(width: 640)
            .background(Color(nsColor: .windowBackgroundColor))
            let rep = try render(row, size: NSSize(width: 640, height: 110), dark: dark)
            try write(rep, to: directory.appendingPathComponent("settings-advanced-history\(dark ? "-dark" : "").png"))
        }
    }

    // MARK: The 60 s reading's cost

    /// What the shell spends on one background reading: the fold of a
    /// 3-hour history for ~20 processes and ~40 stacks, and `proc_pid_rusage`
    /// on 20 child processes (what the engine reads per process). Prints its
    /// figures; set `REARC_TM_COST` to run it.
    func testTheBackgroundReadingsCost() throws {
        guard ProcessInfo.processInfo.environment["REARC_TM_COST"] != nil else { throw XCTSkip("set REARC_TM_COST to measure") }
        let source = LookSource()
        let controller = TaskManagerController(source: source, defaults: UserDefaults(suiteName: "darni-tm-cost-\(UUID().uuidString)")!)
        source.processes = [TaskManagerProcess(pid: 1, kind: .browser, memoryFootprint: 400 << 20),
                            TaskManagerProcess(pid: 2, kind: .gpu, memoryFootprint: 160 << 20)]
        for index in 0 ..< 18 {
            let pid = Int32(100 + index)
            let tabs = [UInt64(index * 2 + 1), UInt64(index * 2 + 2)]
            source.processes.append(TaskManagerProcess(pid: pid, kind: .renderer, tabIDs: tabs, memoryFootprint: 200 << 20,
                                                       details: .init(mainFrameTabIDs: tabs, site: "https://site\(index).example")))
            for tab in tabs {
                source.directory.tabs[tab] = .init(title: "Tab \(tab)", sleep: .init(state: .active, idle: 60), sidebarID: "T\(tab)",
                                                   pageURL: "https://site\(index).example/")
            }
        }
        var time: TimeInterval = 1000
        // Fill 3 hours first, then time 60 more readings on a full history.
        for _ in 0 ..< 180 {
            controller.applyInBackground(TaskManagerSample(processes: source.processes, directory: source.directory), at: time)
            time += 60
        }
        var foldTimes: [Double] = []
        for _ in 0 ..< 60 {
            for index in source.processes.indices { source.processes[index].cpuMicros += 50_000 }
            let start = DispatchTime.now().uptimeNanoseconds
            controller.applyInBackground(TaskManagerSample(processes: source.processes, directory: source.directory), at: time)
            foldTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            time += 60
        }
        // proc_pid_rusage on 20 children, as the engine reads each process.
        var children: [Process] = []
        for _ in 0 ..< 20 {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["30"]
            try child.run()
            children.append(child)
        }
        defer { children.forEach { $0.terminate() } }
        var rusageTimes: [Double] = []
        for _ in 0 ..< 50 {
            let start = DispatchTime.now().uptimeNanoseconds
            for child in children {
                var usage = rusage_info_v4()
                _ = withUnsafeMutablePointer(to: &usage) {
                    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(child.processIdentifier, RUSAGE_INFO_V4, $0) }
                }
            }
            rusageTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let stacks = controller.history.stacks.count
        let cells = controller.history.stacks.values.reduce(0) { $0 + $1.minutes.count }
        print(String(format: "TM-COST fold: median %.3f ms, max %.3f ms (%d processes, %d stacks, %d minute cells)",
                     median(foldTimes), foldTimes.max()!, source.processes.count, stacks, cells))
        print(String(format: "TM-COST proc_pid_rusage x20: median %.3f ms, max %.3f ms", median(rusageTimes), rusageTimes.max()!))
        XCTAssertLessThan(median(foldTimes), 50, "debug build, generous")
    }

    // MARK: Off-screen rendering (Wave33LookSnapshotTests' pattern)

    private func render<V: View>(_ view: V, size: NSSize, dark: Bool) throws -> NSBitmapImageRep {
        let window = OffscreenWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.setContentSize(size)
        for pass in 0 ..< 3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(pass == 0 ? 0.5 : 0.3))
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        window.close()
        return rep
    }

    private func write(_ rep: NSBitmapImageRep, to url: URL) throws {
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
