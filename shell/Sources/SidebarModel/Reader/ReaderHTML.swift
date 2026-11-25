import CryptoKit
import Foundation

/// Writes the reader's page from a sanitised article. Every tag and attribute
/// name in the output is a literal in this file; everything from the page is
/// escaped text or an attribute value `ReaderSanitiser` checked
/// (docs/FEATURE-SPECS/READER-VIEW.md §5).
public enum ReaderHTML {
    /// The page's only stylesheet. Appearance is chosen by attributes on the
    /// root element, so changing it needs no new style text and the policy
    /// below can name this exact sheet by its hash.
    public static let stylesheet = """
    :root{color-scheme:light;--bg:\(ReaderAppearance.backgroundHex(.light));--fg:#1f1f1d;--muted:#6f6f6b;--rule:#e4e4df;--link:#2f5fd0;--wash:#f0f0eb}
    html[data-theme="sepia"]{--bg:\(ReaderAppearance.backgroundHex(.sepia));--fg:#3d3226;--muted:#7d6f5d;--rule:#e2d6bf;--link:#8a4b12;--wash:#ede3cf}
    html[data-theme="dark"]{color-scheme:dark;--bg:\(ReaderAppearance.backgroundHex(.dark));--fg:#e6e6e3;--muted:#98989d;--rule:#38383c;--link:#8ab4ff;--wash:#2a2a2d}
    @media (prefers-color-scheme:dark){html[data-theme="auto"]{color-scheme:dark;--bg:\(ReaderAppearance.backgroundHex(.dark));--fg:#e6e6e3;--muted:#98989d;--rule:#38383c;--link:#8ab4ff;--wash:#2a2a2d}}
    html{background:var(--bg);color:var(--fg);-webkit-text-size-adjust:100%;font-size:18px}
    html[data-size="1"]{font-size:14px}html[data-size="2"]{font-size:16px}html[data-size="3"]{font-size:18px}
    html[data-size="4"]{font-size:20px}html[data-size="5"]{font-size:22px}html[data-size="6"]{font-size:25px}html[data-size="7"]{font-size:28px}
    body{margin:0;padding:64px 32px 120px;font-family:ui-serif,"New York","Iowan Old Style",Charter,Georgia,serif;line-height:1.62;text-rendering:optimizeLegibility;-webkit-font-smoothing:antialiased;overflow-wrap:break-word}
    html[data-font="sans"] body{font-family:-apple-system,"SF Pro Text","Helvetica Neue",Helvetica,Arial,sans-serif;line-height:1.58}
    main{margin:0 auto;max-width:680px}
    html[data-width="narrow"] main{max-width:540px}html[data-width="wide"] main{max-width:860px}
    header{margin:0 0 2.2rem;padding:0 0 1.4rem;border-bottom:1px solid var(--rule)}
    .site{margin:0 0 .9rem;font:600 .68rem/1.3 -apple-system,"SF Pro Text",sans-serif;letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
    h1{margin:0 0 .9rem;font-size:2.05rem;line-height:1.16;letter-spacing:-.012em;font-weight:700}
    .meta{margin:0;font:400 .76rem/1.4 -apple-system,"SF Pro Text",sans-serif;color:var(--muted)}
    .note{margin:1rem 0 0;font:400 .72rem/1.4 -apple-system,"SF Pro Text",sans-serif;color:var(--muted)}
    p{margin:0 0 1.15em}
    h2,h3,h4,h5,h6{margin:2em 0 .6em;line-height:1.24;font-weight:700}
    h2{font-size:1.5rem}h3{font-size:1.24rem}h4,h5,h6{font-size:1.05rem}
    a{color:var(--link);text-decoration:underline;text-decoration-thickness:1px;text-underline-offset:.16em}
    img{display:block;max-width:100%;height:auto;margin:1.6em auto;border-radius:8px}
    figure{margin:1.8em 0}figure img{margin:0 auto}
    figcaption{margin:.7em 0 0;font:400 .76rem/1.45 -apple-system,"SF Pro Text",sans-serif;color:var(--muted);text-align:center}
    figcaption p{margin:0}
    blockquote{margin:1.5em 0;padding:0 0 0 1.1em;border-inline-start:3px solid var(--rule);color:var(--muted)}
    ul,ol{margin:0 0 1.15em;padding-inline-start:1.4em}li{margin:.3em 0}li p{margin:0 0 .5em}
    pre{margin:1.5em 0;padding:14px 16px;border-radius:10px;background:var(--wash);overflow-x:auto;font:400 .78rem/1.5 ui-monospace,"SF Mono",Menlo,monospace;white-space:pre}
    code{font:400 .86em ui-monospace,"SF Mono",Menlo,monospace;background:var(--wash);border-radius:4px;padding:.08em .3em}
    pre code{background:none;padding:0;font-size:1em}
    hr{margin:2.4em auto;border:0;border-top:1px solid var(--rule);width:38%}
    table{margin:1.6em 0;border-collapse:collapse;display:block;max-width:100%;overflow-x:auto;font:400 .82rem/1.45 -apple-system,"SF Pro Text",sans-serif}
    th,td{padding:7px 12px;border:1px solid var(--rule);text-align:start;vertical-align:top}
    th{background:var(--wash);font-weight:600}td p,th p{margin:0}
    ::selection{background:color-mix(in srgb,var(--link) 28%,transparent)}
    """

    /// `'sha256-…'` of `stylesheet`, as a style-src source.
    public static let stylesheetHashSource: String = {
        let digest = SHA256.hash(data: Data(stylesheet.utf8))
        return "'sha256-" + Data(digest).base64EncodedString() + "'"
    }()

    /// The page's policy: nothing loads but images over http(s) (none at all
    /// when images are off), no script, and no style but the one sheet above.
    public static func contentSecurityPolicy(imagesAllowed: Bool) -> String {
        "default-src 'none'; " + (imagesAllowed ? "img-src http: https:; " : "")
            + "style-src \(stylesheetHashSource); base-uri 'none'; form-action 'none'"
    }

    public static func document(for article: ReaderArticle, appearance: ReaderAppearance) -> String {
        var html = "<!doctype html><html"
        if let language = article.language { html += " lang=\"\(escapeAttribute(language))\"" }
        html += " dir=\"\(article.isRightToLeft ? "rtl" : "ltr")\""
        for attribute in appearance.rootAttributes { html += " \(attribute.name)=\"\(escapeAttribute(attribute.value))\"" }
        html += "><head><meta charset=\"utf-8\">"
        html += "<meta http-equiv=\"Content-Security-Policy\" content=\"\(escapeAttribute(contentSecurityPolicy(imagesAllowed: !article.imagesOff)))\">"
        html += "<meta name=\"referrer\" content=\"no-referrer\">"
        html += "<title>\(escapeText(article.title))</title>"
        html += "<style>\(stylesheet)</style></head><body><main><header>"
        html += "<p class=\"site\">\(escapeText(article.siteName))</p>"
        html += "<h1>\(escapeText(article.title))</h1>"
        html += "<p class=\"meta\">\(escapeText(metaLine(for: article)))</p>"
        if let note = imageNote(for: article) { html += "<p class=\"note\">\(escapeText(note))</p>" }
        html += "</header><article>"
        for node in article.body { write(node, to: &html) }
        html += "</article></main></body></html>"
        return html
    }

    /// The article's body alone (tests, and the self-test's check of what was written).
    public static func fragment(for nodes: [ReaderNode]) -> String {
        var html = ""
        for node in nodes { write(node, to: &html) }
        return html
    }

    /// "By Ada Lovelace · 6 min read".
    public static func metaLine(for article: ReaderArticle) -> String {
        let time = "\(article.readingMinutes) min read"
        guard let byline = article.byline, !byline.isEmpty else { return time }
        return "\(byline) · \(time)"
    }

    public static func imageNote(for article: ReaderArticle) -> String? {
        guard article.imagesWithheld > 0 else { return nil }
        if article.imagesOff {
            return "Pictures are not shown in the reader in private windows and containers."
        }
        return article.imagesWithheld == 1
            ? "1 picture is not shown: the page had not loaded it."
            : "\(article.imagesWithheld) pictures are not shown: the page had not loaded them."
    }

    private static func write(_ node: ReaderNode, to html: inout String) {
        switch node {
        case .text(let text):
            html += escapeText(text)
        case .element(let element):
            let name = element.tag.rawValue
            html += "<\(name)"
            switch element.tag {
            case .a:
                if let href = element.href { html += " href=\"\(escapeAttribute(href))\" rel=\"noreferrer noopener\"" }
            case .img:
                if let src = element.src { html += " src=\"\(escapeAttribute(src))\"" }
                html += " alt=\"\(escapeAttribute(element.alt ?? ""))\""
                if let width = element.width { html += " width=\"\(width)\"" }
                if let height = element.height { html += " height=\"\(height)\"" }
                html += " referrerpolicy=\"no-referrer\" decoding=\"async\""
            case .td, .th:
                if let colspan = element.colspan { html += " colspan=\"\(colspan)\"" }
                if let rowspan = element.rowspan { html += " rowspan=\"\(rowspan)\"" }
            case .ol:
                if let start = element.start { html += " start=\"\(start)\"" }
            default:
                break
            }
            html += ">"
            guard !element.tag.isVoid else { return }
            // A parser drops one line break right after <pre>: write one for it to drop.
            if element.tag == .pre { html += "\n" }
            for child in element.children { write(child, to: &html) }
            html += "</\(name)>"
        }
    }

    public static func escapeText(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in ReaderSanitiser.cleanText(text).unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    public static func escapeAttribute(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in ReaderSanitiser.cleanText(text).unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            case "`": result += "&#96;"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
