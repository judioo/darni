import AppKit
import SidebarModel
import SwiftUI

/// The Task Manager's colours, after the owner's rule that every surface
/// looks like Darni (docs/TASK-MANAGER-INSIGHTS.md §4.3): the window takes the
/// focused space's tint, cards are rounded on it, and single-hue scales use
/// the space's accent. The warning colour is the theme's orange.
struct TaskManagerInk {
    var accent: Color
    var isDark: Bool

    init(accent: Color, isDark: Bool) {
        self.accent = accent
        self.isDark = isDark
    }

    /// The focused space's accent in the window's appearance; Darni's own outside a space.
    init(theme: SpaceTheme?, dark: Bool) {
        let chrome = theme.map { ThemeChromeColors(theme: $0, dark: dark) } ?? .outsideSpaces(dark: dark)
        self.init(accent: chrome.accent, isDark: dark)
    }

    var accentNS: NSColor { NSColor(accent) }
    /// Washed over the window's background.
    var tint: Color { accent.opacity(isDark ? 0.09 : 0.05) }
    var card: Color { isDark ? Color.white.opacity(0.06) : Color.white.opacity(0.78) }
    var cardBorder: Color { Color.primary.opacity(isDark ? 0.10 : 0.07) }
    var warning: Color { Color(nsColor: .systemOrange) }
    var hot: Color { Color(nsColor: .systemRed) }
    var quiet: Color { Color.primary.opacity(isDark ? 0.11 : 0.07) }

    /// A heat cell's fill. Asleep and unloaded cells get a pattern on top (`TaskManagerHeatPainter`).
    func heat(_ level: TaskManagerHeat) -> Color {
        switch level {
        case .noReading, .unloaded: return .clear
        case .asleep: return accent.opacity(0.08)
        case .idle: return quiet
        case .low: return accent.opacity(0.22)
        case .moderate: return accent.opacity(0.42)
        case .busy: return accent.opacity(0.65)
        case .high: return accent.opacity(0.95)
        case .hot: return hot
        }
    }

    /// Categories of a stacked bar: the accent first, then fixed hues.
    func category(_ index: Int) -> Color {
        let palette: [Color] = [accent, Color(nsColor: .systemTeal), Color(nsColor: .systemOrange), Color(nsColor: .systemPink),
                                Color(nsColor: .systemIndigo), Color(nsColor: .systemGray)]
        return palette[index % palette.count].opacity(index < palette.count ? 1 : 0.55)
    }
}

private struct TaskManagerInkKey: EnvironmentKey {
    static let defaultValue = TaskManagerInk(accent: .accentColor, isDark: false)
}

extension EnvironmentValues {
    var taskManagerInk: TaskManagerInk {
        get { self[TaskManagerInkKey.self] }
        set { self[TaskManagerInkKey.self] = newValue }
    }
}

/// A rounded card on the window's tint, with an optional small-caps title.
struct TaskManagerCard<Content: View>: View {
    var title: String?
    var trailing: String?
    @ViewBuilder var content: Content
    @Environment(\.taskManagerInk) private var ink

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    if let trailing {
                        Text(trailing).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ink.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ink.cardBorder, lineWidth: 1))
    }
}

// MARK: Heat cells

/// Draws a row of heat cells: CPU steps as fills, asleep cells hatched,
/// unloaded cells as a dashed outline, a cell with no reading as a faint dot,
/// and tab sleep's events as marks on the cells' top edge.
enum TaskManagerHeatPainter {
    static let gap: CGFloat = 2
    static let markHeight: CGFloat = 5

    static func draw(_ cells: [TaskManagerHistoryCell?], marks: [Int: TaskManagerTabEvent.Kind] = [:], in rect: CGRect,
                     context: inout GraphicsContext, ink: TaskManagerInk) {
        guard !cells.isEmpty else { return }
        let width = (rect.width - gap * CGFloat(cells.count - 1)) / CGFloat(cells.count)
        let cellRect = { (index: Int) in
            CGRect(x: rect.minX + CGFloat(index) * (width + gap), y: rect.minY + markHeight, width: width, height: rect.height - markHeight)
        }
        for (index, cell) in cells.enumerated() {
            drawCell(TaskManagerHeat.level(of: cell), in: cellRect(index), context: &context, ink: ink)
        }
        for (index, kind) in marks where cells.indices.contains(index) {
            drawMark(kind, over: cellRect(index), context: &context, ink: ink)
        }
    }

    static func drawCell(_ level: TaskManagerHeat, in rect: CGRect, context: inout GraphicsContext, ink: TaskManagerInk) {
        let shape = Path(roundedRect: rect, cornerRadius: min(3, rect.width / 3))
        switch level {
        case .noReading:
            let dot = CGRect(x: rect.midX - 1, y: rect.midY - 1, width: 2, height: 2)
            context.fill(Path(ellipseIn: dot), with: .color(Color.primary.opacity(0.15)))
        case .unloaded:
            context.stroke(shape.path(in: rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(Color.secondary.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
        case .asleep:
            context.fill(shape, with: .color(ink.heat(.asleep)))
            var hatch = context
            hatch.clip(to: shape)
            var lines = Path()
            var x = rect.minX - rect.height
            while x < rect.maxX {
                lines.move(to: CGPoint(x: x, y: rect.maxY))
                lines.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                x += 3.5
            }
            hatch.stroke(lines, with: .color(ink.accent.opacity(0.55)), lineWidth: 1)
            context.stroke(shape, with: .color(ink.accent.opacity(0.4)), lineWidth: 0.75)
        default:
            context.fill(shape, with: .color(ink.heat(level)))
        }
    }

    /// ● fell asleep, ○ woke, ▼ unloaded, △ loaded again: on the cell's top edge.
    static func drawMark(_ kind: TaskManagerTabEvent.Kind, over rect: CGRect, context: inout GraphicsContext, ink: TaskManagerInk) {
        let size: CGFloat = 5
        let box = CGRect(x: rect.midX - size / 2, y: rect.minY - markHeight, width: size, height: size - 0.5)
        switch kind {
        case .fellAsleep:
            context.fill(Path(ellipseIn: box), with: .color(ink.accent))
        case .woke:
            context.stroke(Path(ellipseIn: box.insetBy(dx: 0.5, dy: 0.5)), with: .color(ink.accent), lineWidth: 1)
        case .unloaded, .loaded:
            var triangle = Path()
            if kind == .unloaded {
                triangle.move(to: CGPoint(x: box.minX, y: box.minY))
                triangle.addLine(to: CGPoint(x: box.maxX, y: box.minY))
                triangle.addLine(to: CGPoint(x: box.midX, y: box.maxY))
                triangle.closeSubpath()
                context.fill(triangle, with: .color(Color.primary.opacity(0.75)))
            } else {
                triangle.move(to: CGPoint(x: box.minX, y: box.maxY))
                triangle.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
                triangle.addLine(to: CGPoint(x: box.midX, y: box.minY))
                triangle.closeSubpath()
                context.stroke(triangle, with: .color(Color.primary.opacity(0.75)), lineWidth: 1)
            }
        }
    }

    /// The events of `key` over cells ending at `now`, by cell position (the latest event of a cell wins).
    static func marks(_ history: TaskManagerHistory, key: String, now: TimeInterval, count: Int,
                      cellSeconds: TimeInterval = TaskManagerHistory.cellSeconds) -> [Int: TaskManagerTabEvent.Kind] {
        let last = Int((now / cellSeconds).rounded(.down))
        let first = last - count + 1
        var marks: [Int: TaskManagerTabEvent.Kind] = [:]
        for event in history[key]?.events ?? [] {
            let index = Int((event.time / cellSeconds).rounded(.down)) - first
            if (0 ..< count).contains(index) { marks[index] = event.kind }
        }
        return marks
    }
}

/// The heat grid's legend: every kind of cell, and the marks.
struct TaskManagerHeatLegend: View {
    var showsMarks = true
    @Environment(\.taskManagerInk) private var ink

    var body: some View {
        HStack(spacing: 10) {
            ForEach([TaskManagerHeat.idle, .low, .moderate, .busy, .high, .hot, .asleep, .unloaded], id: \.self) { level in
                HStack(spacing: 4) {
                    Canvas { context, size in
                        TaskManagerHeatPainter.drawCell(level, in: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5),
                                                        context: &context, ink: ink)
                    }
                    .frame(width: 14, height: 11)
                    Text(level.title).font(.caption).foregroundStyle(.secondary)
                }
            }
            if showsMarks {
                HStack(spacing: 4) {
                    Canvas { context, size in
                        TaskManagerHeatPainter.drawMark(.fellAsleep, over: CGRect(x: 0, y: 6, width: 7, height: 6), context: &context, ink: ink)
                    }
                    .frame(width: 7, height: 11)
                    Text("slept").font(.caption).foregroundStyle(.secondary)
                    Canvas { context, size in
                        TaskManagerHeatPainter.drawMark(.unloaded, over: CGRect(x: 0, y: 6, width: 7, height: 6), context: &context, ink: ink)
                    }
                    .frame(width: 7, height: 11)
                    Text("unloaded").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Legend: idle, under 3 %, under 10 %, under 25 %, under 60 %, 60 % and more in red, asleep hatched, unloaded outlined. "
            + "A dot over a cell: the tab fell asleep; a triangle: it was unloaded.")
    }
}

// MARK: Lines

/// A line over a series (nil: a gap), with a light area under it, scaled
/// between `low` and `high`. `markers` are positions (0…1) of tab sleep's events.
struct TaskManagerLineChart: View {
    var values: [Double?]
    var low: Double
    var high: Double
    var color: Color
    var markers: [(position: Double, kind: TaskManagerTabEvent.Kind)] = []
    @Environment(\.taskManagerInk) private var ink

    var body: some View {
        Canvas { context, size in
            let points = TaskManagerLineChart.points(values, low: low, high: high, size: size)
            for run in points {
                guard let first = run.first, let last = run.last else { continue }
                var line = Path()
                line.move(to: first)
                run.dropFirst().forEach { line.addLine(to: $0) }
                var area = line
                area.addLine(to: CGPoint(x: last.x, y: size.height))
                area.addLine(to: CGPoint(x: first.x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(color.opacity(0.14)))
                if run.count == 1 {
                    context.fill(Path(ellipseIn: CGRect(x: first.x - 1.5, y: first.y - 1.5, width: 3, height: 3)), with: .color(color))
                } else {
                    context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
            for marker in markers {
                let x = size.width * marker.position
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: 6))
                tick.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(tick, with: .color(Color.primary.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                TaskManagerHeatPainter.drawMark(marker.kind, over: CGRect(x: x - 3, y: 5, width: 6, height: 6), context: &context, ink: ink)
            }
        }
    }

    /// Runs of points between gaps, in the view's coordinates (top is high).
    static func points(_ values: [Double?], low: Double, high: Double, size: CGSize) -> [[CGPoint]] {
        guard values.count > 1 else { return [] }
        let span = max(high - low, .ulpOfOne)
        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []
        for (index, value) in values.enumerated() {
            guard let value else {
                if !current.isEmpty { runs.append(current) }
                current = []
                continue
            }
            let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
            let y = size.height - size.height * CGFloat((value - low) / span) * 0.86 - 1
            current.append(CGPoint(x: x, y: min(size.height - 1, max(1, y))))
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// A memory scale with room above and below; a flat line sits in the middle.
    static func memoryScale(_ values: [Double?]) -> (low: Double, high: Double) {
        let known = values.compactMap { $0 }
        guard let low = known.min(), let high = known.max() else { return (0, 1) }
        guard high > low else { return (low * 0.9, high * 1.1 + 1) }
        let pad = (high - low) * 0.15
        return (max(0, low - pad), high + pad)
    }

    /// CPU from 0; an idle line lies along the bottom.
    static func cpuScale(_ values: [Double?]) -> (low: Double, high: Double) {
        (0, max(5, (values.compactMap { $0 }.max() ?? 0) * 1.15))
    }
}

/// The List's sparkline cells: an AppKit view, drawn in place at each
/// reading with no animation, so 1 s updates don't shimmer (§4.3).
final class TaskManagerSparklineView: NSView {
    var values: [Double?] = [] { didSet { if values != oldValue { needsDisplay = true } } }
    var scale: (low: Double, high: Double) = (0, 1) { didSet { needsDisplay = true } }
    var color: NSColor = .controlAccentColor { didSet { if color != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let size = bounds.insetBy(dx: 0, dy: 3).size
        let runs = TaskManagerLineChart.points(values, low: scale.low, high: scale.high, size: size)
        for run in runs {
            guard let first = run.first, let last = run.last else { continue }
            let line = NSBezierPath()
            line.move(to: NSPoint(x: first.x, y: first.y + 3))
            run.dropFirst().forEach { line.line(to: NSPoint(x: $0.x, y: $0.y + 3)) }
            let area = line.copy() as! NSBezierPath
            area.line(to: NSPoint(x: last.x, y: size.height + 3))
            area.line(to: NSPoint(x: first.x, y: size.height + 3))
            area.close()
            color.withAlphaComponent(0.16).setFill()
            area.fill()
            color.setStroke()
            line.lineWidth = 1.25
            line.lineJoinStyle = .round
            line.stroke()
        }
    }
}

final class TaskManagerSparklineCell: NSTableCellView {
    let sparkline = TaskManagerSparklineView()

    init() {
        super.init(frame: .zero)
        identifier = TaskManagerTableController.sparklineCellID
        sparkline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sparkline)
        NSLayoutConstraint.activate([
            sparkline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TaskManagerMetrics.cellInset),
            sparkline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -TaskManagerMetrics.cellInset),
            sparkline.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            sparkline.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(values: [Double?], scale: (low: Double, high: Double), color: NSColor, label: String, help: String?) {
        sparkline.values = values
        sparkline.scale = scale
        sparkline.color = color
        if accessibilityLabel() != label { setAccessibilityLabel(label) }
        if toolTip != help { toolTip = help }
    }
}
