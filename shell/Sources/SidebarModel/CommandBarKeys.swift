import Foundation

/// The ⌘T bar's Tab Groups as chips that run across the bar and wrap, as
/// Chrome's group chips run across its bar: which chip is on which line for
/// a given width, how tall the section is, and where the arrow keys go.
///
/// The view measures each chip's natural width (its name and tab count) and
/// draws what this says, so the bar's height is known before it is drawn.
public struct TabGroupChipLayout: Equatable, Sendable {
    public struct Metrics: Equatable, Sendable {
        public var chipHeight = 26.0
        /// Between two chips on a line.
        public var spacing = 6.0
        public var lineSpacing = 6.0
        /// Lines shown before the section scrolls inside itself.
        public var maxVisibleLines = 3
        /// A longer name is cut short in its chip.
        public var maxChipWidth = 220.0

        public init() {}
    }

    public struct Chip: Equatable, Sendable {
        public var line: Int
        public var x: Double
        public var width: Double
    }

    public enum Direction: Equatable, Sendable { case left, right, up, down }

    /// One per width given, in the same order.
    public let chips: [Chip]
    public let lineCount: Int
    public let metrics: Metrics

    /// Chips flow left to right and wrap when the next one does not fit in
    /// `available`. A chip is never wider than `maxChipWidth` or the line.
    public init(widths: [Double], available: Double, metrics: Metrics = Metrics()) {
        self.metrics = metrics
        let limit = max(1, min(metrics.maxChipWidth, available))
        var chips: [Chip] = []
        var line = 0
        var x = 0.0
        for natural in widths {
            let width = min(max(natural, 1), limit)
            if x > 0, x + width > available {
                line += 1
                x = 0
            }
            chips.append(Chip(line: line, x: x, width: width))
            x += width + metrics.spacing
        }
        self.chips = chips
        lineCount = chips.isEmpty ? 0 : line + 1
    }

    /// The chips' indexes line by line.
    public var lines: [[Int]] {
        var lines = [[Int]](repeating: [], count: lineCount)
        for (index, chip) in chips.enumerated() { lines[chip.line].append(index) }
        return lines
    }

    public func height(lines count: Int) -> Double {
        guard count > 0 else { return 0 }
        return Double(count) * metrics.chipHeight + Double(count - 1) * metrics.lineSpacing
    }

    /// Every line's height.
    public var contentHeight: Double { height(lines: lineCount) }

    /// What the section shows of them: `maxVisibleLines` at most.
    public var visibleHeight: Double { height(lines: min(lineCount, metrics.maxVisibleLines)) }

    public var scrolls: Bool { lineCount > metrics.maxVisibleLines }

    /// The chip an arrow key moves to from `index`. Left and right follow
    /// the reading order across lines and stop at the ends. Up and down go
    /// to the chip nearest above or below; nil is past the first or the last
    /// line, where the keyboard leaves the chips.
    public func index(from index: Int, moving direction: Direction) -> Int? {
        guard chips.indices.contains(index) else { return chips.isEmpty ? nil : 0 }
        switch direction {
        case .left: return max(index - 1, 0)
        case .right: return min(index + 1, chips.count - 1)
        case .up, .down:
            let chip = chips[index]
            let target = chip.line + (direction == .up ? -1 : 1)
            guard target >= 0, target < lineCount else { return nil }
            let centre = chip.x + chip.width / 2
            return chips.indices.filter { chips[$0].line == target }.min { lhs, rhs in
                abs(chips[lhs].x + chips[lhs].width / 2 - centre) < abs(chips[rhs].x + chips[rhs].width / 2 - centre)
            }
        }
    }
}

/// What a key does while the command bar is open and has the keyboard. The
/// bar owns its keys: Tab never moves focus out of the bar or reaches the
/// page, whatever is typed.
///
/// - **Tab**: enters the site search the field offers ("Search … Tab");
///   else takes the inline completion, as Right Arrow does; else, with
///   nothing typed and Tab Groups shown, moves into the chips; else nothing.
/// - **In the chips** (the field keeps the keyboard; one chip is
///   highlighted): Tab and ⇧Tab step to the next and the previous chip and
///   leave past either end, the arrows move between chips and lines, Return
///   adds the group to the space, Esc goes back to the field.
/// - Every other key is the field's and the list's, as before.
public enum CommandBarKeys {
    public enum Key: Equatable, Sendable {
        case tab, backTab, left, right, up, down, `return`, escape
    }

    public struct State: Equatable, Sendable {
        /// The field shows "Search …  Tab" (a shortcut's keyword, or a site it completes to).
        public var offersSiteSearch: Bool
        /// Grey text follows the caret.
        public var hasInlineCompletion: Bool
        public var fieldIsEmpty: Bool
        /// The Tab Groups chips on show; nil or empty when there are none.
        public var chips: TabGroupChipLayout?
        public var highlightedChip: Int?

        public init(offersSiteSearch: Bool = false, hasInlineCompletion: Bool = false, fieldIsEmpty: Bool = true,
                    chips: TabGroupChipLayout? = nil, highlightedChip: Int? = nil) {
            self.offersSiteSearch = offersSiteSearch
            self.hasInlineCompletion = hasInlineCompletion
            self.fieldIsEmpty = fieldIsEmpty
            self.chips = chips
            self.highlightedChip = highlightedChip
        }
    }

    public enum Action: Equatable, Sendable {
        case enterSiteSearch
        case acceptCompletion
        case highlightChip(Int)
        /// Back to the field: no chip is highlighted.
        case leaveChips
        case addHighlightedGroup
        /// Nothing happens, and the key goes no further.
        case consume
        /// The field's and the list's own handling of the key.
        case passToBar
    }

    public static func action(for key: Key, in state: State) -> Action {
        let count = state.chips?.chips.count ?? 0
        if let chips = state.chips, let index = state.highlightedChip, chips.chips.indices.contains(index) {
            func move(_ direction: TabGroupChipLayout.Direction) -> Action {
                chips.index(from: index, moving: direction).map { .highlightChip($0) } ?? .leaveChips
            }
            switch key {
            case .tab: return index + 1 < count ? .highlightChip(index + 1) : .leaveChips
            case .backTab: return index > 0 ? .highlightChip(index - 1) : .leaveChips
            case .left: return move(.left)
            case .right: return move(.right)
            case .up: return move(.up)
            case .down: return move(.down)
            case .return: return .addHighlightedGroup
            case .escape: return .leaveChips
            }
        }
        switch key {
        case .tab:
            if state.offersSiteSearch { return .enterSiteSearch }
            if state.hasInlineCompletion { return .acceptCompletion }
            if state.fieldIsEmpty, count > 0 { return .highlightChip(0) }
            return .consume
        case .backTab:
            return .consume
        case .left, .right, .up, .down, .return, .escape:
            return .passToBar
        }
    }
}
