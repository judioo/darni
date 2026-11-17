import XCTest
@testable import SidebarModel

/// "Connect 1Password to ReArc": when the prompt shows by itself, and what
/// it remembers.
final class OnePasswordConnectTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "OnePasswordConnectTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func shows(app: Bool = true, extension installed: Bool = true, done: Bool = false, dismissals: Int = 0,
                       dismissedThisLaunch: Bool = false, connectionHidesPrompt: Bool = false) -> Bool {
        OnePasswordConnect.showsPrompt(appInstalled: app, extensionInstalled: installed,
                                       preference: OnePasswordConnectPreference(isDone: done, dismissals: dismissals),
                                       dismissedThisLaunch: dismissedThisLaunch, connectionHidesPrompt: connectionHidesPrompt)
    }

    private func watches(done: Bool = false, dismissals: Int = 0, dismissedThisLaunch: Bool = false,
                         _ connection: OnePasswordConnectionState = OnePasswordConnectionState()) -> Bool {
        OnePasswordConnect.watchesConnection(preference: OnePasswordConnectPreference(isDone: done, dismissals: dismissals),
                                             connection: connection, dismissedThisLaunch: dismissedThisLaunch)
    }

    // MARK: The decision

    func testShowsWithTheAppAndTheExtensionAndNothingSaidYet() {
        XCTAssertTrue(shows())
    }

    func testNeedsBothTheAppAndTheExtension() {
        XCTAssertFalse(shows(app: false))
        XCTAssertFalse(shows(extension: false))
        XCTAssertFalse(shows(app: false, extension: false))
    }

    func testDoneNeverShowsAgain() {
        XCTAssertFalse(shows(done: true))
        XCTAssertFalse(shows(done: true, dismissals: 1))
    }

    func testAClosedPromptStaysAwayForTheLaunch() {
        XCTAssertFalse(shows(dismissals: 1, dismissedThisLaunch: true))
    }

    func testAClosedPromptComesBackOnceOnALaterLaunchThenStops() {
        XCTAssertTrue(shows(dismissals: 1))
        XCTAssertFalse(shows(dismissals: 2))
        XCTAssertFalse(shows(dismissals: 3))
        XCTAssertEqual(OnePasswordConnect.maximumDismissals, 2)
    }

    func testEveryCombinationShowsOnlyWhenAllHold() {
        for app in [false, true] {
            for installed in [false, true] {
                for done in [false, true] {
                    for dismissals in 0 ... 3 {
                        for thisLaunch in [false, true] {
                            for connected in [false, true] {
                                let expected = app && installed && !done && !thisLaunch && dismissals < 2 && !connected
                                XCTAssertEqual(shows(app: app, extension: installed, done: done, dismissals: dismissals,
                                                     dismissedThisLaunch: thisLaunch, connectionHidesPrompt: connected), expected,
                                               "app \(app) extension \(installed) done \(done) dismissals \(dismissals) this launch \(thisLaunch) connected \(connected)")
                            }
                        }
                    }
                }
            }
        }
    }

    func testAWorkingConnectionHidesThePrompt() {
        XCTAssertFalse(shows(connectionHidesPrompt: true))
        XCTAssertFalse(shows(dismissals: 1, connectionHidesPrompt: true))
    }

    // MARK: When readings are worth taking

    func testReadsWhileThePromptCouldShow() {
        XCTAssertTrue(watches())
        XCTAssertTrue(watches(dismissals: 1))
        XCTAssertTrue(watches(OnePasswordConnectionState(stored: true)), "The stored value still needs this launch's verdict")
    }

    func testStopsOnceThePromptIsClosedForTheLaunchOrForGood() {
        XCTAssertFalse(watches(dismissals: 1, dismissedThisLaunch: true))
        XCTAssertFalse(watches(dismissals: 2))
        XCTAssertFalse(watches(dismissals: 2, OnePasswordConnectionState(stored: true)))
    }

    func testStopsOnceAHelperWasSeenAttached() {
        var connection = OnePasswordConnectionState()
        connection.record(.attached, uptime: 40)
        XCTAssertFalse(watches(connection))
        connection.record(.absent, uptime: 60)
        XCTAssertFalse(watches(connection), "The prompt does not come back in this launch")
    }

    func testAfterDoneOnlyALostConnectionIsWatchedForAndOnlyUntilTheVerdict() {
        XCTAssertFalse(watches(done: true), "Done with no connection ever seen: nothing to lose")

        var connection = OnePasswordConnectionState(stored: true)
        XCTAssertTrue(watches(done: true, connection))
        connection.record(.unknown, uptime: 0)
        connection.record(.unknown, uptime: OnePasswordConnection.verdictDelay)
        XCTAssertTrue(connection.hasVerdict)
        XCTAssertFalse(watches(done: true, connection), "This launch could not tell, and stops asking")
    }

    func testTheSettingsRowFollowsTheAppAlone() {
        XCTAssertTrue(OnePasswordConnect.showsSettingsRow(appInstalled: true))
        XCTAssertFalse(OnePasswordConnect.showsSettingsRow(appInstalled: false))
    }

    // MARK: The extension

    func testKnowsOnePasswordsExtensions() {
        XCTAssertTrue(OnePasswordConnect.isExtension("aeblfdkhhhdcdjpifhhbdiojplfjncoa"))
        XCTAssertTrue(OnePasswordConnect.isExtension("khgocmkkpikpnmmkgmdnfckapcdkgfaf"))
        XCTAssertTrue(OnePasswordConnect.isExtension("gejiddohjgogedgjnonbofjigllpkmbf"))
        XCTAssertFalse(OnePasswordConnect.isExtension("cjpalhdlnbpafiamejdnhcphjbkeiagm"))
        XCTAssertFalse(OnePasswordConnect.isExtension(""))
    }

    func testEveryListedIDIsAnExtensionID() {
        XCTAssertEqual(OnePasswordConnect.extensionIDs.count, 6)
        for id in OnePasswordConnect.extensionIDs {
            XCTAssertTrue(ExtensionInventoryReader.isExtensionID(id), id)
        }
    }

    // MARK: The words

    func testTheWordsAreTheOwners() {
        XCTAssertEqual(OnePasswordConnect.title, "Connect 1Password to ReArc")
        XCTAssertEqual(OnePasswordConnect.message,
                       "1Password unlocks in ReArc once you add ReArc as a browser in 1Password: Settings › Browser › Add Browser, then choose ReArc. Restart ReArc afterwards.")
        XCTAssertEqual(OnePasswordConnect.open, "Open 1Password")
        XCTAssertEqual(OnePasswordConnect.done, "Done")
        XCTAssertEqual(OnePasswordConnect.settingsLabel, "1Password")
    }

    func testSettingsSaysConnectedAndKeepsTheSteps() {
        XCTAssertEqual(OnePasswordConnect.connected, "Connected")
        XCTAssertEqual(OnePasswordConnect.settingsMessage(connected: false), OnePasswordConnect.message)
        XCTAssertEqual(OnePasswordConnect.settingsMessage(connected: true),
                       "If 1Password stays locked in ReArc, add ReArc as a browser in 1Password: Settings › Browser › Add Browser, then choose ReArc. Restart ReArc afterwards.")
        // The steps are in both, and neither says that 1Password trusts ReArc.
        for connected in [false, true] {
            let words = OnePasswordConnect.settingsMessage(connected: connected)
            XCTAssertTrue(words.contains("Settings › Browser › Add Browser"), words)
            XCTAssertFalse(words.localizedCaseInsensitiveContains("trust"), words)
        }
    }

    // MARK: The preference

    func testNothingSavedIsNotDoneAndNeverClosed() {
        XCTAssertEqual(OnePasswordConnectPreference.load(from: defaults), OnePasswordConnectPreference(isDone: false, dismissals: 0))
    }

    func testRoundTrip() {
        let saved = OnePasswordConnectPreference(isDone: true, dismissals: 1)
        saved.save(to: defaults)
        XCTAssertEqual(OnePasswordConnectPreference.load(from: defaults), saved)

        OnePasswordConnectPreference(isDone: false, dismissals: 2).save(to: defaults)
        XCTAssertEqual(OnePasswordConnectPreference.load(from: defaults), OnePasswordConnectPreference(isDone: false, dismissals: 2))
    }

    func testKeysAreReArcsOwn() {
        OnePasswordConnectPreference(isDone: true, dismissals: 2).save(to: defaults)
        XCTAssertEqual(defaults.object(forKey: "rearc.onePasswordConnectDone") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "rearc.onePasswordConnectDismissals") as? Int, 2)
    }

    // MARK: A lost connection

    func testALostConnectionAfterDoneBringsThePromptBackForOneClose() {
        var preference = OnePasswordConnectPreference(isDone: true, dismissals: 0)
        preference.connectionLost()
        XCTAssertEqual(preference, OnePasswordConnectPreference(isDone: false, dismissals: 1))
        XCTAssertTrue(OnePasswordConnect.showsPrompt(appInstalled: true, extensionInstalled: true, preference: preference))

        // One close and it stops.
        preference.dismissals += 1
        XCTAssertFalse(OnePasswordConnect.showsPrompt(appInstalled: true, extensionInstalled: true, preference: preference))
    }

    func testALostConnectionKeepsTheCloseLimit() {
        var closedOnce = OnePasswordConnectPreference(isDone: true, dismissals: 1)
        closedOnce.connectionLost()
        XCTAssertEqual(closedOnce, OnePasswordConnectPreference(isDone: false, dismissals: 1))

        var closedForGood = OnePasswordConnectPreference(isDone: true, dismissals: 2)
        closedForGood.connectionLost()
        XCTAssertFalse(OnePasswordConnect.showsPrompt(appInstalled: true, extensionInstalled: true, preference: closedForGood),
                       "Closed twice, it stays closed")
    }

    func testALostConnectionWithoutDoneChangesNothing() {
        var preference = OnePasswordConnectPreference(isDone: false, dismissals: 0)
        preference.connectionLost()
        XCTAssertEqual(preference, OnePasswordConnectPreference(isDone: false, dismissals: 0))
    }

    func testANegativeCountReadsAsZero() {
        defaults.set(-4, forKey: OnePasswordConnectPreference.dismissalsKey)
        XCTAssertEqual(OnePasswordConnectPreference.load(from: defaults).dismissals, 0)
    }
}
