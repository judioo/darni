import SwiftUI
import SidebarModel

/// The Ctrl+Tab switcher (Arc `ModalItemSwitcher`): recent tabs, most
/// recent first, as a row of page thumbnails in the middle of the window.
/// The highlighted one is picked when Control is released. Tab and
/// Shift+Tab move, Escape cancels, a click picks.
struct TabSwitcherOverlay: View {
    let session: TabSwitcherSession
    /// The space on show: its colour tints the highlighted card.
    let theme: SpaceTheme
    let favicon: (TabSwitcherItem) -> NSImage?
    let thumbnail: (TabSwitcherItem) -> NSImage?
    let onSelect: (Tab.ID) -> Void

    @Environment(\.themeChrome) private var chrome
    /// Where the strip was, so a step moves it as little as it can.
    @State private var stripStart = 0

    var body: some View {
        GeometryReader { geometry in
            let layout = TabSwitcherLayout(itemCount: session.items.count, availableWidth: geometry.size.width)
            let first = layout.firstVisible(showing: session.index, from: stripStart)
            TabSwitcherPanel(session: session, layout: layout, first: first, theme: theme, dark: chrome.isWindowDark,
                             favicon: favicon, thumbnail: thumbnail, onSelect: onSelect)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: first, initial: true) { _, new in stripStart = new }
        }
        // Centred on the window, as Arc's is, not on the area under the title bar.
        .ignoresSafeArea()
    }
}

/// The switcher's panel: Darni's floating card (the command bar's surface)
/// around a strip of cards. More tabs than fit slide under the panel's
/// edges; a chevron marks each side that has more.
struct TabSwitcherPanel: View {
    let session: TabSwitcherSession
    let layout: TabSwitcherLayout
    /// The first card on show (`TabSwitcherLayout.firstVisible`).
    let first: Int
    let theme: SpaceTheme
    let dark: Bool
    let favicon: (TabSwitcherItem) -> NSImage?
    let thumbnail: (TabSwitcherItem) -> NSImage?
    let onSelect: (Tab.ID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let cornerRadius: CGFloat = 20

    var body: some View {
        let shown = first ..< first + layout.visibleCount
        let ink = TabSwitcherCard.Ink(theme: theme, dark: dark)
        HStack(spacing: 0) {
            ForEach(Array(session.items.enumerated()), id: \.element.id) { index, item in
                TabSwitcherCard(item: item, isHighlighted: index == session.index, layout: layout, ink: ink, dark: dark,
                                favicon: favicon(item), thumbnail: thumbnail(item))
                    .onTapGesture { onSelect(item.id) }
                    .allowsHitTesting(shown.contains(index))
                    .accessibilityHidden(!shown.contains(index))
            }
        }
        .offset(x: -CGFloat(first) * layout.cellWidth)
        .frame(width: layout.stripWidth, height: layout.cellHeight, alignment: .leading)
        .clipped()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: first)
        .padding(TabSwitcherLayout.panelPadding)
        .overlay(alignment: .leading) { moreMark("chevron.compact.left", count: layout.hiddenBefore(first: first)) }
        .overlay(alignment: .trailing) { moreMark("chevron.compact.right", count: layout.hiddenAfter(first: first)) }
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Color(TabSwitcherInk.surface(dark: dark)))
                .shadow(color: .black.opacity(dark ? 0.55 : 0.3), radius: 28, y: 12)
        }
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.black.opacity(dark ? 0.6 : 0.25), lineWidth: 1)
        )
        // The card is light or dark with the space, whatever the system is.
        .environment(\.colorScheme, dark ? .dark : .light)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab switcher")
    }

    @ViewBuilder
    private func moreMark(_ symbol: String, count: Int) -> some View {
        if count > 0 {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(CommandBarInk.glyph(dark: dark)))
                .frame(width: TabSwitcherLayout.panelPadding)
                .accessibilityLabel("\(count) more")
        }
    }
}

/// One tab: its page's thumbnail over its favicon and title. A tab that
/// was never shown has no thumbnail yet and shows its favicon, large, on a
/// pale wash of the space's colour.
private struct TabSwitcherCard: View {
    struct Ink {
        let selection: Color
        let placeholder: Color
        let title: Color
        let selectedTitle: Color

        init(theme: SpaceTheme, dark: Bool) {
            selection = Color(TabSwitcherInk.selection(theme: theme, dark: dark))
            placeholder = Color(TabSwitcherInk.placeholder(theme: theme, dark: dark))
            title = Color(TabSwitcherInk.title(dark: dark))
            selectedTitle = Color(TabSwitcherInk.selectedTitle(theme: theme, dark: dark))
        }
    }

    let item: TabSwitcherItem
    let isHighlighted: Bool
    let layout: TabSwitcherLayout
    let ink: Ink
    let dark: Bool
    let favicon: NSImage?
    let thumbnail: NSImage?

    private static let thumbnailRadius: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: TabSwitcherLayout.titleGap) {
            picture
                .frame(width: layout.thumbnailWidth, height: layout.thumbnailHeight, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: Self.thumbnailRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Self.thumbnailRadius, style: .continuous)
                        .strokeBorder(Color.black.opacity(dark ? 0.4 : 0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(dark ? 0.45 : 0.18), radius: 5, y: 2)
            HStack(spacing: 7) {
                SiteIconView(image: favicon, token: token, size: 14)
                    .frame(width: 16, height: 16)
                Text(item.title)
                    .font(.system(size: 13, weight: isHighlighted ? .bold : .medium))
                    .foregroundStyle(isHighlighted ? ink.selectedTitle : ink.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(height: TabSwitcherLayout.titleHeight)
        }
        .padding(TabSwitcherLayout.thumbnailInset)
        .frame(width: layout.cellWidth, height: layout.cellHeight, alignment: .topLeading)
        .background(isHighlighted ? ink.selection : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.title, item.spaceName, item.url.host()].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }

    private var token: String { Tab.makeFaviconToken(for: item.url) }

    @ViewBuilder
    private var picture: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                ink.placeholder
                SiteIconView(image: favicon, token: token, size: 32)
            }
            .frame(width: layout.thumbnailWidth, height: layout.thumbnailHeight)
        }
    }
}
