import AppKit
import SwiftUI
import SidebarModel

/// What an icon picker's grid hands back.
enum IconPick: Hashable {
    case symbol(String)
    case emoji(String)
}

/// Arc's Emoji / Icon picker: a segmented switch, one search field and the grid,
/// eight to a row (`SymbolGridPicker`'s metrics). Every icon picker shows it: a
/// space's (new or edited), a profile's and a sidebar item's.
///
/// The emoji are drawn here (`EmojiCatalog`) rather than left to the system's Emoji &
/// Symbols palette: the palette takes the key window, which closes a popover before
/// the emoji arrives (owner's recording, 2026-11-19). An emoji typed or pasted into
/// the search field is offered first, so any emoji can still be used.
struct IconGridPicker: View {
    let symbols: [String]
    let isSelected: (IconPick) -> Bool
    let pick: (IconPick) -> Void
    @State private var showsEmoji: Bool
    @State private var query = ""

    init(symbols: [String], startsOnEmoji: Bool = false, isSelected: @escaping (IconPick) -> Bool, pick: @escaping (IconPick) -> Void) {
        self.symbols = symbols
        self.isSelected = isSelected
        self.pick = pick
        _showsEmoji = State(initialValue: startsOnEmoji)
    }

    private let columns = Array(repeating: GridItem(.fixed(SymbolGridPicker.cell), spacing: SymbolGridPicker.spacing),
                                count: SymbolGridPicker.columns)

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
                LazyVGrid(columns: columns, spacing: SymbolGridPicker.spacing) {
                    ForEach(choices, id: \.self) { choice in
                        Button { pick(choice) } label: {
                            label(for: choice)
                                .frame(width: SymbolGridPicker.cell, height: SymbolGridPicker.cell)
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
            .frame(height: SymbolGridPicker.height)
            .overlay {
                if choices.isEmpty {
                    Text(showsEmoji ? "No emoji match" : "No icons match").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: CGFloat(SymbolGridPicker.columns) * (SymbolGridPicker.cell + SymbolGridPicker.spacing) + 8)
    }

    private var choices: [IconPick] {
        showsEmoji ? Self.emojiChoices(matching: query).map(IconPick.emoji)
                   : Self.symbolChoices(matching: query, in: symbols).map(IconPick.symbol)
    }

    @ViewBuilder
    private func label(for choice: IconPick) -> some View {
        switch choice {
        case .symbol(let name): Image(systemName: name).font(.system(size: 15))
        case .emoji(let text): Text(text).font(.system(size: 20))
        }
    }

    private func help(for choice: IconPick) -> String {
        switch choice {
        case .symbol(let name): name
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
