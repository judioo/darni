import SwiftUI
import SidebarModel

// Tab groups in the sidebar (Chrome's, docs/briefs/2026-11-17-chrome-features.md):
// the group's row, its editor, and its menus. A group does not look like a
// folder: its row is filled with the group's colour and carries a stack
// glyph, and its tabs have a bar in that colour beside them
// (`SidebarPlainRowCell`).

enum TabGroupMetrics {
    /// A stack of cards, not a folder.
    static let symbol = "square.stack.3d.up.fill"
    /// The coloured header inside the row's pitch.
    static let headerHeight: CGFloat = 30
    /// The bar beside a group's tabs.
    static let barWidth: CGFloat = 3
    /// The bar's centre, from the left edge of the group's own row highlight.
    static let barInset: CGFloat = 7
    static let dotSize: CGFloat = 18
    static let editorWidth: CGFloat = 250
    /// The group's tile in the mini sidebar.
    static let miniTile: CGFloat = SidebarMetrics.iconSize + 8
}

extension TabGroupColor {
    /// The colour on a sidebar of the given appearance.
    func color(dark: Bool) -> Color { Color(fill(dark: dark)) }

    /// The name and glyph on a header of this colour.
    func ink(dark: Bool) -> Color { inkIsDark(dark: dark) ? Color.black.opacity(0.85) : .white }
}

/// A tab group's row: a header in the group's colour with the stack glyph,
/// its name (or its tab count while unnamed) and a chevron. A click opens
/// and closes it, as in Chrome; the editor is in its menu.
struct TabGroupRowView<Menu: View>: View {
    let name: String
    let color: TabGroupColor
    let tabCount: Int
    let isExpanded: Bool
    let isDropTarget: Bool
    let onToggle: () -> Void
    /// New Tab in Group, on hover.
    var onNewTab: (() -> Void)? = nil
    @ViewBuilder let menu: () -> Menu

    @State private var isHovering = false
    @Environment(\.themeChrome) private var chrome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ink = color.ink(dark: chrome.isDark)
        HStack(spacing: SidebarMetrics.iconToText) {
            Image(systemName: TabGroupMetrics.symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: SidebarMetrics.iconSize, height: SidebarMetrics.iconSize)
            Text(name)
                .font(.system(size: SidebarMetrics.titleSize, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            if isHovering, let onNewTab {
                Button(action: onNewTab) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Tab in Group")
                .accessibilityLabel("New Tab in Group")
            } else if !isExpanded {
                Text("\(tabCount)")
                    .font(.system(size: SidebarMetrics.subtitleSize, weight: .semibold))
                    .opacity(0.8)
                    .accessibilityHidden(true)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)
                .accessibilityHidden(true)
        }
        .foregroundStyle(ink)
        .padding(.leading, SidebarMetrics.iconLeading)
        .padding(.trailing, 8)
        .frame(height: TabGroupMetrics.headerHeight)
        .background(color.color(dark: chrome.isDark).opacity(isHovering ? 0.88 : 1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .padding(.vertical, (SidebarMetrics.rowPitch - TabGroupMetrics.headerHeight) / 2)
        .gesture(TapGesture().onEnded {
            SidebarListController.toggleDisclosure(isExpanded: isExpanded, reduceMotion: reduceMotion, onToggle)
        })
        .onHover { isHovering = $0 }
        .contextMenu { menu() }
        .help("\(name), \(TabGroup.countText(tabCount))")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tab group \(name), \(TabGroup.countText(tabCount))")
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    }
}

/// A group's name field ("Name this group") and its nine colour dots, as
/// Chrome's editor has them, then the group's commands. A change applies as
/// it is made, in every space that shows the group.
struct TabGroupEditorView: View {
    let model: BrowserViewModel
    let groupID: TabGroup.ID
    /// The group's row in this space, when the editor opened from one.
    var referenceID: UUID?
    let onClose: () -> Void

    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let group = model.store.tabGroup(withID: groupID)
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name this group", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(onClose)
                .onChange(of: name) { _, text in model.store.renameTabGroup(groupID, to: text) }
                .accessibilityLabel("Group name")
            HStack(spacing: 0) {
                ForEach(TabGroupColor.allCases, id: \.self) { color in
                    TabGroupColorDot(color: color, isChosen: group?.color == color, dark: colorScheme == .dark) {
                        model.store.setTabGroupColor(color, for: groupID)
                    }
                    if color != TabGroupColor.allCases.last { Spacer(minLength: 0) }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                if let referenceID {
                    command("New Tab in Group", "plus") { model.newTab(inGroup: groupID) }
                    command("Remove from This Space", "rectangle.badge.minus") { model.removeTabGroupFromSpace(referenceID) }
                } else {
                    command("Add to This Space", "plus.rectangle") { model.addTabGroupToActiveSpace(groupID) }
                }
                Divider().padding(.vertical, 4)
                command("Ungroup", "square.stack.3d.up.slash") { model.ungroupTabGroup(groupID) }
                command("Delete Group", "trash") { model.requestTabGroupDeletion(groupID) }
            }
        }
        .padding(12)
        .frame(width: TabGroupMetrics.editorWidth)
        .onAppear {
            name = group?.name ?? ""
            // Once the popover's window is up; asked for at once, the field can miss the keyboard.
            DispatchQueue.main.async { nameFocused = true }
        }
        .onExitCommand(perform: onClose)
    }

    private func command(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        TabGroupEditorCommand(title: title, symbol: symbol) {
            onClose()
            action()
        }
    }
}

private struct TabGroupEditorCommand: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(Color.primary.opacity(isHovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct TabGroupColorDot: View {
    let color: TabGroupColor
    let isChosen: Bool
    let dark: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color.color(dark: dark))
                .frame(width: TabGroupMetrics.dotSize, height: TabGroupMetrics.dotSize)
                .padding(3)
                .overlay { if isChosen { Circle().strokeBorder(color.color(dark: dark), lineWidth: 2) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(color.title)
        .accessibilityLabel(color.title)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }
}

/// The editor under (or beside) the row it was asked from. The popover waits
/// for the row to be in the window: a new group's row is still arriving when
/// its editor is asked for (as `ItemIconPopover` waits).
struct TabGroupEditorPopover: ViewModifier {
    let model: BrowserViewModel
    let anchorID: UUID
    var referenceID: UUID?
    var arrowEdge: Edge = .trailing
    @State private var anchor: NSView?

    func body(content: Content) -> some View {
        let request = model.tabGroupEditor.flatMap { $0.anchorID == anchorID ? $0 : nil }
        content
            .background { if request != nil { AnchorReader { anchor = $0 } } }
            .popover(isPresented: Binding(
                get: { request != nil && anchor != nil },
                set: { if !$0 { close() } }
            ), arrowEdge: arrowEdge) {
                if let request {
                    TabGroupEditorView(model: model, groupID: request.groupID, referenceID: referenceID, onClose: close)
                }
            }
            .onChange(of: request != nil) { _, now in if !now { anchor = nil } }
    }

    private func close() {
        if model.tabGroupEditor?.anchorID == anchorID { model.tabGroupEditor = nil }
    }
}

// MARK: - Menus

/// Colour ▸: the nine colours, the group's own ticked.
struct TabGroupColorMenu: View {
    let model: BrowserViewModel
    let group: TabGroup

    var body: some View {
        Menu("Colour") {
            ForEach(TabGroupColor.allCases, id: \.self) { color in
                Toggle(color.title, isOn: Binding(
                    get: { group.color == color },
                    set: { if $0 { model.store.setTabGroupColor(color, for: group.id) } }
                ))
            }
        }
    }
}

/// The menu of a group's row in a space: name, colour, New Tab in Group,
/// Remove from This Space, Ungroup, Delete Group.
struct TabGroupContextMenu: View {
    let model: BrowserViewModel
    let reference: TabGroupReference

    var body: some View {
        let store = model.store
        let group = reference.group
        let expanded = store.isTabGroupExpanded(reference.id)
        Button("Rename Group…") { model.editTabGroup(group.id, from: reference.id) }
        TabGroupColorMenu(model: model, group: group)
        Divider()
        Button("New Tab in Group") { model.newTab(inGroup: group.id) }
        if case .section(let spaceID, let section) = store.parent(of: reference.id) {
            Button(section == .pinned ? "Unpin Group" : "Pin Group") {
                let target: ItemContainerKind.SpaceSection = section == .pinned ? .unpinned : .pinned
                let index = target == .pinned ? store.content(for: spaceID).pinned.count : 0
                model.moveItem(reference.id, to: .section(spaceID: spaceID, section: target), index: index)
            }
        }
        Button(expanded ? "Collapse Group" : "Expand Group") { store.setTabGroupExpanded(reference.id, !expanded) }
        Divider()
        Button("Remove from This Space") { model.removeTabGroupFromSpace(reference.id) }
            .help("The group and its tabs stay in the other spaces that show it, and in the ⌘T bar")
        Button("Ungroup") { model.ungroupTabGroup(group.id) }
        Button("Delete Group…", role: .destructive) { model.requestTabGroupDeletion(group.id) }
    }
}

/// The menu of a group in the command bar (a group the space on screen does
/// not show): add it, name it, colour it, ungroup it here, delete it.
struct TabGroupCommandBarMenu: View {
    let model: BrowserViewModel
    let groupID: TabGroup.ID

    var body: some View {
        if let group = model.store.tabGroup(withID: groupID) {
            Button("Add to This Space") { model.addTabGroupToActiveSpace(groupID) }
            Divider()
            Button("Rename Group…") { model.editTabGroup(groupID, from: groupID) }
            TabGroupColorMenu(model: model, group: group)
            Divider()
            Button("Ungroup") {
                model.dismissCommandBar()
                model.ungroupTabGroup(groupID)
            }
            .help("Its tabs become plain tabs in this space")
            Button("Delete Group…", role: .destructive) { model.requestTabGroupDeletion(groupID) }
        }
    }
}

/// A tab's group items: Add Tab to New Group, Add Tab to Group ▸, and for a
/// tab already in a group, Remove from Group. While Settings › General › Tab
/// groups is off only Remove from Group shows, for groups made earlier.
struct TabGroupTabMenuItems: View {
    let model: BrowserViewModel
    let tabID: Tab.ID
    @Environment(\.sidebarWindow) private var window

    var body: some View {
        let store = model.store
        let own = store.tabGroupID(holding: tabID)
        if model.tabGroupsEnabled {
            Button("Add Tab to New Group") {
                model.newTabGroup(in: store.spaceContaining(tabID: tabID) ?? model.space(in: window).id, containing: [tabID])
            }
            let groups = store.tabGroupsAccepting(tabID)
            if !groups.isEmpty {
                Menu("Add Tab to Group") {
                    ForEach(groups) { group in
                        Button(group.displayName) { model.addTab(tabID, toGroup: group.id) }
                    }
                }
            }
        }
        if own != nil {
            Button("Remove from Group") { model.removeTabFromGroup(tabID, in: window) }
        }
    }
}

/// New Tab Group, on the "+ New Tab" row and on the sidebar's blank space.
struct NewTabGroupMenuItem: View {
    let model: BrowserViewModel
    let spaceID: Space.ID

    var body: some View {
        if model.tabGroupsEnabled {
            Button("New Tab Group") { model.newTabGroup(in: spaceID) }
        }
    }
}
