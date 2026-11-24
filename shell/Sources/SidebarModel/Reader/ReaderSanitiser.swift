import Foundation

/// Turns the tree the page gave (untrusted) into `ReaderNode`s: an allowlist
/// over a parsed tree, never a pattern over HTML text
/// (docs/FEATURE-SPECS/READER-VIEW.md §5).
///
/// The input is JSON: a string is text, an object is an element
/// `{"t": local name, "ns": namespace when not HTML, "a": {attribute: value},
/// "c": [children]}`. The page's own HTML parser made the tree (the extraction
/// script walks the DOM), so entities are decoded and there is no markup left
/// to parse here.
///
/// - An element named in `ReaderTag` is kept, with the attributes its tag allows.
/// - An element in `droppedWithContent`, or in any namespace but HTML (SVG,
///   MathML), goes with everything under it.
/// - Any other element is unwrapped: its children are kept, it is not.
public struct ReaderSanitiser {
    public struct Limits: Sendable {
        public var maxNodes = 40_000
        /// Elements nested deeper than this are unwrapped.
        public var maxDepth = 40
        /// Input nested deeper than this is dropped.
        public var maxInputDepth = 300
        public var maxTextBytes = 4 * 1024 * 1024
        public var maxAltBytes = 1024
        public var maxImageCandidates = 24
        public init() {}
    }

    public struct Output: Equatable, Sendable {
        public var nodes: [ReaderNode]
        public var imagesShown: Int
        public var imagesWithheld: Int
        /// A limit cut the article short.
        public var truncated: Bool
    }

    /// Removed with all they contain. Scripts, styles, frames, plug-ins, form
    /// controls, foreign content, document metadata, and the elements whose
    /// content a parser reads as raw text or keeps apart (the mutation-XSS set).
    public static let droppedWithContent: Set<String> = [
        "script", "style", "iframe", "frame", "frameset", "noframes", "object", "embed", "applet", "param",
        "form", "input", "button", "select", "option", "optgroup", "textarea", "datalist", "output", "label",
        "fieldset", "legend", "keygen", "meter", "progress",
        "svg", "math", "link", "meta", "base", "template", "noscript", "noembed", "plaintext", "xmp", "listing",
        "head", "title", "audio", "video", "source", "track", "canvas", "map", "area", "dialog", "slot", "portal",
        "col", "colgroup", "caption", "rp", "rt", "nav", "menu", "marquee", "bgsound", "image", "isindex",
    ]

    /// Unwrapped without a paragraph break around them.
    static let inlineWrappers: Set<String> = [
        "span", "sub", "sup", "u", "s", "strike", "small", "big", "mark", "abbr", "acronym", "cite", "q", "time",
        "font", "kbd", "samp", "var", "dfn", "ins", "del", "bdi", "bdo", "wbr", "data", "ruby", "tt", "nobr", "picture",
    ]

    static let aliases: [String: ReaderTag] = ["b": .strong, "i": .em, "tfoot": .tbody, "h1": .h2]

    public let baseURL: URL
    public let images: ReaderImagePolicy
    public var limits = Limits()

    public init(baseURL: URL, images: ReaderImagePolicy) {
        self.baseURL = baseURL
        self.images = images
    }

    public func sanitise(_ raw: Any?) -> Output {
        let state = State()
        let top: [Piece]
        if let list = raw as? [Any] {
            top = list.flatMap { pieces($0, depth: 0, inputDepth: 0, state: state) }
        } else if let raw {
            top = pieces(raw, depth: 0, inputDepth: 0, state: state)
        } else {
            top = []
        }
        return Output(nodes: paragraphs(top, always: true), imagesShown: state.imagesShown,
                      imagesWithheld: state.imagesWithheld, truncated: state.truncated)
    }

    // MARK: The walk

    private final class State {
        var nodes = 0
        var textBytes = 0
        var imagesShown = 0
        var imagesWithheld = 0
        var truncated = false
    }

    /// A kept node, or the edge of an unwrapped block (a `div`, a `section`).
    private enum Piece {
        case node(ReaderNode)
        case blockBreak
    }

    private func pieces(_ raw: Any, depth: Int, inputDepth: Int, state: State) -> [Piece] {
        if state.nodes >= limits.maxNodes {
            state.truncated = true
            return []
        }
        if let text = raw as? String {
            let cleaned = Self.cleanText(text)
            guard !cleaned.isEmpty else { return [] }
            guard state.textBytes + cleaned.utf8.count <= limits.maxTextBytes else {
                state.truncated = true
                return []
            }
            state.textBytes += cleaned.utf8.count
            state.nodes += 1
            return [.node(.text(cleaned))]
        }
        guard let element = raw as? [String: Any], let name = element["t"] as? String else { return [] }
        guard inputDepth < limits.maxInputDepth else {
            state.truncated = true
            return []
        }
        // Foreign content (SVG, MathML, anything not HTML) goes whole.
        if let namespace = element["ns"], !(namespace is NSNull) { return [] }
        if Self.droppedWithContent.contains(name) { return [] }
        let attributes = element["a"] as? [String: Any] ?? [:]
        let rawChildren = element["c"] as? [Any] ?? []
        func children(at depth: Int) -> [Piece] {
            rawChildren.flatMap { pieces($0, depth: depth, inputDepth: inputDepth + 1, state: state) }
        }
        guard let tag = Self.aliases[name] ?? ReaderTag(rawValue: name), depth < limits.maxDepth else {
            // Not on the list (or too deep): the element goes, its children stay.
            let inner = children(at: depth)
            return Self.inlineWrappers.contains(name) ? inner : [.blockBreak] + inner + [.blockBreak]
        }
        state.nodes += 1
        var result = ReaderElement(tag)
        switch tag {
        case .br, .hr:
            break
        case .img:
            guard let image = image(attributes, shown: element["cs"] as? String, state: state) else { return [] }
            result = image
        case .a:
            let inner = children(at: depth + 1)
            guard let raw = attributes["href"] as? String,
                  let href = ReaderURLPolicy.resolve(raw, base: baseURL, use: .link),
                  !ReaderURLPolicy.isSameDocument(href, as: baseURL) else { return inner }
            result.href = href
            result.children = inline(inner, breakText: " ")
        case .p, .h1, .h2, .h3, .h4, .h5, .h6, .em, .strong, .code:
            result.children = inline(children(at: depth + 1), breakText: " ")
        case .pre:
            result.children = inline(children(at: depth + 1), breakText: "\n")
        case .blockquote:
            result.children = paragraphs(children(at: depth + 1), always: true)
        case .li, .figure, .figcaption:
            result.children = paragraphs(children(at: depth + 1), always: false)
        case .td, .th:
            result.children = paragraphs(children(at: depth + 1), always: false)
            result.colspan = Self.integer(attributes["colspan"], in: 2...100)
            result.rowspan = Self.integer(attributes["rowspan"], in: 2...1000)
        case .ul, .ol:
            result.children = listItems(children(at: depth + 1))
            if tag == .ol { result.start = Self.integer(attributes["start"], in: -100_000...100_000) }
        case .table:
            result.children = only(children(at: depth + 1), [.thead, .tbody, .tr])
        case .thead, .tbody:
            result.children = only(children(at: depth + 1), [.tr])
        case .tr:
            result.children = only(children(at: depth + 1), [.td, .th])
        }
        if result.children.isEmpty, !tag.isVoid, tag != .td, tag != .th { return [] }
        return [.node(.element(result))]
    }

    /// `shown` is the URL the page showed for this image (its `currentSrc`,
    /// which a `<picture>`'s `<source>` may have chosen): the first candidate,
    /// checked as every other one is. `<source>` itself is never written out.
    private func image(_ attributes: [String: Any], shown: String?, state: State) -> ReaderElement? {
        var candidates: [String] = []
        if let shown { candidates.append(shown) }
        if let src = attributes["src"] as? String { candidates.append(src) }
        // srcset is never written out. Its URLs are only further candidates,
        // each checked as `src` is.
        if let srcset = attributes["srcset"] as? String { candidates += Self.srcsetURLs(srcset) }
        let allowed = candidates.prefix(limits.maxImageCandidates)
            .compactMap { ReaderURLPolicy.resolve($0, base: baseURL, use: .image) }
        guard !allowed.isEmpty else { return nil }
        guard case .loadedByPage(let loaded) = images, let src = allowed.first(where: loaded.contains) else {
            state.imagesWithheld += 1
            return nil
        }
        state.imagesShown += 1
        var image = ReaderElement(.img)
        image.src = src
        if let alt = attributes["alt"] as? String {
            let cleaned = Self.cleanText(alt)
            image.alt = String(cleaned.prefix(limits.maxAltBytes))
        }
        image.width = Self.integer(attributes["width"], in: 1...20_000)
        image.height = Self.integer(attributes["height"], in: 1...20_000)
        return image
    }

    // MARK: Structure

    /// Block content: runs of text and inline elements become paragraphs.
    /// `always` is false where a line of text may stand by itself (a list
    /// item, a table cell): then only content split by blocks is wrapped.
    private func paragraphs(_ pieces: [Piece], always: Bool) -> [ReaderNode] {
        let pieces = pieces.flatMap(Self.withoutStrayTableParts)
        let hasBlocks = pieces.contains {
            if case .node(let node) = $0 { return !node.isInline }
            return true
        }
        guard always || hasBlocks else { return Self.trimmed(pieces.compactMap(Self.node)) }
        var result: [ReaderNode] = []
        var run: [ReaderNode] = []
        func flush() {
            let line = Self.trimmed(run)
            run = []
            guard !line.isEmpty else { return }
            result.append(.element(ReaderElement(.p, children: line)))
        }
        for piece in pieces {
            switch piece {
            case .blockBreak:
                flush()
            case .node(let node) where node.isInline:
                run.append(node)
            case .node(let node):
                flush()
                result.append(node)
            }
        }
        flush()
        return result
    }

    /// Text-level content: an unwrapped block's edge is a space (a line break
    /// in `pre`), and a block element gives only its text-level content.
    private func inline(_ pieces: [Piece], breakText: String) -> [ReaderNode] {
        var result: [ReaderNode] = []
        for piece in pieces {
            switch piece {
            case .blockBreak:
                if !result.isEmpty { result.append(.text(breakText)) }
            case .node(let node):
                result += Self.flattened(node, breakText: breakText)
            }
        }
        // Spaces at the ends stay: they part the words on either side of an inline element.
        return Self.isBlank(result) ? [] : result
    }

    /// A list holds items only: anything else with content becomes one.
    private func listItems(_ pieces: [Piece]) -> [ReaderNode] {
        var result: [ReaderNode] = []
        var stray: [Piece] = []
        func flush() {
            let content = paragraphs(stray, always: false)
            stray = []
            guard !content.isEmpty else { return }
            result.append(.element(ReaderElement(.li, children: content)))
        }
        for piece in pieces {
            if case .node(.element(let element)) = piece, element.tag == .li {
                flush()
                result.append(.element(element))
            } else {
                stray.append(piece)
            }
        }
        flush()
        return result
    }

    private func only(_ pieces: [Piece], _ tags: Set<ReaderTag>) -> [ReaderNode] {
        pieces.compactMap {
            guard case .node(.element(let element)) = $0, tags.contains(element.tag) else { return nil }
            return .element(element)
        }
    }

    private static func node(_ piece: Piece) -> ReaderNode? {
        if case .node(let node) = piece { return node }
        return nil
    }

    /// A row or a cell outside a table gives its content only.
    private static func withoutStrayTableParts(_ piece: Piece) -> [Piece] {
        guard case .node(.element(let element)) = piece else { return [piece] }
        switch element.tag {
        case .thead, .tbody, .tr, .td, .th:
            return [.blockBreak] + element.children.map { Piece.node($0) }.flatMap(withoutStrayTableParts) + [.blockBreak]
        default:
            return [piece]
        }
    }

    private static func flattened(_ node: ReaderNode, breakText: String) -> [ReaderNode] {
        guard case .element(let element) = node, !element.tag.isInline else { return [node] }
        if element.tag == .hr { return [] }
        return [.text(breakText)] + element.children.flatMap { flattened($0, breakText: breakText) } + [.text(breakText)]
    }

    private static func isBlank(_ node: ReaderNode) -> Bool {
        switch node {
        case .text(let text): return text.allSatisfy(\.isWhitespace)
        case .element(let element): return element.tag == .br
        }
    }

    private static func isBlank(_ nodes: [ReaderNode]) -> Bool { nodes.allSatisfy(isBlank) }

    /// Without leading and trailing white space and line breaks; empty when nothing else is left.
    private static func trimmed(_ nodes: [ReaderNode]) -> [ReaderNode] {
        var slice = nodes[...]
        while let first = slice.first, isBlank(first) { slice = slice.dropFirst() }
        while let last = slice.last, isBlank(last) { slice = slice.dropLast() }
        return Array(slice)
    }

    // MARK: Values

    /// Without NUL and the other controls a parser treats specially; tab and line breaks stay.
    static func cleanText(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isStripped) else { return text }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !isStripped(scalar) { scalars.append(scalar) }
        return String(scalars)
    }

    private static func isStripped(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0D: return false
        case 0x00...0x1F, 0x7F, 0xFFFE, 0xFFFF: return true
        default: return false
        }
    }

    /// A whole decimal number in `range`, else nil. No sign but for a range that goes below zero.
    static func integer(_ raw: Any?, in range: ClosedRange<Int>) -> Int? {
        guard let text = raw as? String, !text.isEmpty, text.utf8.count <= 7 else { return nil }
        let digits = range.lowerBound < 0 && text.hasPrefix("-") ? text.dropFirst() : text[...]
        guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let value = Int(text), range.contains(value) else { return nil }
        return value
    }

    /// The URLs of a `srcset`: its tokens but the width and density descriptors.
    static func srcsetURLs(_ srcset: String) -> [String] {
        srcset.split(whereSeparator: \.isWhitespace).compactMap { token in
            let url = token.trimmingCharacters(in: CharacterSet(charactersIn: ","))
            guard !url.isEmpty else { return nil }
            if let last = url.last, "wxh".contains(last), Double(url.dropLast()) != nil { return nil }
            return url
        }
    }
}
