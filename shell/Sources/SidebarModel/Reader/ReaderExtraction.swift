import Foundation

/// Why a page has no reader.
public enum ReaderExtractionError: Error, Equatable, Sendable {
    /// The page's address is not http(s).
    case notReadable
    /// The script found no article, or what it found had no text.
    case noArticle
    /// The script's answer was not what it must be.
    case malformed
}

/// Which images a tab's reader may show, from the kind of profile it is in.
public enum ReaderImageMode: Equatable, Sendable {
    /// Private windows and containers: none.
    case off
    /// Images the page had already loaded.
    case loadedByPage
}

/// Turns the extraction script's answer (JSON text made in the page, so
/// untrusted) into a `ReaderArticle`. Nothing in the answer is used before it
/// is checked here: the body by `ReaderSanitiser`, the rest as plain text with
/// a length limit (docs/FEATURE-SPECS/READER-VIEW.md §4).
public enum ReaderExtraction {
    public static let maxTitleLength = 300
    public static let maxBylineLength = 200
    public static let maxSiteNameLength = 80
    public static let maxLoadedImages = 2000
    /// Reading speed in words a minute; CJK text is counted by character.
    public static let wordsPerMinute = 230.0
    public static let cjkCharactersPerMinute = 500.0
    /// An "article" shorter than this is not one.
    public static let minimumCharacters = 140

    /// The detection script's answer: `{"article": true}`. Anything else is no.
    public static func looksLikeArticle(json: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return false }
        return flag(object["article"]) == true
    }

    /// A JSON true or false; a number is not one (1 is not "yes").
    static func flag(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    public static func article(json: String, pageURL: URL, images: ReaderImageMode,
                               limits: ReaderSanitiser.Limits = .init()) throws -> ReaderArticle {
        guard ReaderURLPolicy.isReadable(pageURL) else { throw ReaderExtractionError.notReadable }
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let found = flag(object["ok"]) else { throw ReaderExtractionError.malformed }
        guard found else { throw ReaderExtractionError.noArticle }
        guard let content = object["content"] else { throw ReaderExtractionError.malformed }

        let policy: ReaderImagePolicy
        switch images {
        case .off:
            policy = .none
        case .loadedByPage:
            let loaded = (object["loaded"] as? [Any] ?? []).prefix(maxLoadedImages).compactMap { $0 as? String }
            policy = .loadedByPage(Set(loaded.compactMap { ReaderURLPolicy.resolve($0, base: pageURL, use: .image) }))
        }
        var sanitiser = ReaderSanitiser(baseURL: pageURL, images: policy)
        sanitiser.limits = limits
        let output = sanitiser.sanitise(content)

        var text = ""
        for node in output.nodes { node.appendText(to: &text) }
        guard text.unicodeScalars.lazy.filter({ !$0.properties.isWhitespace }).prefix(minimumCharacters).count >= minimumCharacters
        else { throw ReaderExtractionError.noArticle }
        let count = wordCount(of: text)

        let host = displayHost(of: pageURL)
        let direction = (object["dir"] as? String)?.lowercased()
        return ReaderArticle(
            sourceURL: pageURL,
            title: plain(object["title"], limit: maxTitleLength) ?? host,
            byline: plain(object["byline"], limit: maxBylineLength),
            siteName: plain(object["siteName"], limit: maxSiteNameLength) ?? host,
            language: language(object["lang"]),
            isRightToLeft: direction == "rtl",
            wordCount: count.words + count.cjk,
            readingMinutes: readingMinutes(words: count.words, cjkCharacters: count.cjk),
            body: output.nodes,
            imagesShown: output.imagesShown,
            imagesWithheld: output.imagesWithheld,
            imagesOff: images == .off
        )
    }

    // MARK: Parts

    /// One line of plain text: controls gone, white space runs made one space, cut at `limit`.
    public static func plain(_ raw: Any?, limit: Int) -> String? {
        guard let text = raw as? String else { return nil }
        let words = ReaderSanitiser.cleanText(text).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let line = words.joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    /// A language tag of letters, digits and hyphens, else nil.
    public static func language(_ raw: Any?) -> String? {
        guard let text = raw as? String, !text.isEmpty, text.utf8.count <= 35,
              text.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D })
        else { return nil }
        return text
    }

    /// The host as the reader's header names it: no "www.".
    public static func displayHost(of url: URL) -> String {
        let host = url.host ?? ""
        return host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Words parted by white space, and CJK characters, which have none between them.
    public static func wordCount(of text: String) -> (words: Int, cjk: Int) {
        var words = 0
        var cjk = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                cjk += 1
                inWord = false
            } else if scalar.properties.isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
            }
        }
        return (words, cjk)
    }

    /// Whole minutes, never under one.
    public static func readingMinutes(words: Int, cjkCharacters: Int = 0) -> Int {
        let minutes = Double(words) / wordsPerMinute + Double(cjkCharacters) / cjkCharactersPerMinute
        return max(1, Int(minutes.rounded(.up)))
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}
