import Foundation

/// Every element the reader's page can contain. There is no other way to name
/// an element in a `ReaderNode`, so nothing outside this list can be drawn.
public enum ReaderTag: String, CaseIterable, Sendable {
    case p, h1, h2, h3, h4, h5, h6
    case ul, ol, li
    case blockquote, pre, code
    case em, strong, a
    case img, figure, figcaption
    case table, thead, tbody, tr, th, td
    case br, hr

    public var isVoid: Bool { self == .br || self == .hr || self == .img }

    /// Flows inside a line of text.
    public var isInline: Bool {
        switch self {
        case .em, .strong, .a, .code, .br, .img: return true
        default: return false
        }
    }
}

/// One allowed element with the attributes its tag may carry, each already
/// checked: URLs by `ReaderURLPolicy`, numbers as numbers. There is no free
/// attribute name, so no `on…` handler, `style`, `id`, `class` or `srcset` can
/// be stored.
public struct ReaderElement: Equatable, Sendable {
    public var tag: ReaderTag
    /// `a` only: http or https.
    public var href: String?
    /// `img` only: http or https.
    public var src: String?
    /// `img` only.
    public var alt: String?
    /// `img` only, CSS pixels.
    public var width: Int?
    public var height: Int?
    /// `td` and `th` only.
    public var colspan: Int?
    public var rowspan: Int?
    /// `ol` only.
    public var start: Int?
    public var children: [ReaderNode]

    public init(_ tag: ReaderTag, children: [ReaderNode] = []) {
        self.tag = tag
        self.children = children
    }
}

/// The article's body after sanitising: text and allowed elements only.
public indirect enum ReaderNode: Equatable, Sendable {
    case text(String)
    case element(ReaderElement)

    public var isInline: Bool {
        switch self {
        case .text: return true
        case .element(let element): return element.tag.isInline
        }
    }

    /// All text under this node, for the word count.
    public func appendText(to result: inout String) {
        switch self {
        case .text(let text):
            result += text
        case .element(let element):
            for child in element.children { child.appendText(to: &result) }
            if !element.tag.isInline { result += " " }
        }
    }

    /// Every element under this node, itself included (tests and counts).
    public func forEachElement(_ visit: (ReaderElement) -> Void) {
        guard case .element(let element) = self else { return }
        visit(element)
        for child in element.children { child.forEachElement(visit) }
    }
}

/// Which images the reader may show (docs/FEATURE-SPECS/READER-VIEW.md §6).
public enum ReaderImagePolicy: Equatable, Sendable {
    /// Private windows and containers: the reader's own web view is not the
    /// tab's profile, so it loads no image at all.
    case none
    /// Only images the page itself had already loaded, by URL (so the
    /// profile's content blocker has passed each one), larger than 1×1.
    case loadedByPage(Set<String>)
}

/// What the reader shows.
public struct ReaderArticle: Equatable, Sendable {
    public var sourceURL: URL
    public var title: String
    public var byline: String?
    public var siteName: String
    /// BCP 47 tag, letters, digits and hyphens only; nil when the page gave none.
    public var language: String?
    public var isRightToLeft: Bool
    public var wordCount: Int
    public var readingMinutes: Int
    public var body: [ReaderNode]
    public var imagesShown: Int
    /// Images left out by the image policy.
    public var imagesWithheld: Int
    /// The page loads no image at all (`ReaderImagePolicy.none`).
    public var imagesOff: Bool

    public init(sourceURL: URL, title: String, byline: String? = nil, siteName: String, language: String? = nil,
                isRightToLeft: Bool = false, wordCount: Int = 0, readingMinutes: Int = 1, body: [ReaderNode],
                imagesShown: Int = 0, imagesWithheld: Int = 0, imagesOff: Bool = false) {
        self.sourceURL = sourceURL
        self.title = title
        self.byline = byline
        self.siteName = siteName
        self.language = language
        self.isRightToLeft = isRightToLeft
        self.wordCount = wordCount
        self.readingMinutes = readingMinutes
        self.body = body
        self.imagesShown = imagesShown
        self.imagesWithheld = imagesWithheld
        self.imagesOff = imagesOff
    }
}
