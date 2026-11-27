import AppKit
import SidebarModel
import SwiftUI

/// The inspector (docs/TASK-MANAGER-INSIGHTS.md §4.2): one stack's figures,
/// its memory by process, its memory history, its processes' CPU in 10 s
/// cells, what tab sleep did to it with the measured effect, and tools for
/// developers. 404 pt beside the table; a sheet in a narrow window.
struct TaskManagerInspector: View {
    let controller: TaskManagerController
    let stack: TaskManagerStack
    var onClose: (() -> Void)?
    @Environment(\.taskManagerInk) private var ink

    static let width: CGFloat = 404

    var body: some View {
        let timeline = controller.timeline
        let track = controller.history.history(of: stack)
        let insights = track.map { TaskManagerInsights.insights(for: $0, in: controller.history, timeline: timeline) } ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                if !stack.members.isEmpty { byProcess }
                memoryHistory(track: track, timeline: timeline, growth: insights.first { $0.kind == .growth })
                if !stack.members.isEmpty {
                    processGrid(timeline: timeline, hints: insights.filter { $0.kind == .busyWhileHidden || $0.kind == .burst })
                }
                if stack.kind == .tab {
                    TaskManagerTabControlsCard(controller: controller, stack: stack, track: track, timeline: timeline,
                                               asleep: insights.first { $0.kind == .asleep })
                }
                developers
            }
            .padding(10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector: \(stack.title)")
    }

    // MARK: Header

    private var header: some View {
        let approx = stack.isEstimate ? "≈ " : ""
        let hasProcess = stack.memoryFootprint != nil
        return TaskManagerCard {
            HStack(alignment: .top, spacing: 10) {
                TaskManagerStackIcon(controller: controller, icon: stack.icon, size: 28, dimmed: stack.sleep?.state == .unloaded)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stack.name.isEmpty ? stack.title : stack.name)
                        .font(.headline)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let onClose {
                    Button(action: onClose) { Image(systemName: "sidebar.trailing") }
                        .buttonStyle(.borderless)
                        .help("Hide the inspector (⌥⌘I)")
                        .accessibilityLabel("Hide the inspector")
                }
            }
            HStack(alignment: .top, spacing: 14) {
                figure(hasProcess ? approx + TaskManagerFormat.memory(stack.memoryFootprint ?? 0) : "–", "memory footprint")
                figure(hasProcess ? approx + TaskManagerFormat.cpu(stack.usage.cpuPercent) + " %" : "–", "CPU now")
                figure(hasProcess ? approx + TaskManagerFormat.cpuTime(stack.cpuTime) : "–", "CPU time")
                figure("\(stack.pids.count)", stack.pids.count == 1 ? "process" : "processes")
            }
            .help("CPU time: what its processes used since they started"
                  + (stack.isEstimate ? ". " + TaskManagerHelp.estimate : "."))
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let host = URL(string: stack.site)?.host { parts.append(host) }
        if let sleep = stack.sleep {
            parts.append(sleep.state.title)
            if !sleep.isOnScreen, sleep.idle != nil, sleep.openedInDarni { parts.append("idle \(TaskManagerFormat.idle(sleep.idle))") }
            if sleep.isOnScreen { parts.append("on screen") }
            if !sleep.openedInDarni { parts.append(TaskManagerHelp.notOpenedInDarni.lowercased()) }
        }
        if parts.isEmpty { parts.append(stack.kind == .browser ? "Darni's own processes" : "Extension") }
        return parts.joined(separator: " · ")
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: By process

    private var byProcess: some View {
        let parts = stack.members.map { (member: $0, bytes: Double($0.memoryFootprint) * $0.share) }
        let total = max(1, parts.reduce(0) { $0 + $1.bytes })
        return TaskManagerCard(title: "Memory by process", trailing: stack.isEstimate ? "≈ shares of shared processes" : nil) {
            GeometryReader { proxy in
                HStack(spacing: 1.5) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        Rectangle()
                            .fill(ink.category(index))
                            .frame(width: max(2, (proxy.size.width - CGFloat(parts.count - 1) * 1.5) * CGFloat(part.bytes / total)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: 12)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(ink.category(index)).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(part.member.task.title).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 6)
                                Text(TaskManagerFormat.memory(UInt64(part.bytes))).monospacedDigit()
                                Text("\(Int((part.bytes / total * 100).rounded())) %")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 38, alignment: .trailing)
                            }
                            .font(.callout)
                            Text(Self.explanation(part.member))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// What a process is, in a line.
    static func explanation(_ member: TaskManagerStack.Member) -> String {
        var line: String
        switch member.task.kind {
        case .tab: line = "The page's own process: its scripts, DOM, styles and decoded images"
        case .subframe: line = "A frame of another site in this page, in a process of its own"
        case .browserExtension: line = "The extension's background page or service worker"
        case .browser: line = "Darni itself: windows, tabs, the sidebar"
        case .helper: line = "Engine work shared by every tab"
        }
        if member.sharedBy > 1 {
            line += ". Shared by \(member.sharedBy) tabs: this one counts 1/\(member.sharedBy) of \(TaskManagerFormat.memory(member.memoryFootprint))"
        }
        return line + " · pid \(member.pid)"
    }

    // MARK: Memory history

    private func memoryHistory(track: TaskManagerStackHistory?, timeline: TaskManagerTimeline, growth: TaskManagerInsight?) -> some View {
        let history = controller.history
        let cells = history.minuteCells(stack.historyKey, now: timeline.now)
        let firstIndex = cells.firstIndex { $0 != nil }
        let shown = firstIndex.map { Array(cells[$0...]) } ?? []
        let values = shown.map { $0?.memory.map { Double($0) } }
        let scale = TaskManagerLineChart.memoryScale(values)
        let minutes = Double(shown.count)
        let start = timeline.now - (minutes - 1) * TaskManagerHistory.minuteSeconds
        let markers = (track?.events ?? []).filter { $0.time >= start }.map { event in
            (position: min(1, max(0, (event.time - start) / max(60, timeline.now - start))), kind: event.kind)
        }
        let title = shown.count >= TaskManagerHistory.minuteCellCount ? "Memory, last 3 hours"
            : shown.isEmpty ? "Memory history" : "Memory, last \(TaskManagerFormat.duration(minutes * 60))"
        return TaskManagerCard(title: title, trailing: shown.isEmpty ? nil : "each point 1 min") {
            if values.compactMap({ $0 }).count < 2 {
                Text(history.lastReading == nil ? "No readings yet." : "The line starts after two minutes of readings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                TaskManagerLineChart(values: values, low: scale.low, high: scale.high,
                                     color: growth == nil ? ink.accent : ink.warning, markers: markers)
                    .frame(height: 64)
                    .accessibilityLabel(TaskManagerAccessibility.memorySparkline(shown, span: title.lowercased()))
                HStack {
                    Text(timeline.clock(start))
                    Spacer()
                    Text("now")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            if let growth {
                VStack(alignment: .leading, spacing: 3) {
                    TaskManagerInsightLine(insight: growth)
                    Text("Scripted rule, not AI: 30 min or more on the same page, steady growth. Reloading the page frees it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ink.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    // MARK: Processes' CPU

    private func processGrid(timeline: TaskManagerTimeline, hints: [TaskManagerInsight]) -> some View {
        let history = controller.history
        let stackCells = history.recentCells(stack.historyKey, now: timeline.now, count: TaskManagerHistory.memberCellCount)
        return TaskManagerCard(title: "CPU, last 5 min", trailing: "each cell 10 s") {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(stack.members, id: \.pid) { member in
                    let own = history.memberCells(stack.historyKey, pid: member.pid, now: timeline.now)
                    // A process's own figure; asleep and unloaded follow the tab.
                    let cells = zip(own, stackCells).map { cell, whole -> TaskManagerHistoryCell? in
                        guard var cell else { return whole?.state == .awake ? nil : whole }
                        if let whole, whole.state != .awake { cell = whole }
                        return cell
                    }
                    HStack(spacing: 8) {
                        Text(TaskManagerInspector.short(member.task.title))
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 104, alignment: .leading)
                        Canvas { context, size in
                            TaskManagerHeatPainter.draw(cells, in: CGRect(origin: .zero, size: size), context: &context, ink: ink)
                        }
                        .frame(height: 15)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(TaskManagerAccessibility.heatRow(name: member.task.title, cells: cells, timeline: timeline))
                }
                HStack {
                    Text("−5 min")
                    Spacer()
                    Text("now")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 112)
                ForEach(hints) { TaskManagerInsightLine(insight: $0) }
            }
        }
    }

    static func short(_ title: String) -> String {
        if title.hasPrefix("Subframe: ") {
            let site = String(title.dropFirst("Subframe: ".count))
            return "Frame · " + (URL(string: site)?.host ?? site)
        }
        if title.hasPrefix("Page") { return "Page" }
        return title
    }

    // MARK: Developers

    @State private var copied = false

    private var developers: some View {
        TaskManagerCard(title: "For developers") {
            HStack(spacing: 8) {
                if stack.kind == .tab {
                    Button("DevTools › Elements") { controller.openDevTools(stack) }
                        .disabled(!controller.canOpenDevTools(stack))
                        .help("Opens Darni's Developer Tools for this tab, on the Elements panel.")
                }
                Button(copied ? "Copied" : "Copy figures") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(controller.figures(for: stack), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .help("Copies this card's figures as plain text, for a bug report.")
            }
            .controlSize(.small)
        }
    }
}

/// Tab controls: the tab's state, Sleep and Unload, and what tab sleep did
/// to it with the measured effect, updated once each effect settles.
struct TaskManagerTabControlsCard: View {
    let controller: TaskManagerController
    let stack: TaskManagerStack
    let track: TaskManagerStackHistory?
    let timeline: TaskManagerTimeline
    let asleep: TaskManagerInsight?
    @Environment(\.taskManagerInk) private var ink

    var body: some View {
        let state = stack.sleep?.state
        TaskManagerCard(title: "Tab controls") {
            if let state {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: Self.symbol(state))
                        .foregroundStyle(state == .sleeping || state == .unloaded ? ink.accent : Color.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.title).font(.callout.weight(.medium))
                        Text(state.explanation).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 8) {
                Button { controller.sleep(stack) } label: { Label("Sleep", systemImage: "moon.zzz") }
                    .disabled(!controller.canSleep(stack))
                    .help(controller.canSleep(stack) ? TabSleepUnavailable.sleepHelp : Self.unavailable(stack, action: "sleep"))
                Button { controller.unload(stack) } label: { Label("Unload", systemImage: "arrow.down.to.line") }
                    .disabled(!controller.canUnload(stack))
                    .help(controller.canUnload(stack) ? "Takes the page out of memory now. It loads again when you show it."
                          : Self.unavailable(stack, action: "unload"))
            }
            .controlSize(.small)
            if let asleep { TaskManagerInsightLine(insight: asleep) }
            let events = (track?.events ?? []).reversed().prefix(6)
            if events.isEmpty {
                Text("No sleep or unload since the history began.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(events), id: \.id) { event in
                        eventLine(event)
                    }
                }
            }
        }
    }

    private func eventLine(_ event: TaskManagerTabEvent) -> some View {
        let history = controller.history
        let line = track.map { TaskManagerEventText.line(event, track: $0, history: history, timeline: timeline, isEstimate: stack.isEstimate) } ?? ""
        let avoided = track.flatMap { TaskManagerEventText.avoided(event, track: $0, history: history, now: timeline.now) }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: Self.symbol(event.kind))
                .font(.caption)
                .foregroundStyle(event.kind == .fellAsleep || event.kind == .unloaded ? ink.accent : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(line)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(event.kind == .unloaded ? TaskManagerInsights.freedRule : event.kind == .fellAsleep
                          ? "Sleep frees CPU, not memory: a frozen page stays in memory. CPU since is measured from the readings after it settled." : "")
                if let avoided {
                    Text(avoided)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(TaskManagerInsights.avoidedRule)
                        .accessibilityHint(TaskManagerInsights.avoidedRule)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func symbol(_ state: TaskManagerTabState) -> String {
        switch state {
        case .active: return "sun.max"
        case .keptAwake: return "eye"
        case .fallingAsleep, .sleeping: return "moon.zzz.fill"
        case .unloaded: return "arrow.down.to.line"
        case .notLoaded: return "tray"
        }
    }

    static func symbol(_ kind: TaskManagerTabEvent.Kind) -> String {
        switch kind {
        case .fellAsleep: return "moon.zzz.fill"
        case .woke: return "sun.max"
        case .unloaded: return "arrow.down.to.line"
        case .loaded: return "arrow.up.to.line"
        }
    }

    /// Why Sleep or Unload is off for this tab.
    static func unavailable(_ stack: TaskManagerStack, action: String) -> String {
        guard let sleep = stack.sleep else { return "Only a tab of a space can \(action) from here." }
        if action == "sleep" { return sleepUnavailable(sleep).text }
        switch sleep.state {
        case .unloaded: return "Already unloaded."
        case .notLoaded: return "Not loaded: nothing in memory to unload."
        case .keptAwake: return sleep.state.explanation
        case .active where sleep.isOnScreen: return "On screen. A tab unloads once you leave it."
        case .sleeping, .fallingAsleep, .active: return "Can't unload this tab now."
        }
    }

    /// Sleep's reason, in the sidebar menu's words (`TabSleepUnavailable`).
    static func sleepUnavailable(_ sleep: TaskManagerTabSleep) -> TabSleepUnavailable {
        switch sleep.state {
        case .unloaded: return .unloaded
        case .notLoaded: return .notLoaded
        case .sleeping, .fallingAsleep: return .asleep
        case .keptAwake(let reason): return .inUse(reason)
        case .active: return sleep.isOnScreen ? .onScreen : .engineCannotFreeze
        }
    }
}
