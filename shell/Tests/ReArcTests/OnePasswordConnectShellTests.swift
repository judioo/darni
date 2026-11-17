import XCTest
@testable import ReArc
@testable import SidebarModel

/// Stands in for the 1Password app: answers at once, records what was
/// opened, never asks LaunchServices.
private final class FakeOnePasswordApp: OnePasswordAppLocating {
    var installed: URL?
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
    private func makeModel(_ app: FakeOnePasswordApp) -> BrowserViewModel {
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
        model.onePasswordApp = app
        model.finishStartup()
        return model
    }

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
}
