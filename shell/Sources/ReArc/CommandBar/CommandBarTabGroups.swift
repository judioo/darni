import SwiftUI
import SidebarModel

/// Tab Groups in the ⌘T bar: under the field while nothing is typed, the
/// groups the space on screen does not show yet (`TabGroupCommandBarRow`).
/// A click adds the group to the space. The first typed character empties
/// the list and the section folds away (a cut with Reduce Motion); from
/// then on the bar is as it always was.
struct CommandBarTabGroupsSection: View {
    let model: BrowserViewModel
    let rows: [TabGroupCommandBarRow]
    let dark: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let headerHeight: CGFloat = 28
    static let rowHeight: CGFloat = 34
    static let rowSpacing: CGFloat = 2
    static let bottomPadding: CGFloat = 8
    /// Rows shown before the section scrolls.
    static let maxVisibleRows = 4
    static let foldDuration: TimeInterval = 0.18

    /// The section's height for `rows` groups; none takes no room.
    static func height(rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        let shown = CGFloat(min(rows, maxVisibleRows))
        return 1 + headerHeight + shown * rowHeight + (shown - 1) * rowSpacing + bottomPadding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !rows.isEmpty {
                list.transition(.opacity)
            }
        }
        .frame(height: Self.height(rows: rows.count), alignment: .top)
        .clipped()
        // Only this section's own height and fade animate: the results under it move with it.
        .animation(reduceMotion ? nil : .easeOut(duration: Self.foldDuration), value: rows.isEmpty)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color(CommandBarInk.separator(dark: dark)))
                .frame(height: 1)
                .padding(.horizontal, 11)
            Text("Tab Groups")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(CommandBarInk.secondaryText(dark: dark)))
                .padding(.leading, CommandBarOverlay.textX)
                .frame(height: Self.headerHeight, alignment: .bottomLeading)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(rows) { row in
                        CommandBarTabGroupRow(model: model, row: row, dark: dark)
                    }
                }
            }
            .scrollDisabled(rows.count <= Self.maxVisibleRows)
        }
    }
}

/// One group: its colour dot, its name and its tab count; "Add to This
/// Space" while the pointer is over it. Its menu renames, colours, ungroups
/// and deletes the group (`TabGroupCommandBarMenu`).
private struct CommandBarTabGroupRow: View {
    let model: BrowserViewModel
    let row: TabGroupCommandBarRow
    let dark: Bool
    @State private var isHovering = false

    var body: some View {
        let primary = Color(CommandBarInk.primaryText(dark: dark))
        let secondary = Color(CommandBarInk.secondaryText(dark: dark))
        Button { model.addTabGroupToActiveSpace(row.id) } label: {
            HStack(spacing: 0) {
                Circle()
                    .fill(row.color.color(dark: dark))
                    .frame(width: 12, height: 12)
                    .frame(width: 24, height: 24)
                    .padding(.trailing, CommandBarOverlay.textX - CommandBarOverlay.rowInset - 10 - 24)
                (Text(row.name).foregroundColor(primary)
                    + Text(" — \(row.countText)").foregroundColor(secondary).fontWeight(.regular))
                    .font(.system(size: CommandBarOverlay.rowFontSize, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if isHovering {
                    Text("Add to This Space")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(secondary)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 13)
            .frame(height: CommandBarTabGroupsSection.rowHeight)
            .background(isHovering ? Color(CommandBarInk.keycap(dark: dark)) : Color.clear,
                        in: RoundedRectangle(cornerRadius: CommandBarOverlay.rowCornerRadius, style: .continuous))
            .padding(.horizontal, CommandBarOverlay.rowInset)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu { TabGroupCommandBarMenu(model: model, groupID: row.id) }
        .modifier(TabGroupEditorPopover(model: model, anchorID: row.id, arrowEdge: .bottom))
        .help("Add “\(row.name)” to this space")
        .accessibilityLabel("Tab group \(row.name), \(row.countText)")
        .accessibilityHint("Adds the group to this space")
    }
}
