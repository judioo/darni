import AppKit
import SwiftUI
import SidebarModel

/// Arc's Emoji / Icon picker: a segmented switch, one search field and the grid,
/// eight to a row with seven rows in view, as Arc's picker lays its icons out. Every
/// icon picker shows it: a space's (new or edited), a profile's and a sidebar item's.
/// It hands back a `SidebarItemIcon`, the symbol-or-emoji type items and profiles keep.
///
/// The emoji are drawn here (`EmojiCatalog`) rather than left to the system's Emoji &
/// Symbols palette: the palette takes the key window, which closes a popover before
/// the emoji arrives (owner's recording, 2026-11-19). An emoji typed or pasted into
/// the search field is offered first, so any emoji can still be used.
struct IconGridPicker: View {
    let symbols: [String]
    let isSelected: (SidebarItemIcon) -> Bool
    let pick: (SidebarItemIcon) -> Void
    @State private var showsEmoji: Bool
    @State private var query = ""

    static let columns = 8
    static let visibleRows = 7
    static let cell: CGFloat = 30
    static let spacing: CGFloat = 6
    /// Seven rows and the six gaps between them: 246 pt.
    static var height: CGFloat { CGFloat(visibleRows) * cell + CGFloat(visibleRows - 1) * spacing }

    init(symbols: [String], startsOnEmoji: Bool = false, isSelected: @escaping (SidebarItemIcon) -> Bool,
         pick: @escaping (SidebarItemIcon) -> Void) {
        self.symbols = symbols
        self.isSelected = isSelected
        self.pick = pick
        _showsEmoji = State(initialValue: startsOnEmoji)
    }

    private let columns = Array(repeating: GridItem(.fixed(Self.cell), spacing: Self.spacing),
                                count: Self.columns)

    var body: some View {
        VStack(spacing: 8) {
            Picker("Icon type", selection: $showsEmoji) {
                Text("Icons").tag(false)
                Text("Emoji").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField(showsEmoji ? "Search emoji, or type one" : "Search icons", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if let first = choices.first { pick(first) } }
            ScrollView {
                LazyVGrid(columns: columns, spacing: Self.spacing) {
                    ForEach(choices, id: \.self) { choice in
                        Button { pick(choice) } label: {
                            label(for: choice)
                                .frame(width: Self.cell, height: Self.cell)
                                .background(isSelected(choice) ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05),
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(help(for: choice))
                        .accessibilityLabel(help(for: choice))
                    }
                }
            }
            .frame(height: Self.height)
            .overlay {
                if choices.isEmpty {
                    Text(showsEmoji ? "No emoji match" : "No icons match").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: CGFloat(Self.columns) * (Self.cell + Self.spacing) + 8)
    }

    private var choices: [SidebarItemIcon] {
        showsEmoji ? Self.emojiChoices(matching: query).map(SidebarItemIcon.emoji)
                   : Self.symbolChoices(matching: query, in: symbols).map { .sfSymbol(name: $0) }
    }

    @ViewBuilder
    private func label(for choice: SidebarItemIcon) -> some View {
        switch choice {
        case .sfSymbol(let name): Image(systemName: name).font(.system(size: 15))
        case .emoji(let text): Text(text).font(.system(size: 20))
        }
    }

    private func help(for choice: SidebarItemIcon) -> String {
        switch choice {
        case .sfSymbol(let name): name
        case .emoji(let text): EmojiCatalog.keywords(for: text) ?? text
        }
    }

    static func emojiChoices(matching query: String) -> [String] {
        EmojiCatalog.matches(query)
    }

    /// The offered symbols matching `query`; a symbol named in full that the picker
    /// does not offer comes first.
    static func symbolChoices(matching query: String, in symbols: [String] = Space.iconChoices) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = symbols.filter { needle.isEmpty || $0.localizedCaseInsensitiveContains(needle) }
        if !needle.isEmpty, !matches.contains(needle), Space.isSymbolName(needle),
           NSImage(systemSymbolName: needle, accessibilityDescription: nil) != nil {
            return [needle] + matches
        }
        return matches
    }
}
