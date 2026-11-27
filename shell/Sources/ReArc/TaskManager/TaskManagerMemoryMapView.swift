import AppKit
import SidebarModel
import SwiftUI

/// Memory map (docs/TASK-MANAGER-INSIGHTS.md §4.1): a squarified treemap of
/// the stacks shown, area for footprint, the tab's favicon colour for the
/// fill, each tab divided by process (page, frames). A dashed "ghost" tile is
/// the memory an unload gave back, as measured (`TaskManagerHistory`). A click
/// selects the stack and opens the inspector.
struct TaskManagerMemoryMapView: View {
    let controller: TaskManagerController
    @Environment(\.taskManagerInk) private var ink

    /// A tile of the map: a stack, or the ghost of an unloaded tab.
    struct Entry: Identifiable {
        var id: String
        var stack: TaskManagerStack
        var freed: (bytes: UInt64, approximate: Bool)?
        var value: Double
    }

    static func entries(_ stacks: [TaskManagerStack], history: TaskManagerHistory) -> [Entry] {
        stacks.compactMap { stack in
            if let memory = stack.memoryFootprint, memory > 0 {
                return Entry(id: stack.historyKey, stack: stack, value: Double(memory))
            }
            // Unloaded: the memory its unload measurably gave back, while it stays unloaded.
            guard stack.kind == .tab, stack.sleep?.state == .unloaded, let track = history.history(of: stack),
                  let event = track.events.last(where: { $0.kind == .unloaded && $0.endedAt == nil }),
                  case .freed(let bytes, let approximate) = event.effect, bytes > 0 else { return nil }
            return Entry(id: "ghost/\(stack.historyKey)", stack: stack, freed: (bytes, approximate), value: Double(bytes))
        }
    }

    var body: some View {
        let entries = Self.entries(controller.visibleStacks, history: controller.history)
        let total = entries.filter { $0.freed == nil }.reduce(0) { $0 + $1.value }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory map").font(.title3.weight(.semibold))
                    Text("Area is memory footprint; each tab is divided by process (its page, frames of other sites). "
                         + "Dashed: memory an unload gave back, as measured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Total \(TaskManagerFormat.memory(UInt64(total)))")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(ink.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(ink.accent.opacity(0.12), in: Capsule())
                    .help("The footprint of every process shown. Shared processes count once.")
            }
            GeometryReader { proxy in
                let tiles = TaskManagerTreemap.layout(entries.map { .init(id: $0.id, value: $0.value) },
                                                      in: CGRect(origin: .zero, size: proxy.size))
                let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
                ZStack(alignment: .topLeading) {
                    ForEach(tiles, id: \.id) { tile in
                        if let entry = byID[tile.id] {
                            TaskManagerMapTile(controller: controller, entry: entry, size: tile.rect.size)
                                .frame(width: tile.rect.width, height: tile.rect.height)
                                .offset(x: tile.rect.minX, y: tile.rect.minY)
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Memory map")
        }
        .padding(16)
    }
}

private struct TaskManagerMapTile: View {
    let controller: TaskManagerController
    let entry: TaskManagerMemoryMapView.Entry
    let size: CGSize
    @Environment(\.taskManagerInk) private var ink

    var body: some View {
        let stack = entry.stack
        let focused = controller.focusedKey == stack.historyKey
        Group {
            if let freed = entry.freed {
                ghost(freed)
            } else {
                filled(stack)
            }
        }
        .padding(1.5)
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(ink.accent, lineWidth: 2.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { controller.focus(stack) }
        .help(help(stack))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help(stack))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { controller.focus(stack) }
    }

    private func help(_ stack: TaskManagerStack) -> String {
        if let freed = entry.freed {
            return "\(stack.title), unloaded: freed \(freed.approximate ? "≈ " : "")\(TaskManagerFormat.memory(freed.bytes))"
        }
        let memory = stack.memoryFootprint.map(TaskManagerFormat.memory) ?? "–"
        let processes = stack.pids.count == 1 ? "1 process" : "\(stack.pids.count) processes"
        return "\(stack.title), \(stack.isEstimate ? "≈ " : "")\(memory), \(processes)"
    }

    private func filled(_ stack: TaskManagerStack) -> some View {
        let fill = TaskManagerTileColor.color(for: stack, controller: controller, ink: ink)
        let textColor = TaskManagerTileColor.text(on: fill)
        let label = size.width > 70 && size.height > 34
        let growth = controller.history.history(of: stack).flatMap { TaskManagerInsights.growth($0, now: controller.timeline.now) }
        return ZStack(alignment: .topLeading) {
            Canvas { context, canvas in
                let rect = CGRect(origin: .zero, size: canvas)
                context.fill(Path(rect), with: .color(Color(nsColor: fill)))
                let top: CGFloat = canvas.height > 70 ? 34 : 0
                let area = CGRect(x: 0, y: top, width: canvas.width, height: canvas.height - top)
                guard stack.members.count > 1, area.height > 12 else { return }
                let parts = TaskManagerTreemap.layout(
                    stack.members.map { .init(id: "\($0.pid)", value: Double($0.memoryFootprint) * $0.share) }, in: area
                )
                for (index, part) in parts.enumerated() {
                    if index > 0 { context.fill(Path(part.rect), with: .color(Color.black.opacity(0.06 + 0.05 * Double(index % 4)))) }
                    context.stroke(Path(part.rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(Color.white.opacity(0.4)), lineWidth: 1)
                    if let member = stack.members.first(where: { "\($0.pid)" == part.id }), part.rect.width > 96, part.rect.height > 26,
                       index > 0 || top == 0 {
                        let text = Text("\(Self.short(member.task.title)) \(TaskManagerFormat.memory(UInt64(Double(member.memoryFootprint) * member.share)))")
                            .font(.system(size: 10))
                            .foregroundColor(Color(nsColor: textColor).opacity(0.85))
                        context.draw(text, at: CGPoint(x: part.rect.minX + 6, y: part.rect.maxY - 6), anchor: .bottomLeading)
                    }
                }
            }
            if label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(stack.title.hasPrefix("Tab: ") ? String(stack.title.dropFirst(5)) : stack.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 3) {
                        Text((stack.isEstimate ? "≈ " : "") + TaskManagerFormat.memory(stack.memoryFootprint ?? 0))
                        if growth != nil {
                            Image(systemName: "arrowtriangle.up.fill").font(.system(size: 8))
                            Text("growing")
                        }
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .opacity(0.85)
                }
                .foregroundColor(Color(nsColor: textColor))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func ghost(_ freed: (bytes: UInt64, approximate: Bool)) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(ink.accent.opacity(0.04))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1.25, dash: [5, 3]))
            if size.width > 70, size.height > 34 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.stack.title.hasPrefix("Tab: ") ? String(entry.stack.title.dropFirst(5)) : entry.stack.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text("Unloaded · freed \(freed.approximate ? "≈ " : "")\(TaskManagerFormat.memory(freed.bytes))")
                        .font(.system(size: 11).monospacedDigit())
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
    }

    /// "Page", "Frame · ads.example": a member's name inside a tile.
    static func short(_ title: String) -> String {
        if title.hasPrefix("Page") { return "Page" }
        if title.hasPrefix("Subframe: ") {
            let site = String(title.dropFirst("Subframe: ".count))
            return "Frame · " + (URL(string: site)?.host ?? site)
        }
        return title
    }
}

/// A tile's fill: the favicon's own colour (its average over the opaque,
/// coloured pixels); the space's palette when it has none (a template symbol, no icon).
enum TaskManagerTileColor {
    private static let cache = NSCache<NSImage, NSColor>()

    @MainActor static func color(for stack: TaskManagerStack, controller: TaskManagerController, ink: TaskManagerInk) -> NSColor {
        if let image = controller.source.icon(for: stack.icon), let color = average(image) { return color }
        let seed = stack.historyKey.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return NSColor(ink.category(stack.kind == .browser ? 0 : seed % 6)).usingColorSpace(.deviceRGB) ?? .systemBlue
    }

    static func average(_ image: NSImage) -> NSColor? {
        if let cached = cache.object(forKey: image) { return cached }
        guard !image.isTemplate, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 12, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 12, height: 12))
        NSGraphicsContext.restoreGraphicsState()
        var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
        for x in 0 ..< 12 {
            for y in 0 ..< 12 {
                guard let pixel = rep.colorAt(x: x, y: y), pixel.alphaComponent > 0.5 else { continue }
                // Coloured pixels count more than white or grey ones.
                let w = pixel.alphaComponent * (0.15 + pixel.saturationComponent)
                red += pixel.redComponent * w
                green += pixel.greenComponent * w
                blue += pixel.blueComponent * w
                weight += w
            }
        }
        guard weight > 0 else { return nil }
        let color = NSColor(deviceRed: red / weight, green: green / weight, blue: blue / weight, alpha: 1)
        cache.setObject(color, forKey: image)
        return color
    }

    /// White on a dark fill, near-black on a light one.
    static func text(on fill: NSColor) -> NSColor {
        let rgb = fill.usingColorSpace(.deviceRGB) ?? fill
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.6 ? NSColor(white: 0.1, alpha: 1) : .white
    }
}
