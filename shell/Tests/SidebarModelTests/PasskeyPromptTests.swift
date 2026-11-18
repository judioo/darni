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
        XCTAssertEqual(step.title, "Sign in to login.microsoft.com")
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
        XCTAssertTrue(busy.message.contains("for ada@example.com at example.com"))
        XCTAssertTrue(busy.message.contains("does not sync"))
    }

    func testTheSiteIsTheRelyingPartyElseThePagesHost() throws {
        XCTAssertEqual(PasskeyStep(json: #"{"step":"choose","rp_id":"example.com","origin":"https://login.example.com"}"#)?.site, "example.com")
        XCTAssertEqual(PasskeyStep(json: #"{"step":"choose","origin":"https://login.example.com"}"#)?.site, "login.example.com")
    }
}
