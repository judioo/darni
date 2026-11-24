import AppKit
import SidebarModel
import SwiftUI

/// The reader button in the address field: there only when the page looks
/// like an article (or its reader is open). It also asks the page, once it
/// has loaded, whether it is one.
struct ReaderAddressButton: View {
    let model: BrowserViewModel
    let tab: Tab?
    let engine: (any WebEngine)?
    var ink: Color = .secondary
    var size: CGFloat = 13

    private struct PageKey: Equatable {
        var tabID: Tab.ID?
        var url: URL?
        var isLoading: Bool
    }

    var body: some View {
        let state = model.readerButtonState(for: tab, engine: engine)
        Group {
            if state != .hidden {
                Button { model.toggleReader(tabID: tab?.id) } label: {
                    Image(systemName: state == .showing ? "doc.plaintext.fill" : "doc.plaintext")
                        .font(.system(size: size, weight: .medium))
                        .foregroundStyle(state == .showing ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(ink))
                        .opacity(state == .opening ? 0.45 : 1)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .addressBarControlFocus()
                .disabled(state == .opening)
                .help(state == .showing ? "Hide Reader (⌥⌘R)" : "Show Reader (⌥⌘R)")
                .accessibilityLabel(state == .showing ? "Hide Reader" : "Show Reader")
                .accessibilityIdentifier("reader-button")
            }
        }
        .task(id: PageKey(tabID: tab?.id, url: engine?.currentURL, isLoading: engine?.isLoading ?? true)) {
            guard let tab, let engine else { return }
            model.detectReaderArticle(for: tab, engine: engine)
        }
    }
}

extension View {
    /// A tab's page with its reader over it while one is open. The page stays
    /// where it is underneath, so leaving the reader shows it as it was left.
    func readerOverlay(_ model: BrowserViewModel, tabID: Tab.ID, engine: any WebEngine) -> some View {
        modifier(ReaderOverlayModifier(model: model, tabID: tabID, engine: engine))
    }
}

private struct ReaderOverlayModifier: ViewModifier {
    let model: BrowserViewModel
    let tabID: Tab.ID
    let engine: any WebEngine

    func body(content: Content) -> some View {
        content
            .overlay {
                if let session = model.reader.session(for: tabID) {
                    ReaderSurface(model: model, session: session)
                        .id(session.id)
                }
            }
            // The tab went somewhere else (a link, Back, a redirect): the reader was that page's.
            .onChange(of: engine.currentURL) { _, url in model.reader.pageChanged(tabID: tabID, url: url) }
    }
}

/// The open reader: the article's page, and Darni's own controls over its top corner.
private struct ReaderSurface: View {
    let model: BrowserViewModel
    let session: ReaderCenter.Session
    @State private var showsSettings = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.addressBarOverlayInset) private var topInset

    var body: some View {
        let appearance = model.reader.appearance
        let palette = ReaderPalette(theme: appearance.theme, isDark: colorScheme == .dark)
        ZStack(alignment: .topTrailing) {
            palette.background
            ReaderPageView(page: session.page)
            HStack(spacing: 2) {
                ReaderChromeButton(symbol: "textformat.size", label: "Reader appearance", palette: palette) {
                    showsSettings.toggle()
                }
                .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
                    ReaderSettingsView(model: model)
                }
                ReaderChromeButton(symbol: "xmark", label: "Hide Reader (⌥⌘R)", palette: palette) {
                    model.closeReader(tabID: session.tabID)
                }
                .accessibilityIdentifier("reader-close")
            }
            .padding(3)
            .background(palette.chrome, in: Capsule())
            .overlay(Capsule().strokeBorder(palette.ink.opacity(0.10)))
            .padding(.top, 12 + topInset)
            .padding(.trailing, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reader: \(session.article.title)")
    }
}

/// The reader's colours outside its page (the page's own are in `ReaderHTML.stylesheet`, the same values).
struct ReaderPalette {
    let background: Color
    let ink: Color
    let chrome: Color

    init(theme: ReaderAppearance.Theme, isDark: Bool) {
        let resolved: ReaderAppearance.Theme = theme == .auto ? (isDark ? .dark : .light) : theme
        switch resolved {
        case .sepia:
            background = Color(.sRGB, red: 0xF6 / 255, green: 0xEF / 255, blue: 0xE0 / 255)
            ink = Color(.sRGB, red: 0x3D / 255, green: 0x32 / 255, blue: 0x26 / 255)
            chrome = Color(.sRGB, red: 0xED / 255, green: 0xE3 / 255, blue: 0xCF / 255)
        case .dark:
            background = Color(.sRGB, red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)
            ink = Color(.sRGB, red: 0xE6 / 255, green: 0xE6 / 255, blue: 0xE3 / 255)
            chrome = Color(.sRGB, red: 0x2A / 255, green: 0x2A / 255, blue: 0x2D / 255)
        default:
            background = Color(.sRGB, red: 0xFB / 255, green: 0xFB / 255, blue: 0xF9 / 255)
            ink = Color(.sRGB, red: 0x1F / 255, green: 0x1F / 255, blue: 0x1D / 255)
            chrome = Color(.sRGB, red: 0xF0 / 255, green: 0xF0 / 255, blue: 0xEB / 255)
        }
    }
}

private struct ReaderChromeButton: View {
    let symbol: String
    let label: String
    let palette: ReaderPalette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.ink.opacity(hovering ? 0.95 : 0.62))
                .frame(width: 28, height: 24)
                .background(palette.ink.opacity(hovering ? 0.08 : 0), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Font, text size, width and theme. Each change is kept and shows at once.
struct ReaderSettingsView: View {
    let model: BrowserViewModel

    var body: some View {
        let appearance = model.reader.appearance
        VStack(alignment: .leading, spacing: 12) {
            row("Font") {
                ReaderChoiceRow(options: ReaderAppearance.Font.allCases, selected: appearance.font, title: \.title) {
                    model.reader.appearance.font = $0
                }
            }
            row("Size") {
                HStack(spacing: 6) {
                    ReaderStepButton(symbol: "textformat.size.smaller", label: "Smaller text", enabled: appearance.canShrink) {
                        model.reader.appearance = appearance.resized(by: -1)
                    }
                    Text("\(appearance.size) of \(ReaderAppearance.sizeRange.upperBound)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    ReaderStepButton(symbol: "textformat.size.larger", label: "Larger text", enabled: appearance.canGrow) {
                        model.reader.appearance = appearance.resized(by: 1)
                    }
                }
            }
            row("Width") {
                ReaderChoiceRow(options: ReaderAppearance.Width.allCases, selected: appearance.width, title: \.title) {
                    model.reader.appearance.width = $0
                }
            }
            row("Theme") {
                ReaderChoiceRow(options: ReaderAppearance.Theme.allCases, selected: appearance.theme, title: \.title) {
                    model.reader.appearance.theme = $0
                }
            }
        }
        .padding(14)
        .frame(width: 286)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            content()
        }
    }
}

/// One choice of several, drawn as Darni draws its own controls (no stock segmented control).
private struct ReaderChoiceRow<Option: Hashable>: View {
    let options: [Option]
    let selected: Option
    let title: KeyPath<Option, String>
    let choose: (Option) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selected
                Button { choose(option) } label: {
                    Text(option[keyPath: title])
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(Color.primary.opacity(isSelected ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ReaderStepButton: View {
    let symbol: String
    let label: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 44, height: 24)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }
}
