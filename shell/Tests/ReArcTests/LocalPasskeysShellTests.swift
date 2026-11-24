import XCTest
@testable import ReArc
@testable import SidebarModel

/// Settings › Profiles › Passkeys on This Mac (PASSKEYS-AND-SITE-PERMISSIONS.md, 1.7): the
/// model that lists a profile's "this Mac" passkeys and deletes one after it has asked, and
/// the rule for which launch may ask the engine at all. Every store here is a fixture in
/// memory (security review PK-08): no test lists, makes or deletes a real passkey.
final class LocalPasskeysShellTests: XCTestCase {
    private let ada = LocalPasskey(id: "00ff", site: "example.com", userName: "ada@example.com", displayName: "Ada Lovelace")
    private let bob = LocalPasskey(id: "a1b2c3", site: "bank.example", userName: "bob")
    private let cyd = LocalPasskey(id: "0c0d", site: "mail.example", userName: "cyd")

    /// A store whose answers wait until the test lets them through.
    private func held(_ passkeys: [LocalPasskey]) -> (FixtureLocalPasskeyStore, () -> Void) {
        let store = FixtureLocalPasskeyStore(passkeys: passkeys)
        var waiting: [() -> Void] = []
        store.deliver = { waiting.append($0) }
        return (store, {
            let now = waiting
            waiting = []
            now.forEach { $0() }
        })
    }

    private func loaded(_ passkeys: [LocalPasskey]) -> (LocalPasskeysModel, FixtureLocalPasskeyStore, [String]) {
        let store = FixtureLocalPasskeyStore(passkeys: passkeys)
        let model = LocalPasskeysModel(store: store)
        model.refresh()
        return (model, store, store.calls)
    }

    // MARK: Capability

    func testTheFeatureIsAskedForByNameBecauseItsMinorLiesUnderTheHeaders() {
        let all: (String) -> Bool = { _ in true }
        // The engine's header says 73 (dark mode landed first): 72 is "may have it".
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 73, hasFeature: all).localPasskeys)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 72, hasFeature: all).localPasskeys)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 90, hasFeature: all).localPasskeys, "a later minor is a capability bump, not another interface")
        // An engine with dark mode (1.73) and without this patch: the minor alone does not say it has the calls.
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 73, hasFeature: { $0 != "local_passkeys" }).localPasskeys)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 71, hasFeature: all).localPasskeys)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 73, hasFeature: { $0 != "profiles" }).localPasskeys, "the calls take a profile")
        XCTAssertFalse(ChromiumCapabilities.none.localPasskeys)
        XCTAssertEqual(ChromiumCapabilities.introducedIn["local_passkeys"], 72)
    }

    // MARK: The list

    func testTheListIsTheStoresAnswer() {
        let (store, flush) = held([ada, bob])
        let model = LocalPasskeysModel(store: store)
        var log: [String] = []
        model.log = { log.append($0) }
        XCTAssertEqual(model.phase, .loading)
        model.refresh()
        XCTAssertEqual(model.phase, .loading, "nothing is shown before the answer")
        flush()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.passkeys, [bob, ada])
        XCTAssertEqual(log, ["listed 2"])
        XCTAssertFalse(log.joined().contains("example"), "the log names no site and no account")
    }

    func testOneRequestIsOutAtATimeAndTheLastStateArrives() {
        let (store, flush) = held([ada])
        let model = LocalPasskeysModel(store: store)
        model.refresh()
        model.refresh()
        model.refresh()
        XCTAssertEqual(store.calls, ["list"])
        flush()
        XCTAssertEqual(store.calls, ["list", "list"], "asked once more, because something asked meanwhile")
        flush()
        XCTAssertEqual(store.calls, ["list", "list"])
        XCTAssertEqual(model.passkeys, [ada])
    }

    func testABuildThatKeepsNoneSaysSo() {
        let model = LocalPasskeysModel(store: UnavailableLocalPasskeyStore())
        model.refresh()
        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertEqual(model.passkeys, [])
        model.ask(ada)
        XCTAssertNil(model.asking, "nothing to delete")
    }

    func testAStoreThatCannotBeReadShowsNoRows() {
        let store = FixtureLocalPasskeyStore(passkeys: [ada])
        store.fails = true
        let model = LocalPasskeysModel(store: store)
        model.refresh()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.passkeys, [])
        store.fails = false
        model.refresh()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.passkeys, [ada])
    }

    // MARK: Deleting asks first (security advance read, point 8)

    func testAskingDeletesNothing() {
        let (model, store, _) = loaded([ada, bob])
        model.ask(ada)
        XCTAssertEqual(model.asking, ada, "the confirmation names this passkey: its site and its account")
        XCTAssertEqual(model.asking?.siteLine, "example.com")
        XCTAssertEqual(model.asking?.accountLine, "ada@example.com")
        XCTAssertEqual(store.calls, ["list"], "no delete has been sent")
        XCTAssertEqual(store.passkeys.count, 2)
    }

    func testCancelLeavesEverything() {
        let (model, store, _) = loaded([ada, bob])
        model.ask(ada)
        model.cancelDelete()
        XCTAssertNil(model.asking)
        XCTAssertEqual(store.calls, ["list"])
        XCTAssertEqual(model.passkeys, [bob, ada])
        // And a confirm after a cancel has nothing to confirm.
        model.confirmDelete()
        XCTAssertEqual(store.calls, ["list"])
    }

    func testConfirmDeletesThePasskeyThatWasAskedAboutAndOnlyThatOne() {
        let (model, store, _) = loaded([ada, bob, cyd])
        var log: [String] = []
        model.log = { log.append($0) }
        model.ask(bob)
        model.confirmDelete()
        XCTAssertEqual(store.calls, ["list", "delete a1b2c3"])
        XCTAssertEqual(model.passkeys, [ada, cyd], "the list is the store's answer after the delete")
        XCTAssertNil(model.asking)
        XCTAssertFalse(model.isDeleting)
        XCTAssertEqual(model.notice, LocalPasskeyText.deleted)
        XCTAssertEqual(log, ["deleted"])
    }

    func testNothingIsDeletedWithoutAConfirmation() {
        let (model, store, _) = loaded([ada])
        model.confirmDelete()
        XCTAssertEqual(store.calls, ["list"], "no confirmation was open")
        XCTAssertEqual(store.passkeys, [ada])
    }

    func testOnlyAPasskeyOfTheListCanBeAskedAbout() {
        let (model, store, _) = loaded([ada])
        model.ask(bob)
        XCTAssertNil(model.asking)
        // The same ID with another name is not the row that was shown.
        model.ask(LocalPasskey(id: ada.id, site: "other.example", userName: "eve"))
        XCTAssertNil(model.asking)
        model.confirmDelete()
        XCTAssertEqual(store.calls, ["list"])
    }

    func testASecondConfirmWhileOneIsOutSendsNothing() {
        let (store, flush) = held([ada, bob])
        let model = LocalPasskeysModel(store: store)
        model.refresh()
        flush()
        model.ask(ada)
        model.confirmDelete()
        XCTAssertTrue(model.isDeleting)
        model.confirmDelete()
        model.cancelDelete()
        model.ask(bob)
        model.refresh()
        XCTAssertEqual(store.calls, ["list", "delete 00ff"], "one delete, and nothing else until it answers")
        XCTAssertEqual(model.asking, ada, "the confirmation stays while its delete is out")
        flush()
        XCTAssertFalse(model.isDeleting)
        XCTAssertEqual(model.passkeys, [bob])
    }

    func testAPasskeyThatIsAlreadyGoneIsSaidSo() {
        let (model, store, _) = loaded([ada, bob])
        model.ask(ada)
        // Deleted elsewhere meanwhile (Chromium's Clear Browsing Data, another window).
        store.delete(id: ada.id) { _ in }
        model.confirmDelete()
        XCTAssertEqual(model.notice, LocalPasskeyText.alreadyGone)
        XCTAssertEqual(model.passkeys, [bob], "and the list is brought up to date")
        XCTAssertNil(model.asking)
    }

    func testARefusedDeleteSaysThePasskeyIsStillThere() {
        let (model, store, _) = loaded([ada])
        model.ask(ada)
        store.fails = true
        model.confirmDelete()
        XCTAssertEqual(model.notice, LocalPasskeyText.deleteFailed)
        XCTAssertEqual(store.passkeys, [ada])
        XCTAssertNil(model.asking)
        XCTAssertEqual(store.calls, ["list", "delete 00ff", "list"], "the list is asked again")
        store.fails = false
        model.refresh()
        XCTAssertEqual(model.passkeys, [ada])
    }

    /// A store that says "ok" and still lists the passkey has not deleted it.
    func testAnOKThatStillListsThePasskeyIsNotADelete() {
        final class Liar: LocalPasskeyStoring {
            let passkeys: [LocalPasskey]
            init(_ passkeys: [LocalPasskey]) { self.passkeys = passkeys }
            func list(_ receive: @escaping (LocalPasskeyAnswer) -> Void) { receive(.init(status: .ok, available: true, passkeys: passkeys)) }
            func delete(id: String, _ receive: @escaping (LocalPasskeyAnswer) -> Void) { receive(.init(status: .ok, available: true, passkeys: passkeys)) }
        }
        let model = LocalPasskeysModel(store: Liar([ada]))
        model.refresh()
        model.ask(ada)
        model.confirmDelete()
        XCTAssertEqual(model.notice, LocalPasskeyText.deleteFailed)
        XCTAssertEqual(model.passkeys, [ada])
    }

    /// The row the person confirmed must still be the row in the list: an
    /// answer that arrived between the question and the click changes it.
    func testAListThatChangedUnderTheConfirmationDeletesNothing() {
        let (store, flush) = held([ada, bob])
        let model = LocalPasskeysModel(store: store)
        model.refresh()
        flush()
        model.ask(ada)
        // Meanwhile the passkey went, and a new answer says so (the confirmation goes with it).
        store.delete(id: ada.id) { _ in }
        model.refresh()
        flush()
        XCTAssertNil(model.asking, "a confirmation for a passkey that is gone closes")
        model.confirmDelete()
        XCTAssertEqual(store.calls.filter { $0.hasPrefix("delete") }, ["delete 00ff"], "only the test's own delete")
        XCTAssertEqual(model.passkeys, [bob])
    }

    func testANoticeGoesWithTheNextQuestion() {
        let (model, _, _) = loaded([ada, bob])
        model.ask(ada)
        model.confirmDelete()
        XCTAssertNotNil(model.notice)
        model.ask(bob)
        XCTAssertNil(model.notice)
    }

    // MARK: Which launch reaches real passkeys (security advance read, point 5)

    private final class CountingEngineStores {
        var asked: [Profile.ID] = []
        let store = FixtureLocalPasskeyStore(passkeys: [])
    }

    func testATestLaunchNeverGetsTheEnginesStore() {
        let engine = CountingEngineStores()
        let profile = Profile.ID()
        for choice in [LocalPasskeyStorePolicy.Choice.none, .fixture(path: "/nonexistent/passkeys.json")] {
            let controller = LocalPasskeysController()
            controller.configure(choice: choice)
            // Even if an engine attached by mistake, this launch does not use it.
            controller.attach { id in
                engine.asked.append(id)
                return engine.store
            }
            XCTAssertFalse(controller.isOffered, "\(choice): Settings has no row")
            XCTAssertTrue(controller.store(for: profile) is UnavailableLocalPasskeyStore, "\(choice)")
            let model = controller.model(for: profile)
            model.refresh()
            XCTAssertEqual(model.phase, .unavailable)
        }
        XCTAssertEqual(engine.asked, [], "the engine's store was never made")
        XCTAssertEqual(engine.store.calls, [])
    }

    func testBeforeTheLaunchIsKnownThereIsNoStore() {
        let controller = LocalPasskeysController()
        XCTAssertEqual(controller.choice, .none)
        XCTAssertFalse(controller.isOffered)
        XCTAssertTrue(controller.store(for: Profile.ID()) is UnavailableLocalPasskeyStore)
    }

    func testAFixtureLaunchListsTheFixtureAndSaysItIsOne() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-local-passkeys-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("passkeys.json")
        try Data(LocalPasskeyAnswer(status: .ok, available: true, passkeys: [ada, bob]).json.utf8).write(to: file)
        let controller = LocalPasskeysController()
        controller.configure(choice: .fixture(path: file.path))
        XCTAssertTrue(controller.isOffered)
        let model = controller.model(for: Profile.ID())
        XCTAssertTrue(model.isFixture, "the sheet says these are not real")
        model.refresh()
        XCTAssertEqual(model.passkeys, [bob, ada])
        model.ask(ada)
        model.confirmDelete()
        XCTAssertEqual(model.passkeys, [bob])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), LocalPasskeyAnswer(status: .ok, available: true, passkeys: [ada, bob]).json,
                       "the fixture is in memory: the file is not written")
    }

    func testAnOrdinaryLaunchUsesTheEnginesStoreForTheProfileAsked() {
        let engine = CountingEngineStores()
        let controller = LocalPasskeysController()
        controller.configure(choice: .engine)
        XCTAssertFalse(controller.isOffered, "no engine has attached: no row")
        XCTAssertTrue(controller.store(for: Profile.ID()) is UnavailableLocalPasskeyStore)
        controller.attach { id in
            engine.asked.append(id)
            return engine.store
        }
        XCTAssertTrue(controller.isOffered)
        let profile = Profile.ID(), container = Profile.ID()
        XCTAssertFalse(controller.model(for: profile).isFixture)
        _ = controller.model(for: container)
        XCTAssertEqual(engine.asked, [profile, container], "a container has its own passkeys")
    }

    func testTheEnginesAnswerIsMappedByItsStatus() {
        let json = #"{"available":true,"passkeys":[{"id":"00ff","rp_id":"example.com","user_name":"ada@example.com","user_display_name":"Ada Lovelace"}]}"#
        XCTAssertEqual(LocalPasskeyAnswer(engineStatus: 0, json: json), LocalPasskeyAnswer(status: .ok, available: true, passkeys: [ada]))
        XCTAssertEqual(LocalPasskeyAnswer(engineStatus: 4, json: json).status, .notFound)
        XCTAssertEqual(LocalPasskeyAnswer(engineStatus: 16, json: json), .failed, "internal: the list is not trusted")
        XCTAssertEqual(LocalPasskeyAnswer(engineStatus: 10, json: json), .failed)
        XCTAssertEqual(LocalPasskeyAnswer(engineStatus: 0, json: nil), .failed)
        XCTAssertEqual(LocalPasskeyAnswer(engineStatus: 0, json: "{}"), .failed)
        XCTAssertEqual(LocalPasskeyAnswer(engineStatus: 0, json: #"{"available":false,"passkeys":[]}"#), .unavailable)
    }

    func testThePasskeyGroupIsToldByItsSuffix() {
        XCTAssertTrue(SignedKeychainGroups.hasPasskeyGroup(in: ["TEAM123456.com.rearc.browser", "TEAM123456.com.rearc.browser.webauthn"]))
        XCTAssertFalse(SignedKeychainGroups.hasPasskeyGroup(in: ["TEAM123456.com.rearc.browser"]))
        XCTAssertFalse(SignedKeychainGroups.hasPasskeyGroup(in: []))
        // The test process is not signed with it, so no test can reach the real group.
        XCTAssertFalse(SignedKeychainGroups.hasPasskeyGroup)
    }
}
