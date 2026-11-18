import XCTest
@testable import SidebarModel

final class SpaceCircleTests: XCTestCase {
    func testInkChoosesTheHigherContrastAgainstTheFill() {
        for (red, green, blue) in [(0.0, 0.0, 0.0), (1, 1, 1), (0.95, 0.95, 0.9), (0.1, 0.2, 0.5), (1, 0, 0), (0, 1, 0)] {
            let theme = SpaceTheme(red: red, green: green, blue: blue)
            let fill = PageColor(red: red, green: green, blue: blue)
            let light = SpaceCircles.prefersLightInk(on: theme)
            XCTAssertGreaterThanOrEqual(fill.contrast(with: light ? .white : .black),
                                        fill.contrast(with: light ? .black : .white))
        }
    }

    func testInitialTrimsWhitespaceAndKeepsAGrapheme() {
        XCTAssertEqual(SpaceCircles.initial(for: "  alpha\n"), "A")
        XCTAssertEqual(SpaceCircles.initial(for: "école"), "É")
        XCTAssertEqual(SpaceCircles.initial(for: "👩🏽‍💻 Work"), "👩🏽‍💻")
        XCTAssertEqual(SpaceCircles.initial(for: " \n"), "?")
    }

    func testSlotsStayFixedWithOverflowAndLeaveRoomForTheRing() {
        XCTAssertEqual(SpaceCircles.widths(count: 11), Array(repeating: 24, count: 11))
        XCTAssertEqual(SpaceCircles.widths(count: 0), [])
        XCTAssertEqual(SpaceCircles.widths(count: -1), [])
        XCTAssertEqual(SpaceCircles.slotWidth - SpaceCircles.diameter, 6)
        XCTAssertLessThanOrEqual(SpaceCircles.ringDiameter, SpaceCircles.slotWidth)
    }

    func testStyleDefaultsAndPersistence() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SpaceCircleTests.\(UUID())"))
        defer { defaults.removeObject(forKey: SpaceIconStyle.defaultsKey) }
        XCTAssertEqual(SpaceIconStyle.load(from: defaults), .colouredCircles)
        SpaceIconStyle.arcDots.save(to: defaults)
        XCTAssertEqual(SpaceIconStyle.load(from: defaults), .arcDots)
        SpaceIconStyle.colouredCircles.save(to: defaults)
        XCTAssertEqual(SpaceIconStyle.load(from: defaults), .colouredCircles)
        defaults.set("unknown", forKey: SpaceIconStyle.defaultsKey)
        XCTAssertEqual(SpaceIconStyle.load(from: defaults), .colouredCircles)
    }

    func testSymbolIconsShowAsColourEmoji() {
        XCTAssertEqual(SpaceCircles.emoji(forSymbol: "house.fill"), "🏠")
        XCTAssertEqual(SpaceCircles.emoji(forSymbol: "heart.circle.fill"), "❤️")
        XCTAssertEqual(SpaceCircles.emoji(forSymbol: "music.note"), "🎵")
        XCTAssertNil(SpaceCircles.emoji(forSymbol: "🌿"), "an emoji draws as itself")
        XCTAssertNil(SpaceCircles.emoji(forSymbol: "circle.fill"), "no emoji keeps the symbol")
        for symbol in Space.iconChoices where symbol != "circle.fill" {
            XCTAssertNotNil(SpaceCircles.emoji(forSymbol: symbol), symbol)
        }
    }
}

/// Arc's space icons (2026-11-18): the picker offers Arc's 56 in Arc's order,
/// then ReArc's own, and an Arc import draws Arc's named icons.
final class ArcSpaceIconTests: XCTestCase {
    func testThePickerOffersArcsIconsInArcsOrderThenReArcsExtras() {
        let arc = ArcSpaceIcons.pickerOrder.map(\.symbol)
        XCTAssertEqual(arc.count, 56)
        XCTAssertEqual(Array(Space.iconChoices.prefix(56)), arc)
        XCTAssertEqual(Set(Space.iconChoices).count, Space.iconChoices.count, "no icon twice")
        for symbol in Space.rearcIconChoices {
            XCTAssertTrue(Space.iconChoices.contains(symbol), "\(symbol) is kept")
        }
    }

    func testArcIconNamesDrawAsTheirSymbols() {
        XCTAssertEqual(Space.symbolToDraw(for: "code"), "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(Space.symbolToDraw(for: "planet"), "globe.americas.fill")
        XCTAssertEqual(Space.symbolToDraw(for: "star"), "star.fill", "Arc's star is filled")
        XCTAssertEqual(Space.symbolToDraw(for: "house.fill"), "house.fill")
        XCTAssertNil(Space.symbolToDraw(for: "🌿"))
    }

    func testAnArcImportMapsNamedIcons() {
        XCTAssertEqual(ArcSidebarReader.icon(["icon": "code"]), .sfSymbol(name: "chevron.left.forwardslash.chevron.right"))
        XCTAssertEqual(ArcSidebarReader.icon(["icon": "fileTrayFull"]), .sfSymbol(name: "tray.full.fill"), "camelCase names were dropped before")
        XCTAssertEqual(ArcSidebarReader.icon(["icon": "star.fill"]), .sfSymbol(name: "star.fill"))
        XCTAssertEqual(ArcSidebarReader.icon(["emoji_v2": "🧪", "emoji": 3]), .emoji("🧪"))
    }
}
