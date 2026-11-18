import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// The shell side of the engine's site permission state (ABI 1.67) and of a
/// passkey request's steps (ABI 1.68): the model that asks the engine, and
/// the page's sheet state.
final class PasskeysAndSiteAccessShellTests: XCTestCase {
    // MARK: Capabilities

    func testBothFeaturesNeedTheirMinorAndTheirName() {
        let all: (String) -> Bool = { _ in true }
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 66, hasFeature: all).sitePermissions)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 67, hasFeature: all).sitePermissions)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 67, hasFeature: all).passkeyPrompts)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 68, hasFeature: all).passkeyPrompts)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 68, hasFeature: { $0 != "site_permissions" }).sitePermissions)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 68, hasFeature: { $0 != "webauthn_prompts" }).passkeyPrompts)
        XCTAssertFalse(ChromiumCapabilities.none.sitePermissions || ChromiumCapabilities.none.passkeyPrompts)
    }

    // MARK: Site access

    /// An engine that answers when the test says so.
    private final class FakeSiteEngine {
        var answer: SiteAccess?
        var pending: [(SiteAccess?) -> Void] = []
        var sets: [String] = []
        var revokes: [String] = []
        var accepts = true

        func attach(to model: SiteAccessModel) {
            model.fetch = { [unowned self] receive in pending.append(receive) }
            model.setPermission = { [unowned self] origin, type, setting in
                sets.append("\(origin) \(type) \(setting)")
                return accepts
            }
            model.revokeDevice = { [unowned self] origin, kind, key in
                revokes.append("\(origin) \(kind) \(key)")
                return accepts
            }
        }

        func deliver() {
            let waiting = pending
            pending = []
            waiting.forEach { $0(answer) }
        }
    }

    private let camera = SiteAccess.Permission(type: "media-stream-camera", setting: .allow)

    func testAModelWithoutAnEngineReportsNothing() {
        let model = SiteAccessModel()
        XCTAssertFalse(model.isAvailable)
        model.refresh()
        model.documentChanged()
        XCTAssertNil(model.access)
        let row = SiteControlCenter.siteAccessRows(SiteAccess(origin: "https://a.example", permissions: [camera]))[0]
        XCTAssertFalse(model.perform(.block, on: row))
    }

    func testRefreshAsksOnceAndOnceMoreForWhatChangedMeanwhile() {
        let engine = FakeSiteEngine()
        let model = SiteAccessModel()
        engine.attach(to: model)
        XCTAssertTrue(model.isAvailable)
        engine.answer = SiteAccess(origin: "https://a.example", permissions: [camera])
        model.refresh()
        model.refresh()
        model.refresh()
        XCTAssertEqual(engine.pending.count, 1, "one request is out; the others wait for it")
        engine.answer = SiteAccess(origin: "https://a.example", permissions: [camera], inUse: ["camera"])
        engine.deliver()
        XCTAssertEqual(engine.pending.count, 1, "asked once more, for the state after the last change")
        engine.deliver()
        XCTAssertEqual(model.access?.inUse, ["camera"])
        XCTAssertEqual(engine.pending.count, 0)
        XCTAssertEqual(model.answers, 2)
    }

    func testAChangeGoesToTheEngineWithTheSiteTheRowWasShownFor() throws {
        let engine = FakeSiteEngine()
        let model = SiteAccessModel()
        engine.attach(to: model)
        let usb = SiteAccess.Device(kind: "usb", key: "1050;0407;A1", name: "YubiKey")
        engine.answer = SiteAccess(origin: "https://a.example", permissions: [camera], devices: [usb])
        model.refresh()
        engine.deliver()
        let rows = SiteControlCenter.siteAccessRows(try XCTUnwrap(model.access))
        XCTAssertFalse(model.needsReload)

        XCTAssertTrue(model.perform(.block, on: rows[0]))
        XCTAssertTrue(model.perform(.allow, on: rows[0]))
        XCTAssertTrue(model.perform(.reset, on: rows[0]))
        XCTAssertEqual(engine.sets, ["https://a.example media-stream-camera 2", "https://a.example media-stream-camera 1",
                                     "https://a.example media-stream-camera 0"])
        XCTAssertTrue(model.perform(.removeDevice, on: rows[1]))
        XCTAssertEqual(engine.revokes, ["https://a.example usb 1050;0407;A1"])
        XCTAssertTrue(model.needsReload, "the loaded page may keep what it had")
        XCTAssertEqual(engine.pending.count, 1, "and the engine is asked what holds now")

        // Actions that are not the row's do nothing.
        XCTAssertFalse(model.perform(.removeDevice, on: rows[0]))
        XCTAssertFalse(model.perform(.allow, on: rows[1]))
        XCTAssertFalse(model.perform(.reloadPage, on: SiteControlCenter.reloadToApplyRow))
        XCTAssertEqual(engine.sets.count, 3)

        // A new document: the change has taken effect.
        model.documentChanged()
        XCTAssertFalse(model.needsReload)
    }

    func testARefusedChangeAsksForNoReload() throws {
        let engine = FakeSiteEngine()
        let model = SiteAccessModel()
        engine.attach(to: model)
        engine.answer = SiteAccess(origin: "https://a.example", permissions: [camera])
        model.refresh()
        engine.deliver()
        engine.accepts = false // the page moved to another site meanwhile: invalid_state
        let row = SiteControlCenter.siteAccessRows(try XCTUnwrap(model.access))[0]
        XCTAssertFalse(model.perform(.block, on: row))
        XCTAssertFalse(model.needsReload)
        XCTAssertEqual(engine.pending.count, 1, "the row shows what really holds")
    }

    func testAClosedTabHoldsNothing() {
        let engine = FakeSiteEngine()
        let model = SiteAccessModel()
        engine.attach(to: model)
        engine.answer = SiteAccess(origin: "https://a.example", permissions: [camera])
        model.refresh()
        engine.deliver()
        model.clear()
        XCTAssertNil(model.access)
    }

    // MARK: The passkey sheet

    private func step(_ json: String) -> PasskeyStep { PasskeyStep(json: json)! }

    func testARequestOpensTheSheetAndItsStepsReplaceEachOther() {
        let prompts = PagePromptCenter()
        var answers: [PasskeyAction] = []
        XCTAssertFalse(prompts.hasPendingPrompt)
        prompts.presentPasskey(id: 7, step: step(#"{"step":"choose","rp_id":"example.com","mechanisms":[{"index":0,"kind":"phone"}]}"#)) {
            answers.append($0)
        }
        XCTAssertTrue(prompts.passkeySheetShown && prompts.hasPendingPrompt && prompts.permissionCovered)
        prompts.answerPasskey(.chooseMechanism(0))
        XCTAssertEqual(answers, [.chooseMechanism(0)])
        XCTAssertEqual(prompts.passkey?.step.kind, .choose, "the sheet stays until the engine sends the next step")

        prompts.presentPasskey(id: 7, step: step(#"{"step":"qr","qr":"FIDO:/123"}"#)) { answers.append($0) }
        XCTAssertEqual(prompts.passkey?.step.kind, .qr)
        // macOS shows its own prompt: the request stays, the sheet goes.
        prompts.presentPasskey(id: 7, step: step(#"{"step":"system"}"#)) { answers.append($0) }
        XCTAssertFalse(prompts.passkeySheetShown)
        XCTAssertTrue(prompts.hasPendingPrompt)

        prompts.endPasskey(id: 7)
        XCTAssertNil(prompts.passkey)
        XCTAssertEqual(answers, [.chooseMechanism(0)], "the end of a request needs no reply")
        XCTAssertEqual(prompts.answered["passkey"], 1)
    }

    func testCancelClosesTheSheetAtOnceAndTheEndThatFollowsIsIgnored() {
        let prompts = PagePromptCenter()
        var answers: [PasskeyAction] = []
        prompts.presentPasskey(id: 3, step: step(#"{"step":"security_key"}"#)) { answers.append($0) }
        prompts.answerPasskey(.cancel)
        XCTAssertNil(prompts.passkey)
        XCTAssertEqual(answers, [.cancel])
        prompts.endPasskey(id: 3)
        prompts.answerPasskey(.cancel)
        XCTAssertEqual(answers, [.cancel], "one answer")
    }

    func testThePinIsCheckedSentOnceAndForgotten() {
        let prompts = PagePromptCenter()
        var answers: [PasskeyAction] = []
        let setUp = step(#"{"step":"pin_setup","pin":{"min_length":4,"error":"none"}}"#)
        prompts.presentPasskey(id: 1, step: setUp) { answers.append($0) }
        prompts.passkeyPin = "1234"
        prompts.passkeyPinConfirmation = "1243"
        prompts.submitPasskeyPin()
        XCTAssertEqual(prompts.passkeyPinProblem, "The two PINs do not match.")
        XCTAssertTrue(answers.isEmpty)
        // The same step drawn again keeps what is typed.
        prompts.presentPasskey(id: 1, step: setUp) { answers.append($0) }
        XCTAssertEqual(prompts.passkeyPin, "1234")

        prompts.passkeyPinConfirmation = "1234"
        prompts.submitPasskeyPin()
        XCTAssertEqual(answers, [.pin("1234")])
        XCTAssertEqual(prompts.passkeyPin, "")
        XCTAssertEqual(prompts.passkeyPinConfirmation, "")
        XCTAssertNil(prompts.passkeyPinProblem)

        // The key refuses it: the step comes again with its complaint, and with empty fields.
        prompts.passkeyPin = "typed too early"
        prompts.presentPasskey(id: 1, step: step(#"{"step":"pin_setup","pin":{"min_length":6,"error":"too_short"}}"#)) { answers.append($0) }
        XCTAssertEqual(prompts.passkeyPin, "")
        // Nothing is sent while the engine works.
        prompts.presentPasskey(id: 1, step: step(#"{"step":"pin","busy":true,"pin":{"error":"none"}}"#)) { answers.append($0) }
        prompts.passkeyPin = "123456"
        prompts.submitPasskeyPin()
        XCTAssertEqual(answers.count, 1)
    }

    func testASecondRequestTakesTheSheetAndTheFirstIsCancelled() {
        let prompts = PagePromptCenter()
        var first: [PasskeyAction] = [], second: [PasskeyAction] = []
        prompts.presentPasskey(id: 1, step: step(#"{"step":"pin","pin":{"error":"none"}}"#)) { first.append($0) }
        prompts.passkeyPin = "0000"
        prompts.presentPasskey(id: 2, step: step(#"{"step":"choose"}"#)) { second.append($0) }
        XCTAssertEqual(first, [.cancel])
        XCTAssertEqual(prompts.passkey?.id, 2)
        XCTAssertEqual(prompts.passkeyPin, "", "a PIN typed for one request never reaches another")
        prompts.endPasskey(id: 1)
        XCTAssertEqual(prompts.passkey?.id, 2, "the first request's end does not close the second's sheet")
        XCTAssertTrue(second.isEmpty)
    }

    func testAPageThatGoesAnswersOrWithdrawsTheRequest() {
        let prompts = PagePromptCenter()
        var answers: [PasskeyAction] = []
        prompts.presentPasskey(id: 1, step: step(#"{"step":"qr","qr":"FIDO:/1"}"#)) { answers.append($0) }
        prompts.answerAllConservatively()
        XCTAssertEqual(answers, [.cancel])
        XCTAssertNil(prompts.passkey)

        prompts.presentPasskey(id: 2, step: step(#"{"step":"pin","pin":{"error":"none"}}"#)) { answers.append($0) }
        prompts.passkeyPin = "9999"
        prompts.withdrawAll()
        XCTAssertNil(prompts.passkey)
        XCTAssertEqual(prompts.passkeyPin, "")
        XCTAssertEqual(answers, [.cancel], "the engine retired the request itself: no reply")
    }

    func testTheQRCodeIsDrawnFromTheEnginesText() throws {
        let image = try XCTUnwrap(PasskeyQRCode.image(for: "FIDO:/13086400838107303667332719012595115747821895775708323189557153075146383351399743589971313508078026948312026786722471666005727649643501784024544726574771401798171307406596245"))
        XCTAssertEqual(image.size.width, image.size.height)
        // 21 modules is the smallest code there is; this text needs more.
        XCTAssertGreaterThan(image.size.width, 30, "one point per module, and a long text makes many")
        XCTAssertNil(PasskeyQRCode.image(for: ""))
    }
}
