import AppKit
import SidebarModel
import SwiftUI

/// Heat grid (docs/TASK-MANAGER-INSIGHTS.md §4.1): a row per stack, a cell per
/// 10 s over the last 10 minutes, coloured by the stack's CPU share. Asleep
/// cells are hatched and unloaded ones outlined, so a cold row is visibly
/// tab sleep's doing. "Spotted" under it: up to three scripted observations.
struct TaskManagerHeatGridView: View {
    let controller: TaskManagerController
    @Environment(\.taskManagerInk) private var ink

    static let nameWidth: CGFloat = 220
    static let averageWidth: CGFloat = 76
    static let rowHeight: CGFloat = 21

    var body: some View {
        let timeline = controller.timeline
        let stacks = controller.visibleStacks
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("CPU heat grid").font(.title3.weight(.semibold))
                        Spacer()
                        TaskManagerHeatLegend()
                    }
                    Text("Each cell is 10 s of one tab's processes (its share of shared ones), last 10 minutes, while this window was open. "
                         + "Asleep tabs are hatched and unloaded ones outlined.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TaskManagerCard {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(stacks, id: \.historyKey) { stack in
                            row(stack, timeline: timeline)
                        }
                        HStack {
                            Text("−10 min")
                            Spacer()
                            Text("−5 min")
                            Spacer()
                            Text("now")
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, Self.nameWidth + 8)
                        .padding(.trailing, Self.averageWidth + 8)
                        .padding(.top, 4)
                    }
                }
                TaskManagerSpottedCard(insights: controller.spotted)
            }
            .padding(16)
        }
    }

    private func row(_ stack: TaskManagerStack, timeline: TaskManagerTimeline) -> some View {
        let cells = controller.history.recentCells(stack.historyKey, now: timeline.now)
        let marks = TaskManagerHeatPainter.marks(controller.history, key: stack.historyKey, now: timeline.now, count: cells.count)
        let shares = cells.compactMap { $0?.state == .awake ? $0?.cpuPercent : nil }
        let average = shares.isEmpty ? "–" : String(format: "%.1f %% avg", shares.reduce(0, +) / Double(shares.count))
        let focused = controller.focusedKey == stack.historyKey
        return HStack(spacing: 8) {
            TaskManagerStackIcon(controller: controller, icon: stack.icon, dimmed: stack.sleep?.state == .unloaded)
            Text(stack.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.nameWidth - 24, alignment: .leading)
            Canvas { context, size in
                TaskManagerHeatPainter.draw(cells, marks: marks, in: CGRect(origin: .zero, size: size), context: &context, ink: ink)
            }
            .frame(height: Self.rowHeight - 4)
            Text(average)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: Self.averageWidth, alignment: .trailing)
        }
        .frame(height: Self.rowHeight)
        .padding(.horizontal, 4)
        .background(focused ? ink.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { controller.focus(stack) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TaskManagerAccessibility.heatRow(name: stack.title, cells: cells, timeline: timeline))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { controller.focus(stack) }
    }
}

/// Up to three scripted observations, each with its rule in the help.
struct TaskManagerSpottedCard: View {
    let insights: [TaskManagerInsight]
    @Environment(\.taskManagerInk) private var ink

    var body: some View {
        TaskManagerCard(title: "Spotted", trailing: "scripted rules, nothing leaves this Mac") {
            if insights.isEmpty {
                Text("Nothing stands out in the last 10 minutes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(insights) { insight in
                        TaskManagerInsightLine(insight: insight, showsName: true)
                    }
                }
            }
        }
    }
}

/// "▲ YouTube used 14.8 % of a core for 10 min while hidden.", its rule in the help.
struct TaskManagerInsightLine: View {
    let insight: TaskManagerInsight
    var showsName = false
    @Environment(\.taskManagerInk) private var ink

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: insight.isWarning ? "exclamationmark.triangle.fill" : "moon.zzz.fill")
                .font(.caption)
                .foregroundStyle(insight.isWarning ? ink.warning : ink.accent)
            (showsName ? Text(insight.name).bold() + Text(" ") + Text(lowercasedFirst(insight.text)) : Text(insight.text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(insight.rule)
        .accessibilityElement(children: .combine)
        .accessibilityHint(insight.rule)
    }

    private func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}

/// A stack's picture: the favicon, the extension's icon or Darni's.
struct TaskManagerStackIcon: View {
    let controller: TaskManagerController
    let icon: TaskManagerTask.Icon
    var size: CGFloat = 16
    var dimmed = false

    var body: some View {
        Image(nsImage: TaskManagerStackIcon.image(icon, controller: controller))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .opacity(dimmed ? 0.45 : 1)
            .accessibilityHidden(true)
    }

    @MainActor static func image(_ icon: TaskManagerTask.Icon, controller: TaskManagerController) -> NSImage {
        if let image = controller.source.icon(for: icon) { return image }
        let symbol: String
        switch icon {
        case .browser: return NSApp.applicationIconImage ?? NSImage()
        case .tab, .sidebarTab: symbol = "globe"
        case .frame: symbol = "rectangle.dashed"
        case .browserExtension, .system: symbol = "puzzlepiece.extension"
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
    }
}
