import XCTest
@testable import SidebarModel

/// When an extension or a page may change the space on screen, the loop
/// breaker behind that rule, the blank tabs an extension never used, and a
/// tab selected in a space that is not on screen (owner's report 2026-11-22:
/// two profiles' Claude extensions passed the window between them for ever).
final class ExtensionFocusGateTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let a = UUID(), b = UUID(), c = UUID()

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    // MARK: The rule

    func testAnExtensionOfAProfileNotOnScreenNeverMovesTheWindow() {
        var gate = ExtensionFocusGate()
        gate.noteUserInput(at: at(0))
        XCTAssertEqual(gate.decide(from: a, to: b, source: .extensionRequest, sameProfile: false, at: at(0.1)), .stay(.otherProfile),
                       "the user cannot have clicked anything of a profile that is not on screen")
        XCTAssertEqual(gate.decide(from: a, to: c, source: .extensionRequest, sameProfile: true, at: at(0.2)), .follow,
                       "the refusal did not spend the user's input")
    }

    func testWithoutUserInputAnExtensionDoesNotMoveTheWindow() {
        var gate = ExtensionFocusGate()
        XCTAssertEqual(gate.decide(from: a, to: b, source: .extensionRequest, sameProfile: true, at: at(0)), .stay(.noUserInput))
        gate.noteUserInput(at: at(10))
        XCTAssertEqual(gate.decide(from: a, to: b, source: .extensionRequest, sameProfile: true,
                                   at: at(10 + ExtensionFocusGate.userInputWindow + 0.1)), .stay(.noUserInput),
                       "an input older than the window started nothing")
    }

    func testOneUserInputPaysForOneSwitch() {
        var gate = ExtensionFocusGate()
        gate.noteUserInput(at: at(0))
        XCTAssertEqual(gate.decide(from: a, to: b, source: .extensionRequest, sameProfile: true, at: at(1)), .follow)
        XCTAssertEqual(gate.decide(from: b, to: a, source: .extensionRequest, sameProfile: true, at: at(1.2)), .stay(.noUserInput),
                       "the click was spent on the first switch: nothing answers a switch Darni itself just made")
        gate.noteUserInput(at: at(2))
        XCTAssertEqual(gate.decide(from: b, to: a, source: .extensionRequest, sameProfile: true, at: at(2.1)), .follow)
    }

    func testTheSpaceOnScreenNeedsNoDecision() {
        var gate = ExtensionFocusGate()
        XCTAssertEqual(gate.decide(from: a, to: a, source: .extensionRequest, sameProfile: false, at: at(0)), .follow)
        gate.noteUserInput(at: at(0))
        XCTAssertEqual(gate.decide(from: a, to: a, source: .extensionRequest, sameProfile: true, at: at(0.1)), .follow)
        XCTAssertEqual(gate.decide(from: a, to: b, source: .extensionRequest, sameProfile: true, at: at(0.2)), .follow,
                       "a tab opened in the space on screen spent nothing")
    }

    func testAPagesOwnNewTabNeedsNoInputHere() {
        var gate = ExtensionFocusGate()
        XCTAssertEqual(gate.decide(from: a, to: b, source: .pageOpenedTab, sameProfile: false, at: at(0)), .follow,
                       "Chromium's popup blocker has asked for the user's gesture already")
    }

    // MARK: The loop breaker

    func testTheLoopBreakerStopsProgramsPassingTheWindowBetweenTheSameSpaces() {
        var gate = ExtensionFocusGate()
        var followed = 0
        var shown = a
        // Two pages that each open a tab in their own space, with nobody at the keyboard.
        for step in 0..<40 {
            let target = shown == a ? b : a
            if gate.decide(from: shown, to: target, source: .pageOpenedTab, sameProfile: true, at: at(Double(step) * 0.35)) == .follow {
                followed += 1
                shown = target
            }
        }
        XCTAssertEqual(followed, ExtensionFocusGate.loopReturns + 1, "one way out, \(ExtensionFocusGate.loopReturns) returns, then it holds")
        XCTAssertEqual(gate.trips, 1, "one trip to log, however long the loop goes on")
        XCTAssertTrue(gate.isPaused(at: at(14)))
    }

    func testTheLoopBreakerHoldsEvenWhenTheUserKeepsClicking() {
        var gate = ExtensionFocusGate()
        var shown = a
        var verdicts: [ExtensionFocusGate.Verdict] = []
        for step in 0..<6 {
            let now = at(Double(step))
            gate.noteUserInput(at: now)
            let target = shown == a ? b : a
            let verdict = gate.decide(from: shown, to: target, source: .extensionRequest, sameProfile: true, at: now.addingTimeInterval(0.1))
            verdicts.append(verdict)
            if verdict == .follow { shown = target }
        }
        XCTAssertEqual(verdicts, [.follow, .follow, .follow, .follow, .stay(.loop), .stay(.loop)])
    }

    func testThePauseEndsAndSlowSwitchesNeverTripIt() {
        var gate = ExtensionFocusGate()
        var shown = a
        for step in 0..<5 {
            let target = shown == a ? b : a
            if gate.decide(from: shown, to: target, source: .pageOpenedTab, sameProfile: true, at: at(Double(step))) == .follow { shown = target }
        }
        XCTAssertEqual(gate.trips, 1)
        let tripped = at(4)
        XCTAssertEqual(gate.decide(from: shown, to: c, source: .pageOpenedTab, sameProfile: true,
                                   at: tripped.addingTimeInterval(ExtensionFocusGate.loopPause - 1)), .stay(.loop),
                       "while it holds, no program moves the window, wherever to")
        let later = tripped.addingTimeInterval(ExtensionFocusGate.loopPause + 1)
        XCTAssertEqual(gate.decide(from: shown, to: c, source: .pageOpenedTab, sameProfile: true, at: later), .follow)
        XCTAssertFalse(gate.isPaused(at: later))

        // A page that opens a tab in another space every few seconds is no loop.
        var slow = ExtensionFocusGate()
        var slowShown = a
        for step in 0..<20 {
            let target = slowShown == a ? b : a
            XCTAssertEqual(slow.decide(from: slowShown, to: target, source: .pageOpenedTab, sameProfile: true,
                                       at: at(Double(step) * (ExtensionFocusGate.loopWindow / 2))), .follow)
            slowShown = target
        }
        XCTAssertEqual(slow.trips, 0)
    }

    func testVisitingNewSpacesIsNotALoop() {
        var gate = ExtensionFocusGate()
        var shown = UUID()
        for step in 0..<12 {
            let target = UUID()
            XCTAssertEqual(gate.decide(from: shown, to: target, source: .pageOpenedTab, sameProfile: true, at: at(Double(step) * 0.2)), .follow)
            shown = target
        }
        XCTAssertEqual(gate.trips, 0)
    }

    // MARK: Blank tabs

    func testAnExtensionHoldsOnlySoManyUnusedBlankTabs() {
        var blank = ExtensionBlankTabs()
        let profile = UUID(), other = UUID()
        var open: Set<UUID> = []
        for _ in 0..<ExtensionBlankTabs.limit {
            XCTAssertLessThan(blank.unused(for: "ext", in: profile) { open.contains($0) }, ExtensionBlankTabs.limit)
            let tab = UUID()
            open.insert(tab)
            blank.opened(tab, by: "ext", in: profile)
        }
        XCTAssertEqual(blank.unused(for: "ext", in: profile) { open.contains($0) }, ExtensionBlankTabs.limit)
        XCTAssertEqual(blank.unused(for: "ext", in: other) { open.contains($0) }, 0, "its copy in another profile has its own")
        XCTAssertEqual(blank.unused(for: "another", in: profile) { open.contains($0) }, 0, "so has another extension")
        // One loads a page, one is closed: neither is an unused blank tab any more, now or later.
        open.remove(open.first!)
        open.remove(open.first!)
        XCTAssertEqual(blank.unused(for: "ext", in: profile) { open.contains($0) }, ExtensionBlankTabs.limit - 2)
        XCTAssertEqual(blank.unused(for: "ext", in: profile) { _ in true }, ExtensionBlankTabs.limit - 2, "a used tab is forgotten")
    }

    func testOnlyANewTabWithoutAPageIsABlankTabRequest() {
        XCTAssertTrue(ExtensionTabRequest(id: 1, profileID: 1, kind: .createTab, url: "about:blank").isForBlankTab,
                      "chrome://newtab reaches the shell as about:blank")
        XCTAssertTrue(ExtensionTabRequest(id: 1, profileID: 1, kind: .createTab).isForBlankTab)
        XCTAssertFalse(ExtensionTabRequest(id: 1, profileID: 1, kind: .createTab, url: "chrome-extension://abc/pairing.html").isForBlankTab)
        XCTAssertFalse(ExtensionTabRequest(id: 1, profileID: 1, kind: .optionsPage, url: "about:blank").isForBlankTab)
        XCTAssertFalse(ExtensionTabRequest(id: 1, profileID: 1, tabID: 4, kind: .activate).isForBlankTab)
    }

    // MARK: A tab selected in a space that is not on screen

    private func twoSpaces() -> (SidebarStore, Space, Space) {
        let home = Space(name: "Home", sortRank: "a")
        let store = SidebarStore(spaces: [home])
        let away = store.addSpace(name: "Away")
        store.selectSpace(home.id)
        return (store, home, away)
    }

    private let page = URL(string: "about:blank")!

    func testATabBecomesItsOwnSpacesSelectionWhileAnotherSpaceStaysOnScreen() {
        let (store, home, away) = twoSpaces()
        let shown = store.addTab(kind: .today, title: "Shown", url: page, in: home.id)
        store.selectTab(shown.id)
        let first = store.addTab(kind: .today, title: "First", url: page, in: away.id)
        let second = store.addTab(kind: .today, title: "Second", url: page, in: away.id)

        XCTAssertTrue(store.selectTabInItsSpace(first.id))
        XCTAssertEqual(store.activeSpaceID, home.id, "the space on screen stayed")
        XCTAssertEqual(store.selectedTabID, shown.id, "and so did its selection")
        XCTAssertEqual(store.selectedTab(inSpace: away.id)?.id, first.id)
        XCTAssertTrue(store.selectTabInItsSpace(second.id))
        XCTAssertEqual(store.selectedTab(inSpace: away.id)?.id, second.id)

        store.selectSpace(away.id)
        XCTAssertEqual(store.selectedTabID, second.id, "the space comes back showing the tab")
    }

    func testInTheSpaceOnScreenItIsAnOrdinarySelection() {
        let (store, home, _) = twoSpaces()
        let tab = store.addTab(kind: .today, title: "Here", url: page, in: home.id)
        XCTAssertTrue(store.selectTabInItsSpace(tab.id))
        XCTAssertEqual(store.selectedTabID, tab.id)
    }

    func testASpaceLeftBlankTakesTheTab() {
        let (store, home, away) = twoSpaces()
        store.selectSpace(away.id)
        let tab = store.addTab(kind: .today, title: "Later", url: page, in: away.id)
        XCTAssertNil(store.selectedItemID)
        store.selectSpace(home.id)
        XCTAssertNil(store.selectedTab(inSpace: away.id), "left with nothing selected, it would come back blank")
        XCTAssertTrue(store.selectTabInItsSpace(tab.id))
        XCTAssertEqual(store.selectedTab(inSpace: away.id)?.id, tab.id)
    }

    func testATabWithoutAnOpenPageOrASpaceCannotBeSelectedThere() {
        let (store, home, away) = twoSpaces()
        let shown = store.addTab(kind: .today, title: "Shown", url: page, in: home.id)
        store.selectTab(shown.id)
        let open = store.addTab(kind: .today, title: "Open", url: page, in: away.id)
        let unloaded = store.addTab(kind: .today, title: "Unloaded", url: page, in: away.id)
        store.isTabOpen = { $0 != unloaded.id }
        XCTAssertTrue(store.selectTabInItsSpace(open.id))
        XCTAssertFalse(store.selectTabInItsSpace(unloaded.id), "only an open page can be a space's selection without loading")
        XCTAssertEqual(store.selectedTab(inSpace: away.id)?.id, open.id, "nothing changed")
        let favorite = store.addTab(kind: .favorite, title: "Favorite", url: page)
        XCTAssertFalse(store.selectTabInItsSpace(favorite.id), "a favorite is in no space")
        XCTAssertFalse(store.selectTabInItsSpace(UUID()))
        XCTAssertEqual(store.activeSpaceID, home.id)
        XCTAssertEqual(store.selectedTabID, shown.id)
    }

    func testASplitTakesTheSelectionWithTheTabAsItsFocusedPane() throws {
        let (store, home, away) = twoSpaces()
        let shown = store.addTab(kind: .today, title: "Shown", url: page, in: home.id)
        store.selectTab(shown.id)
        store.selectSpace(away.id)
        let left = store.addTab(kind: .today, title: "Left", url: page, in: away.id)
        let right = store.addTab(kind: .today, title: "Right", url: page, in: away.id)
        let split = try XCTUnwrap(store.splitTab(right.id, with: left.id))
        store.selectSplit(split.id, focusTabID: left.id)
        store.selectSpace(home.id)

        XCTAssertTrue(store.selectTabInItsSpace(right.id))
        XCTAssertEqual(store.activeSpaceID, home.id)
        XCTAssertEqual(store.selectedItemID(inSpace: away.id), split.id)
        XCTAssertEqual(store.selectedTab(inSpace: away.id)?.id, right.id)
    }
}
