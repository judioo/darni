import AppKit
import SwiftUI
import SidebarModel

/// The sizes of the ⌘T bar's Tab Groups section and of its chips.
enum CommandBarTabGroupsMetrics {
    static let headerHeight: CGFloat = 26
    /// Between the header and the first line of chips.
    static let headerGap: CGFloat = 4
    static let bottomPadding: CGFloat = 10
    /// The chips' inset from the card's sides: where the result rows' icons start.
    static let sideInset: CGFloat = CommandBarOverlay.rowInset + 10
    /// Room around the chips inside the scrolling area, for the highlight's ring.
    static let ringRoom: CGFloat = 3
    static let foldDuration: TimeInterval = 0.18

    static let chipCornerRadius: CGFloat = 7
    static let chipPadding: CGFloat = 10
    /// Between a chip's name and its tab count.
    static let chipGap: CGFloat = 6
    static let nameSize: CGFloat = 12
    static let countSize: CGFloat = 11

    private static let nameFont = NSFont.systemFont(ofSize: nameSize, weight: .semibold)
    private static let countFont = NSFont.systemFont(ofSize: countSize, weight: .medium)

    private static func width(of text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// A chip's width with its whole name; the layout cuts it at `maxChipWidth`.
    static func naturalWidth(of row: TabGroupCommandBarRow) -> CGFloat {
        let count = row.chipCount.map { chipGap + width(of: $0, font: countFont) } ?? 0
        // A point to spare: SwiftUI's text can measure a fraction wider than AppKit's.
        return chipPadding * 2 + width(of: row.name, font: nameFont) + count + 1
    }

    /// The chips of `rows` across a bar `barWidth` wide.
    static func layout(rows: [TabGroupCommandBarRow], barWidth: CGFloat) -> TabGroupChipLayout {
        TabGroupChipLayout(widths: rows.map { Double(naturalWidth(of: $0)) }, available: Double(barWidth - sideInset * 2))
    }

    /// The section's height for a layout; no chips take no room.
    static func height(_ layout: TabGroupChipLayout) -> CGFloat {
        guard layout.lineCount > 0 else { return 0 }
        return 1 + headerHeight + headerGap + scrollHeight(layout) + bottomPadding
    }

    static func scrollHeight(_ layout: TabGroupChipLayout) -> CGFloat {
        CGFloat(layout.visibleHeight) + ringRoom * 2
    }
}

/// Tab Groups in the ⌘T bar: under the field while nothing is typed, the
/// groups the space on screen does not show yet (`TabGroupCommandBarRow`),
/// as chips that run across the bar and wrap, as Chrome's group chips run
/// across its bar. Twenty groups take a few lines; past three lines the
/// section scrolls inside itself. A click adds the group to the space. Tab
/// moves into the chips and the arrows between them (`CommandBarKeys`). The
/// first typed character empties the list and the section folds away (a cut
/// with Reduce Motion); from then on the bar is as it always was.
struct CommandBarTabGroupsSection: View {
    let model: BrowserViewModel
    let rows: [TabGroupCommandBarRow]
    let dark: Bool
    let barWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layout = CommandBarTabGroupsMetrics.layout(rows: rows, barWidth: barWidth)
        VStack(alignment: .leading, spacing: 0) {
            if !rows.isEmpty {
                list(layout).transition(.opacity)
            }
        }
        .frame(height: CommandBarTabGroupsMetrics.height(layout), alignment: .top)
        .clipped()
        // Only this section's own height and fade animate: the results under it move with it.
        .animation(reduceMotion ? nil : .easeOut(duration: CommandBarTabGroupsMetrics.foldDuration), value: rows.isEmpty)
    }

    private func list(_ layout: TabGroupChipLayout) -> some View {
        let highlighted = model.commandBarTabGroupHighlight
        return VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color(CommandBarInk.separator(dark: dark)))
                .frame(height: 1)
                .padding(.horizontal, 11)
            header(choosing: highlighted != nil)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: layout.metrics.lineSpacing) {
                        ForEach(Array(layout.lines.enumerated()), id: \.offset) { _, line in
                            HStack(spacing: layout.metrics.spacing) {
                                ForEach(line, id: \.self) { index in
                                    let row = rows[index]
                                    CommandBarTabGroupChip(model: model, row: row, dark: dark, isHighlighted: row.id == highlighted)
                                        .frame(width: layout.chips[index].width, height: layout.metrics.chipHeight)
                                        .id(row.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, CommandBarTabGroupsMetrics.sideInset)
                    .padding(.vertical, CommandBarTabGroupsMetrics.ringRoom)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDisabled(!layout.scrolls)
                .frame(height: CommandBarTabGroupsMetrics.scrollHeight(layout))
                // The keyboard's chip stays in view past the third line.
                .onChange(of: highlighted) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            .padding(.top, CommandBarTabGroupsMetrics.headerGap)
        }
    }

    /// "Tab Groups", and at the right what the keyboard does next.
    private func header(choosing: Bool) -> some View {
        let secondary = Color(CommandBarInk.secondaryText(dark: dark))
        return HStack(spacing: 6) {
            Text("Tab Groups")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if choosing {
                Text("Add to This Space")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(secondary)
            }
            CommandBarKeycap(title: choosing ? "↩" : "Tab", dark: dark)
                .help(choosing ? "Return adds the group. The arrow keys move between groups, Esc goes back to the field."
                               : "Press Tab to choose a group with the keyboard")
                .accessibilityHidden(true)
        }
        .padding(.horizontal, CommandBarTabGroupsMetrics.sideInset + 2)
        .frame(height: CommandBarTabGroupsMetrics.headerHeight, alignment: .bottom)
    }
}

/// A key's cap in the bar's hints ("Tab", "↩").
private struct CommandBarKeycap: View {
    let title: String
    let dark: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(CommandBarInk.primaryText(dark: dark)).opacity(0.75))
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 18)
            .background(Color(CommandBarInk.keycap(dark: dark)), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// One group as a chip filled with the group's colour, as its header is in
/// the sidebar: its name, cut short when long (the whole name is in its
/// tooltip), and its tab count. A click adds the group to the space. The
/// keyboard's chip has a ring. Its menu renames, colours, ungroups and
/// deletes the group (`TabGroupCommandBarMenu`).
private struct CommandBarTabGroupChip: View {
    let model: BrowserViewModel
    let row: TabGroupCommandBarRow
    let dark: Bool
    let isHighlighted: Bool
    @State private var isHovering = false

    var body: some View {
        let ink = row.color.ink(dark: dark)
        let shape = RoundedRectangle(cornerRadius: CommandBarTabGroupsMetrics.chipCornerRadius, style: .continuous)
        Button { model.addTabGroupToActiveSpace(row.id) } label: {
            HStack(spacing: CommandBarTabGroupsMetrics.chipGap) {
                Text(row.name)
                    .font(.system(size: CommandBarTabGroupsMetrics.nameSize, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(0)
                if let count = row.chipCount {
                    Text(count)
                        .font(.system(size: CommandBarTabGroupsMetrics.countSize, weight: .medium))
                        .opacity(0.8)
                        .fixedSize()
                        .layoutPriority(1)
                }
            }
            .foregroundStyle(ink)
            .padding(.horizontal, CommandBarTabGroupsMetrics.chipPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(row.color.color(dark: dark).opacity(isHovering ? 0.88 : 1), in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlay {
            if isHighlighted {
                RoundedRectangle(cornerRadius: CommandBarTabGroupsMetrics.chipCornerRadius + 2.5, style: .continuous)
                    .strokeBorder(Color(CommandBarInk.primaryText(dark: dark)), lineWidth: 2)
                    .padding(-CommandBarTabGroupsMetrics.ringRoom)
                    .allowsHitTesting(false)
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu { TabGroupCommandBarMenu(model: model, groupID: row.id) }
        .modifier(TabGroupEditorPopover(model: model, anchorID: row.id, arrowEdge: .bottom))
        .help("Add “\(row.name)” (\(row.countText)) to this space")
        .accessibilityLabel("Tab group \(row.name), \(row.countText)")
        .accessibilityHint("Adds the group to this space")
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }
}
