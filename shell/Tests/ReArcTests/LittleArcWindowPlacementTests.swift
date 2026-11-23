import AppKit
import XCTest
@testable import ReArc

/// Owner, 2026-11-23: Little Darni always opened in the same place, even
/// after one was moved to another screen. A new one opens where the last was
/// left, on that screen.
final class LittleArcWindowPlacementTests: XCTestCase {
    /// A laptop screen with the menu bar, and a larger display to its right.
    private let laptop = NSRect(x: 0, y: 0, width: 1512, height: 944)
    private let display = NSRect(x: 1512, y: -200, width: 2560, height: 1415)

    func testANewWindowOpensWhereTheLastWasLeftOnTheOtherScreen() throws {
        let left = NSRect(x: 2400, y: 300, width: 1100, height: 800)
        let frame = try XCTUnwrap(LittleArcWindowPlacement.frame(remembered: left, screens: [laptop, display]))
        XCTAssertEqual(frame, left, "it opens on the display it was moved to, where it was left, at its size")
    }

    func testNothingRememberedKeepsTheDefaultPlacement() {
        XCTAssertNil(LittleArcWindowPlacement.frame(remembered: nil, screens: [laptop, display]))
    }

    func testAScreenNoLongerAttachedKeepsTheDefaultPlacement() {
        let onDetachedDisplay = NSRect(x: 2400, y: 300, width: 1100, height: 800)
        XCTAssertNil(LittleArcWindowPlacement.frame(remembered: onDetachedDisplay, screens: [laptop]),
                     "a frame on a display that is gone does not pull the window off screen")
    }

    func testAFrameHangingOffTheScreenIsBroughtOnIt() throws {
        let hanging = NSRect(x: 1200, y: -100, width: 900, height: 700)
        let frame = try XCTUnwrap(LittleArcWindowPlacement.frame(remembered: hanging, screens: [laptop]))
        XCTAssertTrue(laptop.contains(frame), "\(frame) is not wholly on \(laptop)")
        XCTAssertEqual(frame.size, hanging.size)
        XCTAssertEqual(frame.maxX, laptop.maxX)
        XCTAssertEqual(frame.minY, laptop.minY)
    }

    func testAWindowLeftLargeOnTheDisplayFitsTheSmallerScreen() throws {
        // Mostly on the laptop, but bigger than it.
        let large = NSRect(x: 0, y: 0, width: 2000, height: 1300)
        let frame = try XCTUnwrap(LittleArcWindowPlacement.frame(remembered: large, screens: [laptop]))
        XCTAssertEqual(frame, laptop)
    }

    func testASecondWindowStepsOffTheFirst() throws {
        let left = NSRect(x: 2400, y: 300, width: 1100, height: 800)
        let first = try XCTUnwrap(LittleArcWindowPlacement.frame(remembered: left, screens: [laptop, display]))
        let second = try XCTUnwrap(LittleArcWindowPlacement.frame(remembered: left, screens: [laptop, display], occupied: [first]))
        XCTAssertEqual(second.minX, first.minX + LittleArcWindowPlacement.cascadeStep)
        XCTAssertEqual(second.maxY, first.maxY - LittleArcWindowPlacement.cascadeStep)
        XCTAssertEqual(second.size, first.size)
        let third = try XCTUnwrap(LittleArcWindowPlacement.frame(remembered: left, screens: [laptop, display], occupied: [first, second]))
        XCTAssertEqual(third.minX, second.minX + LittleArcWindowPlacement.cascadeStep)
    }

    func testTheInstalledAppRemembersInItsDefaultsAndTheSelfTestInMemory() throws {
        let suite = "rearc-little-darni-frame-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let left = NSRect(x: 2400, y: 300, width: 1100, height: 800)

        LittleArcFrameMemory(defaults: defaults, key: "frame").remember(left)
        XCTAssertEqual(LittleArcFrameMemory(defaults: defaults, key: "frame").frame, left, "a relaunch reads the same place")

        let selfTest = LittleArcFrameMemory(defaults: nil)
        XCTAssertNil(selfTest.frame)
        selfTest.remember(left)
        XCTAssertEqual(selfTest.frame, left)
        XCTAssertNil(UserDefaults.standard.string(forKey: "frame"))

        LittleArcFrameMemory(defaults: defaults, key: "frame").remember(.zero)
        XCTAssertEqual(LittleArcFrameMemory(defaults: defaults, key: "frame").frame, left, "an empty frame is never kept")
    }

    @MainActor
    func testAMinimisedOrHiddenWindowIsNotRemembered() {
        let memory = LittleArcFrameMemory(defaults: nil)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 500, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        memory.remember(window)
        XCTAssertNil(memory.frame, "a window that is not on screen is no place to come back to")
    }
}
