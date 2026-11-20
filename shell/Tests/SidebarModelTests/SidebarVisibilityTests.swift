import XCTest
@testable import SidebarModel

/// ⌘S per window: one window's sidebar hides and shows and the others keep
/// theirs, a new window starts as the one it was opened from, and a closed
/// window is forgotten. (Owner's recording, builds 1080 and 1105: ⌘S in one
/// of two windows hid the sidebar in both.)
final class SidebarVisibilityTests: XCTestCase {
    private let a = SidebarWindowID()
    private let b = SidebarWindowID()

    /// ⌘S with its slide run to the end.
    private func toggle(_ visibility: inout SidebarVisibility, in window: SidebarWindowID?) {
        let showing = visibility.beginToggle(in: window)
        visibility.setReveal(showing ? 1 : 0, in: window)
        visibility.endToggle(showing: showing, in: window)
    }

    func testToggleInOneWindowLeavesTheOtherAlone() {
        var visibility = SidebarVisibility()
        visibility.open(a)
        visibility.open(b)
        XCTAssertEqual(visibility.state(in: a), .shown, "a new window with nothing to copy shows its sidebar")

        toggle(&visibility, in: a)
        XCTAssertEqual(visibility.state(in: a), .hidden)
        XCTAssertEqual(visibility.state(in: b), .shown, "the other window keeps its sidebar")

        toggle(&visibility, in: b)
        toggle(&visibility, in: a)
        XCTAssertEqual(visibility.state(in: a), .shown, "the same key brings it back")
        XCTAssertEqual(visibility.state(in: b), .hidden, "and the other window's own ⌘S is its own")
        XCTAssertEqual(visibility.state(in: nil), .shown, "no window: untouched")
    }

    func testAHideLaysThePageOutWideAtOnceAndAShowAtTheEnd() {
        var visibility = SidebarVisibility()
        visibility.open(a)
        visibility.open(b)
        XCTAssertFalse(visibility.beginToggle(in: a))
        XCTAssertFalse(visibility.isVisible(in: a))
        XCTAssertFalse(visibility.isLaidOut(in: a), "hide: the page goes wide in the first frame")
        XCTAssertTrue(visibility.isSliding(in: a))
        XCTAssertEqual(visibility.reveal(in: a), 1, "the animation moves the edge")
        XCTAssertTrue(visibility.isLaidOut(in: b), "the other window's page is not laid out again")
        XCTAssertFalse(visibility.isSliding(in: b))
        visibility.setReveal(0, in: a)
        visibility.endToggle(showing: false, in: a)
        XCTAssertEqual(visibility.state(in: a), .hidden)
        XCTAssertEqual(visibility.reveal(in: b), 1)

        XCTAssertTrue(visibility.beginToggle(in: a))
        XCTAssertFalse(visibility.isLaidOut(in: a), "show: the wide page slides with the sidebar")
        visibility.setReveal(1, in: a)
        visibility.endToggle(showing: true, in: a)
        XCTAssertEqual(visibility.state(in: a), .shown, "laid out narrow once the show completes")
    }

    func testANewerToggleOwnsTheStateWhenAnOlderSlideEnds() {
        var visibility = SidebarVisibility()
        visibility.open(a)
        let first = visibility.beginToggle(in: a)
        let second = visibility.beginToggle(in: a)
        XCTAssertFalse(first)
        XCTAssertTrue(second)
        visibility.endToggle(showing: first, in: a)
        XCTAssertTrue(visibility.isSliding(in: a), "the hide's end leaves the show's slide alone")
        XCTAssertFalse(visibility.isLaidOut(in: a))
        visibility.endToggle(showing: second, in: a)
        XCTAssertFalse(visibility.isSliding(in: a))
        XCTAssertTrue(visibility.isLaidOut(in: a))
    }

    func testANewWindowStartsAsTheWindowItWasOpenedFrom() {
        var visibility = SidebarVisibility()
        visibility.open(a)
        toggle(&visibility, in: a)
        visibility.open(b, openedFrom: a)
        XCTAssertEqual(visibility.state(in: b), .hidden)

        let c = SidebarWindowID()
        visibility.open(c, openedFrom: SidebarWindowID())
        XCTAssertEqual(visibility.state(in: c), .shown, "an unknown parent gives a shown sidebar")

        toggle(&visibility, in: b)
        XCTAssertEqual(visibility.state(in: a), .hidden, "afterwards each goes its own way")
        visibility.open(b, openedFrom: a)
        XCTAssertEqual(visibility.state(in: b), .shown, "registering again (the view appearing) changes nothing")
    }

    func testANewWindowTakesTheSideAtRestNotAStateMidSlideOrFloating() {
        var visibility = SidebarVisibility()
        visibility.open(a)
        visibility.beginToggle(in: a)
        visibility.setReveal(0.4, in: a)
        visibility.open(b, openedFrom: a)
        XCTAssertEqual(visibility.state(in: b), .hidden, "hidden for good, with no slide of its own to finish")

        visibility.setReveal(0, in: a)
        visibility.endToggle(showing: false, in: a)
        XCTAssertTrue(visibility.setPeeking(true, in: a))
        let c = SidebarWindowID()
        visibility.open(c, openedFrom: a)
        XCTAssertFalse(visibility.isPeeking(in: c), "the pointer is at the first window's edge, not this one's")
    }

    func testAClosedWindowIsForgotten() {
        var visibility = SidebarVisibility()
        visibility.open(a)
        visibility.open(b)
        toggle(&visibility, in: a)
        visibility.forget(a)
        XCTAssertFalse(visibility.isRegistered(a))
        XCTAssertEqual(visibility.state(in: a), .shown)
        XCTAssertTrue(visibility.isRegistered(b))

        // The window closes mid-slide: the slide's end does not bring it back.
        let showing = visibility.beginToggle(in: b)
        visibility.forget(b)
        visibility.endToggle(showing: showing, in: b)
        XCTAssertFalse(visibility.isRegistered(b))
        XCTAssertEqual(visibility, SidebarVisibility())
    }

    func testOnlyAHiddenSidebarFloatsAndOnlyInItsOwnWindow() {
        var visibility = SidebarVisibility()
        visibility.open(a)
        visibility.open(b)
        XCTAssertFalse(visibility.setPeeking(true, in: a), "a shown sidebar never floats")
        toggle(&visibility, in: a)
        toggle(&visibility, in: b)
        XCTAssertTrue(visibility.setPeeking(true, in: a))
        XCTAssertFalse(visibility.setPeeking(true, in: a), "no change")
        XCTAssertTrue(visibility.isPeeking(in: a))
        XCTAssertFalse(visibility.isPeeking(in: b), "the other hidden sidebar stays away")

        toggle(&visibility, in: a)
        XCTAssertFalse(visibility.isPeeking(in: a), "⌘S pins it")

        visibility.setPeeking(true, in: b)
        visibility.endPeekingEverywhere()
        XCTAssertFalse(visibility.isPeeking(in: b))
        XCTAssertFalse(visibility.isVisible(in: b), "dismissed, still hidden")
    }
}
