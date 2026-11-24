import Foundation

/// The only URLs the reader's page may carry (docs/FEATURE-SPECS/READER-VIEW.md §5):
/// http and https, for a link and for an image. Everything else (javascript:,
/// data:, blob:, file:, chrome:, about:, view-source:, mailto:, an extension's
/// or Darni's own schemes) is refused, whatever its spelling. A mailto link
/// would have to leave by a route other than the tab's navigation, so it
/// stays plain text for now.
///
/// The answer is a string this code built: it starts with the literal scheme it
/// was checked for, so the reader's HTML parser cannot read another scheme in it.
public enum ReaderURLPolicy {
    public enum Use: Sendable {
        case link
        case image
    }

    public static let maxLength = 4096

    /// The page a reader can be made from: http or https with a host.
    public static func isReadable(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// `raw` as the page wrote it (entities already decoded by the page's
    /// parser), resolved against the article's URL; nil when it is refused.
    public static func resolve(_ raw: String, base: URL, use: Use) -> String? {
        guard isReadable(base), raw.utf8.count <= maxLength else { return nil }
        // As a browser's URL parser does: tab and newline are removed wherever
        // they are ("jav&#x09;ascript:" is javascript:), and leading or
        // trailing controls and spaces are trimmed.
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars where scalar != "\t" && scalar != "\n" && scalar != "\r" {
            scalars.append(scalar)
        }
        var cleaned = Substring(String(scalars))
        while let first = cleaned.unicodeScalars.first, first.value <= 0x20 { cleaned = cleaned.dropFirst() }
        while let last = cleaned.unicodeScalars.last, last.value <= 0x20 { cleaned = cleaned.dropLast() }
        guard !cleaned.isEmpty else { return nil }
        // Any control left, or a backslash (a browser reads it as a slash, Foundation does not), is refused.
        for scalar in cleaned.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7F || scalar == "\\" {
            return nil
        }
        guard let url = URL(string: String(cleaned), relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased() else { return nil }
        let text = url.absoluteString
        switch scheme {
        case "http", "https":
            guard let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                  text.count > scheme.count + 3,
                  text.prefix(scheme.count + 3).lowercased() == scheme + "://" else { return nil }
            _ = use
            return finish(scheme + "://", text.dropFirst(scheme.count + 3))
        default:
            return nil
        }
    }

    /// The same document as `base`, a fragment apart: such a link cannot work in the reader.
    public static func isSameDocument(_ resolved: String, as base: URL) -> Bool {
        func withoutFragment(_ text: String) -> Substring { text.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0] }
        return withoutFragment(resolved) == withoutFragment(base.absoluteString)
    }

    private static func finish(_ prefix: String, _ rest: Substring) -> String? {
        for scalar in rest.unicodeScalars {
            if scalar.value <= 0x20 || scalar.value == 0x7F { return nil }
            switch scalar {
            case "\"", "'", "<", ">", "`", "\\": return nil
            default: break
            }
        }
        let result = prefix + rest
        return result.utf8.count <= maxLength ? result : nil
    }
}
