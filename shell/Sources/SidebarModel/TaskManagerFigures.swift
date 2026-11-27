import Foundation

/// The Task Manager's three views of the same stacks (docs/TASK-MANAGER-INSIGHTS.md
/// §4.1). The choice is kept across launches, as the columns are.
public enum TaskManagerViewMode: String, CaseIterable, Sendable {
    case list, heatGrid, memoryMap

    public var title: String {
        switch self {
        case .list: return "List"
        case .heatGrid: return "Heat grid"
        case .memoryMap: return "Memory map"
        }
    }

    static let defaultsKey = "ReArcTaskManagerView"

    public static func load(from defaults: UserDefaults) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .list
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// The inspector's Copy figures: the card as plain text, for a bug report.
public enum TaskManagerFigures {
    public static func text(stack: TaskManagerStack, history: TaskManagerHistory, timeline: TaskManagerTimeline) -> String {
        let approx = stack.isEstimate ? "≈ " : ""
        // A private window's page: no title, site or address on the pasteboard (security N-1).
        var lines = ["\(Brand.name) Task Manager · \(stack.isPrivate ? "Private tab" : stack.title)"]
        if !stack.site.isEmpty, !stack.isPrivate { lines.append("Site: \(stack.site)") }
        if let sleep = stack.sleep {
            lines.append("State: \(sleep.state.title) · idle \(sleep.idleText)")
        }
        if let memory = stack.memoryFootprint {
            lines.append("Memory footprint: \(approx)\(TaskManagerFormat.memory(memory))"
                + " · CPU now: \(approx)\(TaskManagerFormat.cpu(stack.usage.cpuPercent)) %"
                + " · CPU time: \(approx)\(TaskManagerFormat.cpuTime(stack.cpuTime))"
                + " · Processes: \(stack.pids.count)")
            lines.append("By process:")
            for member in stack.members {
                let name = stack.isPrivate ? "Process" : member.task.title
                var line = "  \(name) · \(TaskManagerFormat.memory(member.memoryFootprint)) · pid \(member.pid)"
                if member.sharedBy > 1 { line += " (shared by \(member.sharedBy), counted \(TaskManagerFormat.memory(UInt64(Double(member.memoryFootprint) * member.share))))" }
                lines.append(line)
            }
        } else {
            lines.append("No process: nothing of the page is in memory.")
        }
        if let track = history.history(of: stack) {
            let minutes = history.minuteCells(track.key, now: timeline.now).compactMap { $0 }
            let memory = minutes.compactMap(\.memory)
            if let first = memory.first, let last = memory.last, let peak = minutes.map(\.memoryPeak).max() {
                let span = TaskManagerFormat.duration(Double(minutes.count) * TaskManagerHistory.minuteSeconds)
                lines.append("Memory, last \(span): \(TaskManagerFormat.memory(first)) → \(TaskManagerFormat.memory(last)), peak \(TaskManagerFormat.memory(peak))")
            }
            let recent = history.recentCells(track.key, now: timeline.now)
            if recent.contains(where: { $0?.cpuPercent != nil }) {
                lines.append(TaskManagerAccessibility.cpuSparkline(recent))
            }
            if !track.events.isEmpty {
                lines.append("Tab controls:")
                for event in track.events {
                    lines.append("  " + TaskManagerEventText.line(event, track: track, history: history, timeline: timeline,
                                                                  isEstimate: stack.isEstimate))
                }
            }
            let hints = TaskManagerInsights.insights(for: track, in: history, timeline: timeline)
            if !hints.isEmpty {
                lines.append("Spotted (\(TaskManagerInsights.notAI.lowercased())):")
                lines += hints.map { "  \($0.text)" }
            }
        }
        let date = DateFormatter.localizedString(from: timeline.wallNow, dateStyle: .medium, timeStyle: .medium)
        lines.append("Read \(date). ≈ marks a share of processes other tabs use too. Kept in memory on this Mac only.")
        return lines.joined(separator: "\n")
    }
}
