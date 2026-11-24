import XCTest
@testable import SidebarModel

/// Tab sleep: a tab left unseen is frozen first and unloaded later. The
/// policy decides which tabs; the engine does the freezing and the unload.
final class TabSleepPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    /// One domain for the class, emptied before and after each test and removed
    /// with its file at the end: the app's own defaults are never written.
    private static let domain = "darni-sleep-policy-tests"

    private func scratchDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: Self.domain))
    }

    private static func clearDefaults() {
        UserDefaults.standard.removePersistentDomain(forName: domain)
        CFPreferencesAppSynchronize(domain as CFString)
    }

    override func setUp() {
        super.setUp()
        Self.clearDefaults()
    }

    override func tearDown() {
        Self.clearDefaults()
        super.tearDown()
    }

    override class func tearDown() {
        clearDefaults()
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(domain).plist")
        try? FileManager.default.removeItem(at: file)
        super.tearDown()
    }

    // MARK: Thresholds

    func testTheFreezeChoicesAreNeverFifteenThirtyAndAnHour() {
        XCTAssertEqual(TabFreezeThreshold.allCases, [.never, .fifteenMinutes, .thirtyMinutes, .oneHour])
        XCTAssertEqual(TabFreezeThreshold.allCases.map(\.interval), [nil, 900, 1800, 3600])
        XCTAssertEqual(TabFreezeThreshold.allCases.map(\.title), ["Never", "After 15 Minutes", "After 30 Minutes", "After 1 Hour"])
    }

    func testTabsFreezeAfterThirtyMinutesAndUnloadAfterFourHoursByDefault() throws {
        let defaults = try scratchDefaults()
        XCTAssertEqual(TabFreezeThreshold.load(from: defaults), .thirtyMinutes)
        XCTAssertEqual(TabUnloadThreshold.load(from: defaults), .fourHours)
    }

    func testTheFreezeChoiceIsRememberedUnderItsOwnKey() throws {
        let defaults = try scratchDefaults()
        TabFreezeThreshold.oneHour.save(to: defaults)
        XCTAssertEqual(TabFreezeThreshold.load(from: defaults), .oneHour)
        XCTAssertEqual(defaults.string(forKey: "ReArcTabFreezeThreshold"), "oneHour")
        TabFreezeThreshold.never.save(to: defaults)
        XCTAssertEqual(TabFreezeThreshold.load(from: defaults), .never)
    }

    func testAnExistingUnloadChoiceIsKeptAndTheFreezeStartsAtItsDefault() throws {
        // What a build before tab freezing left behind: the unload key only.
        let defaults = try scratchDefaults()
        defaults.set("twelveHours", forKey: "ReArcTabUnloadThreshold")
        XCTAssertEqual(TabUnloadThreshold.load(from: defaults), .twelveHours)
        XCTAssertEqual(TabFreezeThreshold.load(from: defaults), .thirtyMinutes)
        // Saving the freeze choice leaves the unload choice as it was.
        TabFreezeThreshold.fifteenMinutes.save(to: defaults)
        XCTAssertEqual(defaults.string(forKey: "ReArcTabUnloadThreshold"), "twelveHours")
    }

    func testAnUnknownStoredValueFallsBackToTheDefault() throws {
        // A later build may store a choice this one does not know.
        let defaults = try scratchDefaults()
        defaults.set("twoMinutes", forKey: "ReArcTabFreezeThreshold")
        XCTAssertEqual(TabFreezeThreshold.load(from: defaults), .thirtyMinutes)
    }

    // MARK: Freeze, then unload

    func testATabIsFrozenAtTheFreezeThresholdAndUnloadedAtTheUnloadThreshold() {
        let young = Tab.ID(), idle = Tab.ID(), old = Tab.ID()
        let candidates = [
            TabUnloadCandidate(tabID: young, lastActive: ago(10)),
            TabUnloadCandidate(tabID: idle, lastActive: ago(45)),
            TabUnloadCandidate(tabID: old, lastActive: ago(5 * 60)),
        ]
        // Oldest first.
        XCTAssertEqual(TabUnloadPolicy.tabsToFreeze(candidates, threshold: .thirtyMinutes, now: now), [old, idle])
        XCTAssertEqual(TabUnloadPolicy.tabsToUnload(candidates, threshold: .fourHours, now: now), [old])
        XCTAssertEqual(TabUnloadPolicy.tabsToFreeze(candidates, threshold: .fifteenMinutes, now: now), [old, idle])
        XCTAssertEqual(TabUnloadPolicy.tabsToFreeze(candidates, threshold: .oneHour, now: now), [old])
        XCTAssertEqual(TabUnloadPolicy.tabsToFreeze(candidates, threshold: .never, now: now), [])
    }

    func testTheThresholdIsReachedExactlyAtItsMinute() {
        let id = Tab.ID()
        let almost = [TabUnloadCandidate(tabID: id, lastActive: now.addingTimeInterval(-1799))]
        let exactly = [TabUnloadCandidate(tabID: id, lastActive: now.addingTimeInterval(-1800))]
        XCTAssertEqual(TabUnloadPolicy.tabsToFreeze(almost, threshold: .thirtyMinutes, now: now), [])
        XCTAssertEqual(TabUnloadPolicy.tabsToFreeze(exactly, threshold: .thirtyMinutes, now: now), [id])
    }

    func testAFrozenTabIsNotAskedAgainAndIsStillUnloadedLater() {
        let id = Tab.ID()
        let frozen = [TabUnloadCandidate(tabID: id, lastActive: ago(5 * 60), isFrozen: true)]
        XCTAssertEqual(TabUnloadPolicy.tabsToFreeze(frozen, threshold: .thirtyMinutes, now: now), [])
        XCTAssertEqual(TabUnloadPolicy.tabsToUnload(frozen, threshold: .fourHours, now: now), [id])
    }

    func testAnUnloadedOrLoadingTabIsNeitherFrozenNorUnloaded() {
        let unloaded = [TabUnloadCandidate(tabID: Tab.ID(), lastActive: ago(9 * 60), isUnloaded: true)]
        XCTAssertEqual(TabUnloadPolicy.tabsToFreeze(unloaded, threshold: .fifteenMinutes, now: now), [])
        XCTAssertEqual(TabUnloadPolicy.tabsToUnload(unloaded, threshold: .thirtyMinutes, now: now), [])
    }

    // MARK: Every exemption

    /// One candidate per reason a tab is in use, each unseen for nine hours.
    private func inUse() -> [(reason: String, candidate: TabUnloadCandidate)] {
        let long = ago(9 * 60)
        return [
            ("on screen", TabUnloadCandidate(tabID: Tab.ID(), lastActive: long, isVisible: true)),
            ("audible or playing", TabUnloadCandidate(tabID: Tab.ID(), lastActive: long, isAudible: true)),
            ("a prompt or passkey request waits", TabUnloadCandidate(tabID: Tab.ID(), lastActive: long, hasPendingPrompt: true)),
            ("camera, microphone, call or sharing", TabUnloadCandidate(tabID: Tab.ID(), lastActive: long, isCapturing: true)),
            ("shared by another page", TabUnloadCandidate(tabID: Tab.ID(), lastActive: long, isShared: true)),
            ("a download is running", TabUnloadCandidate(tabID: Tab.ID(), lastActive: long, hasDownload: true)),
            ("Peek or Little Darni", TabUnloadCandidate(tabID: Tab.ID(), lastActive: long, isTransient: true)),
        ]
    }

    func testATabInUseIsNeverFrozen() {
        for (reason, candidate) in inUse() {
            XCTAssertTrue(candidate.isInUse, reason)
            for threshold in TabFreezeThreshold.allCases {
                XCTAssertEqual(TabUnloadPolicy.tabsToFreeze([candidate], threshold: threshold, now: now), [], "\(reason), \(threshold)")
            }
        }
    }

    func testATabInUseIsNeverUnloaded() {
        for (reason, candidate) in inUse() {
            for threshold in TabUnloadThreshold.allCases {
                XCTAssertEqual(TabUnloadPolicy.tabsToUnload([candidate], threshold: threshold, now: now), [], "\(reason), \(threshold)")
            }
        }
    }

    func testATabThatIsOnlyIdleIsNotInUse() {
        let idle = TabUnloadCandidate(tabID: Tab.ID(), lastActive: ago(9 * 60))
        XCTAssertFalse(idle.isInUse)
        XCTAssertFalse(TabUnloadCandidate(tabID: Tab.ID(), lastActive: ago(9 * 60), isFrozen: true).isInUse, "frozen is not a use")
        XCTAssertFalse(TabUnloadCandidate(tabID: Tab.ID(), lastActive: ago(9 * 60), isUnloaded: true).isInUse)
    }

    func testOneTabInUseDoesNotKeepTheOthersAwake() {
        let busy = TabUnloadCandidate(tabID: Tab.ID(), lastActive: ago(120), isAudible: true)
        let idle = TabUnloadCandidate(tabID: Tab.ID(), lastActive: ago(120))
        XCTAssertEqual(TabUnloadPolicy.tabsToFreeze([busy, idle], threshold: .thirtyMinutes, now: now), [idle.tabID])
    }

    // MARK: Thawing

    func testAFrozenTabThatIsInUseAgainIsThawed() {
        for (reason, candidate) in inUse() {
            var frozen = candidate
            frozen.isFrozen = true
            XCTAssertEqual(TabUnloadPolicy.tabsToThaw([frozen], threshold: .thirtyMinutes, now: now), [frozen.tabID], reason)
        }
    }

    func testAFrozenTabThatIsStillIdleStaysFrozen() {
        let frozen = [TabUnloadCandidate(tabID: Tab.ID(), lastActive: ago(45), isFrozen: true)]
        XCTAssertEqual(TabUnloadPolicy.tabsToThaw(frozen, threshold: .thirtyMinutes, now: now), [])
        XCTAssertEqual(TabUnloadPolicy.tabsToThaw(frozen, threshold: .fifteenMinutes, now: now), [])
    }

    func testRaisingTheThresholdOrTurningItOffThawsTabsNoLongerDue() {
        let id = Tab.ID()
        let frozen = [TabUnloadCandidate(tabID: id, lastActive: ago(45), isFrozen: true)]
        XCTAssertEqual(TabUnloadPolicy.tabsToThaw(frozen, threshold: .oneHour, now: now), [id])
        XCTAssertEqual(TabUnloadPolicy.tabsToThaw(frozen, threshold: .never, now: now), [id])
    }

    func testATabThatIsNotFrozenIsNeverInTheThawList() {
        let running = inUse().map(\.candidate) + [TabUnloadCandidate(tabID: Tab.ID(), lastActive: ago(1))]
        XCTAssertEqual(TabUnloadPolicy.tabsToThaw(running, threshold: .never, now: now), [])
    }

    // MARK: The shared tab

    func testATabChosenForAShareIsATargetBeforeItsStreamIsLiveAndUntilItEnds() {
        var ledger = ScreenShareLedger<Int>()
        XCTAssertEqual(ledger.chosenTargets, [])
        ledger.noteChosen(ScreenShare(kind: .tab, target: 2), by: 1)
        ledger.noteChosen(ScreenShare(kind: .window), by: 1)
        XCTAssertEqual(ledger.chosenTargets, [2], "chosen: the capture is about to start")
        ledger.captureChanged(1, isCapturingDisplay: true)
        XCTAssertEqual(ledger.chosenTargets, [2])
        ledger.captureChanged(1, isCapturingDisplay: false)
        XCTAssertEqual(ledger.chosenTargets, [], "the share is over")
    }

    func testAClosedTargetIsNoLongerOne() {
        var ledger = ScreenShareLedger<Int>()
        ledger.noteChosen(ScreenShare(kind: .tab, target: 2), by: 1)
        ledger.forget(2)
        XCTAssertEqual(ledger.chosenTargets, [])
    }
}
