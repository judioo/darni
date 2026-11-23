import XCTest
@testable import SidebarModel

/// Screen sharing's values (engine ABI 1.70 `display_capture`): the request
/// as the engine words it, the answer, the outcome and the record of what is
/// shared now.
final class ScreenShareTests: XCTestCase {
    // MARK: The request

    func testARequestIsReadFromTheEnginesJSON() throws {
        let json = """
        {"origin":"https://meet.google.com","top_origin":"https://meet.google.com","profile_id":"3","content_generation":"1",
         "audio":true,"current_tab":true,"window":true,"screen":true,"tab_audio":true,"window_audio":false,"screen_audio":true,
         "prefer":"screen","system_picker":true,"screen_recording_permission":"not_needed","a_key_of_tomorrow":42}
        """
        let request = try XCTUnwrap(ScreenShareRequest(json: json))
        XCTAssertEqual(request.site, "meet.google.com")
        XCTAssertEqual(request.title, "Share with meet.google.com")
        XCTAssertNil(request.frameNote)
        XCTAssertTrue(request.isFromWebPage && request.wantsAudio && request.allowsCurrentTab)
        XCTAssertTrue(request.offers(.tab) && request.offers(.window) && request.offers(.screen))
        XCTAssertTrue(request.offersAudio(for: .tab) && request.offersAudio(for: .screen))
        XCTAssertFalse(request.offersAudio(for: .window))
        XCTAssertEqual(request.preference, .screen)
        XCTAssertEqual(request.initialKind, .screen, "the page's preference opens the sheet on that kind")
        XCTAssertFalse(request.needsScreenRecordingPermission)
    }

    func testWhatTheEngineDoesNotSayIsReadConservatively() throws {
        let request = try XCTUnwrap(ScreenShareRequest(json: #"{"origin":"https://a.example"}"#))
        XCTAssertFalse(request.allowsCurrentTab, "an unsaid current_tab is the page excluding itself")
        XCTAssertFalse(request.offersWindow || request.offersScreen || request.wantsAudio)
        XCTAssertEqual(request.screenRecording, .missing)
        XCTAssertFalse(request.needsScreenRecordingPermission, "nothing to explain when no window or screen is offered")
        XCTAssertEqual(request.initialKind, .tab)
        XCTAssertNil(ScreenShareRequest(json: "{}"), "no origin, no request")
        XCTAssertNil(ScreenShareRequest(json: "not json"))
        XCTAssertNil(ScreenShareRequest(json: #"{"origin":""}"#))
    }

    func testOnlyAWebPageGetsTheSheet() {
        XCTAssertTrue(ScreenShareRequest(origin: "https://a.example").isFromWebPage)
        XCTAssertTrue(ScreenShareRequest(origin: "http://127.0.0.1:8080").isFromWebPage)
        XCTAssertFalse(ScreenShareRequest(origin: "chrome-extension://abcdefghijklmnopabcdefghijklmnop").isFromWebPage)
        XCTAssertFalse(ScreenShareRequest(origin: "chrome://settings").isFromWebPage)
        XCTAssertFalse(ScreenShareRequest(origin: "null").isFromWebPage)
    }

    func testAFrameOfAnotherSiteIsNamedWithThePageItSitsIn() {
        let request = ScreenShareRequest(origin: "https://widget.example", topOrigin: "https://news.example")
        XCTAssertEqual(request.site, "widget.example")
        XCTAssertEqual(request.embeddingSite, "news.example")
        XCTAssertEqual(request.frameNote, "widget.example is a frame inside news.example.")
        XCTAssertEqual(ScreenShareRequest(origin: "http://127.0.0.1:8123").site, "127.0.0.1:8123", "a port is part of who asks")
    }

    func testAPageThatAskedForItsOwnTabIsSaidSo() {
        let asked = ScreenShareRequest(origin: "https://slides.example", preference: .currentTab)
        XCTAssertEqual(asked.preferenceNote, "slides.example asked to share its own tab.")
        XCTAssertNil(ScreenShareRequest(origin: "https://slides.example", preference: .tab).preferenceNote)
        XCTAssertNil(ScreenShareRequest(origin: "https://slides.example").preferenceNote)
        XCTAssertNil(ScreenShareRequest(origin: "https://slides.example", allowsCurrentTab: false, preference: .currentTab).preferenceNote,
                     "a page cannot ask for its own tab and exclude it")
    }

    func testOnlyATabsOwnSoundStartsTicked() {
        let request = ScreenShareRequest(origin: "https://a.example", wantsAudio: true, tabAudio: true, windowAudio: true, screenAudio: true)
        XCTAssertTrue(request.audioDefault(for: .tab))
        XCTAssertFalse(request.audioDefault(for: .screen), "the whole Mac's sound is never shared without a tick")
        XCTAssertFalse(request.audioDefault(for: .window))
        XCTAssertFalse(ScreenShareRequest(origin: "https://a.example").audioDefault(for: .tab), "no sound asked, none offered")
    }

    func testWithoutScreenRecordingOnMacOS14AWindowOrScreenIsExplainedNotOffered() {
        let request = ScreenShareRequest(origin: "https://a.example", preference: .screen, screenRecording: .missing)
        XCTAssertTrue(request.needsScreenRecordingPermission)
        XCTAssertEqual(request.initialKind, .tab, "the sheet opens on what works")
        XCTAssertFalse(ScreenShareRequest(origin: "https://a.example", screenRecording: .granted).needsScreenRecordingPermission)
        XCTAssertFalse(ScreenShareText.permissionBody.isEmpty || ScreenShareText.openSettings.isEmpty)
    }

    func testAPreferenceForSomethingNotOfferedFallsBackToATab() {
        XCTAssertEqual(ScreenShareRequest(origin: "https://a.example", offersScreen: false, preference: .screen).initialKind, .tab)
        XCTAssertEqual(ScreenShareRequest(origin: "https://a.example", preference: .window).initialKind, .window)
        XCTAssertEqual(ScreenShareRequest(origin: "https://a.example", preference: .currentTab).initialKind, .tab)
    }

    // MARK: The answer

    func testAnAnswerBecomesTheEnginesNumbers() {
        XCTAssertTrue(ScreenShareChoice.cancel.engineValues == (0, 0, false))
        XCTAssertTrue(ScreenShareChoice.tab(41, audio: true).engineValues == (1, 41, true))
        XCTAssertTrue(ScreenShareChoice.window(audio: false).engineValues == (2, 0, false))
        XCTAssertTrue(ScreenShareChoice.screen(audio: true).engineValues == (3, 0, true))
        XCTAssertEqual(ScreenShareChoice.tab(41, audio: true).kind, .tab)
        XCTAssertNil(ScreenShareChoice.cancel.kind)
        XCTAssertEqual(ScreenShareChoice.screen(audio: true).logName, "screen with sound")
    }

    // MARK: The outcome

    func testAnOutcomeIsReadFromTheEnginesJSON() {
        XCTAssertEqual(ScreenShareOutcome(json: #"{"outcome":"shared","kind":"tab","target_tab":"12","audio":true}"#),
                       .shared(.tab, targetTab: 12, audio: true))
        XCTAssertEqual(ScreenShareOutcome(json: #"{"outcome":"shared","kind":"screen","audio":false}"#),
                       .shared(.screen, targetTab: nil, audio: false))
        XCTAssertEqual(ScreenShareOutcome(json: #"{"outcome":"cancelled"}"#), .cancelled)
        XCTAssertEqual(ScreenShareOutcome(json: #"{"outcome":"failed"}"#), .failed)
        XCTAssertEqual(ScreenShareOutcome(json: #"{"outcome":"withdrawn"}"#), .withdrawn)
    }

    func testAnOutcomeThatCannotBeReadIsNeverAShare() {
        XCTAssertEqual(ScreenShareOutcome(json: ""), .withdrawn)
        XCTAssertEqual(ScreenShareOutcome(json: #"{"outcome":"something new"}"#), .withdrawn)
        XCTAssertEqual(ScreenShareOutcome(json: #"{"outcome":"shared","kind":"hologram"}"#), .withdrawn)
        XCTAssertEqual(ScreenShareOutcome(json: #"{"outcome":"shared"}"#), .withdrawn)
    }

    // MARK: What is shared now

    func testAChoiceShowsOnlyWhileTheStreamIsLive() {
        var ledger = ScreenShareLedger<String>()
        ledger.noteChosen(ScreenShare(kind: .screen), by: "meet")
        XCTAssertTrue(ledger.isEmpty, "chosen, but nothing leaves the Mac yet")
        XCTAssertEqual(ledger.shares(of: "meet"), [])

        ledger.captureChanged("meet", isCapturingDisplay: true)
        XCTAssertEqual(ledger.capturers, ["meet"])
        XCTAssertEqual(ledger.shares(of: "meet"), [ScreenShare(kind: .screen)])
        XCTAssertEqual(ledger.summary(of: "meet") { _ in nil }, "your screen")

        ledger.captureChanged("meet", isCapturingDisplay: false)
        XCTAssertTrue(ledger.isEmpty)
        ledger.captureChanged("meet", isCapturingDisplay: true)
        XCTAssertEqual(ledger.shares(of: "meet"), [], "the old choice ended with its stream")
    }

    func testALiveStreamWithNoRecordedChoiceStillShows() {
        var ledger = ScreenShareLedger<String>()
        ledger.captureChanged("page", isCapturingDisplay: true)
        XCTAssertTrue(ledger.isSharing("page"), "the indicator is never missing while a page captures")
        XCTAssertEqual(ledger.summary(of: "page") { _ in nil }, "your screen or a window")
    }

    func testTheSummaryNamesWhatIsShared() {
        var ledger = ScreenShareLedger<String>()
        ledger.captureChanged("meet", isCapturingDisplay: true)
        ledger.noteChosen(ScreenShare(kind: .tab, target: "docs"), by: "meet")
        XCTAssertEqual(ledger.summary(of: "meet") { $0 == "docs" ? "Quarterly plan" : nil }, "“Quarterly plan”")
        XCTAssertEqual(ledger.summary(of: "meet") { _ in nil }, "a tab")
        XCTAssertEqual(ledger.capturers(of: "docs"), ["meet"])
        XCTAssertEqual(ledger.capturers(of: "meet"), [])

        ledger.noteChosen(ScreenShare(kind: .window), by: "meet")
        XCTAssertEqual(ledger.summary(of: "meet") { _ in nil }, "2 things")

        var own = ScreenShareLedger<String>()
        own.captureChanged("slides", isCapturingDisplay: true)
        own.noteChosen(ScreenShare(kind: .tab, target: "slides"), by: "slides")
        XCTAssertEqual(own.summary(of: "slides") { _ in "Slides" }, "this tab")
        own.noteChosen(ScreenShare(kind: .window), by: "other")
        XCTAssertEqual(own.shares(of: "other"), [], "another tab's unanswered stream shows nothing")
    }

    func testAClosedTabIsForgottenAsSharerAndAsShared() {
        var ledger = ScreenShareLedger<String>()
        ledger.captureChanged("meet", isCapturingDisplay: true)
        ledger.noteChosen(ScreenShare(kind: .tab, target: "docs"), by: "meet")
        ledger.forget("docs")
        XCTAssertEqual(ledger.capturers(of: "docs"), [])
        XCTAssertEqual(ledger.summary(of: "meet") { _ in "gone" }, "a tab", "the share stays until the engine says its stream ended")
        ledger.forget("meet")
        XCTAssertTrue(ledger.isEmpty)
        XCTAssertEqual(ledger, ScreenShareLedger<String>())
    }

    func testTheBarsWords() {
        XCTAssertEqual(ScreenShareText.capturerLine(summary: "your screen", site: "meet.google.com"), "Sharing your screen with meet.google.com")
        XCTAssertEqual(ScreenShareText.capturedLine(site: "meet.google.com"), "meet.google.com is sharing this tab")
        XCTAssertEqual(ScreenShareText.stop, "Stop Sharing")
    }
}
