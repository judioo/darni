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
                       dismissedThisLaunch: Bool = false) -> Bool {
        OnePasswordConnect.showsPrompt(appInstalled: app, extensionInstalled: installed,
                                       preference: OnePasswordConnectPreference(isDone: done, dismissals: dismissals),
                                       dismissedThisLaunch: dismissedThisLaunch)
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
                            let expected = app && installed && !done && !thisLaunch && dismissals < 2
                            XCTAssertEqual(shows(app: app, extension: installed, done: done, dismissals: dismissals,
                                                 dismissedThisLaunch: thisLaunch), expected,
                                           "app \(app) extension \(installed) done \(done) dismissals \(dismissals) this launch \(thisLaunch)")
                        }
                    }
                }
            }
        }
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

    func testANegativeCountReadsAsZero() {
        defaults.set(-4, forKey: OnePasswordConnectPreference.dismissalsKey)
        XCTAssertEqual(OnePasswordConnectPreference.load(from: defaults).dismissals, 0)
    }
}
