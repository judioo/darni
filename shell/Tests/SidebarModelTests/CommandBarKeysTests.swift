import XCTest
@testable import SidebarModel

/// The ⌘T bar's Tab Groups chips (which chip is on which line, how tall the
/// section is, where the arrows go) and what each key does while the bar is
/// open (`CommandBarKeys`): Tab never leaves the bar.
final class CommandBarKeysTests: XCTestCase {
    private func layout(_ widths: [Double], available: Double = 300) -> TabGroupChipLayout {
        TabGroupChipLayout(widths: widths, available: available)
    }

    // MARK: Chips

    func testChipsFlowLeftToRightAndWrapAtTheBarsWidth() {
        // Spacing 6: 100 + 6 + 100 + 6 + 80 = 292 fits in 300, the next 60 does not. The 250 chip
        // is cut to 220 and sits beside the 60 (66 + 220 = 286); the 40 after it starts a third line.
        let chips = layout([100, 100, 80, 60, 250, 40])
        XCTAssertEqual(chips.lines, [[0, 1, 2], [3, 4], [5]])
        XCTAssertEqual(chips.chips.map(\.x), [0, 106, 212, 0, 66, 0])
        XCTAssertEqual(chips.chips.map(\.width), [100, 100, 80, 60, 220, 40])
        XCTAssertEqual(chips.lineCount, 3)

        XCTAssertEqual(layout([100, 100, 88]).lines, [[0, 1, 2]], "exactly the width still fits")
        XCTAssertEqual(layout([100, 100, 89]).lines, [[0, 1], [2]])
        XCTAssertEqual(layout([]).lines, [])
        XCTAssertEqual(layout([]).visibleHeight, 0)
    }

    func testALongNamesChipIsCutAtTheMaximumAndNeverWiderThanTheBar() {
        let chips = layout([900, 50], available: 400)
        XCTAssertEqual(chips.chips[0].width, chips.metrics.maxChipWidth)
        XCTAssertEqual(chips.lines, [[0, 1]], "the cut chip leaves room beside it")
        XCTAssertEqual(layout([900], available: 120).chips[0].width, 120)
    }

    func testTwentyGroupsTakeAFewLinesAndTheSectionStopsGrowingAtThree() {
        // The 765 pt bar less its insets. Seven 90 pt chips and six gaps are 666 pt; an eighth does not fit.
        let twenty = layout(Array(repeating: 90, count: 20), available: 725)
        XCTAssertEqual(twenty.lines.map(\.count), [7, 7, 6], "seven to a line across the bar")
        XCTAssertFalse(twenty.scrolls)
        XCTAssertEqual(twenty.visibleHeight, 3 * 26 + 2 * 6)

        let forty = layout(Array(repeating: 90, count: 40), available: 725)
        XCTAssertEqual(forty.lineCount, 6)
        XCTAssertTrue(forty.scrolls)
        XCTAssertEqual(forty.visibleHeight, twenty.visibleHeight, "past three lines it scrolls inside itself")
        XCTAssertEqual(forty.contentHeight, 6 * 26 + 5 * 6)
        XCTAssertEqual(layout([100]).visibleHeight, 26)
    }

    func testTheArrowsMoveBetweenChipsAndLines() {
        // Line 0: 0 (0…100), 1 (106…206), 2 (212…292). Line 1: 3 (0…60), 4 (66…286). Line 2: 5 (0…40).
        let chips = layout([100, 100, 80, 60, 250, 40])
        XCTAssertEqual(chips.index(from: 0, moving: .right), 1)
        XCTAssertEqual(chips.index(from: 2, moving: .right), 3, "on to the next line")
        XCTAssertEqual(chips.index(from: 3, moving: .left), 2)
        XCTAssertEqual(chips.index(from: 0, moving: .left), 0, "stops at the first")
        XCTAssertEqual(chips.index(from: 5, moving: .right), 5, "and at the last")

        XCTAssertEqual(chips.index(from: 2, moving: .down), 4, "the nearest below: centres 252 and 176")
        XCTAssertEqual(chips.index(from: 0, moving: .down), 3)
        XCTAssertEqual(chips.index(from: 4, moving: .down), 5, "the only chip on the line below")
        XCTAssertEqual(chips.index(from: 5, moving: .up), 3)
        XCTAssertEqual(chips.index(from: 4, moving: .up), 1, "the nearest above: centres 176 and 156")
        XCTAssertNil(chips.index(from: 1, moving: .up), "past the first line: out of the chips")
        XCTAssertNil(chips.index(from: 5, moving: .down), "past the last line too")
    }

    // MARK: Keys

    private typealias Keys = CommandBarKeys

    func testTabTakesTheSiteSearchThenTheCompletionThenTheChips() {
        let chips = layout([100, 100])
        func tab(_ state: Keys.State) -> Keys.Action { Keys.action(for: .tab, in: state) }
        XCTAssertEqual(tab(.init(offersSiteSearch: true, hasInlineCompletion: true, fieldIsEmpty: false)), .enterSiteSearch,
                       "the offered site search first, as before")
        XCTAssertEqual(tab(.init(hasInlineCompletion: true, fieldIsEmpty: false)), .acceptCompletion, "“post” becomes “posthog.com”")
        XCTAssertEqual(tab(.init(fieldIsEmpty: true, chips: chips)), .highlightChip(0), "nothing typed: into the chips")
        XCTAssertEqual(tab(.init(fieldIsEmpty: false, chips: chips)), .consume, "typed text with no completion")
        XCTAssertEqual(tab(.init(fieldIsEmpty: true)), .consume, "an empty bar with no chips")
        XCTAssertEqual(tab(.init(fieldIsEmpty: true, chips: layout([]))), .consume)
    }

    func testTabNeverLeavesTheBar() {
        let chips = layout([100, 100])
        var states: [Keys.State] = []
        for site in [false, true] {
            for completion in [false, true] {
                for empty in [false, true] {
                    for shown in [nil, chips] as [TabGroupChipLayout?] {
                        for highlight in [nil, 0, 1, 7] as [Int?] {
                            states.append(.init(offersSiteSearch: site, hasInlineCompletion: completion, fieldIsEmpty: empty,
                                                chips: shown, highlightedChip: highlight))
                        }
                    }
                }
            }
        }
        for state in states {
            XCTAssertNotEqual(Keys.action(for: .tab, in: state), .passToBar, "\(state)")
            XCTAssertNotEqual(Keys.action(for: .backTab, in: state), .passToBar, "\(state)")
        }
    }

    func testShiftTabDoesNothingOutsideTheChips() {
        XCTAssertEqual(Keys.action(for: .backTab, in: .init(hasInlineCompletion: true, fieldIsEmpty: false)), .consume)
        XCTAssertEqual(Keys.action(for: .backTab, in: .init(fieldIsEmpty: true, chips: layout([100]))), .consume)
    }

    func testInTheChipsTheKeysAreTheChips() {
        let chips = layout([100, 100, 80, 60])   // lines [0, 1, 2] and [3]
        func act(_ key: Keys.Key, at index: Int) -> Keys.Action {
            Keys.action(for: key, in: .init(fieldIsEmpty: true, chips: chips, highlightedChip: index))
        }
        XCTAssertEqual(act(.tab, at: 0), .highlightChip(1))
        XCTAssertEqual(act(.tab, at: 3), .leaveChips, "past the last chip: back to the field")
        XCTAssertEqual(act(.backTab, at: 1), .highlightChip(0))
        XCTAssertEqual(act(.backTab, at: 0), .leaveChips, "⇧Tab from the first: back to the field")
        XCTAssertEqual(act(.right, at: 0), .highlightChip(1))
        XCTAssertEqual(act(.left, at: 1), .highlightChip(0))
        XCTAssertEqual(act(.left, at: 0), .highlightChip(0))
        XCTAssertEqual(act(.down, at: 1), .highlightChip(3))
        XCTAssertEqual(act(.up, at: 3), .highlightChip(0))
        XCTAssertEqual(act(.up, at: 1), .leaveChips)
        XCTAssertEqual(act(.down, at: 3), .leaveChips)
        XCTAssertEqual(act(.return, at: 2), .addHighlightedGroup)
        XCTAssertEqual(act(.escape, at: 2), .leaveChips, "Esc goes back to the field; a second Esc closes the bar")
    }

    func testOutsideTheChipsTheOtherKeysAreTheFieldsAndTheLists() {
        let state = Keys.State(fieldIsEmpty: true, chips: layout([100, 100]))
        for key in [Keys.Key.left, .right, .up, .down, .return, .escape] {
            XCTAssertEqual(Keys.action(for: key, in: state), .passToBar)
        }
        // A highlight for a chip that is gone counts as none.
        let stale = Keys.State(fieldIsEmpty: true, chips: layout([100]), highlightedChip: 4)
        XCTAssertEqual(Keys.action(for: .return, in: stale), .passToBar)
        XCTAssertEqual(Keys.action(for: .tab, in: stale), .highlightChip(0))
    }
}
