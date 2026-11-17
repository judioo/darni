import XCTest
@testable import SidebarModel

/// 1Password's connection, from process facts alone: what one reading says,
/// what a launch's readings add up to, and the one value kept between
/// launches (security pre-review of 2026-11-17, proposal B, condition 8).
final class OnePasswordConnectionTests: XCTestCase {
    private typealias Connection = OnePasswordConnection
    private typealias State = OnePasswordConnectionState

    private let helper = "/Applications/1Password.app/Contents/Library/LoginItems/1Password Browser Helper.app/Contents/MacOS/1Password-BrowserSupport"
    private let renderer = "/Applications/ReArc.app/Contents/Frameworks/ReArc Helper (Renderer).app/Contents/MacOS/ReArc Helper (Renderer)"
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "OnePasswordConnectionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// ReArc's children: its own renderer, and 1Password's helper when it
    /// has an age.
    private func snapshot(helperAge: TimeInterval? = nil, helperPath: String? = nil) -> ChildProcessSnapshot {
        var children = [ChildProcessFact(executablePath: renderer, startTime: now.addingTimeInterval(-3600))]
        if let helperAge {
            children.append(ChildProcessFact(executablePath: helperPath ?? helper, startTime: now.addingTimeInterval(-helperAge)))
        }
        return ChildProcessSnapshot(takenAt: now, children: children)
    }

    private func reading(helperAge: TimeInterval? = nil, appRunning: Bool = true, extension installed: Bool = true,
                         manifestPath: String? = "") -> Connection.Reading {
        Connection.reading(of: snapshot(helperAge: helperAge), helperPath: manifestPath == "" ? helper : manifestPath,
                           appRunning: appRunning, extensionInstalled: installed)
    }

    /// Readings every `pollInterval` from `start`, the last at or after `end`.
    @discardableResult
    private func record(_ reading: Connection.Reading, in state: inout State, from start: TimeInterval = 0,
                        through end: TimeInterval) -> [State.Outcome] {
        var outcomes: [State.Outcome] = []
        var uptime = start
        while true {
            outcomes.append(state.record(reading, uptime: uptime))
            if uptime >= end { return outcomes }
            uptime += Connection.pollInterval
        }
    }

    // MARK: One reading

    func testNoHelperIsNotConnected() {
        XCTAssertEqual(reading(), .absent)
        XCTAssertEqual(Connection.reading(of: ChildProcessSnapshot(takenAt: now, children: []), helperPath: helper,
                                          appRunning: true, extensionInstalled: true), .absent)
    }

    func testAHelperAliveWithTheAppRunningIsAttachedFromThirtySeconds() {
        XCTAssertEqual(reading(helperAge: 30), .attached)
        XCTAssertEqual(reading(helperAge: 3600), .attached)
        XCTAssertEqual(Connection.minimumHelperAge, 30)
    }

    func testAYoungHelperHasNotStayedYet() {
        XCTAssertEqual(reading(helperAge: 0.5), .absent)
        XCTAssertEqual(reading(helperAge: 10), .absent, "A helper waiting for the app outlives ten seconds")
        XCTAssertEqual(reading(helperAge: 29.9), .absent)
    }

    func testAHelperAliveWithoutTheAppRunningIsNotConnected() {
        XCTAssertEqual(reading(helperAge: 3600, appRunning: false), .unknown)
        XCTAssertEqual(reading(appRunning: false), .unknown)
    }

    func testTheHelperIsKnownByTheManifestsPathNotByItsName() {
        let lookalike = "/Users/someone/Downloads/1Password-BrowserSupport"
        XCTAssertEqual(Connection.reading(of: snapshot(helperAge: 3600, helperPath: lookalike), helperPath: helper,
                                          appRunning: true, extensionInstalled: true), .absent)
        // The manifest names another path: that one is the helper.
        XCTAssertEqual(Connection.reading(of: snapshot(helperAge: 3600, helperPath: lookalike), helperPath: lookalike,
                                          appRunning: true, extensionInstalled: true), .attached)
    }

    func testWithoutAManifestPathNothingIsKnown() {
        XCTAssertEqual(reading(helperAge: 3600, manifestPath: nil), .unknown)
        XCTAssertEqual(Connection.reading(of: snapshot(helperAge: 3600, helperPath: ""), helperPath: "",
                                          appRunning: true, extensionInstalled: true), .unknown)
    }

    func testWithoutTheExtensionAMissingHelperSaysNothing() {
        XCTAssertEqual(reading(extension: false), .unknown)
        XCTAssertEqual(reading(helperAge: 3600, extension: false), .attached, "A helper that stayed is evidence either way")
    }

    func testChildrenNotListedIsNoHelper() {
        XCTAssertEqual(Connection.reading(of: nil, helperPath: helper, appRunning: true, extensionInstalled: true), .absent)
        XCTAssertEqual(Connection.reading(of: nil, helperPath: helper, appRunning: false, extensionInstalled: true), .unknown)
    }

    func testAnEarlierStartThanTheSnapshotNeverCountsBackwards() {
        // The clock was set back: a start time after the snapshot is not an age.
        XCTAssertEqual(reading(helperAge: -120), .absent)
    }

    // MARK: A launch's readings

    func testNothingReadYetIsNotConnectedAndHidesNothing() {
        let state = State()
        XCTAssertFalse(state.isConnected(uptime: 0))
        XCTAssertFalse(state.hidesPrompt)
        XCTAssertFalse(state.hasVerdict)
        XCTAssertFalse(state.stored)
    }

    func testNoHelperNeverConnectsAndTheVerdictComesAfterTheDelay() {
        var state = State()
        let outcomes = record(.absent, in: &state, through: Connection.verdictDelay)
        XCTAssertEqual(outcomes.last, .notConnected(lost: false))
        XCTAssertEqual(outcomes.dropLast().filter { $0 != .nothingNew }, [])
        XCTAssertTrue(state.hasVerdict)
        XCTAssertFalse(state.hidesPrompt)
        XCTAssertFalse(state.isConnected(uptime: Connection.verdictDelay))
        XCTAssertFalse(state.stored)
        XCTAssertEqual(state.record(.absent, uptime: 500), .nothingNew, "One verdict a launch")
    }

    func testAHelperThatExitsAtOnceNeverConnects() {
        var state = State()
        // Seen young in one reading, gone by the next.
        XCTAssertEqual(state.record(reading(helperAge: 0.4), uptime: 8), .nothingNew)
        XCTAssertEqual(state.record(reading(), uptime: 28), .nothingNew)
        XCTAssertFalse(state.isConnected(uptime: 28))
        XCTAssertFalse(state.hidesPrompt)
        XCTAssertFalse(state.stored)
        XCTAssertEqual(state.record(reading(), uptime: 8 + Connection.verdictDelay), .notConnected(lost: false))
    }

    func testAHelperAliveWithTheAppNotRunningDoesNotConnect() {
        var state = State()
        XCTAssertEqual(state.record(reading(helperAge: 600, appRunning: false), uptime: 0), .nothingNew)
        XCTAssertFalse(state.isConnected(uptime: 0))
        XCTAssertFalse(state.hidesPrompt)
        XCTAssertFalse(state.stored)
    }

    func testAHelperAliveWithTheAppRunningConnects() {
        var state = State()
        XCTAssertEqual(state.record(reading(helperAge: 12), uptime: 20), .nothingNew)
        XCTAssertEqual(state.record(reading(helperAge: 32), uptime: 40), .connected)
        XCTAssertTrue(state.isConnected(uptime: 40))
        XCTAssertTrue(state.hidesPrompt)
        XCTAssertTrue(state.hasVerdict)
        XCTAssertTrue(state.wasConnectedThisLaunch)
        XCTAssertTrue(state.stored)
        XCTAssertEqual(state.record(reading(helperAge: 52), uptime: 60), .nothingNew, "Said once")
    }

    func testConnectedIsSaidOnlyFromAFreshReading() {
        var state = State()
        state.record(.attached, uptime: 100)
        XCTAssertTrue(state.isConnected(uptime: 100 + Connection.readingLifetime))
        XCTAssertFalse(state.isConnected(uptime: 100 + Connection.readingLifetime + 1), "Nobody has looked since")
        XCTAssertTrue(state.hidesPrompt, "The prompt stays away all the same")
    }

    func testAHelperThatGoesAfterConnectingFallsBackWithoutThePromptInThatLaunch() {
        var state = State()
        state.record(.attached, uptime: 40)
        XCTAssertEqual(state.record(.absent, uptime: 60), .nothingNew)
        XCTAssertFalse(state.isConnected(uptime: 60), "Settings goes back to the steps")
        XCTAssertTrue(state.hidesPrompt, "The prompt does not come back in this launch")
        XCTAssertEqual(state.record(.absent, uptime: 600), .nothingNew, "Nor does a later reading call it lost")
        XCTAssertTrue(state.stored, "The next launch decides")

        // 1Password quit instead: the same.
        var quit = State()
        quit.record(.attached, uptime: 40)
        XCTAssertEqual(quit.record(.unknown, uptime: 60), .nothingNew)
        XCTAssertFalse(quit.isConnected(uptime: 60))
        XCTAssertTrue(quit.hidesPrompt)
    }

    func testAConnectionAfterTheVerdictStillCounts() {
        var state = State()
        record(.absent, in: &state, through: Connection.verdictDelay)
        XCTAssertFalse(state.hidesPrompt)
        // The person added ReArc in 1Password and the extension connected again.
        XCTAssertEqual(state.record(.attached, uptime: 400), .connected)
        XCTAssertTrue(state.hidesPrompt)
        XCTAssertTrue(state.stored)
    }

    func testAMacAsleepDoesNotUseUpTheDelay() {
        // Uptime stands still in sleep: two readings a moment apart are not a verdict.
        var state = State(stored: true)
        XCTAssertEqual(state.record(.absent, uptime: 3), .nothingNew)
        XCTAssertEqual(state.record(.absent, uptime: 4), .nothingNew)
        XCTAssertFalse(state.hasVerdict)
        XCTAssertTrue(state.hidesPrompt)
    }

    // MARK: The stored value

    func testAStoredValueHidesThePromptAndNothingMore() {
        let state = State(stored: true)
        XCTAssertTrue(state.hidesPrompt)
        XCTAssertFalse(state.isConnected(uptime: 0), "Settings never says Connected from an earlier launch")
        XCTAssertFalse(state.wasConnectedThisLaunch)
        XCTAssertFalse(state.hasVerdict)
    }

    func testAStoredValueHidesOnlyUntilThisLaunchsVerdict() {
        var state = State(stored: true)
        XCTAssertEqual(state.record(.absent, uptime: 0), .nothingNew)
        XCTAssertEqual(state.record(.absent, uptime: Connection.verdictDelay - 1), .nothingNew)
        XCTAssertTrue(state.hidesPrompt, "Still waiting for the helper")
        XCTAssertFalse(state.isConnected(uptime: Connection.verdictDelay - 1))

        XCTAssertEqual(state.record(.absent, uptime: Connection.verdictDelay), .notConnected(lost: true))
        XCTAssertFalse(state.hidesPrompt)
        XCTAssertFalse(state.stored)
    }

    func testAStoredValueIsConfirmedByThisLaunchsOwnReading() {
        var state = State(stored: true)
        XCTAssertEqual(state.record(.absent, uptime: 0), .nothingNew)
        XCTAssertEqual(state.record(.attached, uptime: 40), .connected)
        XCTAssertTrue(state.isConnected(uptime: 40))
        XCTAssertTrue(state.hidesPrompt)
        XCTAssertTrue(state.stored)
    }

    func testALaunchWithoutTheAppRunningStopsHidingAndKeepsTheStoredValue() {
        var state = State(stored: true)
        let outcomes = record(.unknown, in: &state, through: Connection.verdictDelay)
        XCTAssertEqual(outcomes.last, .notConnected(lost: false), "It could not tell, so nothing was lost")
        XCTAssertFalse(state.hidesPrompt, "The stored value hid the prompt until the verdict, and no longer")
        XCTAssertTrue(state.stored, "The next launch with 1Password running decides")
    }

    func testOneReadingWithoutTheAppIsEnoughNotToCallItLost() {
        var state = State(stored: true)
        state.record(.unknown, uptime: 0) // 1Password started after ReArc
        XCTAssertEqual(record(.absent, in: &state, from: 20, through: Connection.verdictDelay).last, .notConnected(lost: false))
        XCTAssertTrue(state.stored)
        XCTAssertFalse(state.hidesPrompt)
    }

    func testNothingStoredAndNothingSeenIsNotLost() {
        var state = State()
        XCTAssertEqual(record(.absent, in: &state, through: Connection.verdictDelay).last, .notConnected(lost: false))
    }

    func testTheStoredValueRoundTripsUnderReArcsOwnKey() {
        XCTAssertEqual(State.load(from: defaults), State(), "Nothing saved reads as never seen")

        var state = State()
        state.record(.attached, uptime: 40)
        state.save(to: defaults)
        XCTAssertEqual(State.storedKey, "rearc.onePasswordConnectionSeen")
        XCTAssertEqual(defaults.object(forKey: "rearc.onePasswordConnectionSeen") as? Bool, true)

        // The next launch gets the stored value and none of this launch's readings.
        let next = State.load(from: defaults)
        XCTAssertEqual(next, State(stored: true))
        XCTAssertFalse(next.isConnected(uptime: 40))
        XCTAssertFalse(next.wasConnectedThisLaunch)
    }

    func testOnlyOneKeyIsWritten() {
        var state = State(stored: true)
        state.record(.attached, uptime: 40)
        state.save(to: defaults)
        XCTAssertEqual(Set(defaults.persistentDomain(forName: suiteName)?.keys.map { $0 } ?? []), [State.storedKey])
    }

    // MARK: The numbers

    func testThePollIsSeldomAndTheVerdictLeavesRoomForTheHelperToStay() {
        XCTAssertGreaterThanOrEqual(Connection.pollInterval, 15)
        XCTAssertLessThanOrEqual(Connection.pollInterval, 30)
        XCTAssertGreaterThanOrEqual(Connection.verdictDelay, Connection.minimumHelperAge + 2 * Connection.pollInterval)
        XCTAssertEqual(Connection.hostName, "com.1password.1password")
    }
}
