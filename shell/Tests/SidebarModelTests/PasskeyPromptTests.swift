import Foundation
import XCTest
@testable import SidebarModel

/// The steps of a passkey or security key request (Chromium ABI 1.68) and what the sheet shows for each.
final class PasskeyPromptTests: XCTestCase {
    func testDecodesTheWaysToSignIn() throws {
        let step = try XCTUnwrap(PasskeyStep(json: """
        {"step":"choose","request":"get","rp_id":"login.microsoft.com","origin":"https://login.microsoft.com",
         "profile_id":"1","content_generation":"3","private":false,"busy":false,"can_choose_another":true,"can_try_again":true,
         "mechanisms":[
          {"index":0,"kind":"passkey","source":"this_mac","name":"ada@example.com","description":"Your Chrome profile"},
          {"index":1,"kind":"phone","name":"Use a phone, tablet or security key","description":""},
          {"index":2,"kind":"security_key","name":"USB security key","description":""},
          {"index":3,"kind":"a_later_kind","name":"Something new","description":"From later"}]}
        """))
        XCTAssertEqual(step.kind, .choose)
        XCTAssertFalse(step.isCreate)
        XCTAssertEqual(step.requestLine, "Sign in to login.microsoft.com")
        XCTAssertEqual(step.title, "Choose how to sign in")
        XCTAssertTrue(step.isFromWebPage)
        XCTAssertEqual(step.listedMechanisms.map(\.title), ["ada@example.com", "Phone or Tablet", "USB Security Key", "Something new"])
        // The shell's own words: never "Chrome profile".
        XCTAssertEqual(step.listedMechanisms.map(\.subtitle),
                       ["Passkey on this Mac", "Scan a QR code with its camera", "Insert it and touch it", "From later"])
        XCTAssertNil(step.primary, "the rows are the buttons")
        XCTAssertFalse(step.offersAnotherWay, "this is the list of ways")
        XCTAssertEqual(step.dismissTitle, "Cancel")
        XCTAssertTrue(step.showsSheet)
    }

    func testConfirmOffersTheFirstWayAndTheOthersBehindAnotherWay() throws {
        let step = try XCTUnwrap(PasskeyStep(json: """
        {"step":"confirm","request":"get","rp_id":"example.com","can_choose_another":true,"priority":1,
         "mechanisms":[{"index":0,"kind":"phone","name":"","description":""},
                       {"index":1,"kind":"passkey","source":"security_key","name":"ada","description":""}]}
        """))
        XCTAssertEqual(step.listedMechanisms.map(\.index), [1])
        XCTAssertEqual(step.primary?.title, "Continue")
        XCTAssertEqual(step.primary?.action, .proceed)
        XCTAssertTrue(step.offersAnotherWay)
    }

    func testQRStepCarriesTheCodeAndSaysAKeyWorksToo() throws {
        let step = try XCTUnwrap(PasskeyStep(json: #"{"step":"qr","request":"get","rp_id":"example.com","qr":"FIDO:/0123456789","security_key_too":true,"can_choose_another":true}"#))
        XCTAssertEqual(step.kind, .qr)
        XCTAssertEqual(step.qr, "FIDO:/0123456789")
        XCTAssertTrue(step.message.contains("USB security key"))
        XCTAssertTrue(step.offersAnotherWay)
        XCTAssertNil(step.primary)
        XCTAssertNil(PasskeyStep(json: #"{"step":"qr","qr":""}"#)?.qr)
    }

    func testPinStepsExplainTheKeysComplaint() throws {
        let wrong = try XCTUnwrap(PasskeyStep(json: #"{"step":"pin","rp_id":"example.com","pin":{"min_length":6,"attempts":3,"error":"wrong"}}"#))
        XCTAssertEqual(wrong.kind, .pin(.enter))
        XCTAssertEqual(wrong.pinMinLength, 6)
        XCTAssertEqual(wrong.message, "That PIN is wrong. 3 attempts left.")
        let last = try XCTUnwrap(PasskeyStep(json: #"{"step":"pin","pin":{"min_length":4,"attempts":1,"error":"wrong"}}"#))
        XCTAssertEqual(last.message, "That PIN is wrong. 1 attempt left.")
        let setUp = try XCTUnwrap(PasskeyStep(json: #"{"step":"pin_setup","rp_id":"example.com","pin":{"min_length":4,"error":"none"}}"#))
        XCTAssertEqual(setUp.kind, .pin(.setUp))
        XCTAssertNil(setUp.pinProblem)
        XCTAssertTrue(setUp.message.contains("At least 4 characters"))
        XCTAssertEqual(PasskeyStep(json: #"{"step":"pin_change","pin":{"error":"same_as_current"}}"#)?.pinProblem,
                       "The new PIN must differ from the current one.")
    }

    func testThePinIsCheckedBeforeItIsSent() {
        XCTAssertEqual(PasskeyPin.problem(pin: "", confirmation: "", mode: .enter, minLength: 4), "Enter a PIN.")
        XCTAssertNil(PasskeyPin.problem(pin: "1", confirmation: "", mode: .enter, minLength: 4), "the key judges its own PIN")
        XCTAssertEqual(PasskeyPin.problem(pin: String(repeating: "9", count: 64), confirmation: "", mode: .enter, minLength: 4),
                       "That PIN is too long.")
        XCTAssertEqual(PasskeyPin.problem(pin: "123", confirmation: "123", mode: .setUp, minLength: 4), "Use at least 4 characters.")
        XCTAssertEqual(PasskeyPin.problem(pin: "1234", confirmation: "1235", mode: .change, minLength: 4), "The two PINs do not match.")
        XCTAssertNil(PasskeyPin.problem(pin: "1234", confirmation: "1234", mode: .setUp, minLength: 4))
        // 63 bytes, not characters: 21 three-byte characters fit, 22 do not.
        XCTAssertNil(PasskeyPin.problem(pin: String(repeating: "€", count: 21), confirmation: "", mode: .enter, minLength: 4))
        XCTAssertNotNil(PasskeyPin.problem(pin: String(repeating: "€", count: 22), confirmation: "", mode: .enter, minLength: 4))
    }

    func testAnswersMapToTheEnginesActions() {
        func values(_ action: PasskeyAction) -> [String] {
            let v = action.engineValues
            return ["\(v.action)", "\(v.index)", v.text ?? "-"]
        }
        XCTAssertEqual(values(.cancel), ["0", "0", "-"])
        XCTAssertEqual(values(.chooseMechanism(2)), ["1", "2", "-"])
        XCTAssertEqual(values(.proceed), ["2", "0", "-"])
        XCTAssertEqual(values(.pin("4711")), ["3", "0", "4711"])
        XCTAssertEqual(values(.chooseAccount(1)), ["4", "1", "-"])
        XCTAssertEqual(values(.startOver), ["5", "0", "-"])
        XCTAssertEqual(values(.chooseMechanism(-3)), ["1", "0", "-"])
        // A log line names the answer, never the PIN.
        XCTAssertEqual(PasskeyAction.pin("4711").logName, "pin")
        XCTAssertFalse(PasskeyAction.pin("4711").logName.contains("4711"))
    }

    func testBluetoothStepsLeadToTheSwitchOrToSystemSettings() throws {
        let off = try XCTUnwrap(PasskeyStep(json: #"{"step":"bluetooth_off","bluetooth_on":false,"can_power_on":false}"#))
        XCTAssertNil(off.primary, "the person switches it on; Continue comes with it")
        let on = try XCTUnwrap(PasskeyStep(json: #"{"step":"bluetooth_off","bluetooth_on":true,"can_power_on":false}"#))
        XCTAssertEqual(on.primary?.title, "Continue")
        let auto = try XCTUnwrap(PasskeyStep(json: #"{"step":"bluetooth_off","bluetooth_on":false,"can_power_on":true}"#))
        XCTAssertEqual(auto.primary?.title, "Turn On Bluetooth")
        let denied = try XCTUnwrap(PasskeyStep(json: #"{"step":"bluetooth_denied"}"#))
        XCTAssertEqual(denied.primary?.title, "Open System Settings")
        XCTAssertEqual(denied.primary?.action, .proceed)
        XCTAssertTrue(denied.message.contains("Privacy & Security › Bluetooth"))
    }

    func testErrorsOfferTryAgainExceptAfterATimeout() throws {
        let notRegistered = try XCTUnwrap(PasskeyStep(json: #"{"step":"error_key_not_registered","rp_id":"example.com","can_try_again":true}"#))
        XCTAssertEqual(notRegistered.kind, .failure(.keyNotRegistered))
        XCTAssertEqual(notRegistered.primary?.action, .startOver)
        XCTAssertEqual(notRegistered.dismissTitle, "Close")
        let noRetry = try XCTUnwrap(PasskeyStep(json: #"{"step":"error_key_not_registered","can_try_again":false}"#))
        XCTAssertNil(noRetry.primary)
        let timeout = try XCTUnwrap(PasskeyStep(json: #"{"step":"error_timeout","rp_id":"example.com","can_try_again":true}"#))
        XCTAssertNil(timeout.primary, "the request is over")
        for failure in ["error_no_transports", "error_no_passkeys", "error_not_recognized", "error_timeout", "error_key_not_registered",
                        "error_key_already_registered", "error_missing_capability", "error_storage_full", "error_pin_soft_block",
                        "error_pin_hard_block", "error_key_removed"] {
            let step = try XCTUnwrap(PasskeyStep(json: #"{"step":"\#(failure)","rp_id":"example.com"}"#))
            guard case .failure = step.kind else { return XCTFail(failure) }
            XCTAssertFalse(step.title.isEmpty || step.message.isEmpty, failure)
        }
    }

    func testStepsWithoutASheetAndStepsThisShellDoesNotKnow() throws {
        XCTAssertEqual(PasskeyStep(json: #"{"step":"system"}"#)?.showsSheet, false, "macOS shows its own prompt")
        XCTAssertEqual(PasskeyStep(json: #"{"step":"hidden"}"#)?.showsSheet, false)
        let later = try XCTUnwrap(PasskeyStep(json: #"{"step":"a_later_step","can_choose_another":true}"#))
        XCTAssertEqual(later.kind, .unsupported)
        XCTAssertTrue(later.showsSheet && later.offersAnotherWay)
        XCTAssertNil(PasskeyStep(json: "{}"))
        XCTAssertNil(PasskeyStep(json: "nonsense"))
    }

    func testBusyLeavesOnlyCancel() throws {
        let busy = try XCTUnwrap(PasskeyStep(json: #"{"step":"create_this_mac","request":"create","rp_id":"example.com","busy":true,"can_choose_another":true,"user":{"name":"ada@example.com","display_name":"Ada"}}"#))
        XCTAssertNil(busy.primary)
        XCTAssertFalse(busy.offersAnotherWay)
        XCTAssertTrue(busy.showsProgress)
        XCTAssertTrue(busy.isCreate)
        XCTAssertEqual(busy.requestLine, "Create a passkey for example.com")
        XCTAssertEqual(busy.accountLine, "ada@example.com", "the page's text has a line of its own")
        XCTAssertFalse(busy.message.contains("ada"), "and is no part of ReArc's sentence")
        XCTAssertTrue(busy.message.contains("does not sync"))
    }

    /// Security review PK-03: a request can open on any of these steps, and a
    /// touch or a scan is consent to the site. Each one names it, the same way.
    func testEveryStepNamesTheSiteTheRequestIsFor() throws {
        for name in ["choose", "confirm", "security_key", "qr", "phone_connecting", "phone_connected", "phone_error", "bluetooth_off",
                     "bluetooth_denied", "private_notice", "pin", "pin_setup", "pin_change", "touch_again", "fingerprint_enroll",
                     "verify_again", "account", "create_this_mac", "error_timeout", "error_key_not_registered", "a_later_step"] {
            let get = try XCTUnwrap(PasskeyStep(json: #"{"step":"\#(name)","request":"get","rp_id":"example.com","origin":"https://login.example.com"}"#))
            XCTAssertEqual(get.requestLine, "Sign in to example.com", name)
            let create = try XCTUnwrap(PasskeyStep(json: #"{"step":"\#(name)","request":"create","rp_id":"example.com","origin":"https://login.example.com"}"#))
            XCTAssertEqual(create.requestLine, "Create a passkey for example.com", name)
        }
    }

    /// An extension page may claim a site it has access to as the relying
    /// party; the sheet names the relying party, so such a request gets none.
    func testOnlyAWebPageGetsTheSheet() throws {
        func from(_ origin: String) throws -> Bool {
            try XCTUnwrap(PasskeyStep(json: #"{"step":"choose","rp_id":"accounts.example.com","origin":"\#(origin)"}"#)).isFromWebPage
        }
        XCTAssertTrue(try from("https://accounts.example.com"))
        XCTAssertTrue(try from("http://localhost:8080"))
        XCTAssertFalse(try from("chrome-extension://abcdefghijklmnopabcdefghijklmnop"))
        XCTAssertFalse(try from("null"))
        XCTAssertFalse(try from(""))
    }

    /// Security review PK-04: a page chooses the account's name freely.
    func testTextThePageChoosesIsOneShortCleanLine() throws {
        XCTAssertEqual(PasskeyStep.pageText("ada@example.com"), "ada@example.com")
        XCTAssertEqual(PasskeyStep.pageText("ada\n\nReArc says: type your password\tnow"), "ada ReArc says: type your password now")
        // Direction overrides and zero-width characters go; the letters stay in the order they were sent.
        XCTAssertEqual(PasskeyStep.pageText("ab\u{202E}dc\u{2066}e\u{200B}f\u{0007}"), "abdcef")
        let long = PasskeyStep.pageText(String(repeating: "x", count: 500))
        XCTAssertEqual(long.count, PasskeyStep.pageTextLimit + 1)
        XCTAssertTrue(long.hasSuffix("…"))
        // A letter keeps two combining marks, so a stack cannot draw over the lines around it (review addendum).
        XCTAssertEqual(PasskeyStep.pageText("a" + String(repeating: "\u{0301}", count: 60) + "b\u{0303}"), "a\u{0301}\u{0301}b\u{0303}")
        XCTAssertEqual(PasskeyStep.pageText("Nguye\u{0302}\u{0303}n ที่"), "Nguye\u{0302}\u{0303}n ที่")
        // The cut counts scalars: a single character can be a run of them without one mark too many.
        let conjuncts = PasskeyStep.pageText(String(repeating: "क\u{094D}", count: 200))
        XCTAssertLessThanOrEqual(conjuncts.unicodeScalars.count, PasskeyStep.pageTextLimit + 1)
        XCTAssertTrue(conjuncts.hasSuffix("…"))
        let accented = PasskeyStep.pageText(String(repeating: "e\u{0301}", count: 40))
        XCTAssertEqual(accented, String(repeating: "e\u{0301}", count: 32) + "…")

        let step = try XCTUnwrap(PasskeyStep(json: """
        {"step":"create_this_mac","request":"create","rp_id":"example.com","origin":"https://example.com",
         "user":{"name":"ada\\n at bank.example will be deleted. Continue to keep it","display_name":""}}
        """))
        XCTAssertEqual(step.accountLine, "ada at bank.example will be deleted. Continue to keep it")
        XCTAssertFalse(step.message.contains("bank.example"))
        let accounts = try XCTUnwrap(PasskeyStep(json: #"{"step":"account","rp_id":"example.com","accounts":[{"index":0,"name":"a\u202Eb\nc","display_name":"\#(String(repeating: "y", count: 300))"}]}"#))
        XCTAssertEqual(accounts.accounts[0].title, "ab c")
        XCTAssertEqual(accounts.accounts[0].subtitle.count, PasskeyStep.pageTextLimit + 1)
        XCTAssertNil(accounts.accountLine, "only the step that confirms a new passkey has the line")
    }

    /// Security review PK-05: what a touch gives the site is said before the touch.
    func testTheKeyStepsCarryChromiumsNotices() throws {
        func notices(_ step: String, _ rest: String) throws -> [String] {
            try XCTUnwrap(PasskeyStep(json: #"{"step":"\#(step)","request":"create","rp_id":"example.com"\#(rest)}"#)).keyNotices
        }
        XCTAssertEqual(try notices("security_key", ""), [])
        XCTAssertEqual(try notices("security_key", #","attestation":"none","stored_on_key":"no""#), [])
        XCTAssertEqual(try notices("security_key", #","attestation":"model","stored_on_key":"maybe""#),
                       ["example.com will learn the make and model of your security key.",
                        "A record of your visit to this site may be kept on your security key."])
        XCTAssertEqual(try notices("touch_again", #","attestation":"serial","stored_on_key":"yes""#),
                       ["example.com wants to learn the ID number of your security key. It will know exactly which key you use.",
                        "A record of your visit to this site will be kept on your security key."])
        // The QR step only when a key can be touched there too; never on a step without a key.
        XCTAssertEqual(try notices("qr", #","qr":"FIDO:/1","security_key_too":true,"attestation":"model""#).count, 1)
        XCTAssertEqual(try notices("qr", #","qr":"FIDO:/1","attestation":"model""#), [])
        XCTAssertEqual(try notices("create_this_mac", #","attestation":"model","stored_on_key":"yes""#), [])
    }

    func testTheSiteIsTheRelyingPartyElseThePagesHost() throws {
        XCTAssertEqual(PasskeyStep(json: #"{"step":"choose","rp_id":"example.com","origin":"https://login.example.com"}"#)?.site, "example.com")
        XCTAssertEqual(PasskeyStep(json: #"{"step":"choose","origin":"https://login.example.com"}"#)?.site, "login.example.com")
    }

    // MARK: Requests from a page nobody sees (security review PK-10, AH-02)

    func testAStepSaysWhatItsPageWasForTheLog() throws {
        let step = try XCTUnwrap(PasskeyStep(json: #"{"step":"qr","request":"get","rp_id":"example.com","origin":"https://example.com","qr":"FIDO:/0123456789","visibility":"visible"}"#))
        XCTAssertEqual(step.pageVisibility, "visible")
        let line = step.firstStepLogLine(request: 7, tab: 3)
        XCTAssertEqual(line, "passkey request 7 of tab 3: first step qr (get), page visible")
        XCTAssertFalse(line.contains("example.com") || line.contains("FIDO"), "no address and no code in the log")
        // An engine before the key, and a word that is not the ABI's.
        let old = try XCTUnwrap(PasskeyStep(json: #"{"step":"pin_setup","request":"create","rp_id":"example.com"}"#))
        XCTAssertEqual(old.firstStepLogLine(request: 1, tab: 2),
                       "passkey request 1 of tab 2: first step pin_setup (create), page visibility not reported by this engine")
        XCTAssertEqual(PasskeyStep(json: #"{"step":"choose","visibility":"https://example.com/"}"#)?.pageVisibility, "")
        for name in ["choose", "confirm", "security_key", "qr", "phone_connecting", "phone_connected", "phone_error", "bluetooth_off",
                     "bluetooth_denied", "private_notice", "pin", "pin_setup", "pin_change", "touch_again", "fingerprint_enroll",
                     "verify_again", "account", "create_this_mac", "system", "hidden", "error_timeout", "error_no_passkeys"] {
            XCTAssertEqual(PasskeyStep.Kind(name: name).logName, name)
        }
        XCTAssertEqual(PasskeyStep.Kind(name: "a_later_step").logName, "unsupported")
    }

    func testARefusalForAPageNobodySeesBecomesOneLogLine() throws {
        let start = try XCTUnwrap(PasskeyRefusal(json: #"{"refused":"not_visible","at":"focus_check","visibility":"occluded"}"#))
        XCTAssertEqual(start, PasskeyRefusal(place: .focusCheck, visibility: "occluded"))
        XCTAssertEqual(start.logLine(request: 0, tab: 5),
                       "passkey request of tab 5 refused: its page is not visible (occluded), at Chromium's focus check")
        XCTAssertEqual(start.logLine(request: 0, tab: 0),
                       "passkey request of a page that is no tab refused: its page is not visible (occluded), at Chromium's focus check")
        let late = try XCTUnwrap(PasskeyRefusal(json: #"{"refused":"not_visible","at":"first_step","visibility":"hidden","request":"get","step":"qr"}"#))
        XCTAssertEqual(late.logLine(request: 9, tab: 5),
                       "passkey request 9 of tab 5 refused: its page is not visible (hidden), at its first step (get, qr)")
        // Only the ABI's words reach the log.
        let odd = try XCTUnwrap(PasskeyRefusal(json: #"{"refused":"not_visible","at":"first_step","visibility":"https://example.com","request":"<b>","step":"Insert Key!"}"#))
        XCTAssertEqual(odd.logLine(request: 2, tab: 1), "passkey request 2 of tab 1 refused: its page is not visible (state not reported), at its first step")
    }

    /// A request whose sheet was open, cancelled because its page went out of sight and a visible page asked.
    func testARequestCancelledForAVisiblePagesRequestHasItsLogLine() throws {
        let json = #"{"refused":"not_visible","at":"newer_request","visibility":"hidden","request":"get","step":"qr","by_tab":"9"}"#
        let cancelled = try XCTUnwrap(PasskeyRefusal(json: json))
        XCTAssertEqual(cancelled, PasskeyRefusal(place: .newerRequest, visibility: "hidden", request: "get", step: "qr", byTab: 9))
        XCTAssertEqual(cancelled.logLine(request: 4, tab: 5),
                       "passkey request 4 of tab 5 cancelled: its page is not visible (hidden) and tab 9, which is visible, asked (get, qr)")
        // Only a number names the other tab.
        let odd = try XCTUnwrap(PasskeyRefusal(json: #"{"refused":"not_visible","at":"newer_request","visibility":"occluded","by_tab":"https://example.com"}"#))
        XCTAssertEqual(odd.logLine(request: 4, tab: 5),
                       "passkey request 4 of tab 5 cancelled: its page is not visible (occluded) and a visible page asked")
    }

    /// A hidden page that asks in a loop: a tab's first refusal has its line, the rest are counted.
    func testRefusalsOfOneTabAreOneLineAndThenCounts() throws {
        var log = PasskeyRefusalLog()
        let refusal = try XCTUnwrap(PasskeyRefusal(json: #"{"refused":"not_visible","at":"focus_check","visibility":"hidden"}"#))
        var lines: [Int: String] = [:]
        for call in 1...1000 {
            lines[call] = log.note(refusal, request: 0, tab: 5)
        }
        XCTAssertEqual(lines.keys.sorted(), [1, 10, 100, 1000])
        XCTAssertEqual(lines[1], refusal.logLine(request: 0, tab: 5))
        XCTAssertEqual(lines[10], "passkey requests of tab 5 refused, their page not visible: 10 so far")
        XCTAssertEqual(lines[1000], "passkey requests of tab 5 refused, their page not visible: 1000 so far")
        // Another tab has its own first line, and so has a page that is no tab.
        XCTAssertEqual(log.note(refusal, request: 0, tab: 6), refusal.logLine(request: 0, tab: 6))
        XCTAssertEqual(log.note(refusal, request: 0, tab: 0), refusal.logLine(request: 0, tab: 0))
        XCTAssertNil(log.note(refusal, request: 0, tab: 6))
        for _ in 2...9 { XCTAssertNil(log.note(refusal, request: 0, tab: 0)) }
        XCTAssertEqual(log.note(refusal, request: 0, tab: 0), "passkey requests of pages that are no tab refused, their page not visible: 10 so far")
        XCTAssertNil(log.note(refusal, request: 0, tab: 5), "the 1001st")

        // A cancelled request is counted apart from the refused ones.
        let cancelled = PasskeyRefusal(place: .newerRequest, visibility: "hidden", request: "get", step: "qr", byTab: 6)
        XCTAssertEqual(log.note(cancelled, request: 7, tab: 5), cancelled.logLine(request: 7, tab: 5))
        XCTAssertNil(log.note(cancelled, request: 8, tab: 5))

        // The tab closes: what was counted since its last line, once, and a later tab starts again.
        XCTAssertEqual(log.tabClosed(5), ["passkey requests of tab 5 refused, their page not visible: 1001 in all, the tab has closed",
                                          "passkey requests of tab 5 cancelled when a visible page asked, their page not visible: 2 in all, the tab has closed"])
        XCTAssertEqual(log.tabClosed(5), [])
        XCTAssertEqual(log.tabClosed(6), ["passkey requests of tab 6 refused, their page not visible: 2 in all, the tab has closed"])
        XCTAssertEqual(log.note(refusal, request: 0, tab: 5), refusal.logLine(request: 0, tab: 5))
        XCTAssertEqual(log.tabClosed(5), [], "its one refusal has its line")
        XCTAssertEqual(log.tabClosed(7), [], "a tab that was never refused")
    }

    func testTheCountLinesOfRefusalsFallOnPowersOfTen() {
        XCTAssertEqual((1...100_000).filter(PasskeyRefusalLog.hasOwnLine), [1, 10, 100, 1000, 10_000, 100_000])
    }

    func testAnOrdinaryEndIsNoRefusal() {
        XCTAssertNil(PasskeyRefusal(json: "{}"))
        XCTAssertNil(PasskeyRefusal(json: #"{"refused":"a_later_reason","at":"focus_check","visibility":"hidden"}"#))
        XCTAssertNil(PasskeyRefusal(json: #"{"refused":"not_visible","at":"somewhere_new","visibility":"hidden"}"#))
        XCTAssertNil(PasskeyRefusal(json: "not json"))
    }

    /// Addendum 3: a visible page starting and aborting requests in a loop writes its
    /// first-step line once, then counts.
    func testFirstStepLinesAreLimitedPerTab() {
        var log = PasskeyFirstStepLog()
        let written = (1...150).compactMap { log.note("passkey request \($0) of tab 4: first step qr (get), page visible", tab: 4) }
        XCTAssertEqual(written.count, 3, "the first line, then the 10th and the 100th")
        XCTAssertEqual(written[0], "passkey request 1 of tab 4: first step qr (get), page visible")
        XCTAssertEqual(written[2], "passkey requests of tab 4 reached their first step: 100 so far")
        XCTAssertEqual(log.tabClosed(4), "passkey requests of tab 4 reached their first step: 150 in all, the tab has closed")
        XCTAssertNil(log.tabClosed(4), "the count went with the tab")
        XCTAssertEqual(log.note("line", tab: 5), "line", "another tab has its own first line")
    }
}

