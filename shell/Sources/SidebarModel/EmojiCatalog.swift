import Foundation

/// The emoji the icon pickers offer, searchable by name. A short list chosen for
/// spaces and folders comes first, with extra words to find them by ("work",
/// "home"); then every single-character emoji the system knows, faces first, found
/// by its Unicode name ("dog face"). Built from the Unicode data in the OS: nothing
/// is bundled, and a newer macOS brings its new emoji.
///
/// The pickers draw this grid themselves: the system's Emoji & Symbols palette
/// takes the key window, which closes a popover before the emoji arrives.
public enum EmojiCatalog {
    public struct Entry: Hashable, Sendable {
        public let emoji: String
        /// Lowercased words to search: the curated keywords, or the Unicode name.
        public let keywords: String
    }

    static let curated: [(String, String)] = [
        ("😀", "smile happy face"), ("😎", "cool sunglasses face"), ("🥰", "love face"), ("🤔", "thinking face"),
        ("🎉", "party celebration"), ("❤️", "heart love red"), ("⭐️", "star"), ("🔥", "fire"),
        ("🌈", "rainbow"), ("☀️", "sun weather"), ("🌙", "moon night"), ("🌍", "earth world travel globe"),
        ("🌱", "plant seedling"), ("🌸", "flower blossom"), ("🌴", "palm tree holiday"), ("🍀", "clover luck"),
        ("🐶", "dog animal pet"), ("🐱", "cat animal pet"), ("🦊", "fox animal"), ("🐻", "bear animal"),
        ("🍎", "apple food"), ("🍋", "lemon food"), ("☕️", "coffee drink cafe"), ("🍕", "pizza food"),
        ("🏠", "home house"), ("🏖️", "beach holiday vacation"), ("✈️", "plane travel flight"), ("🚀", "rocket launch startup"),
        ("🎨", "art palette design"), ("🎵", "music note"), ("🎮", "game controller gaming"), ("📷", "camera photo"),
        ("📚", "books study school reading"), ("💻", "computer laptop work code"), ("💡", "idea light"), ("🛠️", "tools build"),
        ("✅", "check done tasks"), ("📌", "pin"), ("💎", "diamond"), ("🎯", "target goal focus"),
        ("💼", "briefcase work job business"), ("💰", "money finance bag"), ("📈", "chart growth stocks"), ("🧪", "test lab science"),
    ]

    /// Single-scalar emoji, in this order: faces and people, then the rest of the
    /// pictographs, transport, newer additions, and the older symbol blocks.
    static let scalarRanges: [ClosedRange<UInt32>] = [
        0x1F600...0x1F64F, 0x1F910...0x1F9FF, 0x1F300...0x1F5FF, 0x1F680...0x1F6FF,
        0x1FA70...0x1FAFF, 0x2600...0x27BF, 0x2B00...0x2BFF, 0x1F000...0x1F2FF,
    ]

    public static let all: [Entry] = {
        var seen = Set<String>()
        var entries: [Entry] = []
        for (emoji, words) in curated where seen.insert(emoji.withoutPresentationSelector).inserted {
            entries.append(Entry(emoji: emoji, keywords: words.lowercased() + " " + unicodeName(of: emoji)))
        }
        for range in scalarRanges {
            for value in range {
                guard let scalar = Unicode.Scalar(value), isPickable(scalar) else { continue }
                let emoji = String(scalar)
                guard seen.insert(emoji).inserted else { continue }
                entries.append(Entry(emoji: emoji, keywords: unicodeName(of: emoji)))
            }
        }
        return entries
    }()

    /// The words an emoji is found by (its tooltip in the grid); nil for one not listed.
    public static func keywords(for emoji: String) -> String? {
        keywordsByEmoji[emoji]
    }

    private static let keywordsByEmoji: [String: String] = Dictionary(all.map { ($0.emoji, $0.keywords) }, uniquingKeysWith: { first, _ in first })

    /// Drawn as an emoji on its own (not text that needs a variation selector), not a
    /// skin-tone modifier or a regional indicator letter, and named by this OS's Unicode data.
    static func isPickable(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        return properties.isEmojiPresentation && !properties.isEmojiModifier
            && !(0x1F1E6...0x1F1FF).contains(scalar.value) && properties.name != nil
    }

    static func unicodeName(of emoji: String) -> String {
        emoji.unicodeScalars.compactMap { $0.properties.name?.lowercased() }.joined(separator: " ")
    }

    /// The emoji matching `query` (every word must appear); all of them for an empty
    /// query. An emoji typed or pasted into the search field comes first, so any emoji,
    /// a flag or a skin tone included, can be used.
    public static func matches(_ query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return all.map(\.emoji) }
        let words = needle.lowercased().split(whereSeparator: \.isWhitespace)
        var found = all.filter { entry in words.allSatisfy { entry.keywords.contains($0) } }.map(\.emoji)
        if let typed = typedEmoji(needle) {
            found.removeAll { $0.withoutPresentationSelector == typed.withoutPresentationSelector }
            found.insert(typed, at: 0)
        }
        return found
    }

    /// `text` when it is one emoji character (a ZWJ family, a flag, a skin tone).
    public static func typedEmoji(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1, let first = trimmed.unicodeScalars.first,
              trimmed.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F })
                || (first.properties.isEmoji && first.value > 0x7F) else { return nil }
        return trimmed
    }
}

private extension String {
    var withoutPresentationSelector: String {
        String(String.UnicodeScalarView(unicodeScalars.filter { $0.value != 0xFE0F }))
    }
}
