import XCTest
@testable import ReArc
@testable import SidebarModel

/// Stands in for the 1Password app: answers at once, records what was
/// opened, never asks LaunchServices or the workspace.
private final class FakeOnePasswordApp: OnePasswordAppLocating {
    var installed: URL?
    var isRunning = false
    private(set) var looks = 0
    private(set) var opened: [URL] = []

    init(installed: URL? = URL(fileURLWithPath: "/Applications/1Password.app", isDirectory: true)) {
        self.installed = installed
    }

    func locate(_ completion: @escaping (URL?) -> Void) {
        looks += 1
        completion(installed)
    }

    func open(_ app: URL) { opened.append(app) }
}

/// Stands in for ReArc's children: a renderer, and 1Password's helper while
/// `helperStartedAt` says it runs. Time is the test's.
private final class FakeChildProcesses: ChildProcessListing {
    static let helper = "/Applications/1Password.app/Contents/Library/LoginItems/1Password Browser Helper.app/Contents/MacOS/1Password-BrowserSupport"
    private static let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Seconds since the launch.
    var uptime: TimeInterval = 0
    /// When the helper started, in the same seconds; nil while none runs.
    var helperStartedAt: TimeInterval?
    var helperPath = FakeChildProcesses.helper
    private(set) var listings = 0

    func snapshot() -> ChildProcessSnapshot {
        listings += 1
        var children = [ChildProcessFact(executablePath: "/Applications/ReArc.app/Contents/MacOS/ReArc Helper (Renderer)",
                                         startTime: Self.epoch)]
        if let helperStartedAt {
            children.append(ChildProcessFact(executablePath: helperPath, startTime: Self.epoch.addingTimeInterval(helperStartedAt)))
        }
        return ChildProcessSnapshot(takenAt: Self.epoch.addingTimeInterval(uptime), children: children)
    }
}

/// "Connect 1Password to ReArc": what the shell does with the model's
/// decision (the sidebar card, Settings › General's row, the buttons).
final class OnePasswordConnectShellTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    /// Engines stand-ins: the extensions controller keys actions by object.
    private let tab = NSObject()
    private let otherTab = NSObject()

    private let onePassword = ExtensionActionItem(id: "aeblfdkhhhdcdjpifhhbdiojplfjncoa", name: "1Password – Password Manager")
    private let other = ExtensionActionItem(id: "cjpalhdlnbpafiamejdnhcphjbkeiagm", name: "uBlock Origin")

    override func setUp() {
        super.setUp()
        suiteName = "rearc-1password-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// A launch: the saved preference, then startup with `app` in place.
    /// `processes` are ReArc's children and the launch's clock; the helper's
    /// path is the one the launch's manifest names.
    private func makeModel(_ app: FakeOnePasswordApp, processes: FakeChildProcesses = FakeChildProcesses(),
                           helperPath: String? = FakeChildProcesses.helper) -> BrowserViewModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-1password-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: SidebarStore(spaces: [Space(name: "Main", sortRank: "a")]),
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil),
            deferStartup: true
        )
        model.externalLinkDefaults = defaults
        model.onePasswordPreference = .load(from: defaults)
        model.onePasswordConnection = .load(from: defaults)
        model.onePasswordApp = app
        model.onePasswordProcesses = processes
        model.onePasswordHelperPath = helperPath
        model.onePasswordUptime = { processes.uptime }
        model.finishStartup()
        return model
    }

    /// A launch with 1Password installed and running and its extension in a tab.
    private func launch(appRunning: Bool = true, helperPath: String? = FakeChildProcesses.helper)
        -> (model: BrowserViewModel, app: FakeOnePasswordApp, processes: FakeChildProcesses) {
        let app = FakeOnePasswordApp()
        app.isRunning = appRunning
        let processes = FakeChildProcesses()
        let model = makeModel(app, processes: processes, helperPath: helperPath)
        model.extensions.setActions([other, onePassword], for: tab)
        return (model, app, processes)
    }

    /// The watch's turns: one every poll interval until `seconds` have gone by.
    private func run(_ model: BrowserViewModel, _ processes: FakeChildProcesses, for seconds: TimeInterval) {
        let end = processes.uptime + seconds
        while processes.uptime < end {
            processes.uptime += OnePasswordConnection.pollInterval
            model.pollOnePasswordConnection()
        }
    }

    private var storedConnection: Bool? { defaults.object(forKey: OnePasswordConnectionState.storedKey) as? Bool }

    // MARK: When the card shows

    func testShowsOnceTheAppIsFoundAndTheExtensionHasAnAction() {
        let app = FakeOnePasswordApp()
        let model = makeModel(app)
        XCTAssertEqual(app.looks, 1)
        XCTAssertFalse(model.showsOnePasswordPrompt, "No extension yet")

        model.extensions.setActions([other, onePassword], for: tab)
        XCTAssertTrue(model.hasOnePasswordExtension)
        XCTAssertTrue(model.showsOnePasswordPrompt)
    }

    func testShowsRightAfterTheExtensionIsInstalled() {
        let model = makeModel(FakeOnePasswordApp())
        model.extensions.setActions([other], for: tab)
        XCTAssertFalse(model.showsOnePasswordPrompt)

        // The install's refresh brings the new action.
        model.extensions.setActions([other, onePassword], for: tab)
        XCTAssertTrue(model.showsOnePasswordPrompt)
    }

    func testAnotherExtensionIsNotOnePassword() {
        let model = makeModel(FakeOnePasswordApp())
        model.extensions.setActions([other], for: tab)
        XCTAssertFalse(model.hasOnePasswordExtension)
        XCTAssertFalse(model.showsOnePasswordPrompt)
    }

    func testTheExtensionInAnyTabCounts() {
        let model = makeModel(FakeOnePasswordApp())
        model.extensions.setActions([other], for: tab)
        model.extensions.setActions([onePassword], for: otherTab)
        XCTAssertTrue(model.showsOnePasswordPrompt)

        model.extensions.forgetEngine(otherTab)
        XCTAssertFalse(model.showsOnePasswordPrompt, "Removed with its last action")
    }

    func testWithoutTheAppNothingShows() {
        let app = FakeOnePasswordApp(installed: nil)
        let model = makeModel(app)
        model.extensions.setActions([onePassword], for: tab)
        XCTAssertEqual(app.looks, 1)
        XCTAssertNil(model.onePasswordAppURL)
        XCTAssertFalse(model.showsOnePasswordPrompt)
        XCTAssertFalse(model.showsOnePasswordSettingsRow)
    }

    // MARK: Done

    func testDoneHidesTheCardForGoodAndKeepsTheSettingsRow() {
        let model = makeModel(FakeOnePasswordApp())
        model.extensions.setActions([onePassword], for: tab)
        model.markOnePasswordConnected()

        XCTAssertFalse(model.showsOnePasswordPrompt)
        XCTAssertTrue(model.showsOnePasswordSettingsRow)
        XCTAssertEqual(OnePasswordConnectPreference.load(from: defaults), OnePasswordConnectPreference(isDone: true, dismissals: 0))

        let app = FakeOnePasswordApp()
        let relaunched = makeModel(app)
        relaunched.extensions.setActions([onePassword], for: tab)
        XCTAssertFalse(relaunched.showsOnePasswordPrompt)
        XCTAssertEqual(app.looks, 0, "A launch after Done does not look for the app")
    }

    // MARK: The close button

    func testCloseHidesForTheLaunchAndTheCardComesBackOnceMore() {
        let first = makeModel(FakeOnePasswordApp())
        first.extensions.setActions([onePassword], for: tab)
        first.dismissOnePasswordPrompt()
        XCTAssertFalse(first.showsOnePasswordPrompt)
        XCTAssertEqual(OnePasswordConnectPreference.load(from: defaults).dismissals, 1)
        // A second press in the same launch (another window's card) counts once.
        first.dismissOnePasswordPrompt()
        XCTAssertEqual(OnePasswordConnectPreference.load(from: defaults).dismissals, 1)

        let second = makeModel(FakeOnePasswordApp())
        second.extensions.setActions([onePassword], for: tab)
        XCTAssertTrue(second.showsOnePasswordPrompt, "Once more on a later launch")
        second.dismissOnePasswordPrompt()
        XCTAssertEqual(OnePasswordConnectPreference.load(from: defaults).dismissals, 2)

        let app = FakeOnePasswordApp()
        let third = makeModel(app)
        third.extensions.setActions([onePassword], for: tab)
        XCTAssertFalse(third.showsOnePasswordPrompt, "Then it stops")
        XCTAssertEqual(app.looks, 0)
        XCTAssertFalse(OnePasswordConnectPreference.load(from: defaults).isDone)
    }

    // MARK: Settings › General

    func testSettingsFindsTheAppAfterTheCardHasStopped() {
        OnePasswordConnectPreference(isDone: true, dismissals: 0).save(to: defaults)
        let app = FakeOnePasswordApp()
        let model = makeModel(app)
        XCTAssertFalse(model.showsOnePasswordSettingsRow, "Not looked for at launch")

        // The pane appears.
        model.locateOnePasswordApp()
        XCTAssertEqual(app.looks, 1)
        XCTAssertTrue(model.showsOnePasswordSettingsRow)
        XCTAssertFalse(model.showsOnePasswordPrompt)
    }

    func testSettingsDropsTheRowWhenTheAppIsGone() {
        let app = FakeOnePasswordApp()
        let model = makeModel(app)
        XCTAssertTrue(model.showsOnePasswordSettingsRow)

        app.installed = nil
        model.locateOnePasswordApp()
        XCTAssertFalse(model.showsOnePasswordSettingsRow)
    }

    // MARK: Open 1Password

    func testOpenOnePasswordOpensTheAppFoundAndNothingElse() {
        let app = FakeOnePasswordApp()
        let model = makeModel(app)
        model.extensions.setActions([onePassword], for: tab)
        model.openOnePassword()

        XCTAssertEqual(app.opened, [URL(fileURLWithPath: "/Applications/1Password.app", isDirectory: true)])
        XCTAssertTrue(model.showsOnePasswordPrompt, "Opening the app is not Done")
        XCTAssertEqual(OnePasswordConnectPreference.load(from: defaults), OnePasswordConnectPreference())
    }

    func testOpenOnePasswordWithoutTheAppDoesNothing() {
        let app = FakeOnePasswordApp(installed: nil)
        let model = makeModel(app)
        model.openOnePassword()
        XCTAssertTrue(app.opened.isEmpty)
    }

    // MARK: The connection (security pre-review of 2026-11-17, proposal B)

    func testNoHelperLeavesTheCardAndTheStepsAsToday() {
        let (model, app, processes) = launch()
        XCTAssertTrue(model.showsOnePasswordPrompt)

        run(model, processes, for: 300)
        XCTAssertTrue(model.showsOnePasswordPrompt)
        XCTAssertFalse(model.isOnePasswordConnected)
        XCTAssertNotEqual(storedConnection, true)
        XCTAssertGreaterThan(processes.listings, 0)
        XCTAssertTrue(app.opened.isEmpty, "Reading never opens 1Password")
    }

    func testAHelperThatExitsAtOnceChangesNothing() {
        let (model, _, processes) = launch()
        // 1Password refused the browser: the helper is there for one reading at most.
        processes.helperStartedAt = 19.5
        run(model, processes, for: 20)
        XCTAssertTrue(model.showsOnePasswordPrompt)
        XCTAssertFalse(model.isOnePasswordConnected)

        processes.helperStartedAt = nil
        run(model, processes, for: 300)
        XCTAssertTrue(model.showsOnePasswordPrompt)
        XCTAssertFalse(model.isOnePasswordConnected)
        XCTAssertNotEqual(storedConnection, true)
    }

    func testAHelperAliveWithoutTheAppRunningIsNotConnected() {
        let (model, _, processes) = launch(appRunning: false)
        processes.helperStartedAt = 8
        model.onePasswordSettingsRowAppeared()
        run(model, processes, for: 300)

        XCTAssertFalse(model.isOnePasswordConnected)
        XCTAssertTrue(model.showsOnePasswordPrompt)
        XCTAssertNotEqual(storedConnection, true)
        XCTAssertEqual(processes.listings, 0, "Without the app running the children are not even listed")
    }

    func testAHelperAliveWithTheAppRunningHidesTheCardAndSettingsSaysConnected() {
        let (model, app, processes) = launch()
        processes.helperStartedAt = 8
        run(model, processes, for: 20)
        XCTAssertTrue(model.showsOnePasswordPrompt, "Twelve seconds is not staying")
        XCTAssertFalse(model.isOnePasswordConnected)

        run(model, processes, for: 20)
        XCTAssertFalse(model.showsOnePasswordPrompt)
        XCTAssertTrue(model.isOnePasswordConnected)
        XCTAssertEqual(storedConnection, true)
        XCTAssertTrue(model.showsOnePasswordSettingsRow, "The row and its steps stay")
        XCTAssertEqual(OnePasswordConnectPreference.load(from: defaults), OnePasswordConnectPreference(),
                       "ReArc does not press Done for the person")
        XCTAssertTrue(app.opened.isEmpty)
    }

    func testTheHelperIsTheOneTheCopiedManifestNames() {
        let (model, _, processes) = launch()
        processes.helperPath = "/Users/someone/Downloads/1Password-BrowserSupport"
        processes.helperStartedAt = 0
        run(model, processes, for: 300)
        XCTAssertFalse(model.isOnePasswordConnected)
        XCTAssertTrue(model.showsOnePasswordPrompt)
    }

    func testWithoutACopiedManifestEverythingIsAsToday() {
        // A development or verification bundle: the hosts were not mirrored.
        let (model, _, processes) = launch(helperPath: nil)
        processes.helperStartedAt = 0
        model.onePasswordSettingsRowAppeared()
        run(model, processes, for: 300)

        XCTAssertTrue(model.showsOnePasswordPrompt)
        XCTAssertFalse(model.isOnePasswordConnected)
        XCTAssertEqual(processes.listings, 0)
        XCTAssertNotEqual(storedConnection, true)
    }

    func testAStoredValueHidesTheCardUntilThisLaunchsReadingAndSettingsDoesNotSayConnected() {
        defaults.set(true, forKey: OnePasswordConnectionState.storedKey)
        let (model, _, processes) = launch()
        XCTAssertFalse(model.showsOnePasswordPrompt, "No flash of the card before the helper has had time to stay")
        XCTAssertFalse(model.isOnePasswordConnected, "Settings says Connected only from this launch's readings")

        processes.helperStartedAt = 8
        run(model, processes, for: 40)
        XCTAssertTrue(model.isOnePasswordConnected)
        XCTAssertFalse(model.showsOnePasswordPrompt)
        XCTAssertEqual(storedConnection, true)
    }

    func testAStoredValueStopsHidingAtThisLaunchsVerdict() {
        defaults.set(true, forKey: OnePasswordConnectionState.storedKey)
        let (model, _, processes) = launch()
        run(model, processes, for: OnePasswordConnection.verdictDelay - OnePasswordConnection.pollInterval)
        XCTAssertFalse(model.showsOnePasswordPrompt)

        run(model, processes, for: 2 * OnePasswordConnection.pollInterval)
        XCTAssertTrue(model.showsOnePasswordPrompt, "1Password ran all along and no helper stayed")
        XCTAssertFalse(model.isOnePasswordConnected)
        XCTAssertEqual(storedConnection, false)

        // The next launch starts as a first one does.
        let (next, _, _) = launch()
        XCTAssertTrue(next.showsOnePasswordPrompt)
    }

    func testALaunchWithoutTheAppRunningKeepsTheStoredValueForTheNext() {
        defaults.set(true, forKey: OnePasswordConnectionState.storedKey)
        let (model, _, processes) = launch(appRunning: false)
        XCTAssertFalse(model.showsOnePasswordPrompt)

        run(model, processes, for: 200)
        XCTAssertTrue(model.showsOnePasswordPrompt, "The stored value hid the card until the verdict, no longer")
        XCTAssertFalse(model.isOnePasswordConnected)
        XCTAssertEqual(storedConnection, true, "This launch could not tell")
    }

    func testAHelperThatGoesAfterConnectingDoesNotBringTheCardBackInThatLaunch() {
        let (model, _, processes) = launch()
        processes.helperStartedAt = 8
        model.onePasswordSettingsRowAppeared()
        run(model, processes, for: 60)
        XCTAssertTrue(model.isOnePasswordConnected)

        processes.helperStartedAt = nil
        run(model, processes, for: 300)
        XCTAssertFalse(model.isOnePasswordConnected, "Settings is back to the steps alone")
        XCTAssertFalse(model.showsOnePasswordPrompt, "The card stays away for this launch")
        XCTAssertEqual(storedConnection, true, "The next launch decides")
        XCTAssertEqual(OnePasswordConnectPreference.load(from: defaults), OnePasswordConnectPreference())
    }

    func testALostConnectionAfterDoneBringsTheCardBackOnce() {
        // An earlier launch: connected, and the person pressed Done.
        defaults.set(true, forKey: OnePasswordConnectionState.storedKey)
        OnePasswordConnectPreference(isDone: true, dismissals: 0).save(to: defaults)

        let (model, app, processes) = launch()
        XCTAssertEqual(app.looks, 1, "A launch after Done looks while a connection could be lost")
        XCTAssertFalse(model.showsOnePasswordPrompt)
        run(model, processes, for: 200)
        XCTAssertTrue(model.showsOnePasswordPrompt, "The connection is gone: the card is back")
        XCTAssertEqual(OnePasswordConnectPreference.load(from: defaults), OnePasswordConnectPreference(isDone: false, dismissals: 1))
        XCTAssertEqual(storedConnection, false)

        model.dismissOnePasswordPrompt()
        let (next, nextApp, nextProcesses) = launch()
        run(next, nextProcesses, for: 200)
        XCTAssertFalse(next.showsOnePasswordPrompt, "Closed once, it stops")
        XCTAssertEqual(nextApp.looks, 0)
        XCTAssertEqual(nextProcesses.listings, 0)
    }

    func testDoneHoldsWhileTheAppIsNotRunning() {
        defaults.set(true, forKey: OnePasswordConnectionState.storedKey)
        OnePasswordConnectPreference(isDone: true, dismissals: 0).save(to: defaults)
        let (model, _, processes) = launch(appRunning: false)
        run(model, processes, for: 300)

        XCTAssertFalse(model.showsOnePasswordPrompt)
        XCTAssertEqual(OnePasswordConnectPreference.load(from: defaults), OnePasswordConnectPreference(isDone: true, dismissals: 0))
        XCTAssertEqual(storedConnection, true)
    }

    func testTheCloseLimitStaysWhateverTheConnection() {
        OnePasswordConnectPreference(isDone: false, dismissals: 2).save(to: defaults)
        defaults.set(true, forKey: OnePasswordConnectionState.storedKey)
        let (model, app, processes) = launch()
        run(model, processes, for: 300)

        XCTAssertFalse(model.showsOnePasswordPrompt, "Closed twice, it stops")
        XCTAssertEqual(app.looks, 0)
        XCTAssertEqual(processes.listings, 0)
        XCTAssertEqual(OnePasswordConnectPreference.load(from: defaults), OnePasswordConnectPreference(isDone: false, dismissals: 2))
    }

    // MARK: When ReArc reads

    func testNothingIsReadOnceTheCardCannotShow() {
        OnePasswordConnectPreference(isDone: true, dismissals: 0).save(to: defaults)
        let (model, _, processes) = launch()
        processes.helperStartedAt = 0
        run(model, processes, for: 300)
        XCTAssertEqual(processes.listings, 0, "Done, and no connection ever seen: nothing to read for")
        XCTAssertNil(model.onePasswordConnectionTimer)
        XCTAssertNil(storedConnection)
    }

    func testReadingStopsOnceConnectedAndWhenTheCardIsClosed() {
        let (model, _, processes) = launch()
        processes.helperStartedAt = 0
        run(model, processes, for: 40)
        XCTAssertTrue(model.isOnePasswordConnected)
        let listed = processes.listings
        run(model, processes, for: 300)
        XCTAssertEqual(processes.listings, listed)
        XCTAssertNil(model.onePasswordConnectionTimer, "The watch ended by itself")

        defaults.removeObject(forKey: OnePasswordConnectionState.storedKey)
        let (closed, _, closedProcesses) = launch()
        closed.dismissOnePasswordPrompt()
        let before = closedProcesses.listings
        run(closed, closedProcesses, for: 300)
        XCTAssertEqual(closedProcesses.listings, before)
        XCTAssertNil(closed.onePasswordConnectionTimer)
    }

    func testNothingIsReadBeforeTheExtensionIsInATab() {
        let app = FakeOnePasswordApp()
        app.isRunning = true
        let processes = FakeChildProcesses()
        let model = makeModel(app, processes: processes)
        run(model, processes, for: 100)
        XCTAssertEqual(processes.listings, 0)
        XCTAssertNotNil(model.onePasswordConnectionTimer, "Still waiting for the extension")

        model.extensions.setActions([onePassword], for: tab)
        run(model, processes, for: 20)
        XCTAssertEqual(processes.listings, 1)
    }

    func testTheSettingsRowReadsWhileItShowsEvenAfterDone() {
        OnePasswordConnectPreference(isDone: true, dismissals: 0).save(to: defaults)
        let (model, _, processes) = launch()
        model.locateOnePasswordApp() // the pane appears
        processes.helperStartedAt = 0
        processes.uptime = 600

        model.onePasswordSettingsRowAppeared()
        XCTAssertEqual(processes.listings, 1, "Read at once")
        XCTAssertTrue(model.isOnePasswordConnected)
        XCTAssertNotNil(model.onePasswordConnectionTimer)
        run(model, processes, for: 40)
        XCTAssertEqual(processes.listings, 3)

        model.onePasswordSettingsRowDisappeared()
        run(model, processes, for: 100)
        XCTAssertEqual(processes.listings, 3, "A closed pane reads nothing")
        XCTAssertNil(model.onePasswordConnectionTimer)
        XCTAssertFalse(model.isOnePasswordConnected, "An old reading no longer says Connected")

        // Shown again: a fresh reading, with the helper gone meanwhile.
        processes.helperStartedAt = nil
        model.onePasswordSettingsRowAppeared()
        XCTAssertFalse(model.isOnePasswordConnected)
    }

    func testOnlyTheOneKeyIsAddedToTheDefaults() {
        let (model, _, processes) = launch()
        processes.helperStartedAt = 0
        run(model, processes, for: 40)
        model.dismissOnePasswordPrompt()

        let keys = (defaults.persistentDomain(forName: suiteName) ?? [:]).keys.filter { $0.localizedCaseInsensitiveContains("onePassword") }
        XCTAssertEqual(keys.sorted(),
                       ["rearc.onePasswordConnectDismissals", "rearc.onePasswordConnectDone", "rearc.onePasswordConnectionSeen"])
    }

    // MARK: The process listing

    func testTheSystemListingFindsADirectChildByItsPathAndStartTime() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        let before = Date()
        try child.run()
        defer { if child.isRunning { child.terminate() } }

        let snapshot = SystemChildProcesses().snapshot()
        let found = try XCTUnwrap(snapshot.children.first { $0.executablePath == "/bin/sleep" }, "\(snapshot.children)")
        XCTAssertLessThan(abs(found.startTime.timeIntervalSince(before)), 5)
        XCTAssertLessThan(abs(snapshot.takenAt.timeIntervalSince(before)), 5)
        XCTAssertEqual(OnePasswordConnection.reading(of: snapshot, helperPath: "/bin/sleep", appRunning: true, extensionInstalled: true),
                       .absent, "Just started: it has not stayed yet")

        child.terminate()
        child.waitUntilExit()
        XCTAssertFalse(SystemChildProcesses().snapshot().children.contains { $0.executablePath == "/bin/sleep" },
                       "A child that has exited is not listed")
    }
}
