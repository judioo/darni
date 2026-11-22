import SwiftUI
import SidebarModel

/// Arc's "Open in <Space> ⌘O | ⌄" on Little Darni's toolbar: a light pill.
/// "Open in" is grey, the space's name is in the space's colour, ⌘O sits in a
/// small key cap, and a thin line divides off the ⌄ that opens the picker.
/// The colours are `LittleArcOpenInInk`'s: every word clears 4.5:1 on the pill.
///
/// In a narrow window the pill sheds what it can do without before the name
/// goes: first the key cap, then "Open in", then the name truncates. It never
/// leaves the toolbar, and the ⌄ is always there.
struct LittleArcOpenInButton: View {
    /// The target space's name and theme; nil when there is none to name.
    let targetName: String?
    let theme: SpaceTheme?
    /// What the main button's tooltip says.
    let help: String
    let isPickerOpen: Bool
    let open: () -> Void
    let togglePicker: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hoversMain = false
    @State private var hoversChevron = false

    /// The toolbar's controls are 22 pt tall (`LittleArcWindowView.toolbarHeight`).
    static let height: CGFloat = 22
    static let cornerRadius: CGFloat = 7
    static let chevronWidth: CGFloat = 26
    /// A long name is cut here, so the address field keeps room in a wide window too.
    static let maxNameWidth: CGFloat = 200

    private var name: String { targetName ?? "Darni" }

    var body: some View {
        let ink = LittleArcOpenInInk(theme: theme, dark: colorScheme == .dark)
        HStack(spacing: 0) {
            Button(action: open) {
                // Each is as wide as its words and no wider. The last can lose letters of the name.
                ViewThatFits(in: .horizontal) {
                    label(ink, words: true, keyCap: true).fixedSize()
                    label(ink, words: true, keyCap: false).fixedSize()
                    label(ink, words: false, keyCap: false, cutsName: true)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .frame(height: Self.height)
                .background(Color(hoversMain ? ink.pillHover : ink.pill))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .littleArcPart(.openIn)
            .onHover { hoversMain = $0 }
            .help(help)
            .accessibilityLabel("Open in \(name)")
            .accessibilityHint(help)

            Rectangle()
                .fill(Color(ink.label).opacity(0.28))
                .frame(width: 1, height: Self.height)
                .background(Color(ink.pill))

            Button(action: togglePicker) {
                Image(systemName: isPickerOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(ink.label))
                    .frame(width: Self.chevronWidth, height: Self.height)
                    .background(Color(hoversChevron || isPickerOpen ? ink.pillHover : ink.pill))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .littleArcPart(.openInChevron)
            .onHover { hoversChevron = $0 }
            .help("Open in another space")
            .accessibilityLabel("Open in another space")
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.12), radius: 1.5, y: 0.5)
    }

    /// `cutsName`: the name takes what room there is, and never more than it
    /// needs. Otherwise it is whole, up to `maxNameWidth`.
    private func label(_ ink: LittleArcOpenInInk, words: Bool, keyCap: Bool, cutsName: Bool = false) -> some View {
        HStack(spacing: 4) {
            if words {
                Text("Open in")
                    .foregroundStyle(Color(ink.label))
                    .fixedSize()
            }
            Text(name)
                .fontWeight(.medium)
                .foregroundStyle(Color(ink.name))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: cutsName ? nil : Self.maxNameWidth)
            if keyCap {
                Text("⌘O")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(ink.keyCapText))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(ink.keyCap)))
                    .fixedSize()
                    .padding(.leading, 2)
            }
        }
    }
}

/// Arc's space picker under Open in ⌄: a rounded, slightly translucent panel
/// at the window's top trailing corner, over the button it came from. Its top
/// row is a search field with a magnifier and a ⌃ that folds it away. Under it
/// every space is a row: its icon on a small tile tinted with its colour, then
/// its name. Typing filters, ↑ ↓ move, Return chooses, Esc closes.
///
/// What it lists and what a choice does are `LittleArcOpenInMenu`'s: profile
/// headers, "(Container)", disabled rows for a page that cannot cross
/// sessions, and the line that says why.
struct LittleArcSpacePickerView: View {
    let sections: [LittleArcOpenInMenu.Section]
    /// The space as the store has it, for its icon.
    let space: (Space.ID) -> Space?
    /// The tallest the panel may be in its window.
    var maxHeight: CGFloat = LittleArcSpacePickerView.arcHeight
    let choose: (Space.ID) -> Void
    let close: () -> Void
    /// Renders (tests, pictures) start with these, and take no keyboard.
    var initialQuery = ""
    var initialHighlight: Space.ID? = nil
    var takesFocus = true

    @Environment(\.colorScheme) private var colorScheme
    /// What was typed; nil until something is.
    @State private var typed: String?
    /// The row ↑ ↓ and the pointer moved to; nil until either moves.
    @State private var moved: Space.ID?
    @FocusState private var searchFocused: Bool

    /// Arc's panel is 244 pt wide; a little more keeps "(Container)" on a name.
    static let width: CGFloat = 260
    /// Arc's panel at its tallest: the search row and a little over seven rows.
    static let arcHeight: CGFloat = 396
    static let searchHeight: CGFloat = 46
    static let rowHeight: CGFloat = 46
    static let headerHeight: CGFloat = 26
    static let noteHeight: CGFloat = 40
    static let cornerRadius: CGFloat = 10
    static let tileSide: CGFloat = 26
    /// From the panel's edge to the tile, and to the names.
    static let tileX: CGFloat = 10
    static let textX: CGFloat = 46

    static func height(of row: LittleArcSpacePicker.Row) -> CGFloat {
        switch row {
        case .header: return headerHeight
        case .space, .empty: return rowHeight
        case .note: return noteHeight
        }
    }

    /// The list's height for `rows`, in a panel no taller than `maxHeight`.
    static func listHeight(for rows: [LittleArcSpacePicker.Row], maxHeight: CGFloat) -> CGFloat {
        min(rows.reduce(0) { $0 + height(of: $1) }, max(rowHeight, maxHeight - searchHeight))
    }

    private var dark: Bool { colorScheme == .dark }
    private var query: String { typed ?? initialQuery }

    var body: some View {
        let rows = LittleArcSpacePicker.rows(for: sections, query: query)
        // One highlight, as in a menu: the keys and the pointer both move it.
        let current = LittleArcSpacePicker.highlight(moved ?? initialHighlight, in: rows)
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                searchRow(current: current)
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            rowView(row, highlighted: current).id(row.id)
                        }
                    }
                }
                .frame(height: Self.listHeight(for: rows, maxHeight: maxHeight))
            }
            .frame(width: Self.width)
            .clipShape(shape)
            .background {
                shape.fill(.regularMaterial)
                    .overlay(shape.fill(surface.opacity(0.9)))
                    .shadow(color: .black.opacity(dark ? 0.5 : 0.22), radius: 16, y: 6)
            }
            .overlay(shape.strokeBorder(dark ? Color.white.opacity(0.14) : Color.black.opacity(0.12), lineWidth: 0.5))
            .littleArcPart(.picker)
            .onExitCommand(perform: close)
            .onKeyPress(.upArrow) { move(-1, from: current, in: rows, proxy) }
            .onKeyPress(.downArrow) { move(1, from: current, in: rows, proxy) }
        }
        .onAppear { if takesFocus { focusSearch() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open in another space")
    }

    /// ↑ and ↓: the highlight moves, and the list follows it. Only the keys
    /// scroll the list: a row under the pointer never moves away from it.
    private func move(_ offset: Int, from current: Space.ID?, in rows: [LittleArcSpacePicker.Row], _ proxy: ScrollViewProxy) -> KeyPress.Result {
        moved = LittleArcSpacePicker.highlight(current, movedBy: offset, in: rows)
        if let moved { proxy.scrollTo(LittleArcSpacePicker.Row.id(forSpace: moved)) }
        return .handled
    }

    /// The panel's own colour over the material: near white, or a dark grey.
    private var surface: Color {
        dark ? Color(red: 0.16, green: 0.16, blue: 0.18) : Color(red: 0.985, green: 0.985, blue: 0.995)
    }

    private func searchRow(current: Space.ID?) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: Self.textX, alignment: .center)
            TextField(LittleArcSpacePicker.placeholder, text: Binding(get: { query }, set: { typed = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                // Return chooses the highlighted row. With nothing to choose it does nothing.
                .onSubmit { if let current { choose(current) } }
                .accessibilityLabel("Search spaces")
            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 1, height: 18)
                .padding(.leading, 6)
            Button(action: close) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: Self.searchHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
            .accessibilityLabel("Close")
        }
        .frame(height: Self.searchHeight)
    }

    @ViewBuilder
    private func rowView(_ row: LittleArcSpacePicker.Row, highlighted current: Space.ID?) -> some View {
        switch row {
        case .header(_, let title):
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, Self.tileX + 2)
                .padding(.trailing, 10)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Self.headerHeight)
                .accessibilityAddTraits(.isHeader)
        case .space(let entry):
            spaceRow(entry, isHighlighted: entry.spaceID == current)
        case .note(let text):
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Self.tileX + 2)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Self.noteHeight)
        case .empty(let text):
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: Self.rowHeight)
        }
    }

    private func spaceRow(_ entry: LittleArcOpenInMenu.Entry, isHighlighted: Bool) -> some View {
        Button {
            choose(entry.spaceID)
        } label: {
            HStack(spacing: Self.textX - Self.tileX - Self.tileSide) {
                LittleArcSpaceTile(space: space(entry.spaceID), theme: entry.theme, dark: dark)
                Text(entry.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .opacity(entry.isEnabled ? 1 : 0.4)
            .padding(.leading, Self.tileX)
            .padding(.trailing, 12)
            .frame(height: Self.rowHeight)
            // Arc's highlight runs the panel's whole width.
            .background(Color.primary.opacity(isHighlighted ? (dark ? 0.1 : 0.06) : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!entry.isEnabled)
        .onHover { if $0, entry.isEnabled { moved = entry.spaceID } }
        .help(entry.isEnabled ? "" : LittleArcOpenInMenu.webOnlyMessage)
        .accessibilityLabel(entry.title)
        .accessibilityHint(entry.isEnabled ? "" : LittleArcOpenInMenu.webOnlyMessage)
    }

    /// The search field takes the keyboard as the panel opens. A focused page
    /// keeps it otherwise, as it would keep it from the command bar: ask again
    /// while it does (`ShortcutRouter.reclaimFocusFromPage`).
    private func focusSearch() {
        func take() {
            if let window = NSApp.keyWindow, ShortcutRouter.isWebContent(window.firstResponder) { window.makeFirstResponder(nil) }
            searchFocused = true
        }
        take()
        ShortcutRouter.reclaimFocusFromPage {
            searchFocused = false
            DispatchQueue.main.async { take() }
        }
    }
}

/// A space's icon on its tile: the icon as the sidebar's space switcher draws
/// it (`SpaceIconView`: its picture, its emoji or its symbol), on a small
/// rounded square in a pale tint of the space's colour. A symbol takes the
/// space's colour; a space with no icon of its own shows a dot of it, as Arc does.
struct LittleArcSpaceTile: View {
    let space: Space?
    let theme: SpaceTheme
    let dark: Bool

    var body: some View {
        let ink = LittleArcSpaceTileInk(theme: theme, dark: dark)
        let side = LittleArcSpacePickerView.tileSide
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(ink.fill))
                .shadow(color: .black.opacity(dark ? 0.35 : 0.14), radius: 1.2, y: 0.6)
            if let space, space.hasIcon {
                SpaceIconView(space: space, size: 13)
                    .foregroundStyle(Color(ink.glyph))
            } else {
                Circle().fill(Color(ink.glyph)).frame(width: 8, height: 8)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// Where the parts of a Little Darni window are, in the window's own
/// coordinates from its top leading corner. Nothing in the app reads it: the
/// look tests do, to check that Open in and its ⌄ are in the toolbar, whole,
/// in every state and at every width.
struct LittleArcLayout: PreferenceKey {
    enum Part: String, Sendable {
        case address, openIn, openInChevron, close, picker
    }

    static let space = "littleArcWindow"
    static var defaultValue: [Part: CGRect] { [:] }

    static func reduce(value: inout [Part: CGRect], nextValue: () -> [Part: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    func littleArcPart(_ part: LittleArcLayout.Part) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: LittleArcLayout.self, value: [part: proxy.frame(in: .named(LittleArcLayout.space))])
            }
        }
    }
}
