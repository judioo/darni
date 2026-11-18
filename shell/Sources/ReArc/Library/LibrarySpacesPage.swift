import SwiftUI
import SidebarModel

/// Kept over the page rather than replacing it: folding Spaces uncovers
/// the same engine view and scroll position.
struct LibrarySpacesOverlay: View {
    let model: BrowserViewModel
    let window: SidebarWindowID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = model.librarySection(in: window) == .spaces
        let edge: Edge = model.sidebarPlacement.side == .left ? .leading : .trailing
        ZStack {
            if shown {
                LibrarySpacesPage(model: model, window: window)
                    .transition(reduceMotion ? .opacity : .move(edge: edge))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(shown)
        .animation(.timingCurve(0.23, 1, 0.32, 1, duration: LibrarySpacesMotion.duration(opening: shown)), value: shown)
    }
}

/// Every space as a card, as in Arc's Spaces page: 240 pt cards 24 pt apart
/// on the window's theme, each with its sidebar, an edit button, and at its
/// foot the move handle and the space menu. Dragging the handle moves the
/// space among its profile's spaces; the cards between make room as it goes.
struct LibrarySpacesPage: View {
    let model: BrowserViewModel
    let window: SidebarWindowID?
    @State private var drag: CardDrag?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The card being dragged by its handle, within its profile.
    struct CardDrag: Equatable {
        var space: Space.ID
        var profile: Profile.ID
        var source: Int
        var count: Int
        var translation: CGFloat

        var destination: Int {
            LibrarySpaceCards.destination(from: source, translation: Double(translation), count: count)
        }
    }

    private static let margin: CGFloat = 24

    /// A card going to its place, and the others making room: a spring, or a
    /// short plain move under Reduce Motion, as the sidebar's own moves have it
    /// (`SidebarMotion.spring(response:reduceMotion:)`).
    private func settle(_ spring: Animation) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : spring
    }

    var body: some View {
        GeometryReader { geometry in
            let groups = LibrarySpaces.groups(in: model.store)
            let cardHeight = max(240, geometry.size.height - 2 * Self.margin)
            ScrollView(.horizontal) {
                HStack(spacing: CGFloat(LibrarySpaceCards.gap)) {
                    ForEach(groups, id: \.profile.id) { group in
                        ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                            card(row, index: index, profile: group.profile.id, count: group.rows.count)
                                .frame(width: CGFloat(LibrarySpaceCards.width), height: cardHeight)
                        }
                        newSpaceButton(profile: group.profile.id)
                            .frame(height: cardHeight)
                    }
                }
                .padding(Self.margin)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollIndicators(.hidden)
        }
        .background(windowBackdrop)
    }

    /// The window's own theme behind the cards, as Arc shows its gradient.
    private var windowBackdrop: some View {
        let theme = model.space(in: window).theme
        return SpaceThemeFill(palette: SpaceThemePalette(
            theme: theme, darkAppearance: theme.appearance.isDark(systemDark: SystemAppearance.isDark(colorScheme))))
    }

    private func card(_ row: LibrarySpaceRow, index: Int, profile: Profile.ID, count: Int) -> some View {
        let dragging = drag?.space == row.id
        let shift = drag.map { $0.profile == profile && !dragging
            ? LibrarySpaceCards.shift(of: index, dragging: $0.source, to: $0.destination) : 0 } ?? 0
        return LibrarySpaceCard(
            model: model, row: row, window: window, isDragged: dragging,
            onDrag: { translation in
                drag = CardDrag(space: row.id, profile: profile, source: index, count: count, translation: translation)
            },
            onDrop: {
                guard let finished = drag else { return }
                withAnimation(settle(.spring(duration: 0.28, bounce: 0.12))) {
                    drag = nil
                    if finished.destination != finished.source { model.moveSpace(finished.space, toIndex: finished.destination) }
                }
            },
            onMove: { offset in
                withAnimation(settle(.spring(duration: 0.28, bounce: 0.12))) { model.moveSpace(row.id, by: offset) }
            }
        )
        .offset(x: dragging ? drag?.translation ?? 0 : CGFloat(shift) * CGFloat(LibrarySpaceCards.stride))
        .zIndex(dragging ? 1 : 0)
        .animation(dragging ? nil : settle(.spring(duration: 0.25, bounce: 0.1)), value: shift)
    }

    private func newSpaceButton(profile: Profile.ID) -> some View {
        Button { model.beginSpaceCreation(profileID: profile) } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("New Space…")
        .accessibilityLabel("New Space")
    }
}

private struct LibrarySpaceCard: View {
    let model: BrowserViewModel
    let row: LibrarySpaceRow
    let window: SidebarWindowID?
    let isDragged: Bool
    /// The handle moved this far along the row since the drag began.
    let onDrag: (CGFloat) -> Void
    let onDrop: () -> Void
    /// VoiceOver and the menu: one place left (-1) or right (+1).
    let onMove: (Int) -> Void
    /// Folders and groups opened or closed here, against the sidebar's own state.
    @State private var toggled: Set<UUID> = []
    @State private var handleHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let space = row.space
        let content = model.store.content(for: space.id)
        let palette = SpaceThemePalette(theme: space.theme,
                                        darkAppearance: space.theme.appearance.isDark(systemDark: SystemAppearance.isDark(colorScheme)))
        let foreground: Color = palette.prefersLightForeground ? .white : .black.opacity(0.8)
        let shape = RoundedRectangle(cornerRadius: CGFloat(LibrarySpaceCards.cornerRadius), style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            header(space)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    entries(model.store.favorites(in: space.profileID).map(SidebarEntry.tab))
                    entries(content.pinned)
                    if !content.pinned.isEmpty || !content.today.isEmpty {
                        Rectangle().fill(foreground.opacity(0.15)).frame(height: 1)
                            .padding(.horizontal, 8).padding(.vertical, 8)
                    }
                    entries(content.today)
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.never)
            Spacer(minLength: 0)
            footer(space, foreground: foreground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(foreground)
        .background(SpaceThemeFill(palette: palette))
        .clipShape(shape)
        .overlay(shape.strokeBorder(foreground.opacity(0.08)))
        .shadow(color: .black.opacity(isDragged ? 0.28 : 0.1), radius: isDragged ? 18 : 6, y: isDragged ? 8 : 2)
        .scaleEffect(isDragged ? 1.02 : 1)
        .contextMenu { SpaceContextMenu(model: model, space: space) }
    }

    private func header(_ space: Space) -> some View {
        HStack(spacing: 8) {
            Button { model.openLibrarySpace(space.id) } label: {
                HStack(spacing: 8) {
                    SpaceIconView(iconName: space.iconName, size: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(space.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(row.profileName).font(.system(size: 10)).opacity(0.6).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if model.space(in: window).id == space.id {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).accessibilityLabel("Current space")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { model.spaceEditorID = space.id } label: {
                Image(systemName: "pencil").font(.system(size: 12, weight: .medium))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(0.6)
            .help("Edit Theme and Icon…")
            .accessibilityLabel("Edit \(space.name)")
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    /// Arc's foot: the move handle on the left, the space menu on the right.
    private func footer(_ space: Space, foreground: Color) -> some View {
        HStack {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background(Circle().fill(foreground.opacity(handleHovered || isDragged ? 0.12 : 0)))
                .contentShape(Rectangle())
                .opacity(0.65)
                .onHover { inside in
                    handleHovered = inside
                    if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { onDrag($0.translation.width) }
                        .onEnded { _ in onDrop() }
                )
                .help("Drag to move this space")
                .accessibilityElement()
                .accessibilityLabel("Move \(space.name)")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: onMove(1)
                    case .decrement: onMove(-1)
                    @unknown default: break
                    }
                }
            Spacer()
            Menu {
                Button("Move Left") { onMove(-1) }
                Button("Move Right") { onMove(1) }
                Divider()
                SpaceContextMenu(model: model, space: space)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(0.65)
            .accessibilityLabel("\(space.name) options")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private func entries(_ entries: [SidebarEntry]) -> some View {
        // As the sidebar has them (Arc shows a closed folder closed); groups open.
        let base = model.store.expandedFolderIDs.union(SidebarTree.tabGroups(entries).map(\.id))
        let expanded = base.symmetricDifference(toggled)
        return ForEach(SidebarRowItem.rows(entries, expanded: expanded, selected: nil)) { item in
            Button { open(item.entry) } label: {
                HStack(spacing: 8) {
                    glyph(item.entry).frame(width: 18, height: 18)
                    Text(title(item.entry))
                        .font(.system(size: 14, weight: item.entry.isFolder || item.entry.isTabGroup ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(item.depth) * 12 + 8)
                .padding(.trailing, 8)
                .frame(height: CGFloat(LibrarySpaceCards.rowHeight))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private func glyph(_ entry: SidebarEntry) -> some View {
        if case .tab(let tab) = entry {
            SiteIconView(image: model.favicon(for: tab), token: tab.faviconToken, customIcon: tab.customIcon)
        } else if case .tabGroup(let reference) = entry {
            Image(systemName: TabGroupMetrics.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(reference.group.color.color(dark: SystemAppearance.isDark(colorScheme)))
        } else {
            SidebarGlyphView(icon: entry.customIcon, fallback: entry.isFolder ? "folder" : "square.split.2x1")
        }
    }

    private func title(_ entry: SidebarEntry) -> String {
        switch entry {
        case .tab(let tab): return tab.displayTitle
        case .folder(let folder): return folder.title
        case .split(let split): return split.displayTitle
        case .easel(let ref): return model.easelTitle(for: ref)
        case .tabGroup(let reference): return reference.group.displayName
        }
    }

    private func open(_ entry: SidebarEntry) {
        if entry.isFolder || entry.isTabGroup {
            if !toggled.insert(entry.id).inserted { toggled.remove(entry.id) }
            return
        }
        model.selectSpace(row.id)
        switch entry {
        case .tab(let tab): model.selectTab(tab.id)
        case .split(let split): model.selectSplit(split.id)
        case .easel(let ref): model.openLibraryDocument(ref.id)
        case .folder, .tabGroup: break
        }
    }
}
