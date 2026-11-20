import XCTest
@testable import SidebarModel

/// The ⌃Tab switcher's strip of thumbnail cards: its size, which cards
/// show, and its colours.
final class TabSwitcherLayoutTests: XCTestCase {

    // MARK: Size

    func testAWideWindowShowsArcsPanel() {
        let layout = TabSwitcherLayout(itemCount: 5, availableWidth: 1400)
        XCTAssertEqual(layout.visibleCount, 5)
        XCTAssertEqual(layout.cellWidth, 182)
        XCTAssertEqual(layout.thumbnailWidth, 158)
        XCTAssertEqual(layout.thumbnailHeight, 105)
        XCTAssertEqual(layout.cellHeight, 158)
        XCTAssertEqual(layout.panelWidth, 940, "Arc's panel is 939 pt wide")
        XCTAssertEqual(layout.panelHeight, 188, "and 188 pt high")
    }

    func testFewerTabsMakeANarrowerPanel() {
        let layout = TabSwitcherLayout(itemCount: 3, availableWidth: 1400)
        XCTAssertEqual(layout.visibleCount, 3)
        XCTAssertEqual(layout.cellWidth, 182)
        XCTAssertEqual(layout.panelWidth, 576)
        XCTAssertEqual(TabSwitcherLayout(itemCount: 2, availableWidth: 1400).visibleCount, 2)
    }

    func testMoreTabsThanFiveShowFive() {
        let layout = TabSwitcherLayout(itemCount: 15, availableWidth: 1400)
        XCTAssertEqual(layout.itemCount, 15)
        XCTAssertEqual(layout.visibleCount, 5)
        XCTAssertEqual(layout.panelWidth, 940)
    }

    func testANarrowWindowShrinksTheCardsThenShowsFewer() {
        // 900 pt leaves 830 for five cards: 166 each.
        let shrunk = TabSwitcherLayout(itemCount: 12, availableWidth: 900)
        XCTAssertEqual(shrunk.visibleCount, 5)
        XCTAssertEqual(shrunk.cellWidth, 166)
        XCTAssertLessThanOrEqual(shrunk.panelWidth + 2 * TabSwitcherLayout.windowMargin, 900)

        // 700 pt leaves 630: five would be 126 each, under the smallest card.
        let fewer = TabSwitcherLayout(itemCount: 12, availableWidth: 700)
        XCTAssertEqual(fewer.visibleCount, 4)
        XCTAssertGreaterThanOrEqual(fewer.cellWidth, TabSwitcherLayout.minimumCellWidth)
        XCTAssertLessThanOrEqual(fewer.panelWidth + 2 * TabSwitcherLayout.windowMargin, 700)

        let tiny = TabSwitcherLayout(itemCount: 12, availableWidth: 120)
        XCTAssertEqual(tiny.visibleCount, 1, "one card always shows")
        XCTAssertEqual(tiny.cellWidth, TabSwitcherLayout.minimumCellWidth)
    }

    func testEveryWidthFitsTheWindowAndKeepsTheThumbnailShape() {
        for width in stride(from: 240.0, through: 2000, by: 37) {
            for count in [1, 2, 3, 5, 6, 12, 15] {
                let layout = TabSwitcherLayout(itemCount: count, availableWidth: width)
                XCTAssertGreaterThanOrEqual(layout.visibleCount, 1)
                XCTAssertLessThanOrEqual(layout.visibleCount, min(count, TabSwitcherLayout.maximumVisible))
                XCTAssertLessThanOrEqual(layout.cellWidth, TabSwitcherLayout.cellWidth)
                if layout.visibleCount > 1 {
                    XCTAssertLessThanOrEqual(layout.panelWidth + 2 * TabSwitcherLayout.windowMargin, width, "\(count) tabs in \(width) pt")
                }
                XCTAssertEqual(layout.thumbnailWidth / layout.thumbnailHeight, TabSwitcherLayout.thumbnailAspect, accuracy: 0.02)
            }
        }
    }

    // MARK: Which cards show

    func testAllCardsShowWhenTheyFit() {
        let layout = TabSwitcherLayout(itemCount: 4, availableWidth: 1400)
        for index in 0 ..< 4 {
            XCTAssertEqual(layout.firstVisible(showing: index, from: 0), 0)
            XCTAssertEqual(layout.firstVisible(showing: index, from: 9), 0, "a stale start is put right")
        }
        XCTAssertEqual(layout.hiddenBefore(first: 0), 0)
        XCTAssertEqual(layout.hiddenAfter(first: 0), 0)
    }

    func testSteppingForwardSlidesOneCardAtATimeAndWrapsToTheStart() {
        let layout = TabSwitcherLayout(itemCount: 12, availableWidth: 1400)
        var session = TabSwitcherSession(items: Self.items(12), forward: true)!
        var first = layout.firstVisible(showing: session.index, from: 0)
        var starts = [first]
        for _ in 0 ..< 11 {
            session.step(forward: true)
            first = layout.firstVisible(showing: session.index, from: first)
            starts.append(first)
        }
        // Highlights 1…11, then 0 again.
        XCTAssertEqual(starts, [0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 0])
    }

    func testSteppingBackwardStartsAtTheEndAndSlidesBack() {
        let layout = TabSwitcherLayout(itemCount: 12, availableWidth: 1400)
        var session = TabSwitcherSession(items: Self.items(12), forward: false)!
        XCTAssertEqual(session.index, 11)
        var first = layout.firstVisible(showing: session.index, from: 0)
        XCTAssertEqual(first, 7, "the last five")
        for expected in [7, 7, 7, 7, 6, 5] {
            session.step(forward: false)
            first = layout.firstVisible(showing: session.index, from: first)
            XCTAssertEqual(first, expected, "highlight \(session.index)")
        }
    }

    func testTheHighlightedCardIsAlwaysOnShow() {
        for count in 1 ... 15 {
            for width in [300.0, 700, 900, 1400] {
                let layout = TabSwitcherLayout(itemCount: count, availableWidth: width)
                for previous in -2 ... count + 2 {
                    for index in 0 ..< count {
                        let first = layout.firstVisible(showing: index, from: previous)
                        XCTAssertGreaterThanOrEqual(first, 0)
                        XCTAssertLessThanOrEqual(first + layout.visibleCount, max(count, layout.visibleCount))
                        XCTAssertTrue((first ..< first + layout.visibleCount).contains(index),
                                      "\(count) tabs, \(width) pt, from \(previous): card \(index) is off the strip at \(first)")
                    }
                }
            }
        }
    }

    func testHiddenCountsOnEachSide() {
        let layout = TabSwitcherLayout(itemCount: 15, availableWidth: 1400)
        XCTAssertEqual(layout.hiddenBefore(first: 0), 0)
        XCTAssertEqual(layout.hiddenAfter(first: 0), 10)
        XCTAssertEqual(layout.hiddenBefore(first: 4), 4)
        XCTAssertEqual(layout.hiddenAfter(first: 4), 6)
        XCTAssertEqual(layout.hiddenBefore(first: 10), 10)
        XCTAssertEqual(layout.hiddenAfter(first: 10), 0)
        XCTAssertEqual(layout.hiddenBefore(first: 40), 10, "clamped")
    }

    // MARK: Colours

    private static let themes: [SpaceTheme] = SpaceTheme.presets + SpaceTheme.editorVibrant + SpaceTheme.editorPalette.flatMap { $0 }

    func testTheHighlightIsTheSpacesColourOverTheCard() {
        for dark in [false, true] {
            let surface = TabSwitcherInk.surface(dark: dark)
            XCTAssertEqual(surface, CommandBarInk.surface(dark: dark), "Darni's floating card")
            for theme in Self.themes {
                let accent = TabSwitcherInk.accent(theme: theme, dark: dark)
                let fill = TabSwitcherInk.selection(theme: theme, dark: dark)
                XCTAssertEqual(fill.red, surface.red + (accent.red - surface.red) * 0.3, accuracy: 1e-9)
                XCTAssertEqual(fill.green, surface.green + (accent.green - surface.green) * 0.3, accuracy: 1e-9)
                XCTAssertEqual(fill.blue, surface.blue + (accent.blue - surface.blue) * 0.3, accuracy: 1e-9)
            }
        }
        // Two spaces of different colours do not share a highlight, and neither is a system blue.
        let green = TabSwitcherInk.selection(theme: SpaceTheme.editorVibrant[6], dark: false)
        let red = TabSwitcherInk.selection(theme: SpaceTheme.editorVibrant[3], dark: false)
        XCTAssertNotEqual(green, red)
        XCTAssertGreaterThan(green.green, green.blue)
        XCTAssertGreaterThan(red.red, red.blue)
    }

    func testTitlesReadOnTheCardAndOnTheHighlight() {
        for dark in [false, true] {
            let card = TabSwitcherInk.surface(dark: dark)
            let onCard = SidebarBackdrop(darkest: card, lightest: card)
            XCTAssertGreaterThanOrEqual(onCard.contrast(of: TabSwitcherInk.title(dark: dark), lightInk: dark), SidebarContrast.text)
            for theme in Self.themes {
                let fill = TabSwitcherInk.selection(theme: theme, dark: dark)
                let onFill = SidebarBackdrop(darkest: fill, lightest: fill)
                let title = TabSwitcherInk.selectedTitle(theme: theme, dark: dark)
                XCTAssertGreaterThanOrEqual(onFill.contrast(of: title, lightInk: dark), SidebarContrast.text,
                                            "\(theme.baseColor.spaceColor.hex) dark \(dark): \(title.hex) on \(fill.hex)")
            }
        }
    }

    // MARK: Thumbnail cache

    func testTheSwitcherCanAskForAFresherSnapshot() {
        var cache = TabSnapshotCache<String>(capacity: 4, maxAge: 120)
        let id = UUID(), page = URL(string: "https://a.test/")!
        let t0 = Date(timeIntervalSince1970: 1_000)
        cache.store("shot", for: id, url: page, now: t0)
        XCTAssertFalse(cache.shouldCapture(id, url: page, now: t0.addingTimeInterval(20)))
        XCTAssertTrue(cache.shouldCapture(id, url: page, now: t0.addingTimeInterval(20), olderThan: 15))
        XCTAssertFalse(cache.shouldCapture(id, url: page, now: t0.addingTimeInterval(10), olderThan: 15))
        XCTAssertTrue(cache.shouldCapture(id, url: page, now: t0.addingTimeInterval(130), olderThan: 600), "never slower than maxAge")
        cache.beginCapture(id)
        XCTAssertFalse(cache.shouldCapture(id, url: page, now: t0.addingTimeInterval(500), olderThan: 15), "one capture at a time")
    }

    func testClosedTabsKeepNoSnapshot() {
        var cache = TabSnapshotCache<String>(capacity: 8, maxAge: 120)
        let page = URL(string: "https://a.test/")!, now = Date(timeIntervalSince1970: 1_000)
        let ids = (0 ..< 4).map { _ in UUID() }
        for (index, id) in ids.enumerated() { cache.store("\(index)", for: id, url: page, now: now) }
        let open: Set<UUID> = [ids[1], ids[3]]
        cache.removeAll(except: open.contains)
        XCTAssertEqual(Set(cache.entries.keys), open)
        XCTAssertNil(cache.image(for: ids[0], url: page))
        XCTAssertEqual(cache.image(for: ids[3], url: page), "3")
        // The order is still right: two more fill it, the oldest kept one goes first.
        var small = TabSnapshotCache<String>(capacity: 2, maxAge: 120)
        for (index, id) in ids.prefix(2).enumerated() { small.store("\(index)", for: id, url: page, now: now) }
        small.removeAll(except: { $0 == ids[1] })
        small.store("2", for: ids[2], url: page, now: now)
        XCTAssertEqual(Set(small.entries.keys), [ids[1], ids[2]])
        small.store("3", for: ids[3], url: page, now: now)
        XCTAssertEqual(Set(small.entries.keys), [ids[2], ids[3]])
    }

    private static func items(_ count: Int) -> [TabSwitcherItem] {
        (0 ..< count).map { index in
            TabSwitcherItem(id: UUID(), title: "Tab \(index)", url: URL(string: "https://\(index).test/")!,
                            spaceName: "Main", lastActiveAt: Date(timeIntervalSince1970: Double(1_000 - index)))
        }
    }
}
