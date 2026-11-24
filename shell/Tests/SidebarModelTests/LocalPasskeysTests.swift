import XCTest
@testable import SidebarModel

/// "This Mac" passkeys for Settings (PASSKEYS-AND-SITE-PERMISSIONS.md, 1.7; security review
/// PK-07 and PK-08): the engine's answer, the lines a row shows, the fixture store, and
/// which launches may reach real passkeys. Nothing here touches a keychain.
final class LocalPasskeysTests: XCTestCase {
    private let ada = LocalPasskey(id: "00ff", site: "example.com", userName: "ada@example.com", displayName: "Ada Lovelace")
    private let bob = LocalPasskey(id: "a1b2c3", site: "bank.example", userName: "bob", displayName: "")

    // MARK: The engine's JSON

    func testAnAnswerIsRead() throws {
        let json = #"{"available":true,"future_key":7,"passkeys":[{"id":"00ff","rp_id":"example.com","user_name":"ada@example.com","user_display_name":"Ada Lovelace","later":1},{"id":"a1b2c3","rp_id":"bank.example","user_name":"bob","user_display_name":""}]}"#
        let answer = try XCTUnwrap(LocalPasskeyAnswer(json: json))
        XCTAssertEqual(answer, LocalPasskeyAnswer(status: .ok, available: true, passkeys: [ada, bob]))
        XCTAssertEqual(LocalPasskeyAnswer(json: answer.json), answer, "and written back as the same object")
    }

    func testABuildWithoutTheGroupHasNoPasskeys() throws {
        let answer = try XCTUnwrap(LocalPasskeyAnswer(json: #"{"available":false,"passkeys":[]}"#))
        XCTAssertEqual(answer, .unavailable)
        // Rows beside "available": false are not shown: such a build cannot use them.
        let odd = try XCTUnwrap(LocalPasskeyAnswer(json: #"{"available":false,"passkeys":[{"id":"00ff","rp_id":"example.com"}]}"#))
        XCTAssertEqual(odd.passkeys, [])
    }

    func testTextThatIsNotTheObjectIsNoAnswer() {
        for json in ["", "[]", "null", "{}", #"{"passkeys":[]}"#, #"{"available":"yes","passkeys":[]}"#, "{\"available\":true"] {
            XCTAssertNil(LocalPasskeyAnswer(json: json), json)
        }
    }

    func testARowThatCannotBeNamedOrDeletedIsLeftOut() throws {
        let json = #"{"available":true,"passkeys":[{"id":"","rp_id":"a.example"},{"id":"0g","rp_id":"b.example"},{"id":"abc","rp_id":"c.example"},{"id":"00FF","rp_id":"d.example"},{"id":"00ff","rp_id":""},{"id":"00ff"},{"rp_id":"e.example"},{"id":7,"rp_id":"f.example"},{"id":"00ff","rp_id":"ok.example"},{"id":"00ff","rp_id":"twice.example"}]}"#
        let answer = try XCTUnwrap(LocalPasskeyAnswer(json: json))
        XCTAssertEqual(answer.passkeys.map(\.site), ["ok.example"], "one row, and an ID is listed once")
    }

    func testAnIDIsLowerCaseHexOfWholeBytes() {
        for id in ["00", "00ff", String(repeating: "ab", count: 1024)] { XCTAssertTrue(LocalPasskey.isValidID(id), id) }
        for id in ["", "0", "abc", "0G", "00FF", "00 ff", "0x00", "../x", String(repeating: "ab", count: 1025), "ää"] { XCTAssertFalse(LocalPasskey.isValidID(id), id) }
    }

    // MARK: What a row shows

    func testARowShowsTheSiteAndTheAccountOnTheirOwnLines() {
        XCTAssertEqual(ada.siteLine, "example.com")
        XCTAssertEqual(ada.accountLine, "ada@example.com")
        XCTAssertEqual(ada.secondLine, "Ada Lovelace")
        XCTAssertEqual(bob.accountLine, "bob")
        XCTAssertNil(bob.secondLine)
        XCTAssertEqual(LocalPasskeyText.rowLabel(ada), "example.com, ada@example.com")
    }

    func testAnAccountWithoutANameSaysSo() {
        let onlyDisplay = LocalPasskey(id: "01", site: "example.com", userName: "", displayName: "Ada")
        XCTAssertEqual(onlyDisplay.accountLine, "Ada")
        XCTAssertNil(onlyDisplay.secondLine)
        let nameless = LocalPasskey(id: "02", site: "example.com")
        XCTAssertEqual(nameless.accountLine, "No account name")
        let same = LocalPasskey(id: "03", site: "example.com", userName: "ada", displayName: "ada")
        XCTAssertNil(same.secondLine, "the same name is not shown twice")
    }

    /// The site chose the account's names (security review PK-04): they are cleaned and cut
    /// like the names of a passkey request, so a name cannot pose as Darni's own text.
    func testNamesTheSiteChoseAreCleanedAndCut() {
        let hostile = LocalPasskey(id: "04", site: "evil.example\nDelete all passkeys?",
                                   userName: "ada\u{202E}moc.elpmaxe@\n\nThis cannot be undone", displayName: String(repeating: "x", count: 500))
        XCTAssertFalse(hostile.accountLine.contains("\n"))
        XCTAssertFalse(hostile.accountLine.unicodeScalars.contains("\u{202E}"), "no direction override")
        // The limit, and the "…" that says it was cut.
        XCTAssertLessThanOrEqual(hostile.accountLine.unicodeScalars.count, PasskeyStep.pageTextLimit + 1)
        XCTAssertFalse(hostile.siteLine.contains("\n"))
        XCTAssertLessThanOrEqual(hostile.siteLine.unicodeScalars.count, LocalPasskey.siteLimit + 1)
        XCTAssertEqual(hostile.secondLine, String(repeating: "x", count: PasskeyStep.pageTextLimit) + "…")
        let blank = LocalPasskey(id: "05", site: "\u{200B}\n", userName: "\u{200B}", displayName: "\t")
        XCTAssertEqual(blank.siteLine, "Unknown site")
        XCTAssertEqual(blank.accountLine, "No account name")
    }

    // MARK: The texts

    func testTheIntroSaysWhereTheyLiveAndThatTheyDoNotSync() {
        let intro = LocalPasskeyText.intro(profile: "Work")
        XCTAssertTrue(intro.contains("in Work"))
        XCTAssertTrue(intro.contains("stays in this profile on this Mac"))
        XCTAssertTrue(intro.contains("do not sync"))
        XCTAssertTrue(intro.contains("not in iCloud Keychain"))
    }

    /// Security advance read, point 8: the confirmation says it is final. The site and the
    /// account are lines of their own in the view; the warning names neither.
    func testTheDeleteWarningSaysItIsFinal() {
        let warning = LocalPasskeyText.deleteWarning
        XCTAssertTrue(warning.contains("cannot be undone"))
        XCTAssertTrue(warning.contains("not in iCloud or on any other device"))
        XCTAssertTrue(warning.contains("only way into the account"))
        XCTAssertEqual(LocalPasskeyText.deleteQuestion, "Delete this passkey?")
        XCTAssertEqual(LocalPasskeyText.deleteButton, "Delete Passkey")
        XCTAssertEqual(LocalPasskeyText.count(1), "1 passkey")
        XCTAssertEqual(LocalPasskeyText.count(3), "3 passkeys")
    }

    // MARK: The fixture store (PK-08)

    func testTheFixtureStoreListsAndDeletesInMemory() {
        let store = FixtureLocalPasskeyStore(passkeys: [ada, bob])
        var answers: [LocalPasskeyAnswer] = []
        store.list { answers.append($0) }
        XCTAssertEqual(answers.last, LocalPasskeyAnswer(status: .ok, available: true, passkeys: [bob, ada]), "by site")
        store.delete(id: ada.id) { answers.append($0) }
        XCTAssertEqual(answers.last, LocalPasskeyAnswer(status: .ok, available: true, passkeys: [bob]))
        store.delete(id: ada.id) { answers.append($0) }
        XCTAssertEqual(answers.last, LocalPasskeyAnswer(status: .notFound, available: true, passkeys: [bob]), "gone already: the list as it is")
        store.fails = true
        store.delete(id: bob.id) { answers.append($0) }
        XCTAssertEqual(answers.last?.status, .failed)
        XCTAssertEqual(store.passkeys, [bob], "a refused delete removes nothing")
        store.list { answers.append($0) }
        XCTAssertEqual(answers.last, .failed)
        XCTAssertEqual(store.calls, ["list", "delete 00ff", "delete 00ff", "delete a1b2c3", "list"])
    }

    func testTheFixtureStoreReadsAFileInTheEnginesFormat() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-local-passkeys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("passkeys.json")
        try Data(LocalPasskeyAnswer(status: .ok, available: true, passkeys: [ada, bob]).json.utf8).write(to: file)
        XCTAssertEqual(FixtureLocalPasskeyStore(fileURL: file)?.passkeys, [bob, ada])
        try Data("not json".utf8).write(to: file)
        XCTAssertNil(FixtureLocalPasskeyStore(fileURL: file))
        XCTAssertNil(FixtureLocalPasskeyStore(fileURL: directory.appendingPathComponent("missing.json")))
    }

    func testTheUnavailableStoreHasNothingAndDeletesNothing() {
        let store = UnavailableLocalPasskeyStore()
        var answers: [LocalPasskeyAnswer] = []
        store.list { answers.append($0) }
        store.delete(id: "00ff") { answers.append($0) }
        XCTAssertEqual(answers, [.unavailable, .unavailable])
    }

    // MARK: Which launch reaches real passkeys (security advance read, point 5)

    func testOnlyAnOrdinaryLaunchAsksTheEngine() {
        let key = LocalPasskeyStorePolicy.fixtureEnvironmentKey
        XCTAssertEqual(LocalPasskeyStorePolicy.choice(ordinaryLaunch: true, environment: [:]), .engine)
        // A fixture named in the environment does not turn the person's own launch into a test.
        XCTAssertEqual(LocalPasskeyStorePolicy.choice(ordinaryLaunch: true, environment: [key: "/tmp/x.json"]), .engine)
        // Any test launch: a fixture, or nothing. Never the engine.
        XCTAssertEqual(LocalPasskeyStorePolicy.choice(ordinaryLaunch: false, environment: [:]), .none)
        XCTAssertEqual(LocalPasskeyStorePolicy.choice(ordinaryLaunch: false, environment: [key: ""]), .none)
        XCTAssertEqual(LocalPasskeyStorePolicy.choice(ordinaryLaunch: false, environment: [key: "/tmp/x.json"]), .fixture(path: "/tmp/x.json"))
    }
}
